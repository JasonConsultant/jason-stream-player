import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:jason_stream_player/core/secret_store.dart';
import 'package:jason_stream_player/data/downloads/download_transfer.dart';
import 'package:jason_stream_player/data/downloads/url_vault.dart';
import 'package:jason_stream_player/data/recordings/recordings.dart';
import 'package:jason_stream_player/data/storage.dart';
import 'package:jason_stream_player/l10n/strings.dart';
import 'package:jason_stream_player/models/models.dart';
import 'package:jason_stream_player/player/engine_choice.dart';
import 'package:jason_stream_player/player/media_session.dart';
import 'package:jason_stream_player/state/downloads.dart';
import 'package:jason_stream_player/state/playback_session.dart';
import 'package:jason_stream_player/state/profile_mode.dart';
import 'package:jason_stream_player/state/providers.dart';
import 'package:jason_stream_player/ui/downloads/downloads_screen.dart';
import 'package:jason_stream_player/ui/nav.dart';
import 'package:jason_stream_player/ui/player/player_screen.dart';
import 'package:jason_stream_player/ui/settings/settings_screen.dart';
import 'package:jason_stream_player/ui/vod/movie_detail_screen.dart';
import 'package:jason_stream_player/ui/vod/series_detail_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/fake_downloads.dart';
import 'helpers/fake_engine.dart';
import 'helpers/tv_harness.dart';

/// 2.2: Downloads (Knöpfe, Seite Handy/TV, Kinderschutz, Offline-Wiedergabe)
/// und „Aufnehmen, was ich sehe“ (Blatt, ● REC, Stopp, Verbindungslimit).

const _portal = Portal(
    id: 'px',
    name: 'Anbieter X',
    type: PortalType.xtream,
    url: 'http://srv',
    username: 'hans',
    password: 'geheim');

const _film = VodItem(
    id: '101',
    name: 'Der lange Weg',
    categoryId: 'm1',
    streamUrl: 'http://srv/movie/hans/geheim/101.mkv',
    year: 2024,
    plot: 'Ein Film.');
const _hls = VodItem(
    id: '102',
    name: 'Nur Stream',
    categoryId: 'm1',
    streamUrl: 'http://srv/movie/hans/geheim/102.m3u8');
const _adult = VodItem(
    id: '103',
    name: 'Nachtprogramm',
    categoryId: 'xx',
    streamUrl: 'http://srv/movie/hans/geheim/103.mkv');
const _serie = VodItem(
    id: 's9',
    name: 'Die Küste',
    categoryId: 's1',
    streamUrl: '',
    isSeries: true);
const _e1 = Episode(
    id: '201',
    season: 1,
    number: 1,
    title: 'Ankunft',
    streamUrl: 'http://srv/series/hans/geheim/201.mkv');
const _e2 = Episode(
    id: '202',
    season: 1,
    number: 2,
    title: 'Sturm',
    streamUrl: 'http://srv/series/hans/geheim/202.mkv');
const _details =
    SeriesDetails(series: _serie, seasons: {1: [_e1, _e2]});

final _movies = VodData(const [
  Category(id: 'm1', name: 'Action'),
  Category(id: 'xx', name: 'XXX 18+'),
], const [_film, _hls, _adult]);
final _series =
    VodData(const [Category(id: 's1', name: 'Drama')], const [_serie]);

final _channels = [
  for (var i = 0; i < 3; i++)
    Channel(
        id: 'c$i',
        name: 'Sender $i',
        categoryId: 'de',
        streamUrl: 'http://srv/live/hans/geheim/$i.ts',
        epgId: 'c$i',
        number: i + 1),
];

const _channelsMocked = [
  MethodChannel('de.jasonstream.player/platform'),
  MethodChannel('de.jasonstream.player/dl'),
];

late Storage _st;
late FakeFileServer _server;
late FakeHost _host;

