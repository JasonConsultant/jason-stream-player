import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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
import 'package:jason_stream_player/ui/guide/guide_screen.dart';
import 'package:jason_stream_player/ui/shell/home_shell.dart';
import 'package:jason_stream_player/ui/widgets/live_preview.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// TV-Shell (Symbolleiste) und TV-Guide bei 960×540 dp (1080p, dpr 2):
/// keine Überläufe, Leiste klappt bei Fokus auf, Zurück-Taste, Bildschirmfoto.
/// Mit `TV_SHOTS=ordner` wird tv_guide_app.png geschrieben.

const _cats = [
  Category(id: 'ev', name: 'StreamTV · Live Events'),
  Category(id: 'free', name: 'DE · FreeTV/HD+ · RAW'),
  Category(id: 'sky', name: 'DE · Sky · HD'),
  Category(id: 'doku', name: 'DE · Doku'),
];

const _names = [
  ('Welcome Channel', 'ev'),
  ('StreamTV Live Event 1', 'ev'),
  ('StreamTV Live Event 2', 'ev'),
  ('ZDF HD', 'free'),
  ('Das Erste HD', 'free'),
  ('RTL HD', 'free'),
  ('ProSieben HD', 'free'),
  ('SAT.1 HD', 'free'),
  ('VOX HD', 'free'),
  ('kabel eins HD', 'free'),
  ('arte HD', 'doku'),
  ('Sky Cinema Premieren HD', 'sky'),
  ('phoenix HD', 'doku'),
];

final _channels = [
  for (var i = 0; i < _names.length; i++)
    Channel(
      id: 'c$i',
      name: _names[i].$1,
      categoryId: _names[i].$2,
      streamUrl: 'http://s/$i',
      number: i + 1,
      catchupDays: i == 4 ? 7 : 0,
    ),
];

/// (Titel, Beginn, Ende) in Minuten relativ zur laufenden halben Stunde.
const _plan = <int, List<(String, int, int)>>{
  1: [('UFC oder WWE – Live-Übertragungen', 0, 120)],
  2: [('Bundesliga Konferenz', -30, 80), ('Sportschau Highlights', 80, 150)],
  3: [('heute journal', -15, 15), ('Markus Lanz', 15, 90), ('heute+', 90, 120)],
  4: [('Tagesthemen', -15, 50), ('Maischberger', 50, 125)],
  5: [('Wer wird Millionär?', -105, 45), ('RTL Nachtjournal', 45, 90)],
  6: [('The Masked Singer', -105, 40), ('TV total', 40, 130)],
  7: [('Navy CIS', -45, 70), ('Navy CIS: L.A.', 70, 130)],
  8: [('Die Höhle der Löwen', -105, 75), ('Prominent!', 75, 120)],
  9: [('Spielfilm', -60, 60), ('Abenteuer Leben', 60, 150)],
  10: [('Doku am Abend', -30, 45), ('Kultur heute', 45, 150)],
  11: [('Premiere', -40, 70), ('Thriller', 70, 180)],
  12: [('Phoenix Runde', -20, 40), ('Dokumentation', 40, 150)],
};

Map<String, List<EpgEntry>> _epg(DateTime now) {
  final h0 = DateTime(
      now.year, now.month, now.day, now.hour, now.minute < 30 ? 0 : 30);
  return {
    for (final e in _plan.entries)
      '@c${e.key}': [
        for (final (t, a, b) in e.value)
          EpgEntry(
            channelEpgId: '@c${e.key}',
            title: t,
            genre: e.key <= 2 ? 'Sport' : 'Unterhaltung',
            description: e.key == 1
                ? 'Live-Kämpfe der Nacht mit Vorberichten und Analyse. '
                    'Danach: Highlights des Wochenendes.'
                : 'Aktuelle Sendung mit Gästen und Hintergründen.',
            start: h0.add(Duration(minutes: a)),
            end: h0.add(Duration(minutes: b)),
          ),
      ],
  };
}

class _Live extends LiveNotifier {
  @override
  Future<LiveData> build() async => LiveData(_cats, _channels);
}

class _Epg extends EpgNotifier {
  final Map<String, List<EpgEntry>> data;
  _Epg(this.data);
  @override
  Future<Map<String, List<EpgEntry>>> build() async => data;
  @override
  void want(Channel c) {}
}

