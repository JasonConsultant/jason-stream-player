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
import 'package:jason_stream_player/state/vod_library.dart';
import 'package:jason_stream_player/ui/home/home_screen.dart';
import 'package:jason_stream_player/ui/live/live_screen.dart';
import 'package:jason_stream_player/ui/player/player_screen.dart';
import 'package:jason_stream_player/ui/vod/movie_detail_screen.dart';
import 'package:jason_stream_player/ui/vod/vod_screen.dart';
import 'package:jason_stream_player/ui/widgets/focusable_tile.dart';
import 'package:jason_stream_player/ui/widgets/live_preview.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// TV-Layouts (960×540 dp, wie ein 1080p-Fernseher mit dpr 2) mit festen
/// Daten aufbauen: keine Überläufe, keine Ausnahmen. Mit
/// `TV_SHOTS=ordner` werden zusätzlich PNG-Bildschirmfotos geschrieben.

// ---------- Testdaten ----------
const _cats = [
  Category(id: 'ev', name: 'StreamTV · Live Events'),
  Category(id: 'free', name: 'DE · FreeTV/HD+ · RAW'),
  Category(id: 'sky', name: 'DE · Sky · HD'),
  Category(id: 'doku', name: 'DE · Doku'),
  Category(id: 'sport', name: 'DE · Sport'),
  Category(id: 'kids', name: 'DE · Kinder'),
  Category(id: 'at', name: 'AT · Österreich'),
  Category(id: 'ch', name: 'CH · Schweiz'),
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
  ('3sat HD', 'free'),
  ('arte HD', 'doku'),
  ('phoenix HD', 'doku'),
  ('n-tv HD', 'free'),
  ('WELT HD', 'free'),
  ('Sky Cinema Premieren HD', 'sky'),
  ('Sky Sport Bundesliga 1 UHD', 'sport'),
  ('DAZN 1 HD', 'sport'),
  ('KiKA HD', 'kids'),
  ('ORF 1 HD', 'at'),
  ('SRF 1 HD', 'ch'),
];

final _channels = [
  for (var i = 0; i < _names.length; i++)
    Channel(
      id: 'c$i',
      name: _names[i].$1,
      categoryId: _names[i].$2,
      streamUrl: 'http://s/$i',
      number: i + 1,
      catchupDays: i % 3 == 0 ? 7 : 0,
    ),
];

const _titles = [
  ('UFC oder WWE – Live-Übertragungen', 'Sport'),
  ('heute journal', 'Nachrichten'),
  ('Tagesthemen', 'Nachrichten'),
  ('Wer wird Millionär?', 'Show'),
  ('The Masked Singer', 'Show'),
  ('Navy CIS', 'Krimi'),
  ('Die Höhle der Löwen', 'Show'),
  ('Bundesliga Konferenz', 'Sport'),
  ('Markus Lanz', 'Talk'),
];

Map<String, List<EpgEntry>> _epg(DateTime now) {
  final base = DateTime(now.year, now.month, now.day, now.hour);
  final m = <String, List<EpgEntry>>{};
  for (var i = 0; i < _channels.length; i++) {
    if (i == 9) continue; // ein Sender ohne Programm
    final key = '@c$i';
    final start = base.subtract(Duration(minutes: 15 * (i % 4)));
    final (t, g) = _titles[i % _titles.length];
    final (t2, _) = _titles[(i + 3) % _titles.length];
    m[key] = [
      EpgEntry(
          channelEpgId: key,
          title: t,
          genre: g,
          description:
              'Live-Kämpfe der Nacht mit Vorberichten, Interviews und Analyse. '
              'Danach: Highlights des Wochenendes und ein Ausblick auf die '
              'kommenden Events – präsentiert vom Studio-Team.',
          start: start,
          end: start.add(Duration(minutes: 60 + 15 * (i % 3)))),
      EpgEntry(
          channelEpgId: key,
          title: t2,
          start: start.add(Duration(minutes: 60 + 15 * (i % 3))),
          end: start.add(Duration(minutes: 150))),
    ];
  }
  return m;
}

const _flags = ChannelFlags({'c1', 'c3', 'c4', 'c6', 'c11', 'c16'}, {}, {'c7'});
const _recent = ['c1', 'c3', 'c5', 'c15', 'c12', 'c8'];
const _myGroups = [
  MyGroup('my_1', 'Fußball', ['c16', 'c17'])
];

