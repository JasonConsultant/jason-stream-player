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
import 'package:jason_stream_player/state/discover.dart';
import 'package:jason_stream_player/state/playback_session.dart';
import 'package:jason_stream_player/state/providers.dart';
import 'package:jason_stream_player/ui/live/channel_sheet.dart';
import 'package:jason_stream_player/ui/live/live_screen.dart';
import 'package:jason_stream_player/ui/nav.dart';
import 'package:jason_stream_player/ui/player/mini_player.dart';
import 'package:jason_stream_player/ui/shell/home_shell.dart';
import 'package:jason_stream_player/ui/shell/reminder_host.dart'
    show appNavigatorKey;
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/app_fonts.dart';
import 'helpers/fake_engine.dart';
import 'helpers/tv_harness.dart';

/// 1.9: Bildschirmfotos Handy hoch (1080×2280) und Tablet quer
/// (2560×1600, dpr 2) – Leiste unten, Rail, Gruppen-Übersicht, Sender-Menü,
/// Mini-Player über der Leiste. Nur mit `TV_SHOTS=ordner`.
final _shotDir = Platform.environment['TV_SHOTS'];

Future<void> _shot(WidgetTester tester, String name) =>
    writeShot(tester, tvShotKey, name);

const _portal = Portal(
    id: 'pa', name: 'Anbieter A', type: PortalType.xtream, url: 'http://a');

const _titles = [
  'Die Stunde der Wölfe', 'Nebelgrenze', 'Orbit 9', 'Kalter Hafen',
  'Signal aus der Tiefe', 'Die Glasstadt', 'Feuerlinie', 'Funkel',
  'Babam ve Oğlum', 'Kış Uykusu', 'Ayla', 'Müslüm', 'Night Shift',
  'Metropolis', 'Der Pate', 'Heat', 'Paper Moon', 'Atlas Drift',
];

final _movies = VodData([
  const Category(id: 'de1', name: 'DE | Kinofilme 2024'),
  const Category(id: 'de2', name: 'DE | Action'),
  const Category(id: 'de3', name: 'DE · Komödie'),
  const Category(id: 'tr1', name: 'TR • Yerli Filmler'),
  const Category(id: 'tr2', name: 'TR | Aksiyon'),
  const Category(id: 'en1', name: 'EN: Blockbuster'),
  const Category(id: 'ku', name: 'KU | Fîlm'),
  const Category(id: 'kids', name: 'Kinder & Familie'),
  const Category(id: 'cls', name: 'Klassiker'),
], [
  for (var i = 0; i < 96; i++)
    VodItem(
      id: 'm$i',
      name: _titles[i % _titles.length] + (i >= _titles.length ? ' ${i ~/ _titles.length + 1}' : ''),
      categoryId: const [
        'de1', 'de2', 'de3', 'tr1', 'tr2', 'en1', 'ku', 'kids', 'cls',
        'de1', 'de2', 'tr1',
      ][i % 12],
      streamUrl: 'http://s/m$i',
      year: i % 9 == 8 ? 1960 + i % 19 : 2008 + i % 17,
      rating: 5.5 + (i % 9) / 2,
      genre: const [
        'Drama', 'Action, Thriller', 'Komödie', 'Dram', 'Aksiyon',
        'Science-Fiction', 'Animation, Familie', 'Krimi', 'Horror',
        'Abenteuer', 'Dokumentation', 'Romantik',
      ][i % 12],
    ),
]);

Channel _ch(int i) => Channel(
      id: 'c$i',
      name: ['Das Erste HD', 'ZDF HD', 'RTL HD', 'arte HD', 'TRT 1 HD',
          'ProSieben HD'][i % 6],
      categoryId: 'de',
      streamUrl: 'http://s/$i',
      number: i + 1,
      catchupDays: i == 0 ? 7 : 0,
    );

