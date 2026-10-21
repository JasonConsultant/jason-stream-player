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
import 'package:jason_stream_player/state/my_groups.dart';
import 'package:jason_stream_player/state/providers.dart';
import 'package:jason_stream_player/state/vod_library.dart';
import 'package:jason_stream_player/ui/home/home_screen.dart';
import 'package:jason_stream_player/ui/live/live_screen.dart';
import 'package:jason_stream_player/ui/shell/home_shell.dart';
import 'package:jason_stream_player/ui/widgets/common.dart';
import 'package:jason_stream_player/ui/widgets/live_preview.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Zurück-Taste (Handy und Fernbedienung) und Fokus-Schwachstellen der
/// TV-Shell: Start im Inhalt, Spaltenränder in Live TV, Zurück schließt
/// zuerst Blätter/Dialoge/Suche, zweimal Zurück auf Start beendet.

final _cats = [
  const Category(id: 'ev', name: 'StreamTV · Live Events'),
  const Category(id: 'free', name: 'DE · FreeTV'),
  for (var i = 0; i < 30; i++) Category(id: 'g$i', name: 'Gruppe $i'),
];

final _channels = [
  for (var i = 0; i < 40; i++)
    Channel(
      id: 'c$i',
      name: 'Sender $i',
      categoryId: i < 3 ? 'ev' : (i < 20 ? 'free' : 'g${i - 20}'),
      streamUrl: 'http://s/$i',
      number: i + 1,
    ),
];

class _Live extends LiveNotifier {
  @override
  Future<LiveData> build() async => LiveData(_cats, _channels);
}

class _Epg extends EpgNotifier {
  @override
  Future<Map<String, List<EpgEntry>>> build() async => const {};
  @override
  void want(Channel c) {}
}

class _Flags extends ChannelFlagsNotifier {
  @override
  Future<ChannelFlags> build() async => const ChannelFlags({'c1'}, {}, {});
}

class _Sort extends SortOrderNotifier {
  @override
  Future<SortOrder> build() async => SortOrder.empty;
}

class _Recent extends RecentNotifier {
  @override
  Future<List<String>> build() async => const ['c2'];
}

class _Groups extends MyGroupsNotifier {
  @override
  Future<List<MyGroup>> build() async => const [];
}

class _Active extends ActivePortalNotifier {
  @override
  Future<Portal?> build() async => Portal.demo;
}

class _Portals extends PortalsNotifier {
  @override
  Future<List<Portal>> build() async => const [];
}

class _Lib extends VodLibraryNotifier {
  @override
  Future<VodLibrary> build() async => VodLibrary.empty;
}

class _Vod extends VodNotifier {
  _Vod(super.series);
  @override
  Future<VodData> build() async => const VodData([], []);
}

class _NoPreview extends LivePreviewController {
  _NoPreview(super.ref);
  @override
  Future<void> play(Object owner, Channel c) async {}
}

Future<void> _loadFonts() async {
  Future<void> family(String name, List<String> files) async {
    final l = FontLoader(name);
    for (final f in files) {
      l.addFont(Future.value(ByteData.sublistView(File(f).readAsBytesSync())));
    }
    await l.load();
  }

  const d = 'assets/fonts';
  await family('Inter', [
    '$d/Inter-Regular.otf',
    '$d/Inter-Medium.otf',
    '$d/Inter-SemiBold.otf',
    '$d/Inter-Bold.otf',
    '$d/Inter-ExtraBold.otf',
  ]);
  await family('InterDisplay', [
    '$d/InterDisplay-SemiBold.otf',
    '$d/InterDisplay-Bold.otf',
    '$d/InterDisplay-ExtraBold.otf',
  ]);
}

Future<void> _pump(WidgetTester tester, Storage storage,
    {required bool tv, Size size = const Size(960, 540)}) async {
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    overrides: [
      isTvProvider.overrideWithValue(tv),
      storageProvider.overrideWith((ref) async => storage),
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
      minuteTickProvider.overrideWith((ref) => Stream.value(DateTime.now())),
      livePreviewEnabledProvider.overrideWith((ref) async => false),
      livePreviewProvider.overrideWith(_NoPreview.new),
    ],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildTheme(tv: tv),
      home: const HomeShell(),
    ),
  ));
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _dispose(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 5));
}

