import 'dart:async';

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
import 'package:jason_stream_player/state/profile_mode.dart'
    show visibleMoviesProvider;
import 'package:jason_stream_player/state/providers.dart';
import 'package:jason_stream_player/ui/guide/guide_screen.dart';
import 'package:jason_stream_player/ui/home/home_screen.dart';
import 'package:jason_stream_player/ui/live/channel_sheet.dart';
import 'package:jason_stream_player/ui/live/live_screen.dart';
import 'package:jason_stream_player/ui/nav.dart';
import 'package:jason_stream_player/ui/player/mini_player.dart';
import 'package:jason_stream_player/ui/player/player_screen.dart';
import 'package:jason_stream_player/ui/shell/home_shell.dart';
import 'package:jason_stream_player/ui/shell/reminder_host.dart'
    show appNavigatorKey;
import 'package:jason_stream_player/ui/shell/tab_navigation.dart';
import 'package:jason_stream_player/ui/tv/tv_safe.dart';
import 'package:jason_stream_player/ui/vod/vod_groups_view.dart';
import 'package:jason_stream_player/ui/widgets/action_sheet.dart';
import 'package:jason_stream_player/ui/vod/vod_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/app_fonts.dart';
import 'helpers/fake_engine.dart';
import 'helpers/tv_harness.dart';

/// 1.9: Material-3-Navigation auf Handy/Tablet (Leiste unten bzw. links,
/// Stapel je Reiter, Zurück-Reihenfolge, vorausschauendes Zurück,
/// Mini-Player über der Leiste) und die Gruppen-Übersicht Filme/Serien.

final movies = VodData([
  const Category(id: 'de', name: 'DE | Action'),
  const Category(id: 'tr', name: 'TR • Yerli Filmler'),
  const Category(id: 'mix', name: 'Neu im Kino'),
], [
  for (var i = 0; i < 18; i++)
    VodItem(
      id: 'm$i',
      name: i == 17 ? 'Metropolis' : 'Film $i',
      categoryId: ['de', 'tr', 'mix'][i % 3],
      streamUrl: 'http://s/m$i',
      year: i == 17 ? 1927 : 2010 + i % 5,
      rating: 6 + (i % 4).toDouble(),
      genre: i.isEven ? 'Drama' : 'Action, Thriller',
    ),
]);

final channels = [
  for (var i = 0; i < 6; i++)
    Channel(
        id: 'c$i',
        name: 'Sender $i',
        categoryId: 'de',
        streamUrl: 'http://s/$i',
        number: i + 1),
];

TvData data({VodData? m}) => TvData(
      live: LiveData(const [Category(id: 'de', name: 'Deutschland')], channels),
      movies: m ?? movies,
    );

const _movieReq = PlayRequest(
  title: 'Film 1',
  url: 'http://s/m1',
  resumeKey: 'm1',
  artworkSeed: 'Film 1',
);

late Storage storage;
late List<MethodCall> platformCalls;

Future<void> pumpPhone(WidgetTester tester,
    {Size size = const Size(400, 860), Widget? home, TvData? d}) async {
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    overrides: [
      ...tvOverrides(d ?? data(), Future.value(storage), tv: false),
      playbackEngineProvider.overrideWithValue(FakeEngine.factory),
      mediaSessionProvider.overrideWithValue(NoopMediaSession()),
    ],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      navigatorKey: appNavigatorKey,
      theme: buildTheme(tv: false),
      builder: (context, child) => MiniPlayerHost(child: child!),
      home: home ?? const HomeShell(),
    ),
  ));
  await settle(tester);
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> done(WidgetTester tester) async {
  expect(tester.takeException(), isNull);
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 12));
}

HomeShellProbe shell(WidgetTester tester) =>
    HomeShellProbe(tester.state(find.byType(HomeShell)));

/// Zugriff auf die Test-Helfer der Hauptansicht (State ist privat).
class HomeShellProbe {
  final dynamic s;
  HomeShellProbe(this.s);
  int get index => s.debugIndex as int;
  NavigatorState? nav(int i) => s.debugTabNavigator(i) as NavigatorState?;
}

int barIndex(WidgetTester tester) =>
    tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex;

Future<void> sysBack(WidgetTester tester) async {
  await tester.binding.handlePopRoute();
  await settle(tester);
}

