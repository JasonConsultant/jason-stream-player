import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:jason_stream_player/core/app_messages.dart';
import 'package:jason_stream_player/core/secret_store.dart';
import 'package:jason_stream_player/core/subtitle_style.dart';
import 'package:jason_stream_player/core/theme.dart';
import 'package:jason_stream_player/data/storage.dart';
import 'package:jason_stream_player/l10n/strings.dart';
import 'package:jason_stream_player/models/models.dart';
import 'package:jason_stream_player/player/cast.dart';
import 'package:jason_stream_player/player/data_saver.dart';
import 'package:jason_stream_player/player/engine.dart';
import 'package:jason_stream_player/player/exo_engine.dart';
import 'package:jason_stream_player/player/media_session.dart';
import 'package:jason_stream_player/state/playback_session.dart';
import 'package:jason_stream_player/state/providers.dart';
import 'package:jason_stream_player/ui/nav.dart';
import 'package:jason_stream_player/ui/player/mini_player.dart';
import 'package:jason_stream_player/ui/player/mpv_tuning.dart';
import 'package:jason_stream_player/ui/player/player_screen.dart';
import 'package:jason_stream_player/ui/shell/reminder_host.dart'
    show appNavigatorKey;
import 'package:jason_stream_player/ui/widgets/live_preview.dart';
import 'package:jsp_exoplayer/jsp_cast.dart';
import 'package:jsp_exoplayer/jsp_exoplayer.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/fake_engine.dart';
import 'helpers/tv_harness.dart';

/// 1.8c: Chromecast (gemockter Kanal) und Datensparmodus.

const _portal = Portal(
    id: 'pa', name: 'Anbieter A', type: PortalType.xtream, url: 'http://a');

Channel _ch(int i) => Channel(
      id: 'c$i',
      name: 'Sender $i',
      categoryId: 'de',
      streamUrl: 'http://a/live/user/pass/$i.ts',
      number: i + 1,
    );

final _channels = [for (var i = 0; i < 5; i++) _ch(i)];

PlayRequest _movie() => const PlayRequest(
      title: 'Der große Film',
      subtitle: '2024 · 118 Min.',
      url: 'http://a/movie/user/pass/9.mp4',
      resumeKey: 'movie-1',
      artworkSeed: 'film',
    );

PlayRequest _live(int i) => PlayRequest(
      title: _channels[i].name,
      url: _channels[i].streamUrl,
      isLive: true,
      channels: _channels,
      channel: _channels[i],
    );

const _wifi = JspNetState(connected: true, metered: false, cellular: false);
const _cell = JspNetState(connected: true, metered: true, cellular: true);
const _meteredWifi =
    JspNetState(connected: true, metered: true, cellular: false);
const _offline = JspNetState(connected: false);

/// Befehle über den gemockten Methodenkanal; Ereignisse direkt (der
/// EventChannel liefert im Widget-Test erst außerhalb von FakeAsync).
class _TestCast extends JspCast {
  final StreamController<Map<Object?, Object?>> ctl;
  const _TestCast(this.ctl);
  @override
  Stream<Map<Object?, Object?>> events() => ctl.stream;
}

/// Gemockter Cast-Kanal: merkt sich Aufrufe, Ereignisse über [send].
class _CastMock {
  final calls = <MethodCall>[];
  var events = StreamController<Map<Object?, Object?>>.broadcast();
  bool get listening => events.hasListener;
  final loadResults = <bool>[];

  final _messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  void install() {
    _messenger.setMockMethodCallHandler(JspCastChannels.method, (c) async {
      calls.add(c);
      switch (c.method) {
        case 'connect':
          return true;
        case 'load':
          final ok = loadResults.isEmpty ? true : loadResults.removeAt(0);
          return {'ok': ok, 'code': ok ? 0 : 2100};
      }
      return null;
    });
  }

  void remove() {
    _messenger.setMockMethodCallHandler(JspCastChannels.method, null);
    events.close();
  }

