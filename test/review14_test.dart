import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:jason_stream_player/core/secret_store.dart';
import 'package:jason_stream_player/core/theme.dart';
import 'package:jason_stream_player/data/storage.dart';
import 'package:jason_stream_player/data/vod_meta.dart';
import 'package:jason_stream_player/l10n/strings.dart';
import 'package:jason_stream_player/models/models.dart';
import 'package:jason_stream_player/state/discover.dart';
import 'package:jason_stream_player/state/profile_mode.dart'
    show visibleMoviesProvider;
import 'package:jason_stream_player/state/providers.dart';
import 'package:jason_stream_player/state/vod_library.dart';
import 'package:jason_stream_player/ui/guide/guide_screen.dart';
import 'package:jason_stream_player/ui/home/home_screen.dart';
import 'package:jason_stream_player/ui/player/player_screen.dart'
    show canSaveResume;
import 'package:jason_stream_player/ui/search/search_screen.dart';
import 'package:jason_stream_player/ui/shell/app_guard.dart' show AppLock;
import 'package:jason_stream_player/ui/shell/text_size_chooser.dart';
import 'package:jason_stream_player/ui/vod/movie_detail_screen.dart';
import 'package:jason_stream_player/ui/vod/series_detail_screen.dart';
import 'package:jason_stream_player/ui/widgets/a11y.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/content14_harness.dart';

/// Abschlussprüfung 1.4: Korrekturen (Fortsetzen beim Folgenwechsel,
/// Schriftgrößen-Abfrage, Personen-/Empfehlungs-Daten im Kinder- und
/// Gastmodus) und TalkBack-Texte (Startseite, Details, Serien, TV-Guide).

const _pid = '__demo';

VodItem _m(int i, String cat, {String? cast, String genre = 'Komödie'}) =>
    VodItem(
      id: 'm$i',
      name: 'Film $i',
      categoryId: cat,
      streamUrl: 'http://m/$i',
      genre: genre,
      year: 2000 + i,
      rating: (i % 10).toDouble(),
      added: DateTime(2026, 1, 1).add(Duration(days: i)),
      cast: cast,
    );

final _kidsMovies = [
  for (var i = 0; i < 6; i++) _m(i, 'kid', cast: 'Lena Hartmann, Paul Kern'),
];
final _adultMovies = [
  for (var i = 6; i < 12; i++)
    _m(i, 'adult', cast: 'Lena Hartmann, Mira Okafor', genre: 'Komödie, Drama'),
];
final _allMovies = [..._kidsMovies, ..._adultMovies];

Future<Storage> _storage(Map<String, Object> prefs) {
  SharedPreferences.setMockInitialValues({'set_applang': 'de', ...prefs});
  return Storage.open(store: PreviewSecretStore());
}

