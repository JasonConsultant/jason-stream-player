import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:jason_stream_player/core/app_messages.dart';
import 'package:jason_stream_player/core/secret_store.dart';
import 'package:jason_stream_player/core/theme.dart';
import 'package:jason_stream_player/data/storage.dart';
import 'package:jason_stream_player/l10n/strings.dart';
import 'package:jason_stream_player/models/models.dart';
import 'package:jason_stream_player/player/cast.dart';
import 'package:jason_stream_player/player/engine.dart';
import 'package:jason_stream_player/player/engine_choice.dart';
import 'package:jason_stream_player/player/exo_engine.dart';
import 'package:jason_stream_player/player/media_session.dart';
import 'package:jason_stream_player/state/playback_session.dart';
import 'package:jason_stream_player/state/providers.dart';
import 'package:jason_stream_player/ui/nav.dart';
import 'package:jason_stream_player/ui/player/mini_player.dart';
import 'package:jason_stream_player/ui/player/player_screen.dart';
import 'package:jason_stream_player/ui/player/stream_info.dart';
import 'package:jason_stream_player/ui/shell/reminder_host.dart'
    show appNavigatorKey;
import 'package:jason_stream_player/ui/widgets/live_preview.dart';
import 'package:jsp_exoplayer/jsp_cast.dart';
import 'package:jsp_exoplayer/jsp_exoplayer.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/fake_engine.dart';
import 'helpers/tv_harness.dart';

/// Hotfix 2.3.1 (Ton): nie zwei hörbare Engines gleichzeitig, Wiedergabe-
/// Geschwindigkeit immer 1.0, Ton-Angaben in der Stream-Info.

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

class _TestCast extends JspCast {
  final StreamController<Map<Object?, Object?>> ctl;
  const _TestCast(this.ctl);
  @override
  Stream<Map<Object?, Object?>> events() => ctl.stream;
}

late StreamController<Map<Object?, Object?>> _castEvents;
final _castCalls = <MethodCall>[];