  void send(Map<String, Object?> e) => events.add(e);

  void devices([List<(String, String)> d = const [('tv1', 'Wohnzimmer')]]) =>
      send({
        'e': 'devices',
        'devices': [
          for (final x in d) {'id': x.$1, 'name': x.$2}
        ],
      });

  void connected([String name = 'Wohnzimmer']) =>
      send({'e': 'session', 'state': 'connected', 'device': name});

  List<MethodCall> of(String m) => calls.where((c) => c.method == m).toList();
  Map<Object?, Object?> lastArgs(String m) =>
      of(m).last.arguments as Map<Object?, Object?>;
}

StreamController<Map<Object?, Object?>>? _castEvents;

Future<void> _pumpApp(WidgetTester tester, Storage storage,
    {bool tv = false,
    bool cast = true,
    NoopMediaSession? media,
    Stream<JspNetState>? net}) async {
  tester.view.physicalSize = const Size(1080, 2280);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    overrides: [
      ...tvOverrides(
          TvData(
              live: LiveData(
                  const [Category(id: 'de', name: 'Deutschland')], _channels),
              portal: _portal),
          Future.value(storage),
          tv: tv),
      playbackEngineProvider.overrideWithValue(FakeEngine.factory),
      mediaSessionProvider.overrideWithValue(media ?? NoopMediaSession()),
      castSupportedProvider.overrideWithValue(cast && !tv),
      castApiProvider.overrideWithValue(_TestCast(_castEvents!)),
      networkStateProvider.overrideWith((ref) => net ?? Stream.value(_wifi)),
    ],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      navigatorKey: appNavigatorKey,
      scaffoldMessengerKey: appMessengerKey,
      theme: buildTheme(tv: tv),
      builder: (context, child) => MiniPlayerHost(child: child!),
      home: Builder(
        builder: (context) => Scaffold(
          appBar: AppBar(title: const Text('Filme')),
          body: const SizedBox.expand(),
          floatingActionButton:
              Column(mainAxisSize: MainAxisSize.min, children: [
            FloatingActionButton(
              key: const ValueKey('open-movie'),
              heroTag: 'movie',
              onPressed: () => openPlayer(context, _movie()),
              child: const Icon(Icons.movie),
            ),
            const SizedBox(height: 8),
            FloatingActionButton(
              key: const ValueKey('open-live'),
              heroTag: 'live',
              onPressed: () => openPlayer(context, _live(2)),
              child: const Icon(Icons.live_tv),
            ),
          ]),
        ),
      ),
    ),
  ));
  await tester.pump();
}

Future<void> _settle(WidgetTester tester, [int n = 6]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<FakeEngine> _openMovie(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('open-movie')));
  await _settle(tester);
  final e = FakeEngine.created.last;
  e.emit(
      width: 1920,
      buffering: false,
      playing: true,
      duration: const Duration(minutes: 118),
      position: const Duration(minutes: 10));
  await _settle(tester, 2);
  return e;
}

Future<void> _done(WidgetTester tester) async {
  expect(tester.takeException(), isNull);
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 12));
}

/// Gerät wählen, Hinweis bestätigen, Sitzung verbunden melden.
Future<void> _castVia(WidgetTester tester, _CastMock m,
    {bool expectNotice = true}) async {
  await tester.tap(find.byKey(const ValueKey('cast-device-tv1')));
  await _settle(tester, 6);
  if (expectNotice) {
    expect(find.byKey(const ValueKey('cast-notice')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('cast-notice-ok')));
    await _settle(tester, 3);
  } else {
    expect(find.byKey(const ValueKey('cast-notice')), findsNothing);
  }
  expect(m.of('connect'), isNotEmpty);
  expect(m.lastArgs('connect')['id'], 'tv1');
  m.connected();
  await _settle(tester, 6);
}

