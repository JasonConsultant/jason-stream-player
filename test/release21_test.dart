import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:jason_stream_player/core/secret_store.dart';
import 'package:jason_stream_player/core/theme.dart';
import 'package:jason_stream_player/data/host_failover.dart';
import 'package:jason_stream_player/data/storage.dart';
import 'package:jason_stream_player/l10n/strings.dart';
import 'package:jason_stream_player/models/models.dart';
import 'package:jason_stream_player/player/engine.dart';
import 'package:jason_stream_player/player/engine_choice.dart';
import 'package:jason_stream_player/player/media_session.dart';
import 'package:jason_stream_player/state/playback_session.dart';
import 'package:jason_stream_player/state/providers.dart';
import 'package:jason_stream_player/ui/nav.dart';
import 'package:jason_stream_player/ui/player/mini_player.dart';
import 'package:jason_stream_player/ui/player/player_screen.dart';
import 'package:jason_stream_player/ui/shell/reminder_host.dart'
    show appNavigatorKey;
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/fake_engine.dart';
import 'helpers/health_engine.dart';
import 'helpers/tv_harness.dart';

/// 2.1: Start-Leiter, Wachhunde, Verbindungs-Leiter, Zap-Schutz und
/// Stream-Info im echten PlayerScreen – mit Fake-Engines und Fake-Uhr
/// (testWidgets spult `clock` mit).

const _portal = Portal(
    id: 'pa',
    name: 'Anbieter A',
    type: PortalType.xtream,
    url: 'http://s',
    altUrls: ['http://backup']);

Channel _ch(int i) => Channel(
      id: 'c$i',
      name: 'Sender $i',
      categoryId: 'de',
      streamUrl: 'http://s/$i',
      number: i + 1,
    );

final _channels = [for (var i = 0; i < 5; i++) _ch(i)];

PlayRequest _movie() => const PlayRequest(
      title: 'Der große Film',
      url: 'http://s/movie.mp4',
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

Future<void> _pumpApp(WidgetTester tester, Storage storage,
    {bool tv = false, bool exo = true}) async {
  tester.view.physicalSize =
      tv ? const Size(1920, 1080) : const Size(2280, 1080);
  tester.view.devicePixelRatio = tv ? 2 : 3;
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
      playbackEngineProvider.overrideWithValue(HealthEngine.factory),
      mediaSessionProvider.overrideWithValue(NoopMediaSession()),
      exoAvailableProvider.overrideWithValue(exo),
    ],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      navigatorKey: appNavigatorKey,
      theme: buildTheme(tv: tv),
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
}