class _Flags extends ChannelFlagsNotifier {
  @override
  Future<ChannelFlags> build() async => const ChannelFlags({'c1', 'c3'}, {}, {});
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

class _Active extends ActivePortalNotifier {
  @override
  Future<Portal?> build() async => Portal.demo;
}

class _Portals extends PortalsNotifier {
  @override
  Future<List<Portal>> build() async => const [];
}

class _Vod extends VodNotifier {
  _Vod(super.series);
  @override
  Future<VodData> build() async => const VodData([], []);
}

/// Vorschau ohne echten Player.
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
  ]);
  final sdk = Platform.environment['FLUTTER_ROOT'] ??
      File(Platform.resolvedExecutable)
          .parent.parent.parent.parent.parent.parent.path;
  final icons =
      File('$sdk/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
  if (icons.existsSync()) await family('MaterialIcons', [icons.path]);
}

final _shotKey = GlobalKey();

Future<void> _pump(WidgetTester tester, Widget home, Storage storage) async {
  tester.view.physicalSize = const Size(1920, 1080);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    overrides: [
      isTvProvider.overrideWithValue(true),
      storageProvider.overrideWith((ref) async => storage),
      activePortalProvider.overrideWith(_Active.new),
      portalsProvider.overrideWith(_Portals.new),
      liveDataProvider.overrideWith(_Live.new),
      epgProvider.overrideWith(() => _Epg(_epg(DateTime.now()))),
      channelFlagsProvider.overrideWith(_Flags.new),
      sortOrderProvider.overrideWith(_Sort.new),
      recentProvider.overrideWith(_Recent.new),
      myGroupsProvider.overrideWith(_Groups.new),
      moviesProvider.overrideWith(() => _Vod(false)),
      seriesProvider.overrideWith(() => _Vod(true)),
      minuteTickProvider.overrideWith((ref) => Stream.value(DateTime.now())),
      livePreviewEnabledProvider.overrideWith((ref) async => true),
      livePreviewProvider.overrideWith(_NoPreview.new),
    ],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildTheme(tv: true),
      home: RepaintBoundary(key: _shotKey, child: home),
    ),
  ));
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _shot(WidgetTester tester, String name) async {
  final dir = Platform.environment['TV_SHOTS'];
  if (dir == null) return;
  await tester.runAsync(() async {
    final b =
        _shotKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final img = await b.toImage(pixelRatio: 2);
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    File('$dir/$name.png').writeAsBytesSync(data!.buffer.asUint8List());
  });
}

Future<void> _dispose(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 5));
}

double _railWidth(WidgetTester tester) =>
    tester.getSize(find.byType(TvRail)).width;

