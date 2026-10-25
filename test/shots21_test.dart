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
import 'package:jason_stream_player/player/media_session.dart';
import 'package:jason_stream_player/state/playback_session.dart';
import 'package:jason_stream_player/state/providers.dart';
import 'package:jason_stream_player/ui/nav.dart';
import 'package:jason_stream_player/ui/player/mini_player.dart';
import 'package:jason_stream_player/ui/player/player_screen.dart';
import 'package:jason_stream_player/ui/shell/reminder_host.dart'
    show appNavigatorKey;
import 'package:jason_stream_player/ui/tv/tv_safe.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/app_fonts.dart';
import 'helpers/fake_engine.dart';
import 'helpers/health_engine.dart';
import 'helpers/tv_harness.dart';

/// 2.1: Bildschirmfotos – Stream-Info (Handy, Fernseher) und dezente
/// Status-Hinweise bei automatischen Eingriffen. Nur mit `TV_SHOTS=ordner`.
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

const _movieReq = PlayRequest(
  title: 'Nebelgrenze',
  subtitle: '2021 · Drama · 112 Min.',
  url: 'http://s/m1',
  resumeKey: 'm1',
  artworkSeed: 'Nebelgrenze',
);

PlayRequest _liveReq() => PlayRequest(
      title: _channels[1].name,
      url: _channels[1].streamUrl,
      isLive: true,
      channels: _channels,
      channel: _channels[1],
      artworkSeed: _channels[1].name,
    );