TvData _data({int? maxConn, Map<String, List<EpgEntry>> epg = const {}}) =>
    TvData(
      live: LiveData(const [Category(id: 'de', name: 'DE')], _channels),
      portal: _portal,
      movies: _movies,
      series: _series,
      epg: epg,
      account: maxConn == null
          ? null
          : AccountInfo(status: 'Active', maxConnections: maxConn),
    );

List<Override> _extra() => [
      downloadHostProvider.overrideWithValue(_host),
      seriesDetailsProvider.overrideWith((ref, s) async => _details),
      movieDetailsProvider.overrideWith((ref, m) async => m),
      playbackEngineProvider.overrideWithValue(FakeEngine.factory),
      mediaSessionProvider.overrideWithValue(NoopMediaSession()),
      exoAvailableProvider.overrideWithValue(true),
    ];

/// Handy (hochkant) oder TV.
Future<void> _pump(WidgetTester tester, Widget home,
    {bool tv = false,
    Size? size,
    int? maxConn,
    RecordingsNotifier Function()? recs,
    Map<String, List<EpgEntry>> epg = const {}}) async {
  await pumpTv(tester, home, _data(maxConn: maxConn, epg: epg), Future.value(_st),
      tv: tv,
      size: size ?? (tv ? const Size(1920, 1080) : const Size(1080, 2340)),
      dpr: tv ? 2 : 3,
      recs: recs,
      extra: _extra());
}

/// Eintrag (evtl. in einem blätterbaren Blatt) sichtbar machen und antippen.
Future<void> _tapVisible(WidgetTester tester, Finder f) async {
  if (f.evaluate().isEmpty) {
    // Noch nicht gebaut (Liste im Blatt): dorthin blättern.
    await tester.scrollUntilVisible(f, 120,
        scrollable: find.byType(Scrollable).last);
  }
  await tester.ensureVisible(f);
  await tester.pump(const Duration(milliseconds: 200));
  await tester.tap(f);
}

Future<void> _settle(WidgetTester tester, [int n = 10]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

ProviderContainer _container(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));

DownloadItem _seed(String id,
    {DownloadState state = DownloadState.done,
    int bytes = 1500 * 1024 * 1024,
    int total = 1500 * 1024 * 1024,
    String cat = 'm1',
    bool episode = false,
    bool adult = false,
    String title = 'Film'}) =>
    DownloadItem(
      id: DownloadItem.idOf('px', id),
      scope: 'px',
      source: VodSource.portal,
      itemId: id,
      title: title,
      categoryId: cat,
      adult: adult,
      isEpisode: episode,
      seriesId: episode ? 's9' : null,
      seriesName: episode ? 'Die Küste' : null,
      season: episode ? 1 : 0,
      episode: episode ? int.parse(id) % 100 : 0,
      maskedUrl: 'http://srv/${episode ? 'series' : 'movie'}/'
          '\u0000U\u0000/\u0000P\u0000/$id.mkv',
      ext: 'mkv',
      path: '/dl/$id.mkv',
      bytes: bytes,
      total: total,
      state: state,
      added: DateTime(2026, 10, 25),
    );

class _Recs extends RecordingsNotifier {
  final List<Recording> initial;
  _Recs([this.initial = const []]);
  final calls = <String>[];
  @override
  List<Recording> build() => initial;

  Recording _rec(Channel c, String title, DateTime end) => Recording(
      id: '${c.id}_now',
      channelId: c.id,
      channelName: c.name,
      title: title,
      start: DateTime.now().subtract(const Duration(seconds: 1)),
      end: end,
      status: 'läuft');

  @override
  Future<RecResult> recordNow(Channel c, EpgEntry? now) async {
    calls.add('now ${c.id}');
    state = [...state, _rec(c, now?.title ?? 'Aufnahme', now?.end ?? DateTime.now())];
    return RecResult.background;
  }

