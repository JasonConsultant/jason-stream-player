import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jason_stream_player/core/secret_store.dart';
import 'package:jason_stream_player/core/security.dart';
import 'package:jason_stream_player/data/emby/emby_client.dart';
import 'package:jason_stream_player/data/emby/emby_mapper.dart';
import 'package:jason_stream_player/data/emby/emby_playback.dart';
import 'package:jason_stream_player/data/list_cache.dart';
import 'package:jason_stream_player/data/storage.dart';
import 'package:jason_stream_player/l10n/strings.dart';
import 'package:jason_stream_player/models/models.dart';
import 'package:jason_stream_player/state/discover.dart';
import 'package:jason_stream_player/state/emby.dart';
import 'package:jason_stream_player/state/profile_mode.dart';
import 'package:jason_stream_player/state/providers.dart';
import 'package:jason_stream_player/state/vod_library.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/fake_emby.dart';

const _dev = EmbyDevice(name: 'NVIDIA SHIELD', id: 'jsp-test-device', version: '1.6.0');

/// Zählt, was verschlüsselt wurde.
class _CountingStore extends PreviewSecretStore {
  final plain = <String>[];
  @override
  Future<String> encrypt(String plain) {
    this.plain.add(plain);
    return super.encrypt(plain);
  }
}