Future<void> _settle(WidgetTester tester, [int n = 6]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Öffnet den Player; [frame]: erstes Bild sofort melden.
Future<HealthEngine> _open(WidgetTester tester, String key,
    {bool frame = true}) async {
  await tester.tap(find.byKey(ValueKey(key)));
  await _settle(tester);
  expect(find.byType(PlayerScreen), findsOneWidget);
  final e = FakeEngine.created.last as HealthEngine;
  if (frame) {
    e.emit(width: 1920, buffering: false, playing: true);
    await tester.pump();
  }
  return e;
}

List<String> _opens(FakeEngine e) =>
    e.calls.where((c) => c.startsWith('open ')).toList();

/// Gute Wiedergabe: Position, Bilder und Ton laufen.
class _Clock {
  final HealthEngine e;
  int pos = 0, frames = 0, audio = 0;
  _Clock(this.e);

  void tick({bool video = true, bool sound = true, bool position = true}) {
    if (position) pos += 1000;
    if (video) frames += 25;
    if (sound) audio += 1000;
    e.h = EngineHealth(
      position: Duration(milliseconds: pos),
      videoFrames: frames,
      audioTicks: audio,
      droppedFrames: 0,
      hasVideoTrack: true,
      hasAudioTrack: true,
      fps: 25,
    );
    if (position) e.emit(position: Duration(milliseconds: pos));
  }
}

/// [n] Sekunden mit [tick] je Sekunde.
Future<void> _run(WidgetTester tester, int n, void Function() tick) async {
  for (var i = 0; i < n; i++) {
    tick();
    await tester.pump(const Duration(seconds: 1));
  }
}

Future<void> _done(WidgetTester tester) async {
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
    L10n.lang = 'de';
    FakeEngine.created.clear();
    HostFailover.reset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (c) async => null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('de.jasonstream.player/platform'),
            (c) async => c.method == 'isTv' ? false : null);
  });

  tearDown(() {
    HostFailover.reset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('de.jasonstream.player/platform'), null);
  });

  group('Start-Leiter', () {
    testWidgets('kein Bild in 8 s: erneut, vorsichtig, andere Engine – '
        'erfolgreiche Stufe gemerkt', (tester) async {
      await _pumpApp(tester, storage);
      final exo = await _open(tester, 'open-live', frame: false);
      expect(_opens(exo), ['open http://s/2']);
      await tester.pump(const Duration(seconds: 7));
      expect(_opens(exo), hasLength(1), reason: 'Zeitbudget 8 s');
      await tester.pump(const Duration(seconds: 2));
      // (a) gleiche Engine erneut, Hinweis dezent.
      expect(_opens(exo), hasLength(2));
      expect(find.byKey(const ValueKey('player-status')), findsOneWidget);
      expect(find.text('Verbindung wird wiederhergestellt …'), findsOneWidget);
      // (b) vorsichtiger Start.
      await tester.pump(const Duration(seconds: 9));
      expect(exo.calls, contains('set cache-pause-initial=yes'));
      expect(_opens(exo), hasLength(3));
      // (c) Software entfällt (ExoPlayer, kein Decoder-Fehler) → (d) mpv
      // (vorsichtiger Start: 12 s Budget).
      await tester.pump(const Duration(seconds: 13));
      expect(FakeEngine.created, hasLength(2));
      final mpv = FakeEngine.created.last as HealthEngine;
      expect(mpv.id, 'mpv');
      expect(_opens(mpv), ['open http://s/2']);
      mpv.emit(width: 1920, buffering: false, playing: true);
      await tester.pump(const Duration(seconds: 2));
      expect(find.byKey(const ValueKey('player-status')), findsNothing);
      final container = ProviderScope.containerOf(
          tester.element(find.byType(PlayerScreen)));
      final prof = container.read(startMemoryProvider).of('ch:pa:c2');
      expect(prof.careful, isTrue, reason: 'Stufe für den Sender gemerkt');
      await _done(tester);
    });

    testWidgets('Radio (nur Ton): laufende Position gilt als Start',
        (tester) async {
      await _pumpApp(tester, storage);
      final e = await _open(tester, 'open-live', frame: false);
      e.emit(buffering: false, playing: true);
      final c = _Clock(e);
      await _run(tester, 20, () {
        c.tick(video: false);
        e.h = EngineHealth(
            hasVideoTrack: false, hasAudioTrack: true, audioTicks: c.audio);
      });
      expect(_opens(e), hasLength(1));
      expect(find.byKey(const ValueKey('player-status')), findsNothing);
      await _done(tester);
    });
  });

  group('Wachhunde', () {
    testWidgets('Bild eingefroren > 7 s → an der Live-Kante neu öffnen',
        (tester) async {
      await _pumpApp(tester, storage);
      final e = await _open(tester, 'open-live');
      final c = _Clock(e);
      await _run(tester, 5, c.tick);
      await _run(tester, 6, () => c.tick(position: false, video: false));
      expect(_opens(e), hasLength(1));
      await _run(tester, 2, () => c.tick(position: false, video: false));
      expect(find.text('Bild hing – wird neu gestartet …'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      expect(_opens(e), hasLength(2));
      await _done(tester);
    });

    testWidgets('Pause: kein Fehlalarm', (tester) async {
      await _pumpApp(tester, storage);
      final e = await _open(tester, 'open-movie');
      final c = _Clock(e);
      await _run(tester, 3, c.tick);
      e.emit(playing: false);
      await _run(tester, 120,
          () => c.tick(position: false, video: false, sound: false));
      expect(_opens(e), hasLength(1));
      expect(e.calls.where((x) => x.startsWith('video')), isEmpty);
      await _done(tester);
    });

    testWidgets('kein Bild > 6 s: Videoausgabe neu, Hinweis', (tester) async {
      await _pumpApp(tester, storage);
      final e = await _open(tester, 'open-live');
      final c = _Clock(e);
      await _run(tester, 3, c.tick);
      await _run(tester, 8, () => c.tick(video: false));
      expect(e.calls, containsAllInOrder(['video off', 'video on']));
      expect(find.text('Bild hing – neu gestartet'), findsOneWidget);
      expect(_opens(e), hasLength(1), reason: 'erst ohne Neuöffnen');
      await _done(tester);
    });

    testWidgets('Nur-Ton: kein „kein Bild“-Alarm', (tester) async {
      await _pumpApp(tester, storage);
      final e = await _open(tester, 'open-live');
      final container = ProviderScope.containerOf(
          tester.element(find.byType(PlayerScreen)));
      await container.read(playbackProvider.notifier).setAudioOnly(true);
      final c = _Clock(e);
      await _run(tester, 40, () => c.tick(video: false));
      expect(e.calls.where((x) => x == 'video on'), isEmpty);
      expect(_opens(e), hasLength(1));
      await _done(tester);
    });

    testWidgets('Ton weg > 5 s: Tonspur neu wählen', (tester) async {
      await _pumpApp(tester, storage);
      final e = await _open(tester, 'open-live');
      final c = _Clock(e);
      await _run(tester, 3, c.tick);
      await _run(tester, 7, () => c.tick(sound: false));
      expect(e.calls, containsAllInOrder(['audio no', 'audio auto']));
      expect(find.text('Ton neu verbunden'), findsOneWidget);
      await _done(tester);
    });

    testWidgets('Dauer-Puffern > 15 s → Verbindungs-Leiter', (tester) async {
      await _pumpApp(tester, storage);
      final e = await _open(tester, 'open-live');
      final c = _Clock(e);
      await _run(tester, 3, c.tick);
      e.emit(buffering: true);
      await _run(tester, 14,
          () => c.tick(position: false, video: false, sound: false));
      expect(_opens(e), hasLength(1));
      await _run(tester, 3,
          () => c.tick(position: false, video: false, sound: false));
      expect(_opens(e), hasLength(2));
      await _done(tester);
    });

    testWidgets('höchstens 3 Eingriffe je 5 min, dann Fehlermeldung',
        (tester) async {
      await _pumpApp(tester, storage);
      final e = await _open(tester, 'open-live');
      final c = _Clock(e);
      for (var ep = 0; ep < 3; ep++) {
        // 61 s gut (Leiter beginnt von vorn), dann hängt das Bild.
        await _run(tester, 62, c.tick);
        await _run(tester, 9, () => c.tick(position: false, video: false));
        await tester.pump(const Duration(seconds: 1));
        e.emit(width: 1920, buffering: false, playing: true);
      }
      expect(_opens(e), hasLength(4));
      await _run(tester, 62, c.tick);
      await _run(tester, 9, () => c.tick(position: false, video: false));
      expect(
          find.textContaining('Die automatischen Versuche wurden beendet'),
          findsOneWidget);
      expect(find.text('Erneut versuchen'), findsOneWidget);
      // Keine weiteren Versuche.
      await _run(tester, 30, () => c.tick(position: false, video: false));
      expect(_opens(e), hasLength(4));
      // „Erneut versuchen“ → Budget wieder voll.
      await tester.tap(find.text('Erneut versuchen'));
      await _settle(tester);
      expect(_opens(e), hasLength(5));
      await _done(tester);
    });
  });

  group('Verbindungs-Leiter', () {
    testWidgets('HTTP 429: lange warten statt hämmern', (tester) async {
      await _pumpApp(tester, storage);
      final e = await _open(tester, 'open-live');
      e.fail('HTTP error 429 Too Many Requests');
      await tester.pump(const Duration(milliseconds: 1600));
      expect(find.text('Anbieter bremst – neuer Versuch in 8 s'),
          findsOneWidget);
      await tester.pump(const Duration(seconds: 6));
      expect(_opens(e), hasLength(1), reason: 'nicht hämmern');
      await tester.pump(const Duration(seconds: 3));
      expect(_opens(e), hasLength(2));
      await _done(tester);
    });

    testWidgets('Netzfehler: 0,5 s, dann wachsende Wartezeiten',
        (tester) async {
      await _pumpApp(tester, storage);
      final e = await _open(tester, 'open-live');
      e.fail('tcp: Connection timed out');
      await tester.pump(const Duration(milliseconds: 1600));
      await tester.pump(const Duration(milliseconds: 600));
      expect(_opens(e), hasLength(2));
      e.fail('tcp: Connection timed out');
      await tester.pump(const Duration(milliseconds: 1600));
      await tester.pump(const Duration(milliseconds: 600));
      expect(_opens(e), hasLength(2), reason: 'zweite Stufe 1 s');
      await tester.pump(const Duration(milliseconds: 500));
      expect(_opens(e), hasLength(3));
      await _done(tester);
    });

    testWidgets('404: Ersatz-Adresse des Portals für denselben Stream',
        (tester) async {
      await _pumpApp(tester, storage);
      final e = await _open(tester, 'open-live');
      e.fail('HTTP error 404 Not Found');
      await tester.pump(const Duration(milliseconds: 1600));
      expect(find.text('Wechsle auf Ersatz-Server …'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 500));
      expect(_opens(e).last, 'open http://backup/2');
      // Läuft → Ersatz-Adresse gemerkt (auch für andere Sender).
      final c = _Clock(e);
      e.emit(width: 1920, buffering: false, playing: true);
      await _run(tester, 3, c.tick);
      expect(HostFailover.activeBase(_portal), 'http://backup');
      await _done(tester);
    });
  });

  group('Zap-Schutz', () {
    testWidgets('schnelle CH+-Folge: Anzeige sofort, nur letzter Sender '
        'wird geöffnet', (tester) async {
      await _pumpApp(tester, storage);
      final e = await _open(tester, 'open-live');
      final ctl = ProviderScope.containerOf(
              tester.element(find.byType(PlayerScreen)))
          .read(playbackProvider.notifier);
      await ctl.zap(1); // einzeln → sofort
      await tester.pump();
      expect(_opens(e).last, 'open http://s/3');
      await tester.pump(const Duration(milliseconds: 200));
      await ctl.zap(1);
      await tester.pump(const Duration(milliseconds: 200));
      await ctl.zap(1);
      await tester.pump();
      // Anzeige schon beim neuen Sender, Stream noch nicht offen.
      expect(ctl.session!.request.channel!.id, 'c0');
      expect(_opens(e), ['open http://s/2', 'open http://s/3']);
      await tester.pump(const Duration(milliseconds: 400));
      expect(_opens(e), hasLength(2));
      await tester.pump(const Duration(milliseconds: 200));
      expect(_opens(e), ['open http://s/2', 'open http://s/3', 'open http://s/0']);
      // Nach Ruhe ≥ 1,5 s: wieder sofort.
      await tester.pump(const Duration(seconds: 2));
      await ctl.zap(-1);
      await tester.pump();
      expect(_opens(e).last, 'open http://s/4');
      await _done(tester);
    });

    testWidgets('Mini-Player/Benachrichtigung: ebenfalls verzögert',
        (tester) async {
      await _pumpApp(tester, storage);
      final e = await _open(tester, 'open-live');
      await tester.binding.handlePopRoute();
      await _settle(tester);
      expect(find.byKey(const ValueKey('mini-player')), findsOneWidget);
      final ctl = ProviderScope.containerOf(
              tester.element(find.byKey(const ValueKey('mini-player'))))
          .read(playbackProvider.notifier);
      await ctl.zap(1);
      await tester.pump(const Duration(milliseconds: 100));
      await ctl.zap(1);
      await tester.pump(const Duration(milliseconds: 100));
      expect(_opens(e), ['open http://s/2', 'open http://s/3']);
      await tester.pump(const Duration(milliseconds: 600));
      expect(_opens(e).last, 'open http://s/4');
      await _done(tester);
    });
  });

  group('Stream-Info', () {
    testWidgets('⋮ → Stream-Info: verständliche Angaben', (tester) async {
      await _pumpApp(tester, storage);
      final e = await _open(tester, 'open-movie');
      e.h = const EngineHealth(
        width: 1920,
        height: 1080,
        fps: 25,
        videoCodec: 'h264',
        audioCodec: 'E-AC3',
        audioChannels: 6,
        sampleRate: 48000,
        videoBitrate: 6200000,
        bufferSeconds: 14.2,
        hardwareDecoder: true,
        videoDecoder: 'c2.android.avc.decoder',
        droppedFrames: 3,
        hasVideoTrack: true,
        hasAudioTrack: true,
      );
      for (var i = 0; i < 3; i++) {
        final more = find.byIcon(Icons.more_vert_rounded);
        if (more.evaluate().isNotEmpty) {
          await tester.tap(more, warnIfMissed: false);
        } else {
          await tester.tapAt(const Offset(380, 180));
        }
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pumpAndSettle();
        if (find.byType(BottomSheet).evaluate().isNotEmpty) break;
      }
      final item = find.byKey(const ValueKey('menu-stream-info'));
      await tester.scrollUntilVisible(item, 80,
          scrollable: find.byType(Scrollable).last);
      // Eintrag liegt am Rand des Blatts – direkt auslösen.
      tester.widget<ListTile>(item).onTap!();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('stream-info')), findsOneWidget);
      for (final t in [
        'ExoPlayer',
        '1920 × 1080 (Full HD)',
        '25 fps',
        'H.264 (AVC)',
        'Dolby Digital Plus (E-AC3) · 5.1 · 48 kHz',
        '6,2 Mbit/s',
        '14,2 s',
        'Hardware (c2.android.avc.decoder)',
        'keine',
      ]) {
        // Niedriger Bildschirm: Blatt bei Bedarf weiterblättern.
        await tester.scrollUntilVisible(find.text(t), 60,
            scrollable: find.byType(Scrollable).last);
        expect(find.text(t), findsOneWidget, reason: t);
      }
      await tester.scrollUntilVisible(
          find.byKey(const ValueKey('stream-info-decoder')), 60,
          scrollable: find.byType(Scrollable).last);
      expect(e.fullCalls, greaterThan(0), reason: 'volle Messwerte');
      // Dekoder wechseln → Software, gleiche Stelle neu öffnen.
      await tester.tap(find.byKey(const ValueKey('stream-info-decoder')));
      await _settle(tester, 5);
      expect(e.calls, contains('set hwdec=no'));
      expect(_opens(e), hasLength(2));
      await _done(tester);
    });

    testWidgets('Fernseher: Stream-Info über das Spuren-Blatt',
        (tester) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('de.jasonstream.player/platform'),
              (c) async => c.method == 'isTv' ? true : null);
      await _pumpApp(tester, storage, tv: true);
      await _open(tester, 'open-live');
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      // Spuren-Blatt über „Tonspur & Untertitel“ (Knopf oben).
      await tester.tap(find.byIcon(Icons.subtitles_outlined).first);
      await tester.pumpAndSettle();
      final item = find.byKey(const ValueKey('track-stream-info'));
      await tester.scrollUntilVisible(item, 80,
          scrollable: find.byType(Scrollable).last);
      await tester.tap(item);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('stream-info')), findsOneWidget);
      expect(find.text('Stream-Info'), findsOneWidget);
      await _done(tester);
    });
  });
}
