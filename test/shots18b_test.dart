import 'dart:async';
import 'dart:io';

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
import 'package:jason_stream_player/player/exo_engine.dart';
import 'package:jason_stream_player/player/media_session.dart';
import 'package:jason_stream_player/state/playback_session.dart';
import 'package:jason_stream_player/state/providers.dart';
import 'package:jason_stream_player/ui/nav.dart';
import 'package:jason_stream_player/ui/player/mini_player.dart';
import 'package:jason_stream_player/ui/player/player_debug.dart';
import 'package:jason_stream_player/ui/player/player_screen.dart';
import 'package:jason_stream_player/ui/settings/settings_screen.dart';
import 'package:jason_stream_player/ui/shell/reminder_host.dart'
    show appNavigatorKey;
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/app_fonts.dart';
import 'helpers/fake_engine.dart';
import 'helpers/tv_harness.dart';

/// 1.8b: Bildschirmfotos – Einstellung „Player-Engine“, Diagnose-Anzeige
/// mit ExoPlayer-Werten, ⋮-Menü „Player-Engine wechseln“, Hinweis
/// „Kompatibilitätsmodus (mpv)“. Nur mit `TV_SHOTS=ordner`.
final _shotDir = Platform.environment['TV_SHOTS'];

Future<void> _shot(WidgetTester tester, String name) =>
    writeShot(tester, tvShotKey, name);

const _portal = Portal(
    id: 'pa', name: 'Anbieter A', type: PortalType.xtream, url: 'http://a');

Channel _ch(int i) => Channel(
      id: 'c$i',
      name: ['Das Erste HD', 'ZDF HD', 'RTL HD', 'arte HD'][i % 4],
      categoryId: 'de',
      streamUrl: 'http://s/$i',
      number: i + 1,
    );

final _channels = [for (var i = 0; i < 4; i++) _ch(i)];

/// Beispielwerte, wie sie Media3 auf einer TV-Box meldet.
const _exoStats = <String, Object?>{
  'videoDecoder': 'c2.amlogic.hevc.decoder',
  'videoHw': true,
  'audioDecoder': 'ffmpegAudio',
  'audioHw': false,
  'videoMime': 'video/hevc',
  'audioMime': 'audio/eac3',
  'audioChannels': 6,
  'width': 1920,
  'height': 1080,
  'fps': 50.0,
  'dropped': 2,
  'bufferedMs': 14600,
  'bitrate': 7400000,
  'bandwidth': 38500000,
};

/// Fake mit Exo-Statistik für die Diagnose-Anzeige.
class _ExoFake extends FakeEngine implements EngineDiagnostics {
  _ExoFake(EngineConfig c) : super(id: c.engine, config: c);
  @override
  Future<List<String>> diagnostics() async => id == 'exo'
      ? ExoEngine.formatStats(_exoStats)
      : const ['mpv'];
}

Future<PlaybackEngine> _factory(EngineConfig c) async {
  final e = _ExoFake(c);
  FakeEngine.created.add(e);
  return e;
}

void main() {
  late Storage storage;
  final skip = _shotDir == null;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    L10n.lang = 'de';
    await initializeDateFormatting('de');
    await loadAppFonts();
    if (_shotDir != null) Directory(_shotDir!).createSync(recursive: true);
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

  Future<void> pumpPhone(WidgetTester tester, Widget home,
      {Size size = const Size(1080, 2280)}) async {
    tester.view.physicalSize = size;
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
            tv: false),
        playbackEngineProvider.overrideWithValue(_factory),
        mediaSessionProvider.overrideWithValue(NoopMediaSession()),
        exoAvailableProvider.overrideWithValue(true),
      ],
      child: RepaintBoundary(
        key: tvShotKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          navigatorKey: appNavigatorKey,
          theme: buildTheme(tv: false),
          builder: (context, child) => MiniPlayerHost(child: child!),
          home: home,
        ),
      ),
    ));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> done(WidgetTester tester) async {
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 12));
  }

  Future<FakeEngine> openLive(WidgetTester tester) async {
    unawaited(openPlayerAttached(PlayRequest(
      title: _channels[1].name,
      url: _channels[1].streamUrl,
      isLive: true,
      channels: _channels,
      channel: _channels[1],
    )));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(PlayerScreen), findsOneWidget);
    final e = FakeEngine.created.last;
    e.emit(width: 1920, buffering: false, playing: true);
    await tester.pump(const Duration(milliseconds: 300));
    return e;
  }

  testWidgets('Einstellung „Player-Engine“', skip: skip, (tester) async {
    await pumpPhone(tester, const Scaffold(body: SettingsScreen()));
    final item = find.byKey(const ValueKey('player-engine'));
    await tester.scrollUntilVisible(item, 300,
        scrollable: find.byType(Scrollable).first);
    await tester.pump(const Duration(milliseconds: 300));
    await _shot(tester, 'phone_setting_player_engine');
    await done(tester);
  });

  testWidgets('Diagnose-Anzeige mit ExoPlayer-Werten', skip: skip,
      (tester) async {
    await storage.setFlag(PlayerDebugInfo.flagKey, true);
    await pumpPhone(tester, const Scaffold(body: SizedBox()),
        size: const Size(2280, 1080));
    await openLive(tester);
    // Bedienelemente ausblenden (nur die Diagnose bleibt).
    await tester.pump(const Duration(seconds: 6));
    if (find.byIcon(Icons.more_vert_rounded).hitTestable().evaluate().isNotEmpty) {
      await tester.tapAt(const Offset(500, 250));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
    }
    expect(find.textContaining('c2.amlogic.hevc.decoder'), findsOneWidget);
    await _shot(tester, 'phone_player_diagnostics_exo');
    await done(tester);
  });

  testWidgets('⋮-Menü „Player-Engine wechseln“ und Hinweis', skip: skip,
      (tester) async {
    await pumpPhone(tester, const Scaffold(body: SizedBox()),
        size: const Size(2280, 1080));
    final exo = await openLive(tester);
    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
        find.byKey(const ValueKey('menu-engine')), 80,
        scrollable: find.byType(Scrollable).last);
    await tester.pumpAndSettle();
    await _shot(tester, 'phone_player_menu_engine');
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
    // Rückfall nach Decoder-Fehler → Hinweis „Kompatibilitätsmodus (mpv)“.
    exo.failWith(EngineErrorKind.decoder, 'Decoder error');
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    FakeEngine.created.last.emit(width: 1920, buffering: false, playing: true);
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Kompatibilitätsmodus (mpv)'), findsOneWidget);
    await _shot(tester, 'phone_player_compat_mpv');
    await done(tester);
  });
}
