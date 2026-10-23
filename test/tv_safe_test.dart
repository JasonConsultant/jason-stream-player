import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:jason_stream_player/core/secret_store.dart';
import 'package:jason_stream_player/core/theme.dart';
import 'package:jason_stream_player/data/recordings/recordings.dart';
import 'package:jason_stream_player/data/storage.dart';
import 'package:jason_stream_player/l10n/strings.dart';
import 'package:jason_stream_player/models/models.dart';
import 'package:jason_stream_player/state/my_groups.dart';
import 'package:jason_stream_player/state/providers.dart';
import 'package:jason_stream_player/state/shell_tab.dart';
import 'package:jason_stream_player/state/vod_library.dart';
import 'package:jason_stream_player/ui/guide/guide_screen.dart';
import 'package:jason_stream_player/ui/home/home_screen.dart';
import 'package:jason_stream_player/ui/nav.dart';
import 'package:jason_stream_player/ui/player/player_screen.dart';
import 'package:jason_stream_player/ui/shell/home_shell.dart';
import 'package:jason_stream_player/ui/tv/tv_safe.dart';
import 'package:jason_stream_player/ui/widgets/live_preview.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/app_fonts.dart';

/// Sicherer Bereich (Overscan) nur auf dem Fernseher, ohne doppelte Ränder;
/// das Handy bleibt unverändert, der Player randlos. Dazu: die Hauptansicht
/// wechselt auf Wunsch (blaue Taste im Player) zum TV-Guide.

const _channels = [
  Channel(id: 'c0', name: 'Das Erste', categoryId: 'a', streamUrl: 'http://s/0', number: 1),
  Channel(id: 'c1', name: 'ZDF', categoryId: 'a', streamUrl: 'http://s/1', number: 2),
];

class _Live extends LiveNotifier {
  @override
  Future<LiveData> build() async =>
      const LiveData([Category(id: 'a', name: 'Alle')], _channels);
}

class _Epg extends EpgNotifier {
  @override
  Future<Map<String, List<EpgEntry>>> build() async => const {};
  @override
  void want(Channel c) {}
}

class _Flags extends ChannelFlagsNotifier {
  @override
  Future<ChannelFlags> build() async => ChannelFlags.empty;
}

class _Sort extends SortOrderNotifier {
  @override
  Future<SortOrder> build() async => SortOrder.empty;
}

class _Recent extends RecentNotifier {
  @override
  Future<List<String>> build() async => const [];
}

class _Groups extends MyGroupsNotifier {
  @override
  Future<List<MyGroup>> build() async => const [];
}

class _Lib extends VodLibraryNotifier {
  @override
  Future<VodLibrary> build() async => VodLibrary.empty;
}

class _Active extends ActivePortalNotifier {
  @override
  Future<Portal?> build() async => Portal.demo;
}

class _Portals extends PortalsNotifier {
  @override
  Future<List<Portal>> build() async => const [Portal.demo];
}

class _Vod extends VodNotifier {
  _Vod(super.series);
  @override
  Future<VodData> build() async => const VodData([], []);
}

class _Recs extends RecordingsNotifier {
  @override
  List<Recording> build() => const [];
}

class _NoPreview extends LivePreviewController {
  _NoPreview(super.ref);
  @override
  Future<void> play(Object owner, Channel c) async {}
}

late Storage _storage;

List<Override> _overrides(bool tv, {Future<Storage>? storage}) => [
      isTvProvider.overrideWithValue(tv),
      storageProvider.overrideWith((ref) => storage ?? Future.value(_storage)),
      activePortalProvider.overrideWith(_Active.new),
      portalsProvider.overrideWith(_Portals.new),
      liveDataProvider.overrideWith(_Live.new),
      epgProvider.overrideWith(_Epg.new),
      channelFlagsProvider.overrideWith(_Flags.new),
      sortOrderProvider.overrideWith(_Sort.new),
      recentProvider.overrideWith(_Recent.new),
      myGroupsProvider.overrideWith(_Groups.new),
      vodLibraryProvider.overrideWith(_Lib.new),
      moviesProvider.overrideWith(() => _Vod(false)),
      seriesProvider.overrideWith(() => _Vod(true)),
      recordingsProvider.overrideWith(_Recs.new),
      minuteTickProvider.overrideWith((ref) => Stream.value(DateTime.now())),
      livePreviewEnabledProvider.overrideWith((ref) async => false),
      livePreviewProvider.overrideWith(_NoPreview.new),
    ];