/// Zurück wie auf dem Gerät: Escape (im Test statt der Zurück-Taste der
/// Fernbedienung) an Flutter; bleibt sie unbehandelt, schickt Android die
/// System-Zurück-Aktion (popRoute) – wie die Zurück-Geste am Handy.
Future<void> _back(WidgetTester tester) async {
  final handled = await tester.sendKeyEvent(LogicalKeyboardKey.escape);
  if (!handled) await tester.binding.handlePopRoute();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// System-Zurück am Handy (Geste/Taste, kein Tastenereignis).
Future<void> _sysBack(WidgetTester tester) async {
  await tester.binding.handlePopRoute();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _press(WidgetTester tester, LogicalKeyboardKey k) async {
  await tester.sendKeyEvent(k);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
}

FocusNode? get _focus => FocusManager.instance.primaryFocus;

List<FocusNode> _railNodes(WidgetTester tester) =>
    (tester.state(find.byType(HomeShell)) as dynamic).debugRailNodes
        as List<FocusNode>;

double _railWidth(WidgetTester tester) =>
    tester.getSize(find.byType(TvRail)).width;

List<String> _focusedTexts() {
  final out = <String>[];
  void visit(Element e) {
    final w = e.widget;
    if (w is Text && w.data != null) out.add(w.data!);
    e.visitChildren(visit);
  }

  (_focus?.context as Element?)?.visitChildren(visit);
  return out;
}

bool _focusIn(String type) {
  var found = false;
  (_focus?.context as Element?)?.visitAncestorElements((e) {
    if (e.widget.runtimeType.toString() == type) found = true;
    return !found;
  });
  return found;
}

const _snack = 'Zum Beenden nochmal Zurück drücken';

int _tab(WidgetTester tester) =>
    tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex;

void main() {
  late Storage storage;
  late List<MethodCall> platformCalls;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    L10n.lang = 'de';
    await initializeDateFormatting('de');
    await _loadFonts();
    SharedPreferences.setMockInitialValues({});
    storage = await Storage.open(store: PreviewSecretStore());
  });

  setUp(() {
    platformCalls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      platformCalls.add(call);
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  bool exited() =>
      platformCalls.any((c) => c.method == 'SystemNavigator.pop');

  group('Handy: Zurück', () {
    testWidgets('anderer Tab → Start, dann zweimal Zurück beendet',
        (tester) async {
      // App im Vordergrund (sonst meldet Flutter nichts an die Engine).
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _pump(tester, storage, tv: false, size: const Size(440, 900));
      expect(_tab(tester), 0);
      // Android 13+ (Predictive Back): Flutter meldet, dass es Zurück selbst
      // behandelt – sonst schlösse das System die App ohne PopScope.
      final handlesBack = platformCalls
          .where((c) => c.method == 'SystemNavigator.setFrameworkHandlesBack');
      expect(handlesBack, isNotEmpty);
      expect(handlesBack.last.arguments, isTrue);
      await tester.tap(find.byIcon(Icons.live_tv_outlined));
      await tester.pump(const Duration(milliseconds: 300));
      expect(_tab(tester), 1);
      expect(find.byType(LiveScreen), findsOneWidget);

      await _sysBack(tester);
      expect(_tab(tester), 0);
      expect(find.text(_snack), findsNothing);
      expect(exited(), isFalse);

      await _sysBack(tester);
      expect(find.text(_snack), findsOneWidget);
      expect(exited(), isFalse);

      await _sysBack(tester);
      expect(exited(), isTrue);
      await _dispose(tester);
    });

    testWidgets('zweites Zurück nach > 2 s beendet nicht', (tester) async {
      await _pump(tester, storage, tv: false, size: const Size(440, 900));
      await _sysBack(tester);
      expect(find.text(_snack), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 2500));
      await _sysBack(tester);
      expect(exited(), isFalse);
      expect(find.text(_snack), findsOneWidget);
      await _dispose(tester);
    });

    testWidgets('Seiten, Blätter und Dialoge schließen zuerst',
        (tester) async {
      await _pump(tester, storage, tv: false, size: const Size(440, 900));
      await tester.tap(find.byIcon(Icons.live_tv_outlined));
      await tester.pump(const Duration(milliseconds: 300));
      final ctx = tester.element(find.byType(LiveScreen));

      // Innere Seite: Zurück schließt nur sie.
      Navigator.of(ctx).push(MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Innen'))));
      await tester.pumpAndSettle();
      expect(find.text('Innen'), findsOneWidget);
      await _sysBack(tester);
      await tester.pumpAndSettle();
      expect(find.text('Innen'), findsNothing);
      expect(_tab(tester), 1);

      // Blatt.
      showModalBottomSheet<void>(
          context: ctx, builder: (_) => const Text('Blatt'));
      await tester.pumpAndSettle();
      expect(find.text('Blatt'), findsOneWidget);
      await _sysBack(tester);
      await tester.pumpAndSettle();
      expect(find.text('Blatt'), findsNothing);
      expect(_tab(tester), 1);

      // Dialog.
      showDialog<void>(
          context: ctx,
          builder: (_) => const AlertDialog(content: Text('Dialog')));
      await tester.pumpAndSettle();
      await _sysBack(tester);
      await tester.pumpAndSettle();
      expect(find.text('Dialog'), findsNothing);
      expect(_tab(tester), 1);
      expect(find.text(_snack), findsNothing);

      // Suche in Live TV: Zurück schließt zuerst die Suche.
      await tester.tap(find.byIcon(Icons.search).first);
      await tester.pumpAndSettle();
      expect(find.byType(SearchField), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Sender 1');
      await tester.pumpAndSettle();
      await _sysBack(tester);
      expect(find.byType(SearchField), findsNothing);
      expect(_tab(tester), 1);
      await _sysBack(tester);
      expect(_tab(tester), 0);
      expect(exited(), isFalse);
      await _dispose(tester);
    });

    testWidgets('breites Layout (Tablet): Tab → Start → Hinweis',
        (tester) async {
      await _pump(tester, storage, tv: false, size: const Size(1000, 800));
      expect(find.byType(NavigationBar), findsNothing);
      await tester.tap(find.text('Live TV').first);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(LiveScreen), findsOneWidget);
      await _sysBack(tester);
      final shell = tester.state(find.byType(HomeShell));
      expect(find.byType(HomeScreen).hitTestable(), findsOneWidget,
          reason: '$shell');
      await _sysBack(tester);
      expect(find.text(_snack), findsOneWidget);
      expect(exited(), isFalse);
      await _sysBack(tester);
      expect(exited(), isTrue);
      await _dispose(tester);
    });
  });

  group('TV', () {
    testWidgets('Start: Fokus im Inhalt, Leiste bleibt schmal',
        (tester) async {
      await _pump(tester, storage, tv: true);
      final rail = _railNodes(tester);
      expect(rail.contains(_focus), isFalse);
      expect(_focusedTexts(), contains('Live TV'));
      expect(_railWidth(tester), TvRail.width);

      // Fokus verloren (Element entfernt/abgegeben) → wieder im Inhalt,
      // nicht in der Leiste.
      _focus!.unfocus(disposition: UnfocusDisposition.scope);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(rail.contains(_focus), isFalse);
      expect(_focusedTexts(), contains('Live TV'));
      await _press(tester, LogicalKeyboardKey.arrowDown);
      expect(rail.contains(_focus), isFalse);
      expect(_railWidth(tester), TvRail.width);

      // Erst ◀ geht in die Leiste und klappt sie auf.
      for (var i = 0; i < 4 && !rail.contains(_focus); i++) {
        await _press(tester, LogicalKeyboardKey.arrowLeft);
      }
      expect(rail.contains(_focus), isTrue);
      expect(_railWidth(tester), TvRail.expandedWidth);
      await _dispose(tester);
    });

    testWidgets('Live TV: ▲/▼ bleiben an den Listenenden stehen',
        (tester) async {
      await _pump(tester, storage, tv: true);
      final rail = _railNodes(tester);
      rail[1].requestFocus();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(LiveScreen), findsOneWidget);
      // ▶ aus der Leiste → Gruppen, ▶ → Senderliste.
      await _press(tester, LogicalKeyboardKey.arrowRight);
      expect(_focusIn('_TvGroupRow'), isTrue);
      await _press(tester, LogicalKeyboardKey.arrowRight);
      expect(_focusedTexts(), contains('Sender 0'));

      // Senderliste: ganz nach unten, dann bleibt ▼ beim letzten Sender.
      for (var i = 0; i < 45; i++) {
        await _press(tester, LogicalKeyboardKey.arrowDown);
      }
      expect(_focusedTexts(), contains('Sender 39'));
      await _press(tester, LogicalKeyboardKey.arrowDown);
      expect(_focusedTexts(), contains('Sender 39'));
      expect(_focusIn('_TvGroupRow'), isFalse);

      // Gruppen: ◀ ◀ … bis in die Gruppenspalte, dann ganz nach unten.
      await _press(tester, LogicalKeyboardKey.arrowLeft);
      expect(_focusIn('_TvGroupRow'), isTrue);
      for (var i = 0; i < 45; i++) {
        await _press(tester, LogicalKeyboardKey.arrowDown);
      }
      expect(_focusedTexts(), contains('Neue Gruppe'));
      await _press(tester, LogicalKeyboardKey.arrowDown);
      expect(_focusedTexts(), contains('Neue Gruppe'));
      expect(_focusIn('_TvGroupRow'), isTrue);

      // Gruppen oben: ▲ endet im Spaltenkopf, nie in der Nachbarspalte.
      for (var i = 0; i < 45; i++) {
        await _press(tester, LogicalKeyboardKey.arrowUp);
      }
      expect(_focusIn('_TvGroupRow') || _focusIn('TvIconButton'), isTrue);
      expect(rail.contains(_focus), isFalse);
      expect(_focusedTexts().any((t) => t.startsWith('Sender ')), isFalse);
      await _dispose(tester);
    });

    testWidgets('Zurück: Inhalt → Leiste → Start → Hinweis → Ende',
        (tester) async {
      await _pump(tester, storage, tv: true);
      final rail = _railNodes(tester);
      rail[1].requestFocus();
      await tester.pump(const Duration(milliseconds: 300));
      await _press(tester, LogicalKeyboardKey.arrowRight);
      expect(rail.contains(_focus), isFalse);
      await _back(tester);
      expect(_focus, rail[1]);
      await _back(tester);
      expect(_focus, rail[0]);
      expect(exited(), isFalse);
      await _back(tester);
      expect(find.text(_snack), findsOneWidget);
      await _back(tester);
      expect(exited(), isTrue);
      await _dispose(tester);
    });
  });
}