void main() {
  late Storage storage;
  late _CastMock cast;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    L10n.lang = 'de';
    await initializeDateFormatting('de');
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    storage = await Storage.open(store: PreviewSecretStore());
    await storage.setOption('applang', 'de');
    L10n.lang = 'de';
    FakeEngine.created.clear();
    AppMessages.history.clear();
    cast = _CastMock()..install();
    _castEvents = cast.events;
    final m =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    m.setMockMethodCallHandler(SystemChannels.platform, (c) async => null);
    m.setMockMethodCallHandler(
        const MethodChannel('de.jasonstream.player/platform'), (c) async {
      if (c.method == 'isTv') return false;
      return null;
    });
  });

  tearDown(() {
    cast.remove();
    final m =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    m.setMockMethodCallHandler(
        const MethodChannel('de.jasonstream.player/platform'), null);
    m.setMockMethodCallHandler(SystemChannels.platform, null);
  });

  // ------------------------------------------------------------------
  group('Datensparmodus – Logik', () {
    test('Modus × Verbindung → aktiv?', () {
      for (final net in [_wifi, _cell, _meteredWifi, _offline]) {
        expect(dataSaverActive(DataSaverMode.off, net), isFalse);
        expect(dataSaverActive(DataSaverMode.always, net), isTrue);
      }
      expect(dataSaverActive(DataSaverMode.auto, _wifi), isFalse);
      expect(dataSaverActive(DataSaverMode.auto, _cell), isTrue);
      expect(dataSaverActive(DataSaverMode.auto, _meteredWifi), isTrue);
      expect(dataSaverActive(DataSaverMode.auto, _offline), isFalse);
      expect(
          dataSaverActive(
              DataSaverMode.auto,
              const JspNetState(
                  connected: true, metered: false, cellular: true)),
          isTrue,
          reason: 'Mobilfunk ohne Takt (z. B. 5G-Flatrate) zählt mit');
      // Fernseher: nie.
      expect(dataSaverActive(DataSaverMode.always, _cell, tv: true), isFalse);
    });

    test('Einstellung lesen/schreiben', () {
      expect(DataSaverMode.fromId(null), DataSaverMode.off);
      expect(DataSaverMode.fromId('auto'), DataSaverMode.auto);
      expect(DataSaverMode.fromId('always'), DataSaverMode.always);
      expect(DataSaverMode.fromId('quatsch'), DataSaverMode.off);
      expect(DataSaverMode.optionKey, 'datasaver');
    });

    test('Wechsel der Verbindung wird live übernommen', () async {
      await storage.setOption(DataSaverMode.optionKey, 'auto');
      final net = StreamController<JspNetState>();
      final c = ProviderContainer(overrides: [
        storageProvider.overrideWith((ref) => Future.value(storage)),
        isTvProvider.overrideWithValue(false),
        networkStateProvider.overrideWith((ref) => net.stream),
      ]);
      addTearDown(c.dispose);
      await c.read(storageProvider.future);
      final seen = <bool>[];
      c.listen(dataSaverActiveProvider, (_, v) => seen.add(v),
          fireImmediately: true);
      Future<void> flush() async {
        for (var i = 0; i < 5; i++) {
          await Future<void>.delayed(Duration.zero);
        }
      }

      net.add(_wifi);
      await flush();
      net.add(_cell);
      await flush();
      expect(DataSaver.active, isTrue);
      net.add(_wifi);
      await flush();
      expect(seen, [false, true, false]);
      expect(DataSaver.active, isFalse);
      // Modus „Immer“ über die Einstellung.
      await c
          .read(dataSaverModeProvider.notifier)
          .set(DataSaverMode.always);
      expect(c.read(dataSaverActiveProvider), isTrue);
      expect(storage.option(DataSaverMode.optionKey, 'off'), 'always');
      await net.close();
    });

    test('Live-Vorschau beim Stöbern aus', () async {
      await storage.setOption(DataSaverMode.optionKey, 'auto');
      Future<bool> preview(JspNetState n) async {
        final c = ProviderContainer(overrides: [
          storageProvider.overrideWith((ref) => Future.value(storage)),
          isTvProvider.overrideWithValue(false),
          networkStateProvider.overrideWith((ref) => Stream.value(n)),
        ]);
        addTearDown(c.dispose);
        await c.read(storageProvider.future);
        c.listen(networkStateProvider, (_, __) {});
        await c.read(networkStateProvider.future);
        return c.read(livePreviewEnabledProvider.future);
      }

      expect(await preview(_wifi), isTrue);
      expect(await preview(_cell), isFalse);
    });

    test('Bilder in reduzierter Größe', () {
      expect(
          DataSaverTuning.smallImage(
              'https://image.tmdb.org/t/p/w600_and_h900_bestv2/abc.jpg'),
          'https://image.tmdb.org/t/p/w185/abc.jpg');
      final emby = Uri.parse(DataSaverTuning.smallImage(
          'http://emby:8096/Items/42/Images/Primary?maxWidth=400&tag=t1&quality=90'));
      expect(emby.queryParameters['maxWidth'], '240');
      expect(emby.queryParameters['quality'], '60');
      expect(emby.queryParameters['tag'], 't1');
      // Kleiner als die Grenze bleibt klein.
      expect(
          Uri.parse(DataSaverTuning.smallImage(
                  'http://emby/Items/1/Images/Primary?maxWidth=120'))
              .queryParameters['maxWidth'],
          '120');
      // Unbekannte Server: unverändert.
      const other = 'http://cdn.example/poster/9.jpg';
      expect(DataSaverTuning.smallImage(other), other);
      DataSaver.active = false;
      expect(DataSaver.image(
              'https://image.tmdb.org/t/p/original/x.jpg'),
          'https://image.tmdb.org/t/p/original/x.jpg');
      DataSaver.active = true;
      expect(DataSaver.image('https://image.tmdb.org/t/p/original/x.jpg'),
          'https://image.tmdb.org/t/p/w185/x.jpg');
      DataSaver.active = false;
    });
  });

  group('Datensparmodus – Engines', () {
    Map<String, String> open({required bool saver}) => MpvTuning.perOpen(
          live: true,
          plan: null,
          bufferBytes: 32 << 20,
          userAgent: 'JSP',
          referrer: '',
          subtitles: const SubtitleStyle(),
          passthrough: false,
          dataSaver: saver,
        );

    test('mpv: hls-bitrate=min bzw. max', () {
      expect(open(saver: true)['hls-bitrate'], 'min');
      expect(open(saver: false)['hls-bitrate'], 'max');
      expect(DataSaverTuning.mpv(true), {'hls-bitrate': 'min'});
    });

    test('mpv: Wechsel geht als einzelne Änderung raus', () async {
      final sent = <String, String>{};
      final props = MpvProps((k, v) async => sent[k] = v);
      await props.apply(open(saver: false));
      sent.clear();
      expect(await props.apply(open(saver: true)), 1);
      expect(sent, {'hls-bitrate': 'min'});
    });

    test('ExoPlayer: Bitrate/Größe der HLS-Stufe begrenzt', () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(JspExoChannels.method, (c) async {
        calls.add(c);
        if (c.method == 'create') return {'id': 3, 'textureId': 9};
        return null;
      });
      messenger.setMockStreamHandler(EventChannel(JspExoChannels.events(3)),
          MockStreamHandler.inline(onListen: (_, __) {}));
      addTearDown(() {
        messenger.setMockMethodCallHandler(JspExoChannels.method, null);
        messenger.setMockStreamHandler(
            EventChannel(JspExoChannels.events(3)), null);
      });
      final e =
          await ExoEngine.createForTest(const EngineConfig(engine: 'exo'));
      final props = MpvProps(e.setOption);
      await props.apply(open(saver: true));
      expect(e.ignored, isNot(contains('hls-bitrate')));
      await e.open('http://s/1.m3u8', live: true);
      Map<Object?, Object?> last() =>
          calls.lastWhere((c) => c.method == 'open').arguments
              as Map<Object?, Object?>;
      expect(last()['maxVideoBitrate'], DataSaverTuning.maxVideoBitrate);
      expect(last()['maxVideoBitrate'], 1500000);
      expect(last()['maxVideoHeight'], 720);
      await props.apply(open(saver: false));
      await e.open('http://s/1.m3u8', live: true);
      expect(last()['maxVideoBitrate'], 0);
      expect(last()['maxVideoHeight'], 0);
      await e.dispose();
    });
  });

  // ------------------------------------------------------------------
  group('Cast – Adressen', () {
    test('MIME-Typ nach Adresse', () {
      expect(CastMime.of('http://h/live/u/p/1.m3u8', live: true), CastMime.hls);
      expect(CastMime.of('http://h/movie/u/p/9.mp4', live: false), CastMime.mp4);
      expect(CastMime.of('http://h/live/u/p/1.ts', live: true), CastMime.ts);
      expect(CastMime.of('http://h/a.mkv?x=1', live: false), CastMime.mkv);
      expect(
          CastMime.of('http://emby/Videos/1/master.m3u8?api_key=k',
              live: false),
          CastMime.hls);
      expect(
          CastMime.of('http://emby/Videos/1/stream?static=true&Container=mp4',
              live: false),
          CastMime.mp4);
      // Ohne Endung: Live = MPEG-TS, sonst MP4.
      expect(CastMime.of('http://h/u/p/123', live: true), CastMime.ts);
      expect(CastMime.of('http://h/play?id=3', live: false), CastMime.mp4);
    });

    test('Xtream-Live: erst HLS, dann Original', () {
      final c = castCandidates('http://a:8080/live/user/pass/7.ts', live: true);
      expect(c, [
        const CastSource('http://a:8080/live/user/pass/7.m3u8', CastMime.hls),
        const CastSource('http://a:8080/live/user/pass/7.ts', CastMime.ts),
      ]);
      expect(castCandidates('http://h/x.m3u8', live: true),
          [const CastSource('http://h/x.m3u8', CastMime.hls)]);
      expect(castCandidates('http://h/movie/u/p/1.mp4', live: false),
          [const CastSource('http://h/movie/u/p/1.mp4', CastMime.mp4)]);
      // toString verrät die Adresse nicht (Logs).
      expect(c.first.toString(), isNot(contains('pass')));
    });
  });

  group('Cast – Ablauf (gemockter Kanal)', () {
    testWidgets('Knopf nur mit gefundenem Gerät', (tester) async {
      await _pumpApp(tester, storage);
      await _openMovie(tester);
      expect(find.byType(PlayerScreen), findsOneWidget);
      expect(find.byKey(const ValueKey('player-cast')), findsNothing);
      expect(cast.of('startDiscovery'), isNotEmpty);
      cast.devices();
      await _settle(tester, 2);
      expect(find.byKey(const ValueKey('player-cast')), findsOneWidget);
      cast.devices(const []);
      await _settle(tester, 2);
      expect(find.byKey(const ValueKey('player-cast')), findsNothing);
      await _done(tester);
    });

    testWidgets('Fernseher: kein Cast', (tester) async {
      await _pumpApp(tester, storage, tv: true);
      await tester.pump();
      expect(cast.listening, isFalse, reason: 'keine Gerätesuche auf dem TV');
      expect(cast.of('startDiscovery'), isEmpty);
      await _done(tester);
    });

    testWidgets(
        'Film: Hinweis einmalig, Übergabe ab Position, Mini-Player „Läuft auf …“',
        (tester) async {
      final media = NoopMediaSession();
      await _pumpApp(tester, storage, media: media);
      final e = await _openMovie(tester);
      cast.devices();
      await _settle(tester, 2);
      await tester.tap(find.byKey(const ValueKey('player-cast')));
      await _settle(tester, 8);
      await _castVia(tester, cast);
      expect(storage.flag(castNoticeFlag), isTrue);

      final a = cast.lastArgs('load');
      expect(a['url'], 'http://a/movie/user/pass/9.mp4');
      expect(a['mime'], 'video/mp4');
      expect(a['live'], isFalse);
      expect(a['positionMs'], 600000);
      expect(a['title'], 'Der große Film');
      // Lokal pausiert, Player-Seite zu, Mini-Player zeigt das Gerät.
      expect(e.calls, contains('pause'));
      expect(e.disposed, isFalse);
      expect(find.byType(PlayerScreen), findsNothing);
      expect(find.byKey(const ValueKey('mini-casting')), findsOneWidget);
      expect(find.text('Läuft auf Wohnzimmer'), findsWidgets);
      expect(media.updates.last.subtitle, 'Läuft auf Wohnzimmer');

      // Play/Pause im Mini-Player steuert den Fernseher.
      cast.send({'e': 'status', 'state': 'playing', 'ms': 605000});
      await _settle(tester, 2);
      await tester.tap(find.byKey(const ValueKey('mini-play-pause')));
      await _settle(tester, 2);
      expect(cast.of('pause'), hasLength(1));
      expect(e.calls.where((c) => c == 'play'), isEmpty,
          reason: 'lokal bleibt still');

      // Trennen → lokal an der Stelle des Fernsehers weiter.
      cast.send({'e': 'pos', 'ms': 700000});
      cast.send({'e': 'session', 'state': 'ended', 'code': 0});
      await _settle(tester, 3);
      expect(e.calls, contains('seek 700'));
      expect(e.calls.last, 'play');
      expect(find.byKey(const ValueKey('mini-casting')), findsNothing);
      expect(find.byKey(const ValueKey('mini-player')), findsOneWidget);

      // Zweiter Cast: kein Hinweis mehr.
      await tester.tap(find.byKey(const ValueKey('mini-cast')));
      await _settle(tester, 8);
      await _castVia(tester, cast, expectNotice: false);
      expect(cast.of('load'), hasLength(2));
      expect(cast.lastArgs('load')['positionMs'], 700000);
      await _done(tester);
    });

    testWidgets('Hinweis abgelehnt → keine Verbindung', (tester) async {
      await _pumpApp(tester, storage);
      await _openMovie(tester);
      cast.devices();
      await _settle(tester, 2);
      await tester.tap(find.byKey(const ValueKey('player-cast')));
      await _settle(tester, 8);
      await tester.tap(find.byKey(const ValueKey('cast-device-tv1')));
      await _settle(tester, 4);
      await tester.tap(find.text('Abbrechen'));
      await _settle(tester, 3);
      expect(cast.of('connect'), isEmpty);
      expect(storage.flag(castNoticeFlag), isFalse);
      expect(find.byType(PlayerScreen), findsOneWidget);
      await _done(tester);
    });

    testWidgets('Live: ab Live-Kante, lokal Stopp, CH+ zappt auf dem Gerät',
        (tester) async {

      await storage.setFlag(castNoticeFlag, true);
      final media = NoopMediaSession();
      await _pumpApp(tester, storage, media: media);
      await tester.tap(find.byKey(const ValueKey('open-live')));
      await _settle(tester);
      final e = FakeEngine.created.last;
      e.emit(width: 1920, buffering: false, playing: true);
      await _settle(tester, 2);
      cast.devices();
      await _settle(tester, 2);
      await tester.tap(find.byKey(const ValueKey('player-cast')));
      await _settle(tester, 8);
      await _castVia(tester, cast, expectNotice: false);
      var a = cast.lastArgs('load');
      expect(a['live'], isTrue);
      expect(a['url'], 'http://a/live/user/pass/2.m3u8',
          reason: 'Xtream-Live zuerst als HLS');
      expect(a['mime'], 'application/x-mpegURL');
      expect(a['positionMs'], 0);
      expect(e.calls, contains('stop'));
      expect(find.byType(PlayerScreen), findsNothing);

      final opens = e.calls.where((c) => c.startsWith('open')).length;
      await media.callbacks!.onZap!(1);
      await _settle(tester, 3);
      a = cast.lastArgs('load');
      expect(a['url'], 'http://a/live/user/pass/3.m3u8');
      expect(a['title'], 'Sender 3');
      expect(e.calls.where((c) => c.startsWith('open')).length, opens,
          reason: 'lokal wird nicht geöffnet');
      expect(media.updates.last.title, 'Sender 3');
      expect(media.updates.last.subtitle, 'Läuft auf Wohnzimmer');

      // Stopp im Mini-Player beendet auch auf dem Fernseher.
      await tester.tap(find.byKey(const ValueKey('mini-close')));
      await _settle(tester, 3);
      expect(cast.of('stop'), hasLength(1));
      expect(find.byKey(const ValueKey('mini-player')), findsNothing);
      await _done(tester);
    });

    testWidgets('Gerät kann den Sender nicht → nächste Variante, dann Meldung',
        (tester) async {
      await storage.setFlag(castNoticeFlag, true);
      await _pumpApp(tester, storage);
      await tester.tap(find.byKey(const ValueKey('open-live')));
      await _settle(tester);
      final e = FakeEngine.created.last;
      e.emit(width: 1920, buffering: false, playing: true);
      cast.devices();
      await _settle(tester, 2);
      cast.loadResults.addAll([false, false]); // HLS und TS scheitern
      await tester.tap(find.byKey(const ValueKey('player-cast')));
      await _settle(tester, 8);
      await _castVia(tester, cast, expectNotice: false);
      expect(cast.of('load').map((c) => (c.arguments as Map)['mime']),
          ['application/x-mpegURL', 'video/mp2t']);
      expect(AppMessages.history, contains('Dieser Sender kann nicht gestreamt werden'));
      expect(find.text('Dieser Sender kann nicht gestreamt werden'),
          findsOneWidget);
      // Lokal wieder offen (Live neu ab Live-Kante).
      expect(e.calls.last, 'open http://a/live/user/pass/2.ts');
      expect(find.byKey(const ValueKey('mini-casting')), findsNothing);
      await _done(tester);
    });

    testWidgets('Wiedergabefehler nach dem Laden → Meldung, Film lokal weiter',
        (tester) async {
      await storage.setFlag(castNoticeFlag, true);
      await _pumpApp(tester, storage);
      final e = await _openMovie(tester);
      cast.devices();
      await _settle(tester, 2);
      await tester.tap(find.byKey(const ValueKey('player-cast')));
      await _settle(tester, 8);
      await _castVia(tester, cast, expectNotice: false);
      cast.send({'e': 'status', 'state': 'idle', 'idle': 'error', 'ms': 0});
      await _settle(tester, 3);
      expect(AppMessages.history,
          contains('Dieser Inhalt kann nicht gestreamt werden'));
      expect(e.calls, contains('seek 600'));
      expect(e.calls.last, 'play');
      await _done(tester);
    });

    testWidgets('Verbunden + neuer Inhalt → läuft gleich auf dem Gerät',
        (tester) async {
      await storage.setFlag(castNoticeFlag, true);
      await _pumpApp(tester, storage);
      cast.devices();
      cast.connected();
      await _settle(tester, 2);
      expect(cast.of('load'), isEmpty, reason: 'nichts läuft');
      await _openMovie(tester);
      await _settle(tester, 4);
      expect(cast.of('load'), hasLength(1));
      expect(find.byType(PlayerScreen), findsNothing);
      expect(find.byKey(const ValueKey('mini-casting')), findsOneWidget);
      await _done(tester);
    });
  });
}
