import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:jason_stream_player/core/secret_store.dart';
import 'package:jason_stream_player/core/theme.dart';
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
import 'package:jason_stream_player/ui/settings/settings_screen.dart';
import 'package:jason_stream_player/ui/shell/reminder_host.dart'
    show appNavigatorKey;
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/fake_engine.dart';
import 'helpers/tv_harness.dart';

/// 1.8b: ExoPlayer als Standard-Engine, Rückfall-Leiter auf mpv (mit
/// Merken), „Engine wechseln“, Einstellung – mit Fake-Engines, die sich
/// wie „exo“/„mpv“ ausgeben.

const _portal = Portal(
    id: 'pa', name: 'Anbieter A', type: PortalType.xtream, url: 'http://a');

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

/// Handy quer (der Player läuft im Querformat).
Future<void> _pumpApp(WidgetTester tester, Storage storage,
    {bool exo = true, Widget? home}) async {
  tester.view.physicalSize =
      home == null ? const Size(2280, 1080) : const Size(1200, 2000);
  tester.view.devicePixelRatio = home == null ? 3 : 2;
  addTearDown(tester.view.reset);
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
      mediaSessionProvider.overrideWithValue(NoopMediaSession()),
      exoAvailableProvider.overrideWithValue(exo),
    ],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      navigatorKey: appNavigatorKey,
      theme: buildTheme(tv: false),
      builder: (context, child) => MiniPlayerHost(child: child!),
      home: home ??
          Builder(
            builder: (context) => Scaffold(
              body: const Text('Filme'),
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

Future<FakeEngine> _open(WidgetTester tester, String key) async {
  await tester.tap(find.byKey(ValueKey(key)));
  await _settle(tester);
  expect(find.byType(PlayerScreen), findsOneWidget);
  final e = FakeEngine.created.last;
  e.emit(width: 1920, buffering: false, playing: true);
  await tester.pump();
  return e;
}

/// ⋮-Menü öffnen (Bedienelemente ggf. erst einblenden).
Future<void> _openMore(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    final more = find.byIcon(Icons.more_vert_rounded);
    if (more.evaluate().isNotEmpty) {
      await tester.tap(more, warnIfMissed: false);
    } else {
      await tester.tapAt(const Offset(380, 180));
    }
    // Der Player erkennt Doppeltipps (Spulen) – der Tipp auf den Knopf
    // gewinnt erst nach Ablauf der Doppeltipp-Zeit.
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    if (find.byType(BottomSheet).evaluate().isNotEmpty) return;
  }
  fail('⋮-Menü ging nicht auf');
}

/// Eintrag in einem (ggf. scrollbaren) Auswahlblatt antippen.
Future<void> _menuTap(WidgetTester tester, String key, {bool tap = true}) async {
  final f = find.byKey(ValueKey(key));
  await tester.scrollUntilVisible(f, 80,
      scrollable: find.byType(Scrollable).last);
  await tester.pumpAndSettle();
  if (tap) {
    await tester.tap(f);
    await tester.pump();
  }
}

Future<void> _back(WidgetTester tester) async {
  await tester.binding.handlePopRoute();
  await tester.pump();
  await _settle(tester, 5);
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
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (c) async => null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('de.jasonstream.player/platform'),
            (c) async => c.method == 'isTv' ? false : null);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('de.jasonstream.player/platform'), null);
  });

  group('Engine-Wahl', () {
    test('Einstellung und Verfügbarkeit', () {
      expect(preferredEngine(storage, exoAvailable: true), EngineKind.exo);
      expect(preferredEngine(storage, exoAvailable: false), EngineKind.mpv);
      expect(preferredEngine(null, exoAvailable: true), EngineKind.exo);
      expect(EngineKind.fromId('mpv'), EngineKind.mpv);
      expect(EngineKind.fromId('irgendwas'), EngineKind.exo);
      expect(EngineKind.exo.other, EngineKind.mpv);
      expect(engineMemoryKey(_live(1), portalId: 'pa'), 'ch:pa:c1');
      expect(engineMemoryKey(_movie()), 'vod:movie-1');
    });

    testWidgets('Android: Standard ExoPlayer', (tester) async {
      await _pumpApp(tester, storage);
      final e = await _open(tester, 'open-live');
      expect(e.id, 'exo');
      expect(e.config.engine, 'exo');
      await _done(tester);
    });

    testWidgets('Einstellung mpv → mpv', (tester) async {
      await storage.setOption(EngineKind.optionKey, 'mpv');
      await _pumpApp(tester, storage);
      final e = await _open(tester, 'open-live');
      expect(e.id, 'mpv');
      await _done(tester);
    });

    testWidgets('Ohne ExoPlayer (nicht Android) → mpv, kein Wechsel im Menü',
        (tester) async {
      await _pumpApp(tester, storage, exo: false);
      final e = await _open(tester, 'open-movie');
      expect(e.id, 'mpv');
      await _openMore(tester);
      expect(find.byKey(const ValueKey('menu-engine')), findsNothing);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      await _done(tester);
    });
  });

  group('Rückfall-Leiter ExoPlayer → mpv', () {
    testWidgets('Decoder-Fehler live: mpv mit derselben Adresse, Hinweis, '
        'Sender dauerhaft gemerkt', (tester) async {
      await _pumpApp(tester, storage);
      final exo = await _open(tester, 'open-live');
      expect(exo.id, 'exo');
      exo.failWith(EngineErrorKind.decoder,
          'Decoder error (ERROR_CODE_DECODER_INIT_FAILED)');
      await tester.pump();
      await _settle(tester, 3);
      expect(FakeEngine.created, hasLength(2));
      final mpv = FakeEngine.created.last;
      expect(mpv.id, 'mpv');
      expect(mpv.calls, contains('open http://s/2'));
      expect(exo.disposed, isTrue, reason: 'alte Engine freigegeben');
      expect(find.text('Kompatibilitätsmodus (mpv)'), findsOneWidget);
      expect(storage.option(EngineMemory.storageKey, ''), contains('c2'));
      // Keine Fehlermeldung, kein Wiederverbinden auf der alten Engine.
      await tester.pump(const Duration(seconds: 2));
      expect(exo.calls.where((c) => c.startsWith('open')), hasLength(1));
      expect(FakeEngine.created, hasLength(2));
      await _done(tester);
    });

    testWidgets('Netzfehler: kein Wechsel, Wiederverbinden mit ExoPlayer',
        (tester) async {
      await _pumpApp(tester, storage);
      final exo = await _open(tester, 'open-live');
      exo.failWith(EngineErrorKind.network, 'HTTP error 503');
      await tester.pump(const Duration(milliseconds: 1600));
      await tester.pump(const Duration(seconds: 3));
      expect(FakeEngine.created, hasLength(1));
      expect(exo.calls.where((c) => c == 'open http://s/2').length,
          greaterThanOrEqualTo(2),
          reason: 'stilles Wiederverbinden');
      expect(find.text('Kompatibilitätsmodus (mpv)'), findsNothing);
      await _done(tester);
    });

    testWidgets('Film: Container-Fehler → mpv an derselben Stelle, nur für '
        'die Sitzung gemerkt', (tester) async {
      await _pumpApp(tester, storage);
      final exo = await _open(tester, 'open-movie');
      exo.emit(
          duration: const Duration(minutes: 100),
          position: const Duration(minutes: 10));
      await tester.pump();
      exo.failWith(EngineErrorKind.container, 'Container error');
      await tester.pump();
      await _settle(tester, 3);
      final mpv = FakeEngine.created.last;
      expect(mpv.id, 'mpv');
      expect(mpv.calls, contains('open http://s/movie.mp4'));
      mpv.emit(duration: const Duration(minutes: 100));
      await _settle(tester, 2);
      expect(mpv.calls, contains('seek 600'));
      expect(storage.option(EngineMemory.storageKey, ''), isEmpty,
          reason: 'Filme nicht dauerhaft');
      final container = ProviderScope.containerOf(
          tester.element(find.byType(PlayerScreen)));
      expect(container.read(engineMemoryProvider), contains('vod:movie-1'));
      // Stoppen und erneut öffnen (gleiche Sitzung) → gleich mpv.
      await container.read(playbackProvider.notifier).stop();
      await _back(tester);
      final again = await _open(tester, 'open-movie');
      expect(again.id, 'mpv');
      await _done(tester);
    });

    testWidgets('Gemerkter Sender startet direkt mit mpv, anderer Sender '
        'wieder mit ExoPlayer', (tester) async {
      await storage.setOption(
          EngineMemory.storageKey, Uri.encodeComponent('ch:pa:c2'));
      await _pumpApp(tester, storage);
      final e = await _open(tester, 'open-live');
      expect(e.id, 'mpv');
      expect(FakeEngine.created, hasLength(1));
      // Zappen auf Sender 3 (nicht gemerkt) → zurück auf ExoPlayer.
      final container = ProviderScope.containerOf(
          tester.element(find.byType(PlayerScreen)));
      await container.read(playbackProvider.notifier).zap(1);
      await _settle(tester, 8);
      expect(FakeEngine.created.last.id, 'exo');
      expect(e.disposed, isTrue);
      expect(FakeEngine.created.last.calls.last, startsWith('open http://s/'));
      await _done(tester);
    });

    testWidgets('Fehler unter mpv: kein weiterer Wechsel', (tester) async {
      await storage.setOption(EngineKind.optionKey, 'mpv');
      await _pumpApp(tester, storage);
      final e = await _open(tester, 'open-live');
      e.failWith(EngineErrorKind.decoder, 'Decoder error');
      await tester.pump(const Duration(seconds: 2));
      expect(FakeEngine.created, hasLength(1));
      await _done(tester);
    });
  });

  group('Engine wechseln (⋮)', () {
    testWidgets('Exo → mpv → Exo, Nur-Ton bleibt, Mini-Player läuft weiter',
        (tester) async {
      await _pumpApp(tester, storage);
      final exo = await _open(tester, 'open-movie');
      exo.emit(
          duration: const Duration(minutes: 100),
          position: const Duration(minutes: 5));
      // Nur-Ton an.
      await _openMore(tester);
      await _menuTap(tester, 'menu-audio-only');
      await tester.pumpAndSettle();
      expect(exo.calls, contains('video off'));
      // Wechsel zu mpv.
      await _openMore(tester);
      debugPrint('DBG after sheets=${find.byType(BottomSheet).evaluate().length} engine=${find.byKey(const ValueKey('menu-engine'), skipOffstage: false).evaluate().length} audio=${find.byKey(const ValueKey('menu-audio-only'), skipOffstage: false).evaluate().length}');
      await tester.pumpAndSettle();
      await _menuTap(tester, 'menu-engine', tap: false);
      expect(find.text('Aktuell: ExoPlayer'), findsOneWidget);
      await _menuTap(tester, 'menu-engine');
      await tester.pump();
      await _settle(tester, 3);
      final mpv = FakeEngine.created.last;
      expect(mpv.id, 'mpv');
      expect(find.text('Player-Engine: mpv'), findsOneWidget);
      mpv.emit(duration: const Duration(minutes: 100), width: 1920);
      await _settle(tester, 2);
      expect(mpv.calls, contains('seek 300'));
      expect(mpv.calls, contains('video off'), reason: 'Nur-Ton bleibt');
      // Mini-Player mit der neuen Engine.
      await _back(tester);
      expect(find.byKey(const ValueKey('mini-player')), findsOneWidget);
      expect(mpv.disposed, isFalse);
      await tester.tap(find.byKey(const ValueKey('mini-player')));
      await _settle(tester);
      expect(FakeEngine.created.last, same(mpv));
      // Zurück zu ExoPlayer über das Spuren-Blatt (auch TV/breit).
      await _openMore(tester);
      await tester.tap(find.text('Tonspur & Untertitel'));
      await tester.pumpAndSettle();
      await _menuTap(tester, 'track-engine', tap: false);
      expect(find.text('Aktuell: mpv'), findsOneWidget);
      await _menuTap(tester, 'track-engine');
      await tester.pump();
      await _settle(tester, 3);
      expect(FakeEngine.created.last.id, 'exo');
      expect(mpv.disposed, isTrue);
      await _done(tester);
    });
  });

  testWidgets('Einstellungen: Player-Engine ExoPlayer/mpv', (tester) async {
    await _pumpApp(tester, storage,
        home: const Scaffold(body: SettingsScreen()));
    await _settle(tester);
    final item = find.byKey(const ValueKey('player-engine'));
    await tester.scrollUntilVisible(item, 300,
        scrollable: find.byType(Scrollable).first);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('ExoPlayer (empfohlen)'), findsOneWidget);
    // Tippen schaltet weiter.
    await tester.tap(item);
    await _settle(tester, 3);
    expect(storage.option(EngineKind.optionKey, 'exo'), 'mpv');
    await _done(tester);
  });

  testWidgets('Einstellungen ohne ExoPlayer: kein Eintrag', (tester) async {
    await _pumpApp(tester, storage,
        exo: false, home: const Scaffold(body: SettingsScreen()));
    await _settle(tester);
    expect(find.byKey(const ValueKey('player-engine'), skipOffstage: false),
        findsNothing);
    await _done(tester);
  });
}