/// Vorausschauende Zurück-Geste (Android 14+) über den Systemkanal.
Future<void> backGesture(WidgetTester tester, {bool commit = true}) async {
  const codec = StandardMethodCodec();
  Future<void> send(String method, [Object? args]) =>
      tester.binding.defaultBinaryMessenger.handlePlatformMessage(
          'flutter/backgesture',
          codec.encodeMethodCall(MethodCall(method, args)),
          (_) {});
  await send('startBackGesture', {
    'touchOffset': [5.0, 300.0],
    'progress': 0.0,
    'swipeEdge': 0,
  });
  await tester.pump();
  await send('updateBackGestureProgress', {
    'touchOffset': [120.0, 300.0],
    'progress': 0.4,
    'swipeEdge': 0,
  });
  await tester.pump(const Duration(milliseconds: 50));
  await send(commit ? 'commitBackGesture' : 'cancelBackGesture');
  await settle(tester);
}

Future<void> tapBar(WidgetTester tester, String label) => tester.tap(
    find.descendant(of: find.byType(NavigationBar), matching: find.text(label)));

/// Ansicht wählen; der Umschalter scrollt auf schmalen Handys waagrecht.
Future<void> tapView(WidgetTester tester, String name) async {
  final chip = find.byKey(ValueKey('vod-view-$name'));
  await tester.ensureVisible(chip);
  await tester.pump(const Duration(milliseconds: 300));
  await tester.tap(chip);
}

Future<void> pushInner(NavigatorState nav, String text) async {
  unawaited(nav.push(MaterialPageRoute<void>(
      builder: (_) => Scaffold(appBar: AppBar(), body: Text(text)))));
}