const _movieNames = [
  'Dune: Part Two',
  'Oppenheimer',
  'Der Schuh des Manitu',
  'Im Westen nichts Neues',
  'Barbie',
  'John Wick: Kapitel 4',
  'Das Boot',
  'Lola rennt',
  'Toni Erdmann',
  'Inception',
  'Interstellar',
  'Good Bye, Lenin!',
];

List<VodItem> _vod(bool series) => [
      for (var i = 0; i < _movieNames.length; i++)
        VodItem(
          id: '${series ? 's' : 'm'}$i',
          name: series ? 'Serie ${_movieNames[i]}' : _movieNames[i],
          categoryId: i.isEven ? 'action' : 'drama',
          streamUrl: 'http://v/$i',
          rating: 6 + (i % 4) * 0.7,
          year: 1990 + i * 3,
          genre: i.isEven ? 'Action' : 'Drama',
          plot: 'Ein junger Mann zieht in die Wüste, um sein Volk zu rächen '
              'und eine Prophezeiung zu erfüllen.',
          duration: Duration(minutes: 95 + i * 7),
          added: DateTime(2026, 1, 1 + i),
          isSeries: series,
        ),
    ];

const _vodCats = [
  Category(id: 'action', name: 'Action'),
  Category(id: 'drama', name: 'Drama'),
];

final _lib = VodLibrary({
  'm:m1',
  'm:m4',
  's:s2'
}, [
  VodHistoryEntry(false, 'm0', DateTime(2026, 10, 19)),
  VodHistoryEntry(true, 's1', DateTime(2026, 10, 18),
      episodeId: 'e1', season: 2, episode: 3),
  VodHistoryEntry(false, 'm5', DateTime(2026, 10, 17)),
  VodHistoryEntry(false, 'm7', DateTime(2026, 10, 16)),
]);

// ---------- Fakes ----------
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
  Future<ChannelFlags> build() async => _flags;
}

class _Sort extends SortOrderNotifier {
  @override
  Future<SortOrder> build() async => SortOrder.empty;
}

class _Recent extends RecentNotifier {
  @override
  Future<List<String>> build() async => _recent;
}

class _Groups extends MyGroupsNotifier {
  @override
  Future<List<MyGroup>> build() async => _myGroups;
}

class _Lib extends VodLibraryNotifier {
  @override
  Future<VodLibrary> build() async => _lib;
}

class _Vod extends VodNotifier {
  _Vod(super.series);
  @override
  Future<VodData> build() async => VodData(_vodCats, _vod(series));
}

// ---------- Hilfen ----------
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
  final sdk = Platform.environment['FLUTTER_ROOT'] ??
      File(Platform.resolvedExecutable)
          .parent
          .parent
          .parent
          .parent
          .parent
          .parent
          .path;
  final icons =
      File('$sdk/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
  if (icons.existsSync()) {
    await family('MaterialIcons', [icons.path]);
  }
}

final _shotKey = GlobalKey();

/// Merkt sich geöffnete Seiten (Player, Details, Menüs) und entfernt sie
/// sofort wieder, bevor sie gebaut werden (kein echter Player im Test).
class _Routes extends NavigatorObserver {
  final pushed = <Route<dynamic>>[];
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (previousRoute == null) return;
    pushed.add(route);
    Future.microtask(() => route.navigator?.removeRoute(route));
  }

  /// Seite einer PageRouteBuilder-Route (z. B. PlayerScreen).
  Widget? pageOf(Route<dynamic> r, BuildContext context) =>
      r is PageRouteBuilder
          ? r.pageBuilder(
              context, kAlwaysCompleteAnimation, kAlwaysCompleteAnimation)
          : null;
}