Future<ProviderContainer> _pumpApp(WidgetTester tester, Storage storage,
    {NoopMediaSession? media}) async {
  tester.view.physicalSize = const Size(2280, 1080);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  final key = GlobalKey();
  await tester.pumpWidget(ProviderScope(
    overrides: [
      ...tvOverrides(
          TvData(
              live: LiveData(
                  const [Category(id: 'de', name: 'Deutschland')], _channels),
              portal: _portal),
          Future.value(storage),
          tv: false),
      playbackEngineProvider.overrideWithValue(FakeEngine.factory),
      mediaSessionProvider.overrideWithValue(media ?? NoopMediaSession()),
      exoAvailableProvider.overrideWithValue(true),
      castSupportedProvider.overrideWithValue(true),
      castApiProvider.overrideWithValue(_TestCast(_castEvents)),
    ],
    child: MaterialApp(
      key: key,
      debugShowCheckedModeBanner: false,
      navigatorKey: appNavigatorKey,
      scaffoldMessengerKey: appMessengerKey,
      theme: buildTheme(tv: false),
      builder: (context, child) => MiniPlayerHost(child: child!),
      home: Builder(
        builder: (context) => Scaffold(
          body: const Text('Start'),
          floatingActionButton:
              Column(mainAxisSize: MainAxisSize.min, children: [
            FloatingActionButton(
              key: const ValueKey('open-movie'),
              heroTag: 'movie',
              onPressed: () => openPlayer(context, _movie()),
              child: const Icon(Icons.movie),
            ),
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
  return ProviderScope.containerOf(key.currentContext!);
}

/// Pumpen und nach jedem Schritt zählen, wie viele Engines zu hören sind.
Future<void> _settle(WidgetTester tester, [int n = 6]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    FakeEngine.checkAudible();
  }
}

Future<FakeEngine> _open(WidgetTester tester, String key) async {
  await tester.tap(find.byKey(ValueKey(key)));
  await _settle(tester);
  expect(find.byType(PlayerScreen), findsOneWidget);
  final e = FakeEngine.created.last;
  e.emit(width: 1920, buffering: false, playing: true);
  await _settle(tester, 2);
  return e;
}

Future<void> _back(WidgetTester tester) async {
  await tester.binding.handlePopRoute();
  await tester.pump();
  await _settle(tester, 5);
}

void _expectSingleSound() {
  expect(FakeEngine.overlaps, isEmpty,
      reason: 'beim Öffnen war noch eine andere Engine zu hören');
  expect(FakeEngine.maxAudible, lessThanOrEqualTo(1));
  expect(FakeEngine.audibleNow(), lessThanOrEqualTo(1));
}

Future<void> _done(WidgetTester tester) async {
  _expectSingleSound();
  expect(tester.takeException(), isNull);
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 12));
}

void main() {
  late Storage storage;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    L10n.lang = 'de';
    await initializeDateFormatting('de');
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    storage = await Storage.open(store: PreviewSecretStore());
    await storage.setOption('applang', 'de');
    await storage.setFlag(castNoticeFlag, true);
    L10n.lang = 'de';
    FakeEngine.created.clear();
    FakeEngine.overlaps.clear();
    FakeEngine.maxAudible = 0;
    AppMessages.history.clear();
    _castEvents = StreamController<Map<Object?, Object?>>.broadcast();
    _castCalls.clear();
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    m.setMockMethodCallHandler(JspCastChannels.method, (c) async {
      _castCalls.add(c);
      switch (c.method) {
        case 'connect':
          return true;
        case 'load':
          return {'ok': true, 'code': 0};
      }
      return null;
    });
    m.setMockMethodCallHandler(SystemChannels.platform, (c) async => null);
    m.setMockMethodCallHandler(
        const MethodChannel('de.jasonstream.player/platform'),
        (c) async => c.method == 'isTv' ? false : null);
  });

  tearDown(() {
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    m.setMockMethodCallHandler(JspCastChannels.method, null);
    m.setMockMethodCallHandler(SystemChannels.platform, null);
    m.setMockMethodCallHandler(
        const MethodChannel('de.jasonstream.player/platform'), null);
    _castEvents.close();
  });

  group('Höchstens eine hörbare Engine', () {
    testWidgets('Film: öffnen, Zurück → Mini, Mini → Vollbild, Nur-Ton',
        (tester) async {
      await _pumpApp(tester, storage);
      final e = await _open(tester, 'open-movie');
      expect(FakeEngine.audibleNow(), 1);
      await _back(tester);
      expect(find.byKey(const ValueKey('mini-player')), findsOneWidget);
      expect(FakeEngine.audibleNow(), 1, reason: 'läuft im Mini-Player weiter');
      await tester.tap(find.byKey(const ValueKey('mini-player')));
      await _settle(tester);
      expect(FakeEngine.created, hasLength(1),
          reason: 'Vollbild übernimmt dieselbe Engine');
      expect(e.calls.where((c) => c.startsWith('open')), hasLength(1));
      await _done(tester);
    });

    testWidgets('Doppelt geöffnet (Doppeltipp): erste Engine wird freigegeben',
        (tester) async {
      await _pumpApp(tester, storage);
      await tester.tap(find.byKey(const ValueKey('open-live')));
      await tester.tap(find.byKey(const ValueKey('open-live')),
          warnIfMissed: false);
      await _settle(tester, 10);
      final alive = FakeEngine.created.where((e) => !e.disposed).toList();
      expect(alive, hasLength(1));
      for (final e in FakeEngine.created) {
        e.emit(playing: !e.disposed);
      }
      await _settle(tester, 2);
      await _done(tester);
    });

    testWidgets('PlaybackController.start zweimal gleichzeitig → eine Engine',
        (tester) async {
      final c = await _pumpApp(tester, storage);
      final ctl = c.read(playbackProvider.notifier);
      final a = ctl.start(_live(1), config: const EngineConfig(engine: 'exo'));
      final b = ctl.start(_live(3), config: const EngineConfig(engine: 'exo'));
      final sa = await a;
      final sb = await b;
      await tester.pump();
      expect(FakeEngine.created, hasLength(2));
      expect((sa.engine as FakeEngine).disposed, isTrue);
      expect(identical(ctl.session, sb), isTrue);
      expect(FakeEngine.created.where((e) => !e.disposed), hasLength(1));
      await ctl.stop();
      await _done(tester);
    });

    testWidgets('Live: schnelles Zappen (Player + Mini/Benachrichtigung)',
        (tester) async {
      final media = NoopMediaSession();
      await _pumpApp(tester, storage, media: media);
      final e = await _open(tester, 'open-live');
      for (var i = 0; i < 6; i++) {
        await media.callbacks!.onZap!(1);
        await tester.pump(const Duration(milliseconds: 120));
        FakeEngine.checkAudible();
      }
      await _settle(tester, 20);
      await _back(tester);
      for (var i = 0; i < 4; i++) {
        await media.callbacks!.onZap!(-1);
        await tester.pump(const Duration(milliseconds: 90));
        FakeEngine.checkAudible();
      }
      await _settle(tester, 20);
      expect(FakeEngine.created, hasLength(1), reason: 'nur Quelle getauscht');
      expect(e.disposed, isFalse);
      await _done(tester);
    });

    testWidgets('Rückfall ExoPlayer → mpv: alte Engine frei vor dem Öffnen',
        (tester) async {
      await _pumpApp(tester, storage);
      final exo = await _open(tester, 'open-live');
      expect(exo.id, 'exo');
      exo.failWith(EngineErrorKind.decoder, 'Decoder error');
      await _settle(tester, 30);
      final mpv = FakeEngine.created.last;
      expect(mpv.id, 'mpv');
      expect(exo.disposed, isTrue);
      expect(mpv.calls.where((c) => c.startsWith('open')), isNotEmpty);
      mpv.emit(width: 1920, buffering: false, playing: true);
      await _settle(tester, 2);
      await _done(tester);
    });

    testWidgets('Verbindungs-Leiter: Neustart öffnet dieselbe Engine',
        (tester) async {
      await _pumpApp(tester, storage);
      final e = await _open(tester, 'open-live');
      e.failWith(EngineErrorKind.network, 'HTTP error 503');
      await _settle(tester, 40);
      expect(FakeEngine.created, hasLength(1));
      expect(e.calls.where((c) => c.startsWith('open')).length,
          greaterThanOrEqualTo(2));
      await _done(tester);
    });

    testWidgets('Cast verbinden/trennen: lokal still, danach wieder eine',
        (tester) async {
      await _pumpApp(tester, storage);
      final e = await _open(tester, 'open-live');
      _castEvents.add({
        'e': 'devices',
        'devices': [
          {'id': 'tv1', 'name': 'Wohnzimmer'}
        ]
      });
      _castEvents.add({'e': 'session', 'state': 'connected', 'device': 'TV'});
      await _settle(tester, 8);
      expect(_castCalls.where((c) => c.method == 'load'), isNotEmpty);
      expect(e.state.playing, isFalse, reason: 'lokal gestoppt');
      expect(FakeEngine.audibleNow(), 0);
      _castEvents.add({'e': 'session', 'state': 'ended'});
      await _settle(tester, 8);
      expect(e.calls.where((c) => c.startsWith('open')).length, 2,
          reason: 'zurück aufs Handy: Live neu geöffnet');
      expect(FakeEngine.audibleNow(), 1);
      await _done(tester);
    });

    testWidgets('Live-Vorschau startet nicht, solange ein Stream läuft',
        (tester) async {
      final c = await _pumpApp(tester, storage);
      await _open(tester, 'open-movie');
      await _back(tester);
      expect(find.byKey(const ValueKey('mini-player')), findsOneWidget);
      final preview = c.read(livePreviewProvider);
      await preview.play(Object(), _channels[1]);
      expect(preview.alive, isFalse,
          reason: 'kein zweiter Player neben dem Mini-Player');
      await _done(tester);
    });
  });

  group('Geschwindigkeit und Ton-Diagnose', () {
    test('ExoEngine: Statistik → Health mit Ton-Angaben', () {
      final h = ExoEngine.healthFrom({
        'audioMime': 'audio/ac3',
        'audioDecoder': 'ffmpegLib-ac3',
        'audioHw': false,
        'audioChannels': 6,
        'sampleRate': 48000,
        'audioOutChannels': 2,
        'downmixFrom': 6,
        'passthrough': false,
        'audioUnderruns': 3,
        'speed': 1.0,
      });
      expect(h.audioCodec, 'AC3');
      expect(h.audioHardware, isFalse);
      expect(h.downmixFrom, 6);
      expect(h.audioOutputChannels, 2);
      expect(h.audioUnderruns, 3);
      expect(h.speed, 1.0);
    });

    test('Diagnose-Zeile: Ausgabe, Abmischung, Unterläufe; Tempo nur ≠ 1', () {
      final lines = ExoEngine.formatStats({
        'audioOutEncoding': 'pcm16',
        'audioOutChannels': 2,
        'audioOutRate': 48000,
        'audioBufferMs': 500,
        'downmixFrom': 6,
        'audioUnderruns': 0,
        'speed': 1.0,
      });
      final a = lines.firstWhere((l) => l.startsWith('aout'));
      expect(a, contains('pcm16 2ch'));
      expect(a, contains('downmix 6→2'));
      expect(a, contains('underruns 0'));
      expect(a, isNot(contains('speed')));
      final b = ExoEngine.formatStats({'speed': 1.03})
          .firstWhere((l) => l.startsWith('aout'));
      expect(b, contains('speed 1.03'));
    });

    test('Stream-Info: Ton-Dekoder, Ausgabe, Aussetzer', () {
      L10n.lang = 'de';
      const ctx = StreamInfoContext(engine: 'ExoPlayer');
      Map<String, String> rows(EngineHealth h) =>
          {for (final r in StreamInfo.rows(h, ctx)) r.$1: r.$2};
      var r = rows(const EngineHealth(
          audioDecoder: 'ffmpegLib-ac3',
          downmixFrom: 6,
          audioOutputChannels: 2,
          audioUnderruns: 0));
      expect(r['Ton-Dekoder'], 'FFmpeg (Software)');
      expect(r['Ton-Ausgabe'], 'Stereo-Abmischung aus 5.1');
      expect(r['Ton-Aussetzer'], 'keine');
      r = rows(const EngineHealth(
          audioDecoder: 'c2.android.aac.decoder',
          audioOutputChannels: 2,
          audioUnderruns: 4));
      expect(r['Ton-Dekoder'], 'Gerät (c2.android.aac.decoder)');
      expect(r['Ton-Ausgabe'], 'Stereo');
      expect(r['Ton-Aussetzer'], '4');
      r = rows(const EngineHealth(passthrough: true, audioOutputChannels: 6));
      expect(r['Ton-Ausgabe'], 'Durchreichen an · 5.1');
      // mpv: keine Angaben → keine Zeilen.
      r = rows(const EngineHealth());
      expect(r.containsKey('Ton-Dekoder'), isFalse);
      expect(r.containsKey('Ton-Ausgabe'), isFalse);
      expect(r.containsKey('Ton-Aussetzer'), isFalse);
    });

    test('ExoEngine setzt nie eine Geschwindigkeit (Kanal-Aufrufe)', () async {
      final m =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final calls = <MethodCall>[];
      m.setMockMethodCallHandler(JspExoChannels.method, (c) async {
        calls.add(c);
        if (c.method == 'create') return {'id': 9, 'textureId': 1};
        return null;
      });
      final e = await ExoEngine.createForTest(const EngineConfig(engine: 'exo'));
      for (final o in {
        'user-agent': 'x',
        'demuxer-seekable-cache': 'yes',
        'demuxer-max-back-bytes': '100000000',
        'cache-pause-initial': 'yes',
        'speed': '1.03',
      }.entries) {
        await e.setOption(o.key, o.value);
      }
      await e.open('http://s/live.m3u8', live: true);
      await e.play();
      await e.setVolume(100);
      await e.dispose();
      expect(e.ignored, contains('speed'),
          reason: 'mpv-Option „speed“ wird nicht übernommen');
      for (final c in calls) {
        expect(c.method.toLowerCase(), isNot(contains('speed')));
        expect(c.method.toLowerCase(), isNot(contains('rate')));
        final a = c.arguments;
        if (a is Map) {
          expect(a.keys.map((k) => '$k'.toLowerCase()),
              isNot(anyElement(contains('speed'))));
        }
      }
      m.setMockMethodCallHandler(JspExoChannels.method, null);
    });
  });
}