Future<ProviderContainer> _container(Storage st, C14Data d) async {
  final c = ProviderContainer(overrides: c14Overrides(d, Future.value(st)));
  addTearDown(c.dispose);
  await c.read(storageProvider.future);
  await c.read(activePortalProvider.future);
  await c.read(moviesProvider.future);
  await c.read(seriesProvider.future);
  await c.read(vodLibraryProvider.future);
  return c;
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await initializeDateFormatting('de');
  });
  setUp(() => L10n.lang = 'de');
  tearDown(() {
    TextSizeChooser.debugAllowInTests = false;
    AppLock.locked.value = false;
  });

  group('Player: Fortsetzen', () {
    test('beim Öffnen (z. B. nächste Folge) wird keine Stelle gemerkt', () {
      // Sonst landet die Abspann-Stelle der alten Folge unter der neuen.
      expect(canSaveResume(live: false, opening: true, pos: 2650, total: 2700),
          isFalse);
      expect(canSaveResume(live: false, opening: false, pos: 120, total: 2700),
          isTrue);
      expect(canSaveResume(live: true, opening: false, pos: 120, total: 2700),
          isFalse);
      expect(canSaveResume(live: false, opening: false, pos: 3, total: 2700),
          isFalse);
      expect(canSaveResume(live: false, opening: false, pos: 300, total: 0),
          isFalse);
    });
  });

  group('Entdecken: Daten', () {
    test('„Neu hinzugefügt“: ein Durchgang, gleiche Reihenfolge wie Sortieren',
        () {
      final items = [
        for (var i = 0; i < 40; i++)
          VodItem(
            id: '$i',
            name: 'T$i',
            categoryId: 'c',
            streamUrl: 'u',
            // Gleichstände und fehlende Zeitstempel gemischt.
            added: i % 4 == 0 ? null : DateTime(2026, 1, 1 + i % 7),
          ),
      ];
      for (final k in [0, 1, 5, 15, 40, 60]) {
        expect(topNewest(items, k).map((m) => m.id),
            sortNewest(items).take(k).map((m) => m.id),
            reason: 'k=$k');
      }
    });

    test('Empfehlung: nur aus freigegebenen Titeln (Kindermodus), Gast: keine',
        () async {
      final lib = VodLibrary(const {}, [
        VodHistoryEntry(false, 'm1', DateTime(2026)),
      ]);
      final d = C14Data(movies: VodData(const [], _allMovies), library: lib);

      var c = await _container(await _storage({}), d);
      await c.read(genreIndexProvider(false).future);
      await c.read(genreIndexProvider(true).future);
      Recommendation? r = c.read(recommendationProvider);
      expect(r, isNotNull);
      expect(r!.items.map((m) => m.categoryId).toSet(), {'kid', 'adult'});
      expect(r.items.any((m) => m.id == 'm1'), isFalse);

      c = await _container(
          await _storage({
            'set_kids': true,
            'set_kidsvod_$_pid': ['m:kid'],
          }),
          d);
      await c.read(genreIndexProvider(false).future);
      await c.read(genreIndexProvider(true).future);
      final kids = c.read(recommendationProvider);
      expect(kids, isNotNull);
      expect(kids!.items.map((m) => m.categoryId).toSet(), {'kid'});

      c = await _container(await _storage({'set_guest': true}), d);
      await c.read(genreIndexProvider(false).future);
      expect(c.read(recommendationProvider), isNull);
    });

    test('Personen: Verzeichnis nur aus sichtbaren Titeln (Kindermodus)',
        () async {
      final d = C14Data(movies: VodData(const [], _allMovies));
      final c = await _container(
          await _storage({
            'set_kids': true,
            'set_kidsvod_$_pid': ['m:kid'],
          }),
          d);
      final p = await c.read(peopleIndexProvider.future);
      final idx = p!.index;
      expect(identical(p.movies, c.read(visibleMoviesProvider).value!.items),
          isTrue);
      final i = idx.lower.indexOf('lena hartmann');
      expect(idx.titlesAt(i).map((m) => m.categoryId).toSet(), {'kid'});
      expect(idx.lower, isNot(contains('mira okafor')));
    });

    test(
        'Personen-Zwischenspeicher: klein, gekürzt, im Gastmodus nichts '
        'geschrieben', () async {
      final many = [for (var i = 0; i < 25; i++) 'Person Nummer$i'].join(', ');
      VodItem item(int i) => VodItem(
          id: 'x$i',
          name: 'X$i',
          categoryId: 'c',
          streamUrl: 'u',
          cast: many,
          director: 'Regie Frau');

      var st = await _storage({});
      var c = await _container(st, const C14Data());
      c.listen(peopleCacheProvider, (_, __) {});
      final n = c.read(peopleCacheProvider.notifier);
      for (var i = 0; i < PeopleCacheNotifier.maxEntries + 5; i++) {
        n.remember(item(i));
      }
      await Future<void>.delayed(Duration.zero);
      final cache = c.read(peopleCacheProvider);
      expect(cache.length, PeopleCacheNotifier.maxEntries);
      expect(cache.containsKey('m:x0'), isFalse); // älteste fliegen raus
      expect(
          splitPeople(cache['m:x9']!.cast).length, PeopleCacheNotifier.maxCast);
      expect(st.option('people_$_pid', ''), isNotEmpty);

      st = await _storage({'set_guest': true});
      c = await _container(st, const C14Data());
      c.listen(peopleCacheProvider, (_, __) {});
      c.read(peopleCacheProvider.notifier).remember(item(1));
      await Future<void>.delayed(Duration.zero);
      expect(c.read(peopleCacheProvider), isNotEmpty); // nur im Speicher
      expect(st.option('people_$_pid', ''), isEmpty);
    });
  });

  group('Suche', () {
    testWidgets('Kindermodus: Personen nur mit freigegebenen Titeln',
        (tester) async {
      final st = await tester.runAsync(() => _storage({
            'set_kids': true,
            'set_kidsvod_$_pid': ['m:kid'],
          }));
      await pumpC14(
          tester,
          const Scaffold(body: SearchScreen()),
          C14Data(movies: VodData(const [], _allMovies), tv: false),
          Future.value(st!));
      await tester.enterText(find.byType(TextField), 'hartm');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 100));
      expect(
          find.byKey(const ValueKey('person-Lena Hartmann')), findsOneWidget);
      expect(find.text('6 Titel'), findsOneWidget); // nicht 12
      await tester.enterText(find.byType(TextField), 'okafor');
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('person-Mira Okafor')), findsNothing);
      await c14Done(tester);
    });
  });

  group('Schriftgröße beim ersten Start', () {
    Future<void> host(WidgetTester tester, Storage st,
        {bool pushFirst = false, ValueNotifier<bool>? exclude}) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [
          isTvProvider.overrideWithValue(true),
          storageProvider.overrideWith((ref) async => st),
        ],
        child: ValueListenableBuilder<bool>(
          valueListenable: exclude ?? ValueNotifier(false),
          // Wie AppGuard: gesperrt = Inhalt nicht fokussierbar.
          builder: (_, ex, child) => ExcludeFocus(excluding: ex, child: child!),
          child: MaterialApp(
            theme: buildTheme(tv: true),
            home: _Host(pushFirst: pushFirst),
          ),
        ),
      ));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    testWidgets('nicht über einer anderen Seite (z. B. Player)',
        (tester) async {
      TextSizeChooser.debugAllowInTests = true;
      final st = (await tester.runAsync(() => _storage({})))!;
      await host(tester, st, pushFirst: true);
      expect(find.text('Player'), findsOneWidget);
      expect(find.byType(TextSizeChooser), findsNothing);
      // Nicht als „gefragt“ merken → beim nächsten Start.
      expect(st.flag(TextSizeChooser.askedFlag), isFalse);
    });

    testWidgets('wartet auf das Entsperren; Fokus kommt zurück',
        (tester) async {
      TextSizeChooser.debugAllowInTests = true;
      final st = (await tester.runAsync(() => _storage({})))!;
      final exclude = ValueNotifier(true);
      AppLock.locked.value = true;
      await host(tester, st, exclude: exclude);
      expect(find.byType(TextSizeChooser), findsNothing);

      exclude.value = false;
      AppLock.locked.value = false;
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(TextSizeChooser), findsOneWidget);
      expect(focusedTexts(), contains('Normal'));
      await c14Key(tester, LogicalKeyboardKey.arrowRight);
      expect(focusedTexts(), contains('Groß'));

      // Sperre kommt (App im Hintergrund) und geht wieder: Fokus zurück.
      exclude.value = true;
      AppLock.locked.value = true;
      await tester.pump(const Duration(milliseconds: 100));
      expect(focusInType('FocusableTile'), isFalse);
      exclude.value = false;
      AppLock.locked.value = false;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(focusInType('FocusableTile'), isTrue);
      expect(focusedTexts(), contains('Groß'));
      await c14Key(tester, LogicalKeyboardKey.select);
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(TextSizeChooser), findsNothing);
      expect(st.option('uiscale', 'auto'), 'gross');
    });
  });

  group('TalkBack', () {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day, now.hour)
        .subtract(const Duration(minutes: 30));
    const ch = Channel(
        id: 'a',
        name: 'Das Erste',
        categoryId: 'de',
        streamUrl: 'u',
        epgId: 'a',
        number: 1);
    final show = EpgEntry(
        channelEpgId: 'a',
        title: 'Tagesschau',
        start: start,
        end: start.add(const Duration(hours: 2)));
    final next = EpgEntry(
        channelEpgId: 'a',
        title: 'Tatort',
        start: start.add(const Duration(hours: 2)),
        end: start.add(const Duration(hours: 3, minutes: 30)));
    final live = const LiveData([Category(id: 'de', name: 'DE')], [ch]);
    final epg = {
      'a': [show, next]
    };
    String hm(DateTime t) =>
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

    test('Texte', () {
      expect(
          programmeSemantics(show, ch, running: true),
          'Tagesschau, ${hm(show.start)} bis ${hm(show.end)}, Das Erste, '
          'läuft gerade');
      expect(programmeSemantics(next, ch),
          'Tatort, ${hm(next.start)} bis ${hm(next.end)}, Das Erste');
      expect(programmeSemantics(null, ch), 'Keine Programminfo, Das Erste');
      final e = Episode(
          id: 'e',
          season: 2,
          number: 3,
          title: 'Der Bruch',
          streamUrl: 'u',
          duration: const Duration(minutes: 44));
      expect(episodeSemantics(e, progress: 0.4),
          'Staffel 2, Folge 3: Der Bruch, 44 Min., 40 % gesehen');
      expect(episodeSemantics(e, watched: true),
          'Staffel 2, Folge 3: Der Bruch, 44 Min., Gesehen');
      expect(posterSemantics('Dune', year: 2021, seen: true),
          'Dune, 2021, Gesehen');
      expect(ratingSemantics(7.46), 'Bewertung 7,5');
      L10n.lang = 'en';
      expect(programmeSemantics(next, ch),
          'Tatort, ${hm(next.start)} to ${hm(next.end)}, Das Erste');
      expect(seasonSemantics('Season 1', 2, 5), 'Season 1, 2 of 5 watched');
      L10n.lang = 'de';
    });

    for (final tv in [false, true]) {
      testWidgets(
          'TV-Guide (${tv ? 'TV' : 'Handy'}): Sendungen vorlesbar, '
          'D-Pad unverändert', (tester) async {
        final handle = tester.ensureSemantics();
        final st = (await tester.runAsync(() => _storage({})))!;
        await pumpC14(tester, const Scaffold(body: GuideScreen()),
            C14Data(live: live, epg: epg, tv: tv), Future.value(st));
        if (!tv) {
          // Testschrift (Ahem) ist breiter als die echte: Kopfzeile läuft
          // bei 360 dp über – quer weiterprüfen.
          tester.takeException();
          tester.view.physicalSize = const Size(2340, 1080);
          await tester.pump(const Duration(milliseconds: 300));
        }
        final label = 'Tagesschau, ${hm(show.start)} bis ${hm(show.end)}, '
            'Das Erste, läuft gerade';
        expect(find.bySemanticsLabel(label), findsOneWidget);
        final node = tester.getSemantics(find.bySemanticsLabel(label));
        expect(node.flagsCollection.isButton, isTrue);
        if (tv) {
          // Fokus startet auf der laufenden Sendung, ▶ zur nächsten.
          expect(FocusManager.instance.primaryFocus?.debugLabel, 'Tagesschau');
          await c14Key(tester, LogicalKeyboardKey.arrowRight);
          expect(FocusManager.instance.primaryFocus?.debugLabel, 'Tatort');
        }
        handle.dispose();
        await c14Done(tester);
      });
    }

    testWidgets('Startseite (Handy): Senderkarten, Poster, Überschriften',
        (tester) async {
      final handle = tester.ensureSemantics();
      final st = (await tester.runAsync(() => _storage({})))!;
      await st.setWatched('movie_m11');
      await pumpC14(
          tester,
          Scaffold(body: HomeScreen(onOpenTab: (_) {})),
          C14Data(
              live: live,
              epg: epg,
              movies: VodData(const [], _allMovies),
              tv: false),
          Future.value(st));
      await tester.scrollUntilVisible(
          find.byKey(const ValueKey('home-new-movies')), 200,
          scrollable: find.byType(Scrollable).first);
      expect(find.bySemanticsLabel('Film 11, 2011, Gesehen'), findsOneWidget);
      expect(find.bySemanticsLabel('Film 10, 2010'), findsOneWidget);
      final h = tester.getSemantics(find.bySemanticsLabel('Neue Filme'));
      expect(h.flagsCollection.isHeader, isTrue);
      handle.dispose();
      await c14Done(tester);
    });

    testWidgets('Startseite (TV): Senderkarte „1 Das Erste, jetzt: …“',
        (tester) async {
      final handle = tester.ensureSemantics();
      final st = (await tester.runAsync(() => _storage({})))!;
      await pumpC14(
          tester,
          HomeScreen(onOpenTab: (_) {}),
          C14Data(live: live, epg: epg, movies: VodData(const [], _allMovies)),
          Future.value(st));
      // Live-TV-Kachel mit Anzahl, TV-Überschriften normal geschrieben.
      expect(find.bySemanticsLabel('Live TV, 1 Sender'), findsOneWidget);
      final h = tester.getSemantics(find.bySemanticsLabel('Neue Filme'));
      expect(h.flagsCollection.isHeader, isTrue);
      handle.dispose();
      await c14Done(tester);
    });

    testWidgets('Film-Details: Titel als Überschrift, Zurück, Bewertung',
        (tester) async {
      final handle = tester.ensureSemantics();
      final st = (await tester.runAsync(() => _storage({})))!;
      await pumpC14(tester, MovieDetailScreen(movie: _allMovies[7]),
          const C14Data(tv: false), Future.value(st));
      final t = tester.getSemantics(find.bySemanticsLabel('Film 7'));
      expect(t.flagsCollection.isHeader, isTrue);
      expect(find.byTooltip('Zurück'), findsOneWidget);
      expect(find.bySemanticsLabel('Bewertung 7,0'), findsOneWidget);
      // Überschrift nur der Titel, nicht der ganze Block.
      expect(
          tester
              .getSemantics(find.bySemanticsLabel('Bewertung 7,0'))
              .flagsCollection
              .isHeader,
          isFalse);
      // Fokus weiterhin auf „Abspielen“.
      expect(focusedTexts(), contains('Abspielen'));
      handle.dispose();
      await c14Done(tester);
    });

    testWidgets('Serien-Details: Staffel-Reiter und Folgen', (tester) async {
      final handle = tester.ensureSemantics();
      final st = (await tester.runAsync(() => _storage({})))!;
      Episode ep(int s, int n) => Episode(
          id: 'z${s}_$n',
          season: s,
          number: n,
          title: 'Folge $s-$n',
          streamUrl: 'u',
          duration: const Duration(minutes: 44));
      const s = VodItem(
          id: 'z',
          name: 'Kaltes Land',
          categoryId: 'c',
          streamUrl: '',
          isSeries: true);
      await st.setWatched('ep_z1_1');
      await pumpC14(
          tester,
          const SeriesDetailScreen(series: s),
          C14Data(series: const VodData([], [s]), details: {
            'z': SeriesDetails(series: s, seasons: {
              1: [ep(1, 1), ep(1, 2)],
              2: [ep(2, 1)],
            }),
          }),
          Future.value(st));
      final tab = tester
          .getSemantics(find.bySemanticsLabel('Staffel 1, 1 von 2 gesehen'));
      expect(tab.flagsCollection.isSelected, Tristate.isTrue);
      final other = tester
          .getSemantics(find.bySemanticsLabel('Staffel 2, 0 von 1 gesehen'));
      expect(other.flagsCollection.isSelected, isNot(Tristate.isTrue));
      expect(
          find.bySemanticsLabel(
              'Staffel 1, Folge 1: Folge 1-1, 44 Min., Gesehen'),
          findsOneWidget);
      expect(find.bySemanticsLabel('Staffel 1, Folge 2: Folge 1-2, 44 Min.'),
          findsOneWidget);
      handle.dispose();
      await c14Done(tester);
    });
  });
}

class _Host extends ConsumerStatefulWidget {
  final bool pushFirst;
  const _Host({this.pushFirst = false});
  @override
  ConsumerState<_Host> createState() => _HostState();
}

class _HostState extends ConsumerState<_Host> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.pushFirst) {
        Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Player'))));
      }
      TextSizeChooser.maybeShow(context, ref);
    });
  }

  @override
  Widget build(BuildContext context) => const Scaffold(body: Text('Start'));
}
