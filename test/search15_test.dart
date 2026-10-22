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
import 'package:jason_stream_player/state/providers.dart';
import 'package:jason_stream_player/ui/search/recent_searches.dart';
import 'package:jason_stream_player/ui/search/search_engine.dart';
import 'package:jason_stream_player/ui/search/search_screen.dart';
import 'package:jason_stream_player/ui/tv/tv_safe.dart';
import 'package:jason_stream_player/ui/widgets/common.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/content14_harness.dart';

/// 1.5 „Tempo“: Suche auf dem Fernseher – Zurück nach geschlossener
/// Tastatur, „Löschen“-Knopf, langes OK/Menü leert, „Letzte Suchen“,
/// Gastmodus, „Mehr anzeigen“, kein EPG-Neuaufbau beim Tippen.

// ---------------------------------------------------------------- Feld --

class _FieldHost {
  final ctrl = TextEditingController();
  final changes = <String>[];
  final below = FocusNode(debugLabel: 'below');
}

Future<_FieldHost> _pumpField(WidgetTester tester,
    {bool tv = true, bool tvActions = true}) async {
  final h = _FieldHost();
  addTearDown(h.ctrl.dispose);
  addTearDown(h.below.dispose);
  await tester.pumpWidget(ProviderScope(
    overrides: [isTvProvider.overrideWithValue(tv)],
    child: MaterialApp(
      theme: buildTheme(tv: tv),
      home: Scaffold(
        body: Column(children: [
          TextButton(
              autofocus: true, onPressed: () {}, child: const Text('Oben')),
          SearchField(
            controller: h.ctrl,
            hint: 'Suchen',
            width: 700,
            onChanged: h.changes.add,
            tvActions: tvActions,
          ),
          Focus(
              focusNode: h.below, child: const SizedBox(height: 40, width: 40)),
        ]),
      ),
    ),
  ));
  await tester.pump();
  return h;
}

Future<void> _key(WidgetTester tester, LogicalKeyboardKey k) async {
  await tester.sendKeyEvent(k);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

/// Zurück wie auf dem Gerät (Escape nimmt im Test denselben Weg).
Future<int> _backUntilBelow(WidgetTester tester, FocusNode below) async {
  var n = 0;
  while (!below.hasFocus && n < 5) {
    await _key(tester, LogicalKeyboardKey.escape);
    n++;
  }
  return n;
}

TextField _field(WidgetTester tester) =>
    tester.widget<TextField>(find.byType(TextField));

String _ctrlText(WidgetTester tester) => _field(tester).controller!.text;

bool _editing(WidgetTester tester) => !_field(tester).readOnly;

bool _fieldFocused(WidgetTester tester) =>
    _field(tester).focusNode?.hasFocus ?? false;

Future<void> _imeShown(WidgetTester tester) async {
  tester.view.viewInsets = const FakeViewPadding(bottom: 700);
  await tester.pump();
}

/// Tastatur schließt sich (auf dem Gerät: Zurück, das die Tastatur selbst
/// verbraucht – die App sieht nur die geänderten Abmessungen).
Future<void> _imeHiddenByBack(WidgetTester tester) async {
  tester.view.viewInsets = FakeViewPadding.zero;
  await tester.pump();
}

// ------------------------------------------------------------ Bildschirm --

final _now = DateTime.now();

const _cat = Category(id: 'g', name: 'DE | Alle');

final _channels = [
  for (var i = 0; i < 30; i++)
    Channel(
        id: 'c$i',
        name: 'Sender $i',
        categoryId: 'g',
        streamUrl: 'http://s/$i',
        epgId: 'e$i'),
];

Map<String, List<EpgEntry>> _epg(String title) => {
      for (var i = 0; i < 30; i++)
        'e$i': [
          EpgEntry(
              channelEpgId: 'e$i',
              title: '$title $i',
              start: _now.add(Duration(minutes: 10 + i)),
              end: _now.add(Duration(minutes: 70 + i))),
        ],
    };

const _movies = [
  VodItem(id: 'm1', name: 'Tatort: Der Film', categoryId: 'f', streamUrl: 'u'),
];

/// EPG, das sich im Test ändern lässt.
class _LiveEpg extends EpgNotifier {
  _LiveEpg(this.first);
  final Map<String, List<EpgEntry>> first;
  @override
  Future<Map<String, List<EpgEntry>>> build() async => first;
  @override
  void want(Channel c) {}
  void push(Map<String, List<EpgEntry>> m) => state = AsyncData(m);
}

late _LiveEpg _epgNotifier;

Future<Storage> _storage([Map<String, Object> prefs = const {}]) async {
  SharedPreferences.setMockInitialValues(prefs);
  return Storage.open(store: PreviewSecretStore());
}

Future<ProviderContainer> _pumpSearch(WidgetTester tester, Storage st,
    {bool tv = false, Map<String, List<EpgEntry>>? epg}) async {
  final d = C14Data(
    live: LiveData(const [_cat], _channels),
    movies: const VodData([], _movies),
    tv: tv,
  );
  _epgNotifier = _LiveEpg(epg ?? _epg('Tatort'));
  tester.view.physicalSize =
      tv ? const Size(1920, 1080) : const Size(1080, 2340);
  tester.view.devicePixelRatio = tv ? 2 : 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    overrides: [
      for (final o in c14Overrides(d, Future.value(st)))
        // ignore: invalid_use_of_visible_for_testing_member
        if (o.origin != epgProvider) o,
      epgProvider.overrideWith(() => _epgNotifier),
    ],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildTheme(tv: tv),
      builder: (context, child) => TvSafeMediaQuery(enabled: tv, child: child!),
      home: const Scaffold(body: SearchScreen()),
    ),
  ));
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  return ProviderScope.containerOf(tester.element(find.byType(SearchScreen)));
}