final _channels = [for (var i = 0; i < 12; i++) _ch(i)];

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
    debugDiscoverSync = true;
    FakeEngine.created.clear();
    MiniPlayer.corner = MiniCorner.bottomRight;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (c) async => null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('de.jasonstream.player/platform'),
            (c) async => c.method == 'isTv' ? false : null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('de.jasonstream/cast/events'), (c) async => null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('de.jasonstream/network/events'),
            (c) async => null);
  });

  tearDown(() {
    debugDiscoverSync = false;
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
        series: _movies,
        portal: _portal,
        account: AccountInfo(
            status: 'Active',
            expires: DateTime.now().add(const Duration(days: 200))),
      );

  /// Handy hoch 1080×2280 (dpr 3) bzw. Tablet quer 2560×1600 (dpr 2), mit
  /// Statusleiste und Gestenleiste (randlos).
  Future<void> pump(WidgetTester tester, {bool tablet = false}) async {
    tester.view.physicalSize =
        tablet ? const Size(2560, 1600) : const Size(1080, 2280);
    tester.view.devicePixelRatio = tablet ? 2 : 3;
    tester.view.padding = tablet
        ? const FakeViewPadding(top: 48, bottom: 32)
        : const FakeViewPadding(top: 72, bottom: 48);
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
          home: const HomeShell(),
        ),
      ),
    ));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> tapBar(WidgetTester tester, String label) async {
    final bar = find.byType(NavigationBar).evaluate().isEmpty
        ? find.byType(NavigationRail)
        : find.byType(NavigationBar);
    await tester.tap(find.descendant(of: bar, matching: find.text(label)));
    await settle(tester);
  }

  Future<void> view(WidgetTester tester, String name) async {
    final chip = find.byKey(ValueKey('vod-view-$name'));
    await tester.ensureVisible(chip);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(chip);
    await settle(tester);
  }

  Future<void> done(WidgetTester tester) async {
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 12));
  }

  testWidgets('Handy: Start mit Leiste unten, Mehr', skip: skip,
      (tester) async {
    await pump(tester);
    await _shot(tester, 'phone_start_navbar');
    await tapBar(tester, 'Mehr');
    await _shot(tester, 'phone_more');
    await done(tester);
  });

  testWidgets('Handy: Filme-Gruppen (Genre, Jahr, Sprache, Kategorie)',
      skip: skip, (tester) async {
    await pump(tester);
    await tapBar(tester, 'Filme');
    await _shot(tester, 'phone_movies_discover');
    await view(tester, 'genre');
    await _shot(tester, 'phone_movies_groups_genre');
    await view(tester, 'year');
    await _shot(tester, 'phone_movies_groups_year');
    await view(tester, 'language');
    await _shot(tester, 'phone_movies_groups_language');
    await view(tester, 'category');
    await _shot(tester, 'phone_movies_groups_category');
    await view(tester, 'language');
    await tester.tap(find.byKey(const ValueKey('vod-group-TR')));
    await settle(tester);
    await _shot(tester, 'phone_movies_group_turkish');
    await done(tester);
  });

  testWidgets('Handy: Sender-Menü als Blatt', skip: skip, (tester) async {
    await pump(tester);
    await tapBar(tester, 'Live TV');
    final ctx = tester.element(find.byType(LiveScreen));
    unawaited(showChannelSheet(ctx, ctx as WidgetRef, _channels[1]));
    await tester.pumpAndSettle();
    await _shot(tester, 'phone_channel_sheet');
    await done(tester);
  });

  testWidgets('Handy: Mini-Player über der Leiste', skip: skip,
      (tester) async {
    await pump(tester);
    await tapBar(tester, 'Filme');
    unawaited(openPlayerAttached(_movieReq));
    await settle(tester);
    FakeEngine.created.single.emit(
        width: 1920,
        buffering: false,
        playing: true,
        duration: const Duration(minutes: 112),
        position: const Duration(minutes: 37));
    await tester.binding.handlePopRoute();
    await settle(tester);
    expect(find.byKey(const ValueKey('mini-player')), findsOneWidget);
    await _shot(tester, 'phone_mini_player_bar');
    await tester.tap(find.byKey(const ValueKey('mini-close')));
    await settle(tester);
    await done(tester);
  });

  testWidgets('Tablet quer: Rail (ausgeklappt), Filme-Gruppen', skip: skip,
      (tester) async {
    await pump(tester, tablet: true);
    await _shot(tester, 'tablet_rail_start');
    await tapBar(tester, 'Filme');
    await view(tester, 'genre');
    await _shot(tester, 'tablet_rail_movies_genre');
    await done(tester);
  });
}