bool exited() => platformCalls.any((c) => c.method == 'SystemNavigator.pop');

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    L10n.lang = 'de';
    await initializeDateFormatting('de');
    await loadAppFonts();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    storage = await Storage.open(store: PreviewSecretStore());
    await storage.setOption('applang', 'de');
    L10n.lang = 'de';
    debugDiscoverSync = true;
    FakeEngine.created.clear();
    MiniPlayer.corner = MiniCorner.bottomRight;
    platformCalls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (c) async {
      platformCalls.add(c);
      return null;
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('de.jasonstream.player/platform'),
            (c) async => c.method == 'isTv' ? false : null);
  });

  tearDown(() {
    debugDiscoverSync = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('de.jasonstream.player/platform'), null);
  });

  group('Gerüst', () {
    testWidgets('< 600 dp: Leiste unten mit 5 Zielen, keine Seitenleiste',
        (tester) async {
      await pumpPhone(tester);
      expect(find.byType(NavigationRail), findsNothing);
      final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
      expect(bar.destinations.length, 5);
      for (final l in ['Start', 'Live TV', 'Filme', 'Serien', 'Mehr']) {
        expect(
            find.descendant(
                of: find.byType(NavigationBar), matching: find.text(l)),
            findsOneWidget,
            reason: l);
      }
      expect(bar.labelBehavior, NavigationDestinationLabelBehavior.alwaysShow);
      // Edge-to-Edge, durchsichtige Systemleisten.
      expect(
          platformCalls.any((c) =>
              c.method == 'SystemChrome.setEnabledSystemUIMode' &&
              c.arguments == 'SystemUiMode.edgeToEdge'),
          isTrue);
      final region = tester.widget<AnnotatedRegion<SystemUiOverlayStyle>>(
          find.byType(AnnotatedRegion<SystemUiOverlayStyle>).first);
      expect(region.value.statusBarColor, Colors.transparent);
      await done(tester);
    });

    testWidgets('≥ 600 dp: Rail links mit allen Zielen; ≥ 1200 ausgeklappt',
        (tester) async {
      await pumpPhone(tester, size: const Size(800, 1100));
      expect(find.byType(NavigationBar), findsNothing);
      var rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
      expect(rail.destinations.length, 7);
      expect(rail.extended, isFalse);
      expect(rail.labelType, NavigationRailLabelType.all);

      tester.view.physicalSize = const Size(1280, 800) * 2;
      await settle(tester);
      rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
      expect(rail.extended, isTrue);
      expect(rail.destinations.length, 7);

      // Handy quer (wenig Höhe): gebündelt wie unten, mit „Mehr“.
      tester.view.physicalSize = const Size(860, 400) * 2;
      await settle(tester);
      rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
      expect(rail.destinations.length, 5);
      expect(rail.extended, isFalse);
      await done(tester);
    });

    testWidgets('Rail: TV-Guide direkt erreichbar, Auswahl folgt',
        (tester) async {
      await pumpPhone(tester, size: const Size(900, 1000));
      await tester.tap(find.descendant(
          of: find.byType(NavigationRail), matching: find.text('TV-Guide')));
      await settle(tester);
      expect(find.byType(GuideScreen), findsOneWidget);
      expect(tester.widget<NavigationRail>(find.byType(NavigationRail))
          .selectedIndex, 2);
      await sysBack(tester);
      expect(shell(tester).index, 0);
      await done(tester);
    });

    testWidgets('„Mehr“: TV-Guide, Suche, Einstellungen erreichbar',
        (tester) async {
      await pumpPhone(tester);
      await tapBar(tester, 'Mehr');
      await settle(tester);
      expect(find.byType(MoreScreen), findsOneWidget);
      expect(barIndex(tester), 4);
      await tester.tap(find.byKey(const ValueKey('more-2')));
      await settle(tester);
      expect(find.byType(GuideScreen), findsOneWidget);
      expect(barIndex(tester), 4, reason: 'TV-Guide liegt unter „Mehr“');
      // Erneut „Mehr“ → Übersicht.
      await tapBar(tester, 'Mehr');
      await settle(tester);
      expect(find.byType(MoreScreen).hitTestable(), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('more-6')));
      await settle(tester);
      expect(shell(tester).index, 6);
      await tapBar(tester, 'Mehr');
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('more-5')));
      await settle(tester);
      expect(shell(tester).index, 5);
      // Haptik beim Reiterwechsel.
      expect(
          platformCalls.any((c) =>
              c.method == 'HapticFeedback.vibrate' &&
              c.arguments == 'HapticFeedbackType.selectionClick'),
          isTrue);
      await done(tester);
    });
  });

  group('Stapel je Reiter und Zurück', () {
    testWidgets('Stapel bleibt beim Reiterwechsel erhalten', (tester) async {
      await pumpPhone(tester);
      await tapBar(tester, 'Filme');
      await settle(tester);
      expect(find.byType(VodScreen), findsOneWidget);
      await pushInner(shell(tester).nav(3)!, 'Innen Filme');
      await settle(tester);
      expect(find.text('Innen Filme'), findsOneWidget);
      // Leiste bleibt sichtbar (Seite liegt im Reiter, nicht darüber).
      expect(find.byType(NavigationBar).hitTestable(), findsOneWidget);

      await tapBar(tester, 'Live TV');
      await settle(tester);
      expect(find.byType(LiveScreen).hitTestable(), findsOneWidget);
      expect(find.text('Innen Filme').hitTestable(), findsNothing);

      await tapBar(tester, 'Filme');
      await settle(tester);
      expect(find.text('Innen Filme').hitTestable(), findsOneWidget);
      // Erneut „Filme“ → an den Anfang des Stapels.
      await tapBar(tester, 'Filme');
      await settle(tester);
      expect(find.text('Innen Filme'), findsNothing);
      expect(find.byType(VodScreen).hitTestable(), findsOneWidget);
      await done(tester);
    });

    testWidgets('Zurück: Stapel → Start → Hinweis → Beenden', (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await pumpPhone(tester);
      await tapBar(tester, 'Serien');
      await settle(tester);
      final nav = shell(tester).nav(4)!;
      await pushInner(nav, 'Seite 1');
      await settle(tester);
      await pushInner(nav, 'Seite 2');
      await settle(tester);

      await sysBack(tester);
      expect(find.text('Seite 2'), findsNothing);
      expect(find.text('Seite 1').hitTestable(), findsOneWidget);
      expect(barIndex(tester), 3);
      await sysBack(tester);
      expect(find.text('Seite 1'), findsNothing);
      expect(barIndex(tester), 3);
      await sysBack(tester);
      expect(barIndex(tester), 0);
      expect(find.byType(HomeScreen).hitTestable(), findsOneWidget);
      expect(exited(), isFalse);
      await sysBack(tester);
      expect(find.text('Zum Beenden nochmal Zurück drücken'), findsOneWidget);
      await sysBack(tester);
      expect(exited(), isTrue);
      await done(tester);
    });

    testWidgets('Blatt (Sender-Menü) liegt über der Leiste, Zurück schließt',
        (tester) async {
      await pumpPhone(tester);
      await tapBar(tester, 'Live TV');
      await settle(tester);
      final ctx = tester.element(find.byType(LiveScreen));
      // ConsumerStatefulElement ist zugleich WidgetRef.
      unawaited(showChannelSheet(ctx, ctx as WidgetRef, channels.first));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget);
      // Im Navigator der App (über der Leiste), nicht im Reiter.
      expect(shell(tester).nav(1)!.canPop(), isFalse);
      final sheet = tester.getRect(find.byType(BottomSheet));
      final bar = tester.getRect(find.byType(NavigationBar));
      expect(sheet.bottom, greaterThan(bar.top));
      // M3: Griff zum Ziehen.
      expect(
          find.descendant(
              of: find.byType(BottomSheet),
              matching: find.bySemanticsLabel(RegExp('.*'))),
          findsWidgets);
      await sysBack(tester);
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      expect(barIndex(tester), 1);
      await done(tester);
    });

    testWidgets('Handy: Aktionsmenü als Blatt mit Ziehgriff', (tester) async {
      await pumpPhone(tester);
      await tapBar(tester, 'Live TV');
      await settle(tester);
      final ctx = tester.element(find.byType(LiveScreen));
      expect(actionSheetStyleOf(ctx), ActionSheetStyle.sheet);
      unawaited(showChannelSheet(ctx, ctx as WidgetRef, channels.first));
      await tester.pumpAndSettle();
      expect(tester.widget<BottomSheet>(find.byType(BottomSheet)).showDragHandle,
          isTrue);
      expect(find.byType(Dialog), findsNothing);
      await sysBack(tester);
      await tester.pumpAndSettle();
      await done(tester);
    });

    testWidgets('Tablet: Sender-Menü als Dialog, Zurück schließt',
        (tester) async {
      await pumpPhone(tester, size: const Size(1280, 800));
      await tester.tap(find.descendant(
          of: find.byType(NavigationRail), matching: find.text('Live TV')));
      await settle(tester);
      final ctx = tester.element(find.byType(LiveScreen));
      expect(actionSheetStyleOf(ctx), ActionSheetStyle.dialog);
      unawaited(showChannelSheet(ctx, ctx as WidgetRef, channels.first));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.text('Sender bearbeiten'), findsOneWidget);
      final r = tester.getRect(find
          .descendant(of: find.byType(Dialog), matching: find.byType(Material))
          .first);
      expect(r.width, lessThanOrEqualTo(640 + 1));
      expect(r.center.dx, closeTo(640, 1));
      await sysBack(tester);
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
      await done(tester);
    });

    testWidgets('Fernseher: Aktionsmenü bleibt das bisherige Blatt',
        (tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      late BuildContext ctx;
      await tester.pumpWidget(ProviderScope(
        overrides: tvOverrides(data(), Future.value(storage), tv: true),
        child: MaterialApp(
          theme: buildTheme(tv: true),
          home: Builder(builder: (c) {
            ctx = c;
            return const SizedBox();
          }),
        ),
      ));
      expect(actionSheetStyleOf(ctx), ActionSheetStyle.tv);
      unawaited(showActionSheet<void>(
          context: ctx,
          constraints: const BoxConstraints(maxWidth: 480),
          builder: (_) => const ListTile(title: Text('A'))));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.byType(Dialog), findsNothing);
      // Ziehgriff wie bisher aus dem Thema des Fernsehers.
      expect(tester.widget<BottomSheet>(find.byType(BottomSheet)).showDragHandle,
          buildTheme(tv: true).bottomSheetTheme.showDragHandle);
      await done(tester);
    });
  });

  group('Vorausschauendes Zurück', () {
    test('Übergänge: Handy PredictiveBack (kurz), TV unverändert', () {
      final phone = buildTheme(tv: false).pageTransitionsTheme;
      final b = phone.builders[TargetPlatform.android];
      expect(b, isA<AppPageTransitionsBuilder>());
      expect(b, isA<PredictiveBackPageTransitionsBuilder>());
      expect(b!.transitionDuration, const Duration(milliseconds: 300));
      // TV: app.dart setzt weiterhin TvSafePageTransitionsBuilder.
      final tv = buildTheme(tv: true).pageTransitionsTheme;
      expect(tv.builders[TargetPlatform.android],
          isNot(isA<AppPageTransitionsBuilder>()));
      expect(TvSafePageTransitionsBuilder.theme().builders.values,
          everyElement(isA<TvSafePageTransitionsBuilder>()));
    });

    testWidgets('„Animationen entfernen“: Übergang ohne Animation',
        (tester) async {
      late Widget out;
      const child = SizedBox(key: ValueKey('child'));
      await tester.pumpWidget(MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: Builder(builder: (context) {
          out = const AppPageTransitionsBuilder().buildTransitions(
              MaterialPageRoute<void>(builder: (_) => child),
              context,
              kAlwaysCompleteAnimation,
              kAlwaysDismissedAnimation,
              child);
          return const SizedBox();
        }),
      ));
      expect(identical(out, child), isTrue);
    });

    testWidgets('Geste schließt die Seite des sichtbaren Reiters',
        (tester) async {
      await pumpPhone(tester);
      await tapBar(tester, 'Live TV');
      await settle(tester);
      await pushInner(shell(tester).nav(1)!, 'Live innen');
      await settle(tester);
      await backGesture(tester, commit: false);
      expect(find.text('Live innen'), findsOneWidget, reason: 'abgebrochen');
      await backGesture(tester);
      expect(find.text('Live innen'), findsNothing);
      expect(shell(tester).index, 1);
      await done(tester);
    });

    testWidgets('verdeckte Reiter und Seiten unter Dialogen reagieren nicht',
        (tester) async {
      await pumpPhone(tester);
      await tapBar(tester, 'Live TV');
      await settle(tester);
      await pushInner(shell(tester).nav(1)!, 'Live innen');
      await settle(tester);
      // Dialog über allem: die Geste schließt den Dialog, nicht die Seite.
      final ctx = tester.element(find.text('Live innen'));
      unawaited(showDialog<void>(
          context: ctx,
          builder: (_) => const AlertDialog(content: Text('Dialog'))));
      await tester.pumpAndSettle();
      await backGesture(tester);
      await tester.pumpAndSettle();
      expect(find.text('Dialog'), findsNothing);
      expect(find.text('Live innen'), findsOneWidget);

      // Anderer Reiter sichtbar: Live bleibt, wie es ist.
      await tapBar(tester, 'Filme');
      await settle(tester);
      await backGesture(tester);
      expect(shell(tester).index, 0, reason: 'leerer Stapel → Start');
      expect(shell(tester).nav(1)!.canPop(), isTrue);
      await done(tester);
    });

    testWidgets('Player über der App: Zurück schließt den Player zuerst',
        (tester) async {
      await pumpPhone(tester);
      await tapBar(tester, 'Filme');
      await settle(tester);
      await pushInner(shell(tester).nav(3)!, 'Film innen');
      await settle(tester);
      final ctx = tester.element(find.text('Film innen'));
      unawaited(openPlayer(ctx, _movieReq));
      await settle(tester);
      expect(find.byType(PlayerScreen), findsOneWidget);
      // Der Player liegt im Navigator der App, nicht im Reiter.
      expect(appNavigatorKey.currentState!.canPop(), isTrue);
      FakeEngine.created.single.emit(
          width: 1920,
          buffering: false,
          playing: true,
          duration: const Duration(minutes: 90),
          position: const Duration(minutes: 3));
      await sysBack(tester);
      expect(find.byType(PlayerScreen), findsNothing);
      expect(find.text('Film innen'), findsOneWidget);
      expect(find.byKey(const ValueKey('mini-player')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('mini-close')));
      await settle(tester);
      await done(tester);
    });
  });

  group('Mini-Player', () {
    Future<void> toMini(WidgetTester tester) async {
      unawaited(openPlayerAttached(_movieReq));
      await settle(tester);
      FakeEngine.created.single.emit(
          width: 1920,
          buffering: false,
          playing: true,
          duration: const Duration(minutes: 90),
          position: const Duration(minutes: 3));
      await sysBack(tester);
      expect(find.byKey(const ValueKey('mini-player')), findsOneWidget);
    }

    testWidgets('liegt über der Leiste unten (alle Ecken)', (tester) async {
      await pumpPhone(tester);
      await toMini(tester);
      final bar = tester.getRect(find.byType(NavigationBar));
      var mini = tester.getRect(find.byKey(const ValueKey('mini-player')));
      expect(mini.bottom, lessThanOrEqualTo(bar.top));
      // Nach links unten ziehen: bleibt über der Leiste.
      await tester.drag(
          find.byKey(const ValueKey('mini-player')), const Offset(-300, 40));
      await settle(tester);
      expect(MiniPlayer.corner, MiniCorner.bottomLeft);
      mini = tester.getRect(find.byKey(const ValueKey('mini-player')));
      expect(mini.bottom, lessThanOrEqualTo(bar.top));
      await tester.tap(find.byKey(const ValueKey('mini-close')));
      await settle(tester);
      await done(tester);
    });

    testWidgets('Tablet: neben der Rail, nicht darüber', (tester) async {
      MiniPlayer.corner = MiniCorner.bottomLeft;
      await pumpPhone(tester, size: const Size(1000, 800));
      await toMini(tester);
      final rail = tester.getRect(find.byType(NavigationRail));
      final mini = tester.getRect(find.byKey(const ValueKey('mini-player')));
      expect(mini.left, greaterThanOrEqualTo(rail.right));
      await tester.tap(find.byKey(const ValueKey('mini-close')));
      await settle(tester);
      await done(tester);
    });
  });

  group('Gruppen-Übersicht', () {
    Future<void> openMovies(WidgetTester tester, {TvData? d}) async {
      await pumpPhone(tester, d: d);
      await tapBar(tester, 'Filme');
      await settle(tester);
    }

    testWidgets('Genre: Karten mit Anzahl, Antippen öffnet die Titel',
        (tester) async {
      await openMovies(tester);
      await tapView(tester, 'genre');
      await settle(tester);
      expect(find.byKey(const ValueKey('vod-group-all')), findsOneWidget);
      expect(find.text('Alle Titel'), findsOneWidget);
      final drama = find.byKey(const ValueKey('vod-group-drama'));
      expect(drama, findsOneWidget);
      expect(find.descendant(of: drama, matching: find.text('9 Titel')),
          findsOneWidget);
      expect(
          find.descendant(
              of: find.byKey(const ValueKey('vod-group-action')),
              matching: find.text('9 Titel')),
          findsOneWidget);
      await tester.tap(drama);
      await settle(tester);
      expect(find.byType(VodGroupScreen), findsOneWidget);
      expect(find.byType(PosterCard), findsWidgets);
      expect(find.text('9 Titel'), findsOneWidget);
      // Seite liegt im Reiter-Stapel; Zurück → Übersicht.
      expect(shell(tester).nav(3)!.canPop(), isTrue);
      await sysBack(tester);
      expect(find.byType(VodGroupScreen), findsNothing);
      // Ansicht wird gemerkt.
      expect(storage.option('vodview_m', ''), 'genre');
      await done(tester);
    });

    testWidgets('Jahr (vor 1980 zusammengefasst) und Sprache',
        (tester) async {
      await openMovies(tester);
      await tapView(tester, 'year');
      await settle(tester);
      expect(find.byKey(const ValueKey('vod-group-2014')), findsOneWidget);
      expect(find.text('Vor 1980'), findsOneWidget);

      await tapView(tester, 'language');
      await settle(tester);
      expect(find.text('Deutsch'), findsOneWidget);
      expect(find.text('Türkisch'), findsOneWidget);
      expect(find.text('Ohne Sprache'), findsOneWidget);
      expect(
          find.descendant(
              of: find.byKey(const ValueKey('vod-group-TR')),
              matching: find.text('6 Titel')),
          findsOneWidget);

      await tapView(tester, 'category');
      await settle(tester);
      expect(find.text('DE | Action'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('vod-group-all')));
      await settle(tester);
      expect(find.text('18 Titel'), findsOneWidget);
      await sysBack(tester);
      // Zurück zu „Entdecken“: alte Ansicht mit Titelbild und Reihen.
      await tapView(tester, 'discover');
      await settle(tester);
      expect(find.text('Top bewertet'), findsOneWidget);
      await done(tester);
    });

    testWidgets('ohne Genres: freundlicher Hinweis, „Alle Titel“ bleibt',
        (tester) async {
      final plain = VodData(const [Category(id: 'a', name: 'Alle')], [
        for (var i = 0; i < 4; i++)
          VodItem(
              id: 'p$i', name: 'Titel $i', categoryId: 'a', streamUrl: 'x'),
      ]);
      await openMovies(tester, d: data(m: plain));
      await tapView(tester, 'genre');
      await settle(tester);
      expect(find.text('Keine Genre-Angaben'), findsOneWidget);
      expect(find.byKey(const ValueKey('vod-group-all')), findsOneWidget);
      await done(tester);
    });

    testWidgets('Kindermodus/Filter: Gruppen aus der sichtbaren Liste',
        (tester) async {
      await openMovies(tester);
      final c = ProviderScope.containerOf(
          tester.element(find.byType(VodScreen)));
      final g = await c.read(
          vodGroupsProvider((series: false, emby: false)).future);
      final visible = c.read(visibleMoviesProvider).value!;
      expect(identical(g!.items, visible.items), isTrue);
      await done(tester);
    });
  });
}