Future<void> _pumpTv(WidgetTester tester, Widget screen, Storage storage,
    {bool preview = true, _Routes? routes}) async {
  tester.view.physicalSize = const Size(1920, 1080);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  final epg = _epg(DateTime.now());
  await tester.pumpWidget(ProviderScope(
    overrides: [
      isTvProvider.overrideWithValue(true),
      storageProvider.overrideWith((ref) async => storage),
      liveDataProvider.overrideWith(_Live.new),
      epgProvider.overrideWith(() => _Epg(epg)),
      channelFlagsProvider.overrideWith(_Flags.new),
      sortOrderProvider.overrideWith(_Sort.new),
      recentProvider.overrideWith(_Recent.new),
      myGroupsProvider.overrideWith(_Groups.new),
      vodLibraryProvider.overrideWith(_Lib.new),
      moviesProvider.overrideWith(() => _Vod(false)),
      seriesProvider.overrideWith(() => _Vod(true)),
      minuteTickProvider.overrideWith((ref) => Stream.value(DateTime.now())),
      livePreviewEnabledProvider.overrideWith((ref) async => preview),
    ],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildTheme(tv: true),
      navigatorObservers: [if (routes != null) routes],
      home: RepaintBoundary(
        key: _shotKey,
        child: Scaffold(
          body: Row(children: [
            // Platzhalter für die schmale Symbolleiste der Shell (~48 dp).
            Container(
              width: 48,
              color: const Color(0xFF0E1117),
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  for (var i = 0; i < 5; i++)
                    FocusableTile(
                      key: ValueKey('rail$i'),
                      onTap: () {},
                      child: const SizedBox(
                          width: 32,
                          height: 32,
                          child: Icon(Icons.circle_outlined,
                              size: 14, color: Color(0xFF7C8494))),
                    ),
                ],
              ),
            ),
            Expanded(child: screen),
          ]),
        ),
      ),
    ),
  ));
  // Daten laden lassen; unter 700 ms bleiben (sonst startet die Vorschau
  // einen echten Player).
  for (var i = 0; i < 4; i++) {
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
  // Abbauen, bevor der Vorschau-Timer feuert.
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
}

// ---------- D-Pad ----------
Element? get _focusEl =>
    FocusManager.instance.primaryFocus?.context as Element?;

/// Alle Texte im fokussierten Element.
List<String> _focusedTexts() {
  final out = <String>[];
  void visit(Element e) {
    final w = e.widget;
    if (w is Text && w.data != null) out.add(w.data!);
    e.visitChildren(visit);
  }

  _focusEl?.visitChildren(visit);
  return out;
}

/// Liegt der Fokus in einem Widget dieses Typs (auch private Typen)?
bool _focusIn(String type) {
  var found = false;
  _focusEl?.visitAncestorElements((e) {
    if (e.widget.runtimeType.toString() == type) found = true;
    return !found;
  });
  return found;
}

bool _focusOnRail() {
  var found = false;
  _focusEl?.visitAncestorElements((e) {
    final k = e.widget.key;
    if (k is ValueKey<String> && k.value.startsWith('rail')) found = true;
    return !found;
  });
  return found;
}

Future<void> _press(WidgetTester t, LogicalKeyboardKey k) async {
  await t.sendKeyEvent(k);
  await t.pump(const Duration(milliseconds: 200));
}

const _up = LogicalKeyboardKey.arrowUp;
const _down = LogicalKeyboardKey.arrowDown;
const _left = LogicalKeyboardKey.arrowLeft;
const _right = LogicalKeyboardKey.arrowRight;
const _ok = LogicalKeyboardKey.select;