  @override
  Future<RecResult> recordFor(Channel c,
      {EpgEntry? current, Duration? duration}) async {
    calls.add('for ${c.id} ${duration?.inMinutes}');
    state = [
      ...state,
      _rec(c, current?.title ?? 'Aufnahme', DateTime.now().add(duration!))
    ];
    return RecResult.background;
  }

  @override
  Future<void> stop(String id) async {
    calls.add('stop $id');
    state = [
      for (final r in state)
        if (r.id == id) r.copy(status: 'fertig') else r
    ];
  }
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await initializeDateFormatting('de');
  });

  setUp(() async {
    L10n.lang = 'de';
    SharedPreferences.setMockInitialValues({'set_applang': 'de'});
    _st = await Storage.open(store: PreviewSecretStore());
    await _st.addPortal(_portal);
    _server = FakeFileServer()..chunk = 50000;
    for (final p in [
      '/movie/hans/geheim/101.mkv',
      '/movie/hans/geheim/103.mkv',
      '/series/hans/geheim/201.mkv',
      '/series/hans/geheim/202.mkv',
    ]) {
      _server.files[p] = fakeBytes(120000);
    }
    _host = FakeHost(_server)
      ..secrets = UrlVault.secretsOf(username: 'hans', password: 'geheim');
    debugDownloadExists = (_) async => true;
    FakeEngine.created.clear();
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    m.setMockMethodCallHandler(SystemChannels.platform, (c) async => null);
    for (final ch in _channelsMocked) {
      m.setMockMethodCallHandler(ch, (c) async => null);
    }
  });

  tearDown(() {
    debugDownloadExists = null;
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    m.setMockMethodCallHandler(SystemChannels.platform, null);
    for (final ch in _channelsMocked) {
      m.setMockMethodCallHandler(ch, null);
    }
  });

  group('Detailseiten', () {
    testWidgets('Film: Herunterladen → lädt → Heruntergeladen; '
        'gespeichert ohne Zugangsdaten', (tester) async {
      await _pump(tester, const MovieDetailScreen(movie: _film));
      expect(find.text('Herunterladen'), findsOneWidget);
      await tester.tap(find.text('Herunterladen'));
      await _settle(tester);
      expect(find.text('Download gestartet'), findsOneWidget);
      expect(find.text('Heruntergeladen'), findsOneWidget);
      final d = _container(tester).read(downloadsProvider).single;
      expect(d.state, DownloadState.done);
      expect(d.resumeKey, 'movie_101');
      expect(_server.requests.single.url.toString(),
          'http://srv/movie/hans/geheim/101.mkv');
      final saved = jsonEncode(_host.saved);
      expect(saved.contains('geheim'), isFalse);
      expect(saved.contains('hans'), isFalse);
      await tvDone(tester);
    });

    testWidgets('HLS-Film: kein Download-Knopf', (tester) async {
      await _pump(tester, const MovieDetailScreen(movie: _hls));
      expect(find.text('Herunterladen'), findsNothing);
      await tvDone(tester);
    });

    testWidgets('Anbieter mit 1 Verbindung: Hinweis zu Live-TV',
        (tester) async {
      await _pump(tester, const MovieDetailScreen(movie: _film), maxConn: 1);
      await tester.tap(find.text('Herunterladen'));
      await _settle(tester, 4);
      expect(
          find.textContaining('Dein Anbieter erlaubt nur 1 Verbindung'),
          findsOneWidget);
      await tvDone(tester);
    });

    testWidgets('Erwachsenen-Kategorie: nur mit PIN', (tester) async {
      await _st.setPin('4321');
      await _pump(tester, const MovieDetailScreen(movie: _adult));
      await tester.tap(find.text('Herunterladen'));
      await _settle(tester, 4);
      expect(find.text('PIN eingeben'), findsOneWidget);
      await tester.tap(find.text('Abbrechen'));
      await _settle(tester, 4);
      expect(_container(tester).read(downloadsProvider), isEmpty);
      await tester.tap(find.text('Herunterladen'));
      await _settle(tester, 4);
      await tester.enterText(find.byType(TextField), '4321');
      await tester.tap(find.text('OK'));
      await _settle(tester);
      final d = _container(tester).read(downloadsProvider).single;
      expect(d.adult, isTrue);
      await tvDone(tester);
    });

    testWidgets('Serie: Staffel herunterladen + Folgen-Symbol', (tester) async {
      await _pump(tester, const SeriesDetailScreen(series: _serie));
      expect(find.text('Staffel 1 herunterladen'), findsOneWidget);
      expect(find.byKey(const ValueKey('ep-download-201')), findsOneWidget);
      await tester.tap(find.text('Staffel 1 herunterladen'));
      await _settle(tester, 15);
      final list = _container(tester).read(downloadsProvider);
      expect(list.map((d) => d.itemId), ['201', '202']);
      expect(list.every((d) => d.isEpisode && d.seriesName == 'Die Küste'),
          isTrue);
      expect(find.text('Staffel geladen'), findsOneWidget);
      expect(find.byIcon(Icons.download_done_rounded), findsWidgets);
      await tvDone(tester);
    });
  });

  group('Downloads-Seite', () {
    testWidgets('Handy: Abschnitte, Status, Löschen, Fortsetzen',
        (tester) async {
      _host.initial = [
        _seed('101', title: 'Der lange Weg'),
        _seed('201',
            episode: true,
            title: 'Ankunft',
            state: DownloadState.paused,
            bytes: 48000,
            total: 120000,
            cat: 's1'),
      ];
      await _pump(tester, const DownloadsScreen());
      await _settle(tester);
      expect(find.text('WIRD GELADEN'), findsOneWidget);
      expect(find.text('AUF DEM GERÄT'), findsOneWidget);
      expect(find.textContaining('Angehalten 40 %'), findsOneWidget);
      expect(find.text('Die Küste · S1 F1'), findsOneWidget);
      expect(find.text('Der lange Weg'), findsOneWidget);
      // Nur-WLAN-Hinweis (Handy, Mobilfunk nicht erlaubt).
      expect(find.textContaining('nur über WLAN'), findsOneWidget);
      // Fortsetzen: Teildatei wird per Range weitergeladen.
      _host.sinks['px|201'] = MemorySinkWithData(48000);
      await tester.tap(find.byTooltip('Fortsetzen').first);
      await _settle(tester, 15);
      expect(_server.requests.last.headers['Range'], 'bytes=48000-');
      expect(_container(tester).read(downloadsProvider).every(
              (d) => d.state == DownloadState.done),
          isTrue);
      // Löschen.
      await tester.tap(find.byKey(const ValueKey('dl-delete-px|101')));
      await _settle(tester);
      expect(find.text('Der lange Weg'), findsNothing);
      expect(_host.deleted, ['px|101']);
      await tvDone(tester);
    });

    testWidgets('TV: D-Pad – Fokus auf dem ersten Eintrag, OK öffnet Aktionen',
        (tester) async {
      _host.initial = [_seed('101', title: 'Der lange Weg'), _seed('102', title: 'Zweiter')];
      await _pump(tester, const DownloadsScreen(), tv: true);
      await _settle(tester);
      expect(focusUnder(const ValueKey('dl-px|101')), isTrue);
      await tvKey(tester, LogicalKeyboardKey.arrowDown);
      expect(focusUnder(const ValueKey('dl-px|102')), isTrue);
      await tvKey(tester, LogicalKeyboardKey.select);
      await _settle(tester, 4);
      expect(find.text('Offline abspielen'), findsOneWidget);
      // Fokus im Blatt: „Offline abspielen“, ▼ → Löschen, OK.
      await tvKey(tester, LogicalKeyboardKey.arrowDown);
      await tvKey(tester, LogicalKeyboardKey.select);
      await _settle(tester, 4);
      expect(find.text('Zweiter'), findsNothing);
      expect(_host.deleted, ['px|102']);
      await tvDone(tester);
    });

    testWidgets('Kindermodus: nur freigegebene Kategorien, keine 18+',
        (tester) async {
      await _st.setFlag(Storage.kidsFlag, true);
      await _st.setKidsVod('px', {'m:m1'});
      _host.initial = [
        _seed('101', title: 'Erlaubt'),
        _seed('103', title: 'Erwachsen', cat: 'xx', adult: true),
        _seed('201', title: 'Folge', episode: true, cat: 's1'),
      ];
      await _pump(tester, const DownloadsScreen());
      await _settle(tester);
      expect(find.text('Erlaubt'), findsOneWidget);
      expect(find.text('Erwachsen'), findsNothing);
      expect(find.textContaining('Die Küste'), findsNothing);
      // Ohne Kindermodus: alles sichtbar (die automatische
      // Erwachsenen-Sperre ist abgeschaltet, kAdultAutoLockFeature).
      await _container(tester)
          .read(profileModeProvider.notifier)
          .setKids(false);
      await _settle(tester);
      expect(find.textContaining('Die Küste'), findsOneWidget);
      expect(find.text('Erwachsen'), findsOneWidget);
      await tvDone(tester);
    });

    testWidgets('Offline abspielen: lokale Datei, Fortsetzen-Position wie online',
        (tester) async {
      await _st.setResume('movie_101', 600, 5400);
      _host.initial = [_seed('101', title: 'Der lange Weg')];
      await _pump(tester, const DownloadsScreen());
      await _settle(tester);
      await tester.tap(find.text('Der lange Weg'));
      await _settle(tester);
      expect(find.byType(PlayerScreen), findsOneWidget);
      final e = FakeEngine.created.last;
      expect(e.calls.where((c) => c.startsWith('open ')).single,
          'open file:///dl/101.mkv');
      e.emit(duration: const Duration(minutes: 90), width: 1920, buffering: false, playing: true);
      await _settle(tester);
      expect(e.calls, contains('seek 600'));
      await tvDone(tester);
    });

    testWidgets('Film-Detail spielt den Download statt des Streams',
        (tester) async {
      _host.initial = [_seed('101', title: 'Der lange Weg')];
      await _pump(tester, const MovieDetailScreen(movie: _film));
      await _settle(tester);
      await tester.tap(find.text('Abspielen'));
      await _settle(tester);
      final e = FakeEngine.created.last;
      expect(e.calls.where((c) => c.startsWith('open ')).single,
          'open file:///dl/101.mkv');
      expect(_server.requests, isEmpty);
      await tvDone(tester);
    });
  });

  group('Einstellungen', () {
    testWidgets('Downloads-Einträge, Mobilfunk, Vorlauf/Nachlauf',
        (tester) async {
      await _pump(tester, const Scaffold(body: SettingsScreen()));
      await tester.scrollUntilVisible(
          find.text('Eine Verbindung für Live frei halten'), 300,
          scrollable: find.byType(Scrollable).first);
      expect(find.text('AUFNAHMEN & DOWNLOADS'), findsOneWidget);
      expect(find.byKey(const ValueKey('settings-downloads')), findsOneWidget);
      await _tapVisible(tester, find.text('Downloads auch über Mobilfunk'));
      await _settle(tester, 3);
      expect(_st.flag(DownloadSettings.mobileKey), isTrue);
      await _tapVisible(tester, find.text('Aufnahme: Vorlauf'));
      await _settle(tester, 3);
      expect(_st.option(RecPadding.preKey, '2'), '5');
      await _tapVisible(tester, find.text('Aufnahme: Nachlauf'));
      await _settle(tester, 3);
      expect(_st.option(RecPadding.postKey, '5'), '10');
      await _tapVisible(tester, find.text('Eine Verbindung für Live frei halten'));
      await _settle(tester, 3);
      expect(_st.flag(DownloadSettings.keepFreeKey), isTrue);
      await tvDone(tester);
    });
  });

  group('Aufnehmen, was ich sehe', () {
    final t0 = DateTime.now();
    final epg = {
      for (final c in _channels)
        c.epgId!: [
          EpgEntry(
              channelEpgId: c.epgId!,
              title: 'Show ${c.id}',
              start: t0.subtract(const Duration(minutes: 10)),
              end: t0.add(const Duration(minutes: 50))),
        ],
    };

    Future<void> openLive(WidgetTester tester,
        {bool tv = false, int? maxConn, _Recs? recs, Size? size}) async {
      final r = recs ?? _Recs();
      await _pump(
          tester,
          Builder(
              builder: (context) => Scaffold(
                    body: Center(
                      child: TextButton(
                          onPressed: () => openPlayer(
                              context,
                              PlayRequest(
                                  title: _channels[1].name,
                                  url: _channels[1].streamUrl,
                                  isLive: true,
                                  channels: _channels,
                                  channel: _channels[1])),
                          child: const Text('Live')),
                    ),
                  )),
          tv: tv,
          size: size,
          maxConn: maxConn,
          recs: () => r,
          epg: epg);
      await tester.tap(find.text('Live'));
      await _settle(tester);
      FakeEngine.created.last
          .emit(width: 1920, buffering: false, playing: true);
      await tester.pump();
    }

    _Recs recsOf(WidgetTester tester) =>
        _container(tester).read(recordingsProvider.notifier) as _Recs;

    testWidgets('Handy: ⋮ → Aufnehmen … → 30 Min.; ● REC; Stopp',
        (tester) async {
      await openLive(tester, size: const Size(2280, 1080));
      if (find.byIcon(Icons.more_vert_rounded).hitTestable().evaluate().isEmpty) {
        await tester.tapAt(const Offset(380, 180));
        await _settle(tester, 3);
      }
      expect(find.byKey(const ValueKey('rec-badge')), findsNothing);
      await tester.tap(find.byIcon(Icons.more_vert_rounded));
      await _settle(tester, 4);
      await _tapVisible(tester, find.byKey(const ValueKey('menu-record')));
      await _settle(tester, 4);
      expect(find.text('Bis Sendungsende'), findsOneWidget);
      expect(find.textContaining('zusätzliche Verbindung'), findsOneWidget);
      await _tapVisible(tester, find.byKey(const ValueKey('rec-30')));
      await _settle(tester, 4);
      expect(recsOf(tester).calls, ['for c1 30']);
      expect(find.byKey(const ValueKey('rec-badge')), findsOneWidget);
      expect(find.text('REC'), findsOneWidget);
      // Stopp über dasselbe Blatt.
      await tester.tap(find.byKey(const ValueKey('record-btn')));
      await _settle(tester, 4);
      await _tapVisible(tester, find.byKey(const ValueKey('rec-stop')));
      await _settle(tester, 4);
      expect(recsOf(tester).calls.last, 'stop c1_now');
      expect(find.byKey(const ValueKey('rec-badge')), findsNothing);
      await tvDone(tester);
    });

    testWidgets('Aufnahme läuft weiter nach Senderwechsel (REC nur beim Sender)',
        (tester) async {
      final recs = _Recs([
        Recording(
            id: 'c1_x',
            channelId: 'c1',
            channelName: 'Sender 1',
            title: 'Show c1',
            start: t0.subtract(const Duration(minutes: 1)),
            end: t0.add(const Duration(minutes: 40)),
            status: 'läuft'),
      ]);
      await openLive(tester, tv: true, recs: recs);
      expect(find.byKey(const ValueKey('rec-badge')), findsOneWidget);
      await tvKey(tester, LogicalKeyboardKey.channelUp);
      await _settle(tester, 8);
      expect(find.byKey(const ValueKey('rec-badge')), findsNothing);
      expect(recs.state.single.status, 'läuft');
      await tvDone(tester);
    });

    testWidgets('TV: Spuren-Blatt → Aufnehmen … → Bis Sendungsende',
        (tester) async {
      await openLive(tester, tv: true);
      await tvKey(tester, LogicalKeyboardKey.select);
      await _settle(tester, 3);
      await tester.tap(find.byIcon(Icons.subtitles_outlined));
      await _settle(tester, 4);
      await _tapVisible(tester, find.byKey(const ValueKey('track-record')));
      await _settle(tester, 4);
      // Fokus liegt auf „Bis Sendungsende“ → OK.
      await tvKey(tester, LogicalKeyboardKey.select);
      await _settle(tester, 4);
      expect(recsOf(tester).calls, ['now c1']);
      expect(find.byKey(const ValueKey('rec-badge')), findsOneWidget);
      await tvDone(tester);
    });

    testWidgets('max_connections=1: Rückfrage, Live wird beendet', (tester) async {
      await openLive(tester, tv: true, maxConn: 1);
      await tvKey(tester, LogicalKeyboardKey.select);
      await _settle(tester, 3);
      await tester.tap(find.byKey(const ValueKey('record-btn')));
      await _settle(tester, 4);
      expect(find.textContaining('(erlaubt: 1)'), findsOneWidget);
      await _tapVisible(tester, find.byKey(const ValueKey('rec-60')));
      await _settle(tester, 4);
      expect(find.text('Live-TV für die Aufnahme beenden?'), findsOneWidget);
      await tester.tap(find.text('Abbrechen'));
      await _settle(tester, 4);
      expect(recsOf(tester).calls, isEmpty);
      expect(find.byType(PlayerScreen), findsOneWidget);
      // Nochmal – diesmal bestätigen.
      await tester.tap(find.byKey(const ValueKey('record-btn')));
      await _settle(tester, 4);
      await _tapVisible(tester, find.byKey(const ValueKey('rec-60')));
      await _settle(tester, 4);
      await _tapVisible(tester, find.byKey(const ValueKey('rec-stop-live')));
      await _settle(tester, 8);
      expect(recsOf(tester).calls, ['for c1 60']);
      expect(find.byType(PlayerScreen), findsNothing);
      await tvDone(tester);
    });

    testWidgets('Keine freie Verbindung (2 erlaubt, eine frei halten, Aufnahme läuft)',
        (tester) async {
      await _st.setFlag(DownloadSettings.keepFreeKey, true);
      final recs = _Recs([
        Recording(
            id: 'c2_x',
            channelId: 'c2',
            channelName: 'Sender 2',
            title: 'Show c2',
            start: t0.subtract(const Duration(minutes: 1)),
            end: t0.add(const Duration(minutes: 40)),
            status: 'läuft'),
      ]);
      await openLive(tester, tv: true, maxConn: 2, recs: recs);
      await tvKey(tester, LogicalKeyboardKey.select);
      await _settle(tester, 3);
      await tester.tap(find.byKey(const ValueKey('record-btn')));
      await _settle(tester, 4);
      await _tapVisible(tester, find.byKey(const ValueKey('rec-30')));
      await _settle(tester, 4);
      expect(find.text('Keine freie Anbieter-Verbindung für eine weitere Aufnahme'),
          findsOneWidget);
      expect(recs.calls, isEmpty);
      await tvDone(tester);
    });
  });
}

/// Ziel mit schon vorhandenen Bytes (Teildatei).
class MemorySinkWithData extends MemorySink {
  MemorySinkWithData(int n) {
    data.add(fakeBytes(n));
  }
}

/// Liegt der Fokus unter einem Widget mit diesem Schlüssel?
bool focusUnder(Key key) {
  final ctx = FocusManager.instance.primaryFocus?.context;
  if (ctx == null) return false;
  if (ctx.widget.key == key) return true;
  var found = false;
  ctx.visitAncestorElements((e) {
    if (e.widget.key == key) {
      found = true;
      return false;
    }
    return true;
  });
  return found;
}
