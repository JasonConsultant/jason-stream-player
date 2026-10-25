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
import 'package:jason_stream_player/player/media_session.dart';
import 'package:jason_stream_player/state/playback_session.dart';
import 'package:jason_stream_player/state/providers.dart';
import 'package:jason_stream_player/ui/nav.dart';
import 'package:jason_stream_player/ui/player/mini_player.dart';
import 'package:jason_stream_player/ui/player/player_screen.dart';
import 'package:jason_stream_player/ui/settings/settings_screen.dart';
import 'package:jason_stream_player/ui/shell/reminder_host.dart'
    show appNavigatorKey;
import 'package:jason_stream_player/ui/vod/vod_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/app_fonts.dart';
import 'helpers/fake_engine.dart';
import 'helpers/tv_harness.dart';

/// 1.8 Teil 1: Bildschirmfotos (Handy 1080×2280) – Mini-Player über der
/// Filme-Seite, Einstellung „Zurück im Player“, Nur-Ton-Anzeige.
/// Nur mit `TV_SHOTS=ordner`.
final _shotDir = Platform.environment['TV_SHOTS'];

Future<void> _shot(WidgetTester tester, String name) =>
    writeShot(tester, tvShotKey, name);

const _portal = Portal(
    id: 'pa', name: 'Anbieter A', type: PortalType.xtream, url: 'http://a');

final _movies = VodData([
  const Category(id: 'm1', name: 'Neu im Kino'),
  const Category(id: 'm2', name: 'Action'),
  const Category(id: 'm3', name: 'Komödie'),
], [
  for (var i = 0; i < 24; i++)
    VodItem(
      id: 'm$i',
      name: [
        'Die Stunde der Wölfe', 'Nebelgrenze', 'Orbit 9', 'Kalter Hafen',
        'Signal aus der Tiefe', 'Die Glasstadt', 'Feuerlinie', 'Funkel',
      ][i % 8],
      categoryId: 'm${1 + i % 3}',
      streamUrl: 'http://s/m$i',
      year: 2015 + i % 10,
      rating: 5 + (i % 5),
      genre: i.isEven ? 'Drama' : 'Action',
    ),
]);

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

  TvData data() => TvData(
        live: LiveData(
            const [Category(id: 'de', name: 'Deutschland')], _channels),
        movies: _movies,
        portal: _portal,
        account: AccountInfo(
            status: 'Active',
            expires: DateTime.now().add(const Duration(days: 200))),
      );

  Future<void> pumpPhone(WidgetTester tester, Widget home,
      {Size size = const Size(1080, 2280)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        ...tvOverrides(data(), Future.value(storage), tv: false),
        playbackEngineProvider.overrideWithValue(FakeEngine.factory),
        mediaSessionProvider.overrideWithValue(NoopMediaSession()),
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

  testWidgets('Mini-Player über der Filme-Seite', skip: skip, (tester) async {
    await pumpPhone(
        tester,
        Scaffold(
          body: const VodScreen(series: false),
          bottomNavigationBar: NavigationBar(selectedIndex: 2, destinations: [
            NavigationDestination(
                icon: const Icon(Icons.home_rounded), label: tr('Start')),
            NavigationDestination(
                icon: const Icon(Icons.live_tv_rounded), label: tr('Live TV')),
            NavigationDestination(
                icon: const Icon(Icons.movie_rounded), label: tr('Filme')),
            NavigationDestination(
                icon: const Icon(Icons.settings_rounded),
                label: tr('Einstellungen')),
          ]),
        ));
    // Film im Player starten und mit Zurück verlassen → Mini-Player.
    unawaited(openPlayerAttached(_movieReq));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(PlayerScreen), findsOneWidget);
    final e = FakeEngine.created.single;
    e.emit(width: 1920, buffering: false, playing: true,
        duration: const Duration(minutes: 112),
        position: const Duration(minutes: 37));
    await tester.binding.handlePopRoute();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byKey(const ValueKey('mini-player')), findsOneWidget);
    await _shot(tester, 'phone_mini_player_movies');
    await done(tester);
  });

  testWidgets('Einstellung „Zurück im Player“', skip: skip, (tester) async {
    await pumpPhone(tester, const Scaffold(body: SettingsScreen()));
    final item = find.byKey(const ValueKey('leave-player'));
    await tester.scrollUntilVisible(item, 300,
        scrollable: find.byType(Scrollable).first);
    await tester.pump(const Duration(milliseconds: 300));
    await _shot(tester, 'phone_setting_leave_player');
    await done(tester);
  });

  testWidgets('Nur-Ton-Anzeige im Player', skip: skip, (tester) async {
    await pumpPhone(tester, const Scaffold(body: SizedBox()),
        size: const Size(2280, 1080));
    unawaited(openPlayerAttached(_movieReq));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final e = FakeEngine.created.single;
    e.emit(width: 1920, buffering: false, playing: true,
        duration: const Duration(minutes: 112),
        position: const Duration(minutes: 37));
    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();
    await _shot(tester, 'phone_player_menu_audio_only');
    await tester.scrollUntilVisible(
        find.byKey(const ValueKey('menu-audio-only')), 80,
        scrollable: find.byType(Scrollable).last);
    await tester.tap(find.byKey(const ValueKey('menu-audio-only')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('audio-only-badge')), findsOneWidget);
    await _shot(tester, 'phone_player_audio_only');
    // Zurück: Mini-Player im Nur-Ton-Modus.
    await tester.binding.handlePopRoute();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    tester.view.physicalSize = const Size(1080, 2280);
    await tester.pump(const Duration(milliseconds: 300));
    await _shot(tester, 'phone_mini_player_audio_only');
    await done(tester);
  });
}