Future<void> _type(WidgetTester tester, String q) async {
  await tester.enterText(find.byType(TextField), q);
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump();
}

Future<void> _done(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  setUpAll(() async {
    L10n.lang = 'de';
    await initializeDateFormatting('de');
  });

  group('Suchfeld auf dem Fernseher', () {
    testWidgets('Ein Zurück nach geschlossener Tastatur verlässt das Feld',
        (tester) async {
      final h = await _pumpField(tester);
      await _key(tester, LogicalKeyboardKey.arrowDown);
      expect(_fieldFocused(tester), isTrue);
      await _key(tester, LogicalKeyboardKey.select); // OK → tippen
      expect(_editing(tester), isTrue);
      await _imeShown(tester);
      expect(_editing(tester), isTrue);
      await _imeHiddenByBack(tester); // 1. Zurück: verbraucht die Tastatur
      expect(_editing(tester), isFalse, reason: 'Eingabe endet mit Tastatur');
      final backs = await _backUntilBelow(tester, h.below);
      // ignore: avoid_print
      print('[search15] Zurück-Tasten nach Tastatur-Ende bis aus dem Feld: '
          '$backs (vorher 2, insgesamt vorher 3 → jetzt ${backs + 1})');
      expect(backs, 1);
      expect(h.below.hasFocus, isTrue);
      addTearDown(tester.view.resetViewInsets);
    });

    testWidgets('Tastatur ohne Größenmeldung: ein Zurück genügt ebenfalls',
        (tester) async {
      final h = await _pumpField(tester);
      await _key(tester, LogicalKeyboardKey.arrowDown);
      await _key(tester, LogicalKeyboardKey.select);
      expect(_editing(tester), isTrue);
      // (Tastatur schwebt über der App: keine Abmessungs-Änderung.)
      expect(await _backUntilBelow(tester, h.below), 1);
    });

    testWidgets('Ohne Löschen-Funktion startet OK die Eingabe wie bisher',
        (tester) async {
      await _pumpField(tester, tvActions: false);
      await _key(tester, LogicalKeyboardKey.arrowDown);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
      await tester.pump();
      expect(_editing(tester), isTrue);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
      await tester.pump();
    });

    testWidgets('„Löschen“-Knopf neben dem Feld: per ▶ erreichbar, OK leert',
        (tester) async {
      final h = await _pumpField(tester);
      expect(find.byKey(const ValueKey('search-clear-chip')), findsNothing);
      h.ctrl.text = 'tatort';
      await tester.pump();
      expect(find.byKey(const ValueKey('search-clear-chip')), findsOneWidget);
      expect(find.text('Löschen'), findsOneWidget);
      await _key(tester, LogicalKeyboardKey.arrowDown);
      expect(_fieldFocused(tester), isTrue);
      await _key(tester, LogicalKeyboardKey.arrowRight);
      expect(focusUnderKey(const ValueKey('search-clear-chip')), isTrue);
      expect(_fieldFocused(tester), isFalse);
      await _key(tester, LogicalKeyboardKey.select);
      expect(h.ctrl.text, isEmpty);
      expect(h.changes.last, '');
      expect(find.byKey(const ValueKey('search-clear-chip')), findsNothing);
      expect(_fieldFocused(tester), isTrue, reason: 'Fokus zurück ins Feld');
      // Großes X im Feld (Touch).
      h.ctrl.text = 'x';
      await tester.pump();
      final x = tester.widget<Icon>(find.descendant(
          of: find.byKey(const ValueKey('search-clear-x')),
          matching: find.byType(Icon)));
      expect(x.size, greaterThanOrEqualTo(24));
    });

    testWidgets('Langes OK auf dem Feld leert, kurzes OK startet die Eingabe',
        (tester) async {
      final h = await _pumpField(tester);
      h.ctrl.text = 'bundesliga';
      await tester.pump();
      await _key(tester, LogicalKeyboardKey.arrowDown);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
      await tester.pump();
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.select);
      await tester.pump();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
      await tester.pump();
      expect(h.ctrl.text, isEmpty);
      expect(_editing(tester), isFalse, reason: 'Tastatur bleibt zu');
      await _key(tester, LogicalKeyboardKey.select);
      expect(_editing(tester), isTrue);
    });

    testWidgets('Menü-Taste auf dem Feld leert', (tester) async {
      final h = await _pumpField(tester);
      h.ctrl.text = 'news';
      await tester.pump();
      await _key(tester, LogicalKeyboardKey.arrowDown);
      await _key(tester, LogicalKeyboardKey.contextMenu);
      expect(h.ctrl.text, isEmpty);
      expect(_fieldFocused(tester), isTrue);
    });

    testWidgets('Handy: kein Löschen-Knopf, X im Feld', (tester) async {
      final h = await _pumpField(tester, tv: false);
      h.ctrl.text = 'abc';
      await tester.pump();
      expect(find.byKey(const ValueKey('search-clear-chip')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('search-clear-x')));
      await tester.pump();
      expect(h.ctrl.text, isEmpty);
    });
  });

  group('Suche', () {
    testWidgets('Letzte Suchen: merken, übernehmen, lange tippen entfernt',
        (tester) async {
      final st = (await tester.runAsync(() => _storage()))!;
      final c = await _pumpSearch(tester, st);
      expect(find.text('Letzte Suchen'), findsNothing);
      await _type(tester, 'Tatort');
      expect(find.text('Sendungen'), findsOneWidget);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(c.read(recentSearchesProvider), ['Tatort']);
      expect(st.option(RecentSearchesNotifier.keyFor(Portal.demo.id), ''),
          contains('Tatort'));
      // Leeren → Chips erscheinen.
      await tester.tap(find.byKey(const ValueKey('search-clear-x')));
      await tester.pump();
      expect(find.text('Letzte Suchen'), findsOneWidget);
      final chip = find.byKey(const ValueKey('recent-search-Tatort'));
      expect(chip, findsOneWidget);
      await tester.tap(chip);
      await tester.pump();
      expect(find.text('Sendungen'), findsOneWidget, reason: 'sofort gesucht');
      // Kein Treffer → Chips ebenfalls sichtbar.
      await _type(tester, 'xyzxyz');
      expect(find.text('Nichts gefunden'), findsOneWidget);
      expect(chip, findsOneWidget);
      await tester.longPress(chip);
      await tester.pump();
      expect(chip, findsNothing);
      expect(c.read(recentSearchesProvider), isEmpty);
      await _done(tester);
    });

    testWidgets('Fernseher: Letzte Suche per OK/langes OK – Fokus bleibt',
        (tester) async {
      final st = (await tester.runAsync(() => _storage()))!;
      final c = await _pumpSearch(tester, st, tv: true);
      final n = c.read(recentSearchesProvider.notifier);
      await tester.runAsync(() => n.add('Krimi'));
      await tester.runAsync(() => n.add('Tatort'));
      await tester.pump();
      FocusNode chipNode(String q) => Focus.of(tester.element(find.descendant(
          of: find.byKey(ValueKey('recent-search-$q')),
          matching: find.byType(Container)).first));
      bool focusInTree() {
        final f = FocusManager.instance.primaryFocus;
        return f != null && f.context != null && f.context!.mounted &&
            f is! FocusScopeNode;
      }

      // Langes OK entfernt „Tatort“ → Fokus auf den nächsten Eintrag.
      chipNode('Tatort').requestFocus();
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
      await tester.pump(const Duration(milliseconds: 700));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
      await tester.pump();
      await tester.pump();
      expect(c.read(recentSearchesProvider), ['Krimi']);
      expect(focusInTree(), isTrue, reason: 'Fokus nach Entfernen verloren');
      expect(chipNode('Krimi').hasFocus, isTrue);
      // OK übernimmt „Krimi“ → Chips verschwinden, Fokus ins Feld.
      await _key(tester, LogicalKeyboardKey.select);
      await tester.pump();
      expect(_ctrlText(tester), 'Krimi');
      expect(focusInTree(), isTrue, reason: 'Fokus nach Übernehmen verloren');
      expect(_fieldFocused(tester), isTrue);
      await _done(tester);
    });

    testWidgets('Letzte Suchen: höchstens 8, je Portal', (tester) async {
      final st = (await tester.runAsync(() => _storage()))!;
      final c = await _pumpSearch(tester, st);
      final n = c.read(recentSearchesProvider.notifier);
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(() => n.add('Suche $i'));
      }
      await tester.runAsync(() => n.add('suche 3')); // Dublette → nach vorne
      final l = c.read(recentSearchesProvider);
      expect(l.length, RecentSearchesNotifier.max);
      expect(l.first, 'suche 3');
      expect(l.where((x) => x.toLowerCase() == 'suche 3').length, 1);
      expect(st.option(RecentSearchesNotifier.keyFor('anderes'), ''), isEmpty);
      await _done(tester);
    });

    testWidgets('Gastmodus: nichts gemerkt, nichts angezeigt', (tester) async {
      final st = (await tester.runAsync(() => _storage({
            'set_guest': true,
            'set_${RecentSearchesNotifier.keyFor(Portal.demo.id)}':
                '["Geheim"]',
          })))!;
      final c = await _pumpSearch(tester, st);
      expect(find.text('Letzte Suchen'), findsNothing);
      expect(find.text('Geheim'), findsNothing);
      await _type(tester, 'Tatort');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(c.read(recentSearchesProvider), isEmpty);
      expect(st.option(RecentSearchesNotifier.keyFor(Portal.demo.id), ''),
          '["Geheim"]');
      await _done(tester);
    });

    testWidgets('Sendungen: 20 zuerst, „Mehr anzeigen“ zeigt alle',
        (tester) async {
      final st = (await tester.runAsync(() => _storage()))!;
      await _pumpSearch(tester, st);
      await _type(tester, 'tatort');
      expect(find.text('30'), findsOneWidget); // Anzahl in der Überschrift
      final more = find.byKey(const ValueKey('search-more-shows'));
      final list = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(more, 300, scrollable: list);
      expect(find.text('Mehr anzeigen (10)'), findsOneWidget);
      expect(find.text('Tatort 20', skipOffstage: false), findsNothing);
      await tester.tap(more);
      await tester.pump();
      expect(more, findsNothing);
      await tester.scrollUntilVisible(find.text('Tatort 29'), 300,
          scrollable: list);
      expect(find.text('Tatort 29'), findsOneWidget);
      await _done(tester);
    });

    testWidgets('EPG-Update beim Tippen: kein Neuaufbau, erst wenn Feld ruht',
        (tester) async {
      final st = (await tester.runAsync(() => _storage()))!;
      await _pumpSearch(tester, st);
      SearchScreen.debugEpgReindex = 0;
      final searches0 = SearchScreen.debugSearches;
      for (final q in ['ta', 'tat']) {
        await _type(tester, q);
      }
      // Neues EPG (Teil-Updates kommen laufend) – mitten im Tippen.
      _epgNotifier.push(_epg('Krimi'));
      await tester.pump();
      for (final q in ['krim', 'krimi']) {
        await tester.enterText(find.byType(TextField), q);
        await tester.pump(const Duration(milliseconds: 300));
      }
      expect(SearchScreen.debugEpgReindex, 0, reason: 'nicht beim Tippen');
      expect(find.text('Sendungen'), findsNothing); // altes EPG
      // Feld ruht (2 s) und der letzte Aufbau ist lange genug her.
      await tester.pump(SearchScreen.epgMinGap);
      await tester.pump(const Duration(milliseconds: 100));
      expect(SearchScreen.debugEpgReindex, 1);
      expect(find.text('Sendungen'), findsOneWidget);
      // ignore: avoid_print
      print('[search15] Suchen ${SearchScreen.debugSearches - searches0} '
          'für 4 Eingaben + 1 EPG; EPG-Neuaufbauten '
          '${SearchScreen.debugEpgReindex} (vorher je EPG-Update einer)');
      await _done(tester);
    });

    testWidgets('Fernseher: Entprellung 320 ms, Handy 220 ms', (tester) async {
      final st = (await tester.runAsync(() => _storage()))!;
      await _pumpSearch(tester, st, tv: true);
      final s0 = SearchScreen.debugSearches;
      await tester.tap(find.byType(TextField)); // TV: Antippen startet Eingabe
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'tatort');
      await tester.pump(const Duration(milliseconds: 250));
      expect(SearchScreen.debugSearches, s0);
      await tester.pump(const Duration(milliseconds: 100));
      expect(SearchScreen.debugSearches, s0 + 1);
      await _done(tester);
    });
  });

  test('Suchindex: EPG im Hintergrund tauschen, Suche nutzt bis dahin alten',
      () async {
    final e = SearchEngine(
        channels: _channels,
        epg: _epg('Tatort'),
        movies: _movies,
        series: const [],
        buildPeople: false);
    await e.warmUp();
    expect(e.ready, isTrue);
    expect(e.search('tatort', _now).shows, hasLength(30));
    // Groß genug, dass der Aufbau zwischendurch abgibt (≥ 2000 Sendungen).
    final next = {
      for (final e in _epg('Krimi').entries)
        e.key: [for (var k = 0; k < 100; k++) e.value.first],
    };
    final f = e.refreshEpg(next, slice: Duration.zero);
    // Noch nicht getauscht (läuft in Häppchen).
    expect(e.search('tatort', _now).shows, isNotEmpty);
    expect(await f, isTrue);
    expect(identical(e.epg, next), isTrue);
    expect(e.search('tatort', _now).shows, isEmpty);
    expect(e.search('krimi', _now).shows, hasLength(SearchEngine.maxShows));
    // Abbrechen: alter Index bleibt.
    expect(
        await e.refreshEpg(next.map((k, v) => MapEntry(k, [...v])),
            slice: Duration.zero, cancelled: () => true),
        isFalse);
    expect(identical(e.epg, next), isTrue);
  });
}