void main() {
  late Storage storage;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    L10n.lang = 'de';
    await initializeDateFormatting('de');
    await _loadFonts();
    SharedPreferences.setMockInitialValues({
      'resume_movie_m0': '2400/6000',
      'resume_movie_m5': '600/6000',
      'resume_ep_e1': '900/2700',
    });
    storage = await Storage.open(store: PreviewSecretStore());
  });

  testWidgets('Live TV auf dem Fernseher', (tester) async {
    await _pumpTv(tester, const LiveScreen(), storage);
    expect(tester.takeException(), isNull);
    expect(find.text('ZDF HD'), findsWidgets);
    await _shot(tester, 'tv_live_app');
    await _dispose(tester);
  });

  testWidgets('Startseite auf dem Fernseher', (tester) async {
    await _pumpTv(tester, HomeScreen(onOpenTab: (_) {}), storage);
    expect(tester.takeException(), isNull);
    await _shot(tester, 'tv_home_app');
    await _dispose(tester);
  });

  testWidgets('Filme auf dem Fernseher', (tester) async {
    await _pumpTv(tester, const VodScreen(series: false), storage);
    expect(tester.takeException(), isNull);
    await _shot(tester, 'tv_vod_app');
    await _dispose(tester);
  });

  testWidgets('Serien auf dem Fernseher', (tester) async {
    await _pumpTv(tester, const VodScreen(series: true), storage);
    expect(tester.takeException(), isNull);
    await _shot(tester, 'tv_series_app');
    await _dispose(tester);
  });

  group('D-Pad', () {
    testWidgets('Live TV: Spalten, Gruppenwahl, OK spielt', (tester) async {
      final routes = _Routes();
      await _pumpTv(tester, const LiveScreen(), storage,
          preview: false, routes: routes);
      expect(_focusedTexts(), contains('Welcome Channel'));

      await _press(tester, _down);
      expect(_focusedTexts(), contains('StreamTV Live Event 1'));

      // ◀ → Gruppen, nochmal ◀ → Symbolleiste der Shell.
      await _press(tester, _left);
      expect(_focusIn('_TvGroupRow'), isTrue);
      await _press(tester, _left);
      expect(_focusOnRail(), isTrue);
      await _press(tester, _right);
      expect(_focusIn('_TvGroupRow'), isTrue);

      // ▼ bis „DE · Doku“, OK wählt die Gruppe.
      for (var i = 0; i < 15 && !_focusedTexts().contains('DE · Doku'); i++) {
        await _press(tester, _down);
      }
      expect(_focusedTexts(), contains('DE · Doku'));
      await _press(tester, _ok);
      expect(find.text('arte HD'), findsWidgets);
      expect(find.text('ZDF HD'), findsNothing);
      expect(_focusIn('_TvGroupRow'), isTrue); // Fokus bleibt in der Gruppe

      // ▶ → Senderliste (neue Gruppe), ▶ → Info-Spalte, ◀ → zurück.
      await _press(tester, _right);
      // Gewählter Sender der neuen Gruppe (der erste) bekommt den Fokus.
      const ch = 'arte HD';
      expect(_focusedTexts(), contains(ch));
      await _press(tester, _right);
      expect(_focusIn('_TvInfoPanel'), isTrue);
      await _press(tester, _left);
      expect(_focusedTexts(), contains(ch));
      await _press(tester, _left); // → gewählte Gruppe
      expect(_focusedTexts(), contains('DE · Doku'));
      await _press(tester, _right);
      expect(_focusedTexts(), contains(ch));

      // ▲ aus der ersten Zeile → Suchfeld, ▼ zurück in die Liste.
      for (var i = 0; i < 5 && !_focusIn('SearchField'); i++) {
        await _press(tester, _up);
      }
      expect(_focusIn('SearchField'), isTrue);
      await _press(tester, _down);
      expect(_focusedTexts(), contains('arte HD'));

      // OK spielt den Sender.
      await _press(tester, _ok);
      expect(routes.pushed, hasLength(1));
      final page = routes.pageOf(
          routes.pushed.single, tester.element(find.byType(Scaffold).first));
      expect(page, isA<PlayerScreen>());
      expect((page! as PlayerScreen).request.channel?.name, 'arte HD');
      await _dispose(tester);
    });

    testWidgets('Live TV: Menü-Taste und langes OK öffnen das Sendermenü',
        (tester) async {
      final routes = _Routes();
      await _pumpTv(tester, const LiveScreen(), storage,
          preview: false, routes: routes);
      expect(_focusedTexts(), contains('Welcome Channel'));
      await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
      await tester.pump();
      expect(routes.pushed.single, isA<ModalBottomSheetRoute<dynamic>>());
      await _dispose(tester);
    });

    testWidgets('Live TV: OK lang gedrückt = Menü, nicht abspielen',
        (tester) async {
      final routes = _Routes();
      await _pumpTv(tester, const LiveScreen(), storage,
          preview: false, routes: routes);
      await tester.sendKeyDownEvent(_ok);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.sendKeyUpEvent(_ok);
      await tester.pump();
      expect(routes.pushed, hasLength(1));
      expect(routes.pushed.single, isA<ModalBottomSheetRoute<dynamic>>());
      await _dispose(tester);
    });

    testWidgets('Startseite: Kacheln, Reihen, OK spielt', (tester) async {
      final routes = _Routes();
      await _pumpTv(tester, HomeScreen(onOpenTab: (_) {}), storage,
          routes: routes);
      expect(_focusedTexts(), contains('Live TV'));
      await _press(tester, _right);
      expect(_focusedTexts(), contains('TV-Guide'));
      await _press(tester, _right);
      expect(_focusedTexts(), contains('Filme'));
      await _press(tester, _left);
      await _press(tester, _left);
      expect(_focusedTexts(), contains('Live TV'));
      await _press(tester, _left);
      expect(_focusOnRail(), isTrue);
      await _press(tester, _right);
      expect(_focusOnRail(), isFalse);

      // Zu den Kacheln zurück, dann ▼ in „Zuletzt gesehen“.
      for (var i = 0; i < 4 && !_focusedTexts().contains('Live TV'); i++) {
        await _press(tester, _down);
      }
      expect(_focusedTexts(), contains('Live TV'));
      await _press(tester, _down);
      expect(_focusedTexts(), contains('StreamTV Live Event 1'));
      await _press(tester, _right);
      expect(_focusedTexts(), contains('ZDF HD'));
      await _press(tester, _down); // Favoriten
      expect(_focusIn('_TvChannelCards'), isTrue);
      await _press(tester, _down); // Weiterschauen
      expect(_focusIn('PosterCard'), isTrue);
      await _press(tester, _up);
      await _press(tester, _up);
      expect(_focusedTexts(),
          anyOf(contains('StreamTV Live Event 1'), contains('ZDF HD')));
      await _press(tester, _ok);
      expect(routes.pushed.single, isA<PageRouteBuilder<dynamic>>());
      expect(
          routes.pageOf(routes.pushed.single,
              tester.element(find.byType(Scaffold).first)),
          isA<PlayerScreen>());
      await _dispose(tester);
    });

    testWidgets('Startseite: OK auf Weiterschauen öffnet den Film',
        (tester) async {
      final routes = _Routes();
      await _pumpTv(tester, HomeScreen(onOpenTab: (_) {}), storage,
          routes: routes);
      // ▼ Zuletzt gesehen → ▼ Favoriten → ▼ Weiterschauen
      for (var i = 0; i < 3; i++) {
        await _press(tester, _down);
      }
      expect(_focusIn('PosterCard'), isTrue);
      await _press(tester, _ok);
      expect(
          routes.pageOf(routes.pushed.single,
              tester.element(find.byType(Scaffold).first)),
          isA<MovieDetailScreen>());
      await _dispose(tester);
    });

    testWidgets('Filme: Titelbild, Chips, Reihen, Kategorie per OK',
        (tester) async {
      final routes = _Routes();
      await _pumpTv(tester, const VodScreen(series: false), storage,
          routes: routes);
      expect(_focusedTexts(), contains('Abspielen'));
      await _press(tester, _right);
      expect(_focusedTexts(), contains('Details'));
      await _press(tester, _down);
      expect(_focusIn('PosterCard'), isTrue);
      await _press(tester, _right);
      expect(_focusIn('PosterCard'), isTrue);
      // ▲ ▲ → Chip-Reihe
      await _press(tester, _up);
      await _press(tester, _up);
      expect(_focusIn('TvChip'), isTrue);
      for (var i = 0; i < 6 && !_focusedTexts().contains('Action'); i++) {
        await _press(tester, _right);
      }
      expect(_focusedTexts(), contains('Action'));
      await _press(tester, _ok);
      expect(find.byType(GridView), findsOneWidget);
      await _press(tester, _down);
      expect(_focusIn('PosterCard'), isTrue);
      await _press(tester, _ok);
      expect(
          routes.pageOf(routes.pushed.single,
              tester.element(find.byType(Scaffold).first)),
          isA<MovieDetailScreen>());
      // ◀ ganz links → Symbolleiste.
      await _dispose(tester);
    });

    testWidgets('Filme: ◀ ganz links führt zur Symbolleiste', (tester) async {
      await _pumpTv(tester, const VodScreen(series: false), storage);
      await _press(tester, _down);
      expect(_focusIn('PosterCard'), isTrue);
      await _press(tester, _left);
      expect(_focusOnRail(), isTrue);
      await _dispose(tester);
    });
  });
}