/// Wie app.dart: TvSafeMediaQuery im Builder, TV-Seitenübergänge im Theme.
Widget _app(bool tv, Widget home, {Future<Storage>? storage}) => ProviderScope(
      overrides: _overrides(tv, storage: storage),
      child: MaterialApp(
        theme: tv
            ? buildTheme(tv: true).copyWith(
                pageTransitionsTheme: TvSafePageTransitionsBuilder.theme())
            : buildTheme(tv: false),
        builder: (context, child) =>
            TvSafeMediaQuery(enabled: tv, child: child!),
        home: home,
      ),
    );

void _size(WidgetTester tester, bool tv) {
  // TV: 1080p mit dpr 2 → 960×540 dp. Handy: 400×800 dp.
  tester.view.physicalSize = tv ? const Size(1920, 1080) : const Size(800, 1600);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _dispose(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 5));
}

class _Probe extends StatelessWidget {
  final String label;
  const _Probe(this.label);
  @override
  Widget build(BuildContext context) =>
      Text('$label ${MediaQuery.paddingOf(context)}');
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    L10n.lang = 'de';
    await initializeDateFormatting('de');
    await loadAppFonts();
    SharedPreferences.setMockInitialValues({});
    _storage = await Storage.open(store: PreviewSecretStore());
  });

  group('TvSafe', () {
    testWidgets('MediaQuery: TV mindestens die Overscan-Ränder, Handy '
        'unverändert', (tester) async {
      EdgeInsets? seen;
      Widget probe(bool on, EdgeInsets device) => MediaQuery(
            data: MediaQueryData(padding: device, viewPadding: device),
            child: TvSafeMediaQuery(
              enabled: on,
              child: Builder(builder: (c) {
                seen = MediaQuery.paddingOf(c);
                return const SizedBox();
              }),
            ),
          );
      await tester.pumpWidget(probe(true, EdgeInsets.zero));
      expect(seen, TvSafe.insets);
      // Größere Systemränder bleiben erhalten (je Seite das Maximum).
      await tester.pumpWidget(
          probe(true, const EdgeInsets.fromLTRB(0, 60, 0, 10)));
      expect(seen, const EdgeInsets.fromLTRB(48, 60, 48, 27));
      await tester.pumpWidget(
          probe(false, const EdgeInsets.fromLTRB(0, 24, 0, 16)));
      expect(seen, const EdgeInsets.fromLTRB(0, 24, 0, 16));
    });

    for (final tv in [true, false]) {
      testWidgets('Seiten: eingerückt nur auf dem TV, keine doppelten Ränder, '
          'Player randlos (tv=$tv)', (tester) async {
        _size(tester, tv);
        final never = Completer<Storage>();
        await tester.pumpWidget(_app(
          tv,
          storage: never.future,
          Builder(
            builder: (context) => Scaffold(
              body: Column(children: [
                const _Probe('home'),
                TextButton(
                  onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(
                          builder: (_) => const Scaffold(
                              body: SafeArea(child: _Probe('page'))))),
                  child: const Text('Seite'),
                ),
                TextButton(
                  onPressed: () => openPlayer(
                      context,
                      PlayRequest(
                          title: 'ZDF',
                          url: 'http://s/1',
                          isLive: true,
                          channels: _channels,
                          channel: _channels[1])),
                  child: const Text('Player'),
                ),
              ]),
            ),
          ),
        ));
        await _settle(tester);
        final home = tester.getTopLeft(find.textContaining('home '));
        // Startseite regelt ihre Ränder selbst (HomeShell) → nicht verschoben.
        expect(home, Offset.zero);

        await tester.tap(find.text('Seite'));
        await tester.pumpAndSettle();
        final page = find.textContaining('page ');
        expect(tester.getTopLeft(page),
            tv ? const Offset(48, 27) : Offset.zero);
        // Innere SafeArea polstert nicht noch einmal.
        expect((tester.widget<Text>(page)).data, 'page ${EdgeInsets.zero}');
        Navigator.of(tester.element(page)).pop();
        await tester.pumpAndSettle();

        // Player: volle Bildschirmgröße, kein sicherer Rand ums Video.
        await tester.tap(find.text('Player'));
        await _settle(tester);
        final player = find.byType(PlayerScreen);
        expect(player, findsOneWidget);
        expect(tester.getRect(player),
            Offset.zero & (tv ? const Size(960, 540) : const Size(400, 800)));
        expect(find.ancestor(of: player, matching: find.byType(TvSafeArea)),
            findsNothing);
        expect(find.ancestor(of: player, matching: find.byType(SafeArea)),
            findsNothing);
        expect(tester.takeException(), isNull);
        await _dispose(tester);
      });
    }

    testWidgets('Hauptansicht TV: Inhalt neben der Leiste im sicheren '
        'Bereich, Ränder nur einmal', (tester) async {
      _size(tester, true);
      await tester.pumpWidget(_app(true, const HomeShell()));
      await _settle(tester);
      final home = find.byType(HomeScreen);
      expect(home, findsOneWidget);
      expect(tester.getTopLeft(home),
          Offset(TvRail.width > TvSafe.horizontal ? TvRail.width : 48, 27));
      expect(tester.getBottomRight(home), const Offset(960 - 48, 540 - 27));
      // Darunter ist der Rand verbraucht (keine zweite Einrückung).
      expect(MediaQuery.paddingOf(tester.element(home)), EdgeInsets.zero);
      expect(tester.takeException(), isNull);
      await _dispose(tester);
    });

    testWidgets('Hauptansicht Handy: randlos, untere Navigationsleiste',
        (tester) async {
      _size(tester, false);
      await tester.pumpWidget(_app(false, const HomeShell()));
      await _settle(tester);
      final home = find.byType(HomeScreen);
      expect(tester.getTopLeft(home), Offset.zero);
      expect(tester.getSize(home).width, 400);
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byType(TvRail), findsNothing);
      expect(tester.takeException(), isNull);
      await _dispose(tester);
    });
  });

  for (final tv in [true, false]) {
    testWidgets('Reiter-Wunsch (blaue Taste im Player) öffnet den TV-Guide '
        '(tv=$tv)', (tester) async {
      _size(tester, tv);
      await tester.pumpWidget(_app(tv, const HomeShell()));
      await _settle(tester);
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(find.byType(GuideScreen), findsNothing);

      final c = ProviderScope.containerOf(tester.element(find.byType(HomeShell)));
      c.read(shellTabRequestProvider.notifier).open(ShellTab.guide);
      await _settle(tester);
      expect(find.byType(GuideScreen), findsOneWidget);
      // Wunsch ist erledigt (ein erneuter Wunsch wirkt wieder).
      expect(c.read(shellTabRequestProvider), isNull);
      final stack = tester.widget<IndexedStack>(find
          .descendant(
              of: find.byType(HomeShell), matching: find.byType(IndexedStack))
          .first);
      expect(stack.index, ShellTab.guide);
      if (!tv) {
        expect(
            tester.widget<NavigationBar>(find.byType(NavigationBar))
                .selectedIndex,
            ShellTab.guide);
      }
      expect(tester.takeException(), isNull);
      await _dispose(tester);
    });
  }

  for (final (tv, land) in [(true, false), (false, false), (false, true)]) {
    testWidgets('Startseite: Kachel „TV-Guide – Was läuft jetzt?“ öffnet den '
        'TV-Guide (tv=$tv, quer=$land)', (tester) async {
      _size(tester, tv);
      if (land) tester.view.physicalSize = const Size(1600, 800);
      await tester.pumpWidget(_app(tv, const HomeShell()));
      await _settle(tester);
      expect(find.byType(GuideScreen), findsNothing);
      final tile = find.text('Was läuft jetzt?');
      expect(tile, findsOneWidget);
      await tester.ensureVisible(tile);
      await tester.tap(tile);
      await _settle(tester);
      expect(find.byType(GuideScreen), findsOneWidget);
      final stack = tester.widget<IndexedStack>(find
          .descendant(
              of: find.byType(HomeShell), matching: find.byType(IndexedStack))
          .first);
      expect(stack.index, ShellTab.guide);
      expect(tester.takeException(), isNull);
      await _dispose(tester);
    });
  }

  testWidgets('TV: OK auf einen Reiter der Leiste öffnet die Seite und geht '
      'in den Inhalt (Leiste klappt zu, Inhalt nicht verdeckt)', (tester) async {
    _size(tester, true);
    await tester.pumpWidget(_app(true, const HomeShell()));
    await _settle(tester);
    // Fokus in die Leiste auf „TV-Guide“ und OK.
    final shell = tester.state(find.byType(HomeShell));
    final railItem = find.descendant(
        of: find.byType(TvRail), matching: find.byType(Focus));
    expect(railItem, findsWidgets);
    final nodes = (shell as dynamic).debugRailNodes as List<FocusNode>;
    nodes[ShellTab.guide].requestFocus();
    await tester.pump(const Duration(milliseconds: 200));
    expect((shell as dynamic).debugRailOpen as bool, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await _settle(tester);
    expect(find.byType(GuideScreen), findsOneWidget);
    final f = FocusManager.instance.primaryFocus;
    expect(f, isNotNull);
    expect(nodes.contains(f), isFalse, reason: 'Fokus im Inhalt, nicht in der Leiste');
    expect((shell as dynamic).debugRailOpen as bool, isFalse);
    expect(tester.takeException(), isNull);
    await _dispose(tester);
  });
}