const _hd = EngineHealth(
  width: 1920,
  height: 1080,
  fps: 50,
  videoCodec: 'h264',
  audioCodec: 'aac',
  audioChannels: 2,
  sampleRate: 48000,
  videoBitrate: 7400000,
  audioBitrate: 192000,
  bandwidth: 38000000,
  bufferSeconds: 18.4,
  hardwareDecoder: true,
  videoDecoder: 'c2.amlogic.avc.decoder',
  droppedFrames: 2,
  hasVideoTrack: true,
  hasAudioTrack: true,
);

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

  void platform({required bool tv}) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('de.jasonstream.player/platform'),
            (c) async => c.method == 'isTv' ? tv : null);
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    storage = await Storage.open(store: PreviewSecretStore());
    await storage.setOption('applang', 'de');
    L10n.lang = 'de';
    FakeEngine.created.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (c) async => null);
    platform(tv: false);
    // Cast-/Netz-Ereignisse gibt es im Test nicht.
    for (final ch in ['de.jasonstream/cast/events', 'de.jasonstream/network/events']) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(ch), (c) async => null);
    }
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('de.jasonstream.player/platform'), null);
  });

  TvData data() => TvData(
        live: LiveData(
            const [Category(id: 'de', name: 'Deutschland')], _channels),
        portal: _portal,
      );

  Future<void> pump(WidgetTester tester, {required bool tv}) async {
    tester.view.physicalSize =
        tv ? const Size(1920, 1080) : const Size(2280, 1080);
    tester.view.devicePixelRatio = tv ? 2 : 3;
    addTearDown(tester.view.reset);
    platform(tv: tv);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        ...tvOverrides(data(), Future.value(storage), tv: tv),
        playbackEngineProvider.overrideWithValue(HealthEngine.factory),
        mediaSessionProvider.overrideWithValue(NoopMediaSession()),
        exoAvailableProvider.overrideWithValue(true),
      ],
      child: RepaintBoundary(
        key: tvShotKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          navigatorKey: appNavigatorKey,
          theme: buildTheme(tv: tv),
          builder: (context, child) => tv
              ? TvSafeMediaQuery(enabled: true, child: child!)
              : MiniPlayerHost(child: child!),
          home: const Scaffold(body: SizedBox()),
        ),
      ),
    ));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<HealthEngine> start(WidgetTester tester, PlayRequest req) async {
    unawaited(openPlayerAttached(req));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(PlayerScreen), findsOneWidget);
    final e = FakeEngine.created.last as HealthEngine;
    e.h = _hd;
    e.emit(
        width: 1920,
        buffering: false,
        playing: true,
        duration: req.isLive ? null : const Duration(minutes: 112),
        position: req.isLive ? null : const Duration(minutes: 37));
    await tester.pump();
    return e;
  }

  /// Ein Eingriff, damit „Letzte Eingriffe“ etwas zeigt: kurzer Netzfehler,
  /// danach läuft es wieder.
  Future<void> hiccup(WidgetTester tester, HealthEngine e) async {
    e.fail('tcp: Connection timed out');
    await tester.pump(const Duration(milliseconds: 1600));
    await tester.pump(const Duration(milliseconds: 600));
    e.emit(width: 1920, buffering: false, playing: true);
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> done(WidgetTester tester) async {
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 12));
  }

  testWidgets('Handy: Stream-Info über ⋮', skip: skip, (tester) async {
    await pump(tester, tv: false);
    final e = await start(tester, _movieReq);
    await hiccup(tester, e);
    await tester.tap(find.byIcon(Icons.more_vert_rounded), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    await _shot(tester, 'phone_player_menu_stream_info');
    final item = find.byKey(const ValueKey('menu-stream-info'));
    await tester.scrollUntilVisible(item, 80,
        scrollable: find.byType(Scrollable).last);
    tester.widget<ListTile>(item).onTap!();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('stream-info')), findsOneWidget);
    await _shot(tester, 'phone_stream_info');
    // Hochkant: mehr Platz für alle Zeilen.
    tester.view.physicalSize = const Size(1080, 2280);
    await tester.pumpAndSettle();
    await _shot(tester, 'phone_stream_info_portrait');
    await done(tester);
  });

  testWidgets('Fernseher: Stream-Info über das Spuren-Blatt', skip: skip,
      (tester) async {
    await pump(tester, tv: true);
    final e = await start(tester, _liveReq());
    await hiccup(tester, e);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.subtitles_outlined).first);
    await tester.pumpAndSettle();
    final item = find.byKey(const ValueKey('track-stream-info'));
    await tester.scrollUntilVisible(item, 80,
        scrollable: find.byType(Scrollable).last);
    await tester.pumpAndSettle();
    await _shot(tester, 'tv_tracks_stream_info_entry');
    tester.widget<ListTile>(item).onTap!();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('stream-info')), findsOneWidget);
    await _shot(tester, 'tv_stream_info');
    await done(tester);
  });

  testWidgets('Status-Hinweise bei automatischen Eingriffen', skip: skip,
      (tester) async {
    await pump(tester, tv: false);
    final e = await start(tester, _liveReq());
    // Bild läuft, dann steht es → „Bild hing – wird neu gestartet …“.
    var pos = 0;
    for (var i = 0; i < 4; i++) {
      pos += 1000;
      e.emit(position: Duration(milliseconds: pos));
      await tester.pump(const Duration(seconds: 1));
    }
    // Bedienelemente ausblenden (Hinweis unten, dezent).
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(seconds: 1));
      if (find.text('Bild hing – wird neu gestartet …').evaluate().isNotEmpty) {
        break;
      }
    }
    expect(find.text('Bild hing – wird neu gestartet …'), findsOneWidget);
    await _shot(tester, 'phone_status_frozen');
    // Läuft wieder; dann Netzfehler → „Verbindung wird wiederhergestellt …“
    e.emit(width: 1920, buffering: false, playing: true);
    await tester.pump(const Duration(seconds: 1));
    e.fail('tcp: Connection timed out');
    await tester.pump(const Duration(milliseconds: 1600));
    await _shot(tester, 'phone_status_reconnect');
    await tester.pump(const Duration(seconds: 2));
    e.emit(width: 1920, buffering: false, playing: true);
    await tester.pump(const Duration(milliseconds: 300));
    await done(tester);
  });

  testWidgets('Fernseher: Hinweis ohne Fokus, Toast „Bild hing“', skip: skip,
      (tester) async {
    await pump(tester, tv: true);
    final e = await start(tester, _liveReq());
    var pos = 0, frames = 0, audio = 0;
    // Ton/Position laufen, Bild steht → Videoausgabe neu (Toast).
    for (var i = 0; i < 12; i++) {
      pos += 1000;
      audio += 1000;
      if (i < 3) frames += 50;
      e.h = EngineHealth(
          videoFrames: frames,
          audioTicks: audio,
          hasVideoTrack: true,
          hasAudioTrack: true,
          fps: 50,
          droppedFrames: 0);
      e.emit(position: Duration(milliseconds: pos));
      await tester.pump(const Duration(seconds: 1));
      if (find.text('Bild hing – neu gestartet').evaluate().isNotEmpty) break;
    }
    expect(find.text('Bild hing – neu gestartet'), findsOneWidget);
    final focus = FocusManager.instance.primaryFocus;
    await _shot(tester, 'tv_toast_video_restarted');
    expect(FocusManager.instance.primaryFocus, same(focus),
        reason: 'Hinweis nimmt keinen Fokus');
    // Netzfehler → Status-Hinweis.
    e.fail('tcp: Connection timed out');
    await tester.pump(const Duration(milliseconds: 1600));
    expect(find.byKey(const ValueKey('player-status')), findsOneWidget);
    await _shot(tester, 'tv_status_reconnect');
    await tester.pump(const Duration(seconds: 2));
    e.emit(width: 1920, buffering: false, playing: true);
    await tester.pump(const Duration(milliseconds: 300));
    await done(tester);
  });
}