/// Taste drücken und Animationen (150 ms) auslaufen lassen.
Future<void> _key(WidgetTester tester, LogicalKeyboardKey k) async {
  await tester.sendKeyEvent(k);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

/// Zurück-Taste (wie die Fernbedienung) und Animation auslaufen lassen.
Future<void> _back(WidgetTester tester) async {
  await tester.binding.handlePopRoute();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

FocusNode? get _focus => FocusManager.instance.primaryFocus;

void main() {
  late Storage storage;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    L10n.lang = 'de';
    await initializeDateFormatting('de');
    await _loadFonts();
    SharedPreferences.setMockInitialValues({});
    storage = await Storage.open(store: PreviewSecretStore());
  });

  testWidgets('Symbolleiste: schmal, klappt bei Fokus auf', (tester) async {
    var selected = 0;
    final nodes = [for (var i = 0; i < 7; i++) FocusNode()];
    addTearDown(() {
      for (final n in nodes) {
        n.dispose();
      }
    });
    await _pump(
      tester,
      Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => Row(children: [
            TvRail(
              index: selected,
              nodes: nodes,
              autofocus: true,
              onSelect: (i) => setState(() => selected = i),
            ),
            Expanded(
              child: Center(
                child: TextButton(onPressed: () {}, child: const Text('X')),
              ),
            ),
          ]),
        ),
      ),
      storage,
    );
    expect(tester.takeException(), isNull);
    // Autofokus auf dem gewählten Eintrag → aufgeklappt mit Beschriftung.
    await tester.pump(const Duration(milliseconds: 200));
    expect(_railWidth(tester), TvRail.expandedWidth);
    // Fokus auf einen Eintrag wechselt den Bereich.
    nodes[2].requestFocus();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(selected, 2);
    // Fokus raus in den Inhalt → wieder schmal.
    await _key(tester, LogicalKeyboardKey.arrowRight);
    expect(_railWidth(tester), TvRail.width);
    expect(tester.takeException(), isNull);
    await _dispose(tester);
  });

  testWidgets('TV-Shell mit Guide: keine Überläufe, Zurück-Taste',
      (tester) async {
    await _pump(tester, const HomeShell(), storage);
    expect(tester.takeException(), isNull);
    expect(_railWidth(tester), lessThanOrEqualTo(TvRail.expandedWidth));

    // Zum TV-Guide über die Leiste (Fokus wechselt den Bereich).
    // ignore: invalid_use_of_visible_for_testing_member
    final nodes = (tester.state(find.byType(HomeShell)) as dynamic)
        .debugRailNodes as List<FocusNode>;
    nodes[2].requestFocus();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(GuideScreen), findsOneWidget);
    expect(find.text('StreamTV Live Event 1'), findsWidgets);
    expect(tester.takeException(), isNull);

    // In den Inhalt: → (Chips), ↓ (Raster), ↓ (zweite Zeile).
    await _key(tester, LogicalKeyboardKey.arrowRight);
    await _key(tester, LogicalKeyboardKey.arrowDown);
    await _key(tester, LogicalKeyboardKey.arrowDown);
    expect(_railWidth(tester), TvRail.width);
    expect(nodes.contains(_focus), isFalse);
    // Info-Kopf zeigt die fokussierte Sendung.
    expect(find.text('STREAMTV LIVE EVENT 1 · JETZT'), findsOneWidget);

    // Status statt Banner, solange das EPG lädt.
    final container =
        ProviderScope.containerOf(tester.element(find.byType(GuideScreen)));
    container
        .read(epgStatusProvider.notifier)
        .set(const EpgStatus(updating: true));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Programm wird aktualisiert'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _shot(tester, 'tv_guide_app');

    // Zurück: Inhalt → Leiste (gleicher Tab).
    await _back(tester);
    expect(_focus, nodes[2]);
    expect(find.byType(GuideScreen), findsOneWidget);
    // Zurück in der Leiste: → Start.
    await _back(tester);
    expect(_focus, nodes[0]);
    // Zurück auf Start: Hinweis, App bleibt offen.
    await _back(tester);
    expect(find.text('Zum Beenden nochmal Zurück drücken'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _dispose(tester);
  });
  testWidgets('TV-Guide nur mit der Fernbedienung', (tester) async {
    final nodes = [for (var i = 0; i < 7; i++) FocusNode()];
    addTearDown(() {
      for (final n in nodes) {
        n.dispose();
      }
    });
    await _pump(
      tester,
      Scaffold(
        body: Row(children: [
          TvRail(index: 2, nodes: nodes, onSelect: (_) {}),
          const Expanded(child: GuideScreen()),
        ]),
      ),
      storage,
    );
    expect(tester.takeException(), isNull);
    String? focusedText() {
      final c = _focus?.context;
      if (c == null) return null;
      final texts = find.descendant(
          of: find.byElementPredicate((e) => e == c),
          matching: find.byType(Text));
      final w = texts.evaluate().map((e) => (e.widget as Text).data);
      return w.isEmpty ? null : w.first;
    }

    // Start im Raster (nicht in der Leiste), Leiste bleibt schmal.
    expect(_focus, isNotNull);
    expect(nodes.contains(_focus), isFalse);
    expect(_railWidth(tester), TvRail.width);
    // ▼ (Chips → Raster) bis in die Zeile „StreamTV Live Event 1“ (läuft: UFC …).
    for (var i = 0;
        i < 12 && focusedText() != 'UFC oder WWE – Live-Übertragungen';
        i++) {
      await _key(tester, LogicalKeyboardKey.arrowDown);
    }
    expect(focusedText(), 'UFC oder WWE – Live-Übertragungen');
    // ▼ → nächste Zeile, ▶ → nächste Sendung derselben Zeile.
    await _key(tester, LogicalKeyboardKey.arrowDown);
    expect(focusedText(), 'Bundesliga Konferenz');
    await _key(tester, LogicalKeyboardKey.arrowRight);
    expect(focusedText(), 'Sportschau Highlights');
    // OK auf einer kommenden Sendung → Programm-Blatt.
    await _key(tester, LogicalKeyboardKey.select);
    expect(find.text('Sender einschalten'), findsOneWidget);
    // Zurück schließt das Blatt, Fokus wieder im Raster.
    await _back(tester);
    expect(find.text('Sender einschalten'), findsNothing);
    expect(focusedText(), 'Sportschau Highlights');
    // ◀ ◀ → vorherige Sendung, dann Rasteranfang → Leiste.
    await _key(tester, LogicalKeyboardKey.arrowLeft);
    expect(focusedText(), 'Bundesliga Konferenz');
    await _key(tester, LogicalKeyboardKey.arrowLeft);
    expect(nodes.contains(_focus), isTrue);
    // ▶ zurück ins Raster, Menü-Taste auf laufender Sendung → Blatt.
    await _key(tester, LogicalKeyboardKey.arrowRight);
    expect(nodes.contains(_focus), isFalse);
    await _key(tester, LogicalKeyboardKey.contextMenu);
    expect(find.text('Live ansehen'), findsOneWidget);
    await _back(tester);
    // Langes OK → ebenfalls Blatt (statt Abspielen).
    await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.select);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Live ansehen'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _back(tester);
    await _dispose(tester);
  });
}