void main() {
  late FakeEmby server;
  late Directory tmp;

  setUpAll(() async {
    L10n.lang = 'de';
    tmp = await Directory.systemTemp.createTemp('emby_cache');
    ListCache.debugDirectory = tmp.path;
  });

  tearDownAll(() async {
    ListCache.debugDirectory = null;
    await tmp.delete(recursive: true);
  });

  setUp(() async {
    server = FakeEmby();
    await server.start();
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() => server.stop());

  EmbyClient client({bool signedIn = true}) => EmbyClient(server.base,
      device: _dev,
      token: signedIn ? FakeEmby.token : null,
      userId: signedIn ? FakeEmby.userId : null);

  Future<(ProviderContainer, Storage)> container(
      {bool signIn = true, SecretStore? store}) async {
    final st = await Storage.open(store: store ?? PreviewSecretStore());
    final c = ProviderContainer(overrides: [
      storageProvider.overrideWith((ref) async => st),
    ]);
    addTearDown(c.dispose);
    await c.read(storageProvider.future);
    if (signIn) {
      await c
          .read(embyAccountProvider.notifier)
          .signIn(server.base, FakeEmby.user, FakeEmby.password);
    }
    return (c, st);
  }

  group('Adresse und Kopfzeilen', () {
    test('normalizeServer', () {
      expect(EmbyClient.normalizeServer('192.168.1.10:8096'),
          'http://192.168.1.10:8096');
      expect(EmbyClient.normalizeServer('https://emby.example.org/emby/'),
          'https://emby.example.org/emby');
      expect(EmbyClient.normalizeServer('http://nas:8096/web/index.html#!/home'),
          'http://nas:8096');
      expect(EmbyClient.normalizeServer('ftp://nas'), isNull);
      expect(EmbyClient.normalizeServer('  '), isNull);
    });

    test('X-Emby-Authorization, Jellyfin-Variante und Token', () {
      final c = client();
      final h = c.headers;
      expect(h['X-Emby-Authorization'],
          'Emby Client="Jason Stream Player", Device="NVIDIA SHIELD", '
          'DeviceId="jsp-test-device", Version="1.6.0", '
          'Token="${FakeEmby.token}"');
      expect(h['Authorization'], startsWith('MediaBrowser Client="Jason'));
      expect(h['X-Emby-Token'], FakeEmby.token);
      final anon = client(signedIn: false).headers;
      expect(anon.containsKey('X-Emby-Token'), isFalse);
      expect(anon['X-Emby-Authorization'], isNot(contains('Token=')));
    });
  });

  group('Anmeldung', () {
    test('richtiges Passwort → Konto mit Token, Server-Name und Version',
        () async {
      final acc = await client(signedIn: false)
          .authenticate(FakeEmby.user, FakeEmby.password);
      expect(acc.signedIn, isTrue);
      expect(acc.token, FakeEmby.token);
      expect(acc.userId, FakeEmby.userId);
      expect(acc.userName, 'Jason');
      expect(acc.serverName, 'Jasons Mediathek');
      expect(acc.serverVersion, '4.8.10.0');
      expect(acc.jellyfin, isFalse);
      final auth = server.callsTo('/Users/AuthenticateByName').single;
      expect(auth.method, 'POST');
      expect((auth.body as Map)['Username'], FakeEmby.user);
      expect(auth.headers['x-emby-authorization'],
          contains('DeviceId="jsp-test-device"'));
      // Token wird überall ausgeblendet.
      expect(Redactor.redact('x ${FakeEmby.token} y'), 'x ••• y');
    });

    test('falsches Passwort → klare Meldung', () async {
      try {
        await client(signedIn: false).authenticate(FakeEmby.user, 'falsch');
        fail('keine Ausnahme');
      } on EmbyException catch (e) {
        expect(e.kind, EmbyErrorKind.wrongCredentials);
        expect(e.message, 'Benutzername oder Passwort ist falsch.');
      }
    });

    test('Jellyfin wird erkannt', () async {
      server.jellyfin = true;
      final acc = await client(signedIn: false)
          .authenticate(FakeEmby.user, FakeEmby.password);
      expect(acc.jellyfin, isTrue);
    });

    test('kein Emby-Server unter der Adresse', () async {
      final other = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      other.listen((r) {
        r.response.statusCode = 404;
        r.response.close();
      });
      addTearDown(() => other.close(force: true));
      final c = EmbyClient('http://127.0.0.1:${other.port}', device: _dev);
      await expectLater(c.publicInfo(),
          throwsA(isA<EmbyException>().having((e) => e.kind, 'kind', EmbyErrorKind.notEmby)));
    });

    test('Zugang verschlüsselt gespeichert, Abmelden behält Adresse',
        () async {
      final store = _CountingStore();
      final (c, st) = await container(store: store);
      final acc = c.read(embyAccountProvider)!;
      expect(acc.signedIn, isTrue);
      expect(store.plain.any((p) => p.contains(FakeEmby.token)), isTrue);
      final prefs = await SharedPreferences.getInstance();
      for (final k in prefs.getKeys()) {
        expect('${prefs.get(k)}', isNot(contains(FakeEmby.token)), reason: k);
        expect('${prefs.get(k)}', isNot(contains(FakeEmby.password)), reason: k);
      }
      // Neu geöffnet: wieder da.
      final st2 = await Storage.open(store: store);
      expect(st2.embyAccount()!.token, FakeEmby.token);
      await c.read(embyAccountProvider.notifier).signOut();
      expect(server.callsTo('/Sessions/Logout'), hasLength(1));
      final out = c.read(embyAccountProvider)!;
      expect(out.signedIn, isFalse);
      expect(out.server, server.base);
      expect(st.embyAccount()!.token, isNull);
    });

    test('Geräte-Kennung bleibt gleich', () async {
      final st = await Storage.open(store: PreviewSecretStore());
      final a = await st.embyDeviceId();
      expect(a, startsWith('jsp-'));
      expect(await st.embyDeviceId(), a);
    });
  });

  group('Mediatheken und Titel', () {
    test('Seiten zu je 500, Mediatheken nach Typ, Musik übersprungen',
        () async {
      final c = client();
      final movies = await fetchEmbyVod(c, series: false);
      final pages = [
        for (final x in server.callsTo('/Users/u1/Items'))
          if (x.query['ParentId'] == 'v1') x.query['StartIndex']
      ];
      expect(pages, ['0', '500', '1000']);
      expect(
          server.callsTo('/Users/u1/Items').first.query['Limit'], '500');
      expect(server.callsTo('/Users/u1/Items').first.query['Fields'],
          contains('UserData'));
      expect(movies.items, hasLength(1204)); // 1203 + 1 aus „Kinder“
      expect([for (final x in movies.categories) x.name], ['Filme', 'Kinder']);
      expect(
          server.callsTo('/Users/u1/Items').any((x) => x.query['ParentId'] == 'v3'),
          isFalse);
      final series = await fetchEmbyVod(c, series: true);
      expect([for (final x in series.categories) x.name], ['Serien']);
      expect(series.items.map((s) => s.name), ['Dark', 'Babylon Berlin', 'Tatort']);
      expect(series.items.every((s) => s.isSeries && s.isEmby), isTrue);
    });

    test('Abbildung auf VodItem und Bild-Adressen ohne Token', () {
      final c = client();
      final m = EmbyMapper(c).item(FakeEmby.movie(0), categoryId: 'emby_v1');
      expect(m.id, 'emby_m0');
      expect(m.source, VodSource.emby);
      expect(m.name, 'Der Pate');
      expect(m.year, 1972);
      expect(m.rating, 9.2);
      expect(m.genre, 'Drama, Krimi');
      expect(m.cast, 'Marlon Brando, Al Pacino');
      expect(m.director, 'Francis Ford Coppola');
      expect(m.duration, const Duration(minutes: 175));
      expect(m.added!.toUtc(), DateTime.utc(2024, 5, 1, 12));
      expect(m.serverPosition, const Duration(minutes: 60));
      expect(m.serverPlayed, isFalse);
      expect(m.trailer, contains('youtube.com'));
      expect(m.streamUrl, isEmpty);
      expect(m.posterUrl,
          '${server.base}/Items/m0/Images/Primary?maxWidth=400&tag=ptag0&quality=90');
      expect(m.backdropUrl,
          '${server.base}/Items/m0/Images/Backdrop/0?maxWidth=1280&tag=btag0&quality=90');
      expect(m.posterUrl, isNot(contains('api_key')));
      final played = EmbyMapper(c).item(FakeEmby.movie(1), categoryId: 'x');
      expect(played.serverPlayed, isTrue);
      final e = EmbyMapper(c).episode(FakeEmby.episode('s0', 1, 2));
      expect(e.id, 'emby_s0e1x2');
      expect((e.season, e.number, e.title), (1, 2, 'Folge 2'));
      expect(e.serverPosition, const Duration(minutes: 10));
      expect(e.stillUrl, contains('/Items/s0e1x2/Images/Primary'));
    });

    test('Zwischenspeicher: Emby-Felder bleiben, Portal-Listen unverändert',
        () {
      final m = EmbyMapper(client()).item(FakeEmby.movie(1), categoryId: 'c');
      final body = ListCache.vodBody(const [Category(id: 'c', name: 'Filme')], [m]);
      final raw = '{"saved":1,${body.substring(1)}';
      final back = ListCache.debugDecodeVod(raw)!.items.single;
      expect(back.isEmby, isTrue);
      expect(back.serverPlayed, isTrue);
      const portal = VodItem(id: '1', name: 'X', categoryId: 'c', streamUrl: 'u');
      expect(ListCache.vodBody(const [], [portal]), isNot(contains(',1,')));
      final p = ListCache.debugDecodeVod(
              '{"saved":1,${ListCache.vodBody(const [], [portal]).substring(1)}')!
          .items
          .single;
      expect(p.isEmby, isFalse);
    });

    test('Serien-Details: Staffeln sortiert, Folgen je Staffel', () async {
      final (c, st) = await container();
      const s = VodItem(
          id: 'emby_s0',
          name: 'Dark',
          categoryId: 'emby_v2',
          streamUrl: '',
          isSeries: true,
          source: VodSource.emby);
      final d = await c.read(seriesDetailsProvider(s).future);
      expect(d.seasons.keys, [1, 2]);
      expect(d.seasons[1]!.map((e) => e.number), [1, 2, 3]);
      final calls = server.callsTo('/Shows/s0/Episodes');
      expect({for (final x in calls) x.query['SeasonId']}, {'s0_se1', 's0_se2'});
      expect(calls.first.query['UserId'], FakeEmby.userId);
      expect(calls.first.query['Fields'], contains('UserData'));
      // Server-Stand lokal übernommen: Folge 1 gesehen, Folge 2 bei 10 min.
      expect(st.isWatched('ep_emby_s0e1x1'), isTrue);
      expect(st.resume('ep_emby_s0e1x2')!.pos, 600);
    });
  });

  group('Abspielweg', () {
    Map<String, dynamic> info({
      String container = 'mkv',
      int bitrate = 8000000,
      bool direct = true,
      String? transcodingUrl,
    }) {
      final i = server.defaultPlaybackInfo('m0');
      final src = (i['MediaSources'] as List).first as Map<String, dynamic>;
      src['Container'] = container;
      src['Bitrate'] = bitrate;
      src['SupportsDirectPlay'] = direct;
      src['SupportsDirectStream'] = direct;
      if (transcodingUrl != null) src['TranscodingUrl'] = transcodingUrl;
      return i;
    }

    test('Direktwiedergabe der Originaldatei', () {
      final ch = chooseEmbyStream(client(), 'm0', info());
      expect(ch.transcoding, isFalse);
      final u = Uri.parse(ch.url);
      expect(u.path, '/Videos/m0/stream.mkv');
      expect(u.queryParameters['static'], 'true');
      expect(u.queryParameters['MediaSourceId'], 'ms_m0');
      expect(u.queryParameters['api_key'], FakeEmby.token);
      expect(ch.playMethod, 'DirectStream');
      // Direkt: nur externe Untertitel dazu (eingebettete hat die Datei).
      expect(ch.subtitles, hasLength(1));
      expect(ch.subtitles.single.url,
          contains('/Videos/m0/ms_m0/Subtitles/4/Stream.srt'));
      expect(ch.subtitles.single.language, 'eng');
    });

    test('Bitrate über der Grenze → Vorschlag des Servers (HLS)', () {
      final ch = chooseEmbyStream(
          client(),
          'm0',
          info(
              bitrate: 30000000,
              transcodingUrl: '/videos/m0/master.m3u8?MediaSourceId=ms_m0&VideoCodec=h264'),
          maxBitrate: 10000000);
      expect(ch.transcoding, isTrue);
      expect(ch.url, startsWith('${server.base}/videos/m0/master.m3u8?'));
      expect(ch.url, endsWith('api_key=${FakeEmby.token}'));
      // Umgewandelt: Text-Untertitel (auch eingebettete) als SRT.
      expect(ch.subtitles.map((s) => s.language), ['ger', 'eng']);
    });

    test('unbekannter Container / erzwungen → eigene HLS-Adresse mit Tonspur',
        () {
      final ch = chooseEmbyStream(client(), 'm0', info(container: 'xyz'),
          audioPref: 'de');
      expect(ch.transcoding, isTrue);
      final u = Uri.parse(ch.url);
      expect(u.path, '/Videos/m0/master.m3u8');
      expect(u.queryParameters['VideoCodec'], 'h264');
      expect(u.queryParameters['AudioCodec'], 'aac');
      expect(u.queryParameters['AudioStreamIndex'], '2'); // „ger“
      expect(u.queryParameters['api_key'], FakeEmby.token);
      final forced = chooseEmbyStream(client(), 'm0', info(), forceTranscode: true);
      expect(forced.transcoding, isTrue);
      expect(Uri.parse(forced.url).path, '/Videos/m0/master.m3u8');
    });

    test('Bitrate-Einstellung', () {
      expect(embyBitrateOf('auto'), isNull);
      expect(embyBitrateOf('20'), 20000000);
      expect(embyBitrateOf('4'), 4000000);
    });
  });

  group('Fortschritt an den Server', () {
    EmbyPlayback playback({bool allowed = true, Duration? at}) => EmbyPlayback(
          itemId: 'emby_m0',
          client: () async => client(),
          maxBitrate: () => null,
          audioPref: () => 'auto',
          reportAllowed: () => allowed,
          serverPosition: at,
        );

    test('Start, Fortschritt (Pause), Ende mit PositionTicks', () async {
      final pb = playback(at: const Duration(minutes: 60));
      final media = await pb.resolve();
      expect(media.startAt, const Duration(minutes: 60));
      expect(media.transcoding, isFalse);
      final pi = server.callsTo('/Items/m0/PlaybackInfo').single;
      expect(pi.method, 'POST');
      expect(pi.query['UserId'], FakeEmby.userId);
      expect((pi.body as Map)['DeviceProfile'], isA<Map>());
      await pb.started(const Duration(minutes: 60));
      await pb.progress(const Duration(minutes: 61), paused: false);
      await pb.progress(const Duration(minutes: 62), paused: true);
      await pb.stopped(const Duration(minutes: 63));
      await pb.stopped(const Duration(minutes: 63)); // nur einmal
      final start = server.callsTo('/Sessions/Playing').single.body as Map;
      expect(start['ItemId'], 'm0');
      expect(start['MediaSourceId'], 'ms_m0');
      expect(start['PlaySessionId'], 'ps1');
      expect(start['PositionTicks'], ticks(const Duration(minutes: 60)));
      final prog = server.callsTo('/Sessions/Playing/Progress');
      expect(prog, hasLength(2));
      expect((prog[0].body as Map)['IsPaused'], isFalse);
      expect((prog[1].body as Map)['IsPaused'], isTrue);
      expect((prog[1].body as Map)['PositionTicks'], ticks(const Duration(minutes: 62)));
      final stop = server.callsTo('/Sessions/Playing/Stopped');
      expect(stop, hasLength(1));
      expect((stop.single.body as Map)['PositionTicks'],
          ticks(const Duration(minutes: 63)));
    });

    test('Gastmodus: nichts melden', () async {
      final pb = playback(allowed: false);
      await pb.resolve();
      await pb.started(Duration.zero);
      await pb.progress(const Duration(seconds: 10), paused: false);
      await pb.stopped(const Duration(seconds: 20));
      expect(server.calls.where((c) => c.path.startsWith('/Sessions/Playing')),
          isEmpty);
    });

    test('Umwandlung nach gescheiterter Direktwiedergabe', () async {
      final pb = playback();
      expect((await pb.resolve()).transcoding, isFalse);
      final t = await pb.resolve(transcode: true);
      expect(t.transcoding, isTrue);
      expect(t.url, contains('master.m3u8'));
      await pb.started(Duration.zero);
      expect((server.callsTo('/Sessions/Playing').single.body as Map)['PlayMethod'],
          'Transcode');
    });

    test('embyPlaybackFor: Gastmodus und Einstellungen aus dem Speicher',
        () async {
      final (c, st) = await container();
      await st.setOption('embybitrate', '4');
      final pb = embyPlaybackFor(c, 'emby_m0');
      await pb.resolve();
      expect((server.callsTo('/Items/m0/PlaybackInfo').last.body
          as Map)['MaxStreamingBitrate'], 4000000);
      await c.read(profileModeProvider.notifier).setGuest(true);
      await pb.started(Duration.zero);
      expect(server.callsTo('/Sessions/Playing'), isEmpty);
    });
  });

  group('Gesehen und Weiterschauen', () {
    test('Server-Stand übernehmen (Position, gesehen, ungesehen)', () async {
      final st = await Storage.open(store: PreviewSecretStore());
      await syncEmbyState(st, 'movie_emby_m0',
          position: const Duration(minutes: 60),
          played: false,
          total: const Duration(minutes: 175));
      expect(st.resume('movie_emby_m0'), (pos: 3600, total: 10500));
      await syncEmbyState(st, 'movie_emby_m0', played: true);
      expect(st.isWatched('movie_emby_m0'), isTrue);
      expect(st.resume('movie_emby_m0'), isNull);
      await syncEmbyState(st, 'movie_emby_m0', played: false);
      expect(st.isWatched('movie_emby_m0'), isFalse);
    });

    test('Film-Details übernehmen den Server-Stand (Fortsetzen)', () async {
      final (c, st) = await container();
      final m = EmbyMapper(client()).item(FakeEmby.movie(0), categoryId: 'emby_v1');
      final d = await c.read(movieDetailsProvider(m).future);
      expect(d.director, 'Francis Ford Coppola');
      expect(st.resume('movie_emby_m0')!.pos, 3600);
    });

    test('Als gesehen / ungesehen markieren', () async {
      final (c, st) = await container();
      final list = await c.read(embyMoviesProvider.future);
      final m = list.items.firstWhere((x) => x.id == 'emby_m0');
      await setEmbyPlayed(c, m, true);
      expect(server.played, contains('m0'));
      final post = server.callsTo('/Users/u1/PlayedItems/m0').single;
      expect(post.method, 'POST');
      expect(st.isWatched('movie_emby_m0'), isTrue);
      final patched = c
          .read(embyMoviesProvider)
          .value!
          .items
          .firstWhere((x) => x.id == 'emby_m0');
      expect(patched.serverPlayed, isTrue);
      expect(isSeen(st, patched), isTrue);
      await setEmbyPlayed(c, patched, false);
      expect(server.callsTo('/Users/u1/PlayedItems/m0').last.method, 'DELETE');
      expect(st.isWatched('movie_emby_m0'), isFalse);
    });

    test('Startseite: Weiterschauen (Folge → Serie) und Neu hinzugefügt',
        () async {
      final (c, _) = await container();
      final resume = await c.read(embyResumeProvider.future);
      expect(resume.map((m) => m.id), ['emby_m0', 'emby_s0']);
      expect(resume.last.isSeries, isTrue);
      expect(resume.last.name, 'Dark');
      final latest = await c.read(embyLatestProvider.future);
      expect(latest.map((m) => m.id), ['emby_m5', 'emby_s1']);
      // Gastmodus: kein „Weiterschauen“.
      await c.read(profileModeProvider.notifier).setGuest(true);
      expect(await c.read(embyResumeProvider.future), isEmpty);
    });
  });

  group('Unabhängig vom Portal', () {
    test('Portalwechsel lässt Emby-Zugang, Listen und Meine Liste unberührt',
        () async {
      final (c, st) = await container();
      const a = Portal(id: 'pa', name: 'A', type: PortalType.m3u, url: 'http://a/x.m3u');
      const b = Portal(id: 'pb', name: 'B', type: PortalType.m3u, url: 'http://b/x.m3u');
      await st.addPortal(a);
      await st.addPortal(b);
      await c.read(activePortalProvider.notifier).select(a);
      final sub = c.listen(embyMoviesProvider, (_, __) {});
      addTearDown(sub.close);
      final first = await c.read(embyMoviesProvider.future);
      final m = first.items.first;
      await c.read(vodLibraryProvider.future);
      await c.read(vodLibraryProvider.notifier).toggleFavorite(m);
      final requests = server.calls.length;

      await c.read(activePortalProvider.notifier).select(b);
      await c.read(activePortalProvider.future);
      expect(c.read(embyAccountProvider)!.signedIn, isTrue);
      expect(identical(await c.read(embyMoviesProvider.future), first), isTrue);
      expect(server.calls.length, requests);
      final lib = await c.read(vodLibraryProvider.future);
      expect(lib.isFavorite(m), isTrue);
      expect(st.option('vodfav___emby', '[]'), contains('emby_'));
      expect(st.option('vodfav_pb', '[]'), '[]');
    });

    test('Zwischenspeicher: zweiter Start ohne Server-Abruf der Liste',
        () async {
      final (c, _) = await container();
      await c.read(embySeriesProvider.future);
      final n = server.callsTo('/Users/u1/Views').length;
      c.invalidate(embySeriesProvider);
      final again = await c.read(embySeriesProvider.future);
      expect(again.items.map((s) => s.name), ['Dark', 'Babylon Berlin', 'Tatort']);
      expect(server.callsTo('/Users/u1/Views').length, n);
    });
  });

  group('Kinder- und Gastmodus', () {
    test('Kindermodus: nur freigegebene Emby-Mediatheken', () async {
      final (c, st) = await container();
      final sub = c.listen(visibleEmbyMoviesProvider, (_, __) {});
      addTearDown(sub.close);
      await c.read(embyMoviesProvider.future);
      expect(c.read(visibleEmbyMoviesProvider).value!.items, hasLength(1204));
      await st.setPin('1234');
      await c.read(profileModeProvider.notifier).setKids(true);
      expect(c.read(visibleEmbyMoviesProvider).value!.items, isEmpty);
      await c
          .read(profileModeProvider.notifier)
          .setKidsEmby({ProfileMode.vodKey(false, 'emby_v4')});
      final v = c.read(visibleEmbyMoviesProvider).value!;
      expect(v.items.map((m) => m.name), ['Die Sendung mit der Maus']);
      expect(v.categories.map((x) => x.name), ['Kinder']);
      // Freigabe gilt portalunabhängig.
      expect(st.kidsVod(embyScope), {'m:emby_v4'});
      // Startseite: Weiterschauen nur mit freigegebenen Titeln.
      expect(await c.read(embyResumeProvider.future), isEmpty);
    });

    test('Gastmodus: Meine Liste unverändert', () async {
      final (c, st) = await container();
      await c.read(profileModeProvider.notifier).setGuest(true);
      final m = EmbyMapper(client()).item(FakeEmby.movie(3), categoryId: 'x');
      await c.read(vodLibraryProvider.notifier).toggleFavorite(m);
      expect(st.option('vodfav___emby', '[]'), '[]');
    });
  });

  group('Sicherung', () {
    test('Adresse und Benutzer gesichert, Token/Passwort nicht', () async {
      final (c, st) = await container();
      final m = EmbyMapper(client()).item(FakeEmby.movie(2), categoryId: 'x');
      await c.read(vodLibraryProvider.notifier).toggleFavorite(m);
      await st.setOption('embybitrate', '10');
      final data = st.exportAll();
      final text = jsonEncode(data);
      expect(text, isNot(contains(FakeEmby.token)));
      expect(text, isNot(contains(FakeEmby.password)));
      expect((data['emby'] as Map)['server'], server.base);
      expect((data['emby'] as Map)['user'], 'Jason');

      SharedPreferences.setMockInitialValues({});
      final fresh = await Storage.open(store: PreviewSecretStore());
      await fresh.importAll(jsonDecode(text) as Map<String, Object?>);
      final acc = fresh.embyAccount()!;
      expect(acc.server, server.base);
      expect(acc.userName, 'Jason');
      expect(acc.signedIn, isFalse); // einmal neu anmelden
      expect(fresh.option('embybitrate', 'auto'), '10');
      expect(fresh.option('vodfav___emby', '[]'), contains('emby_m2'));
    });
  });
}
