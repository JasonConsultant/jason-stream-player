import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:jason_stream_player/core/secret_store.dart';
import 'package:jason_stream_player/data/vod_meta.dart' show VodSort;
import 'package:jason_stream_player/data/storage.dart';
import 'package:jason_stream_player/l10n/strings.dart';
import 'package:jason_stream_player/models/models.dart';
import 'package:jason_stream_player/state/providers.dart';
import 'package:jason_stream_player/state/vod_library.dart';
import 'package:jason_stream_player/ui/home/home_screen.dart';
import 'package:jason_stream_player/ui/player/next_episode.dart';
import 'package:jason_stream_player/ui/search/person_screen.dart';
import 'package:jason_stream_player/ui/search/search_screen.dart';
import 'package:jason_stream_player/ui/vod/series_detail_screen.dart';
import 'package:jason_stream_player/ui/vod/vod_browse_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/content14_harness.dart';

/// 1.4: Staffel-Reiter, „Nächste Folge“-Karte, Stöbern-Raster,
/// Personensuche und neue Startseiten-Reihen – mit der Fernbedienung.

const _ok = LogicalKeyboardKey.select;
const _back = LogicalKeyboardKey.escape;
const _up = LogicalKeyboardKey.arrowUp;
const _down = LogicalKeyboardKey.arrowDown;
const _left = LogicalKeyboardKey.arrowLeft;
const _right = LogicalKeyboardKey.arrowRight;

Episode _ep(int s, int n) => Episode(
    id: 'k${s}_$n',
    season: s,
    number: n,
    title: 'Folge $s-$n',
    streamUrl: 'http://s/$s/$n',
    duration: const Duration(minutes: 44));

const _series = VodItem(
  id: 'k',
  name: 'Kaltes Land',
  categoryId: 'drama',
  streamUrl: '',
  isSeries: true,
  genre: 'Drama, Krimi',
  year: 2024,
  rating: 8.4,
  trailer: 'https://youtu.be/aqz-KE-bpKQ',
  plot: 'Eine Familie, ein Geheimnis und ein Sommer.',
);

final _details = SeriesDetails(
  series: _series,
  cast: 'Anna Wolff, David Kern, Selin Aydın',
  seasons: {
    1: [_ep(1, 1), _ep(1, 2), _ep(1, 3)],
    2: [_ep(2, 1), _ep(2, 2)],
    3: [_ep(3, 1)],
  },
);

final _genres = ['Drama', 'Komödie', 'Action, Thriller', 'Drama, Krimi'];
final _movies = [
  for (var i = 0; i < 24; i++)
    VodItem(
      id: 'm$i',
      name: 'Film $i',
      categoryId: 'all',
      streamUrl: 'http://m/$i',
      genre: _genres[i % 4],
      year: 1988 + i * 2,
      rating: 5 + (i % 5),
      added: DateTime(2026, 1, 1).add(Duration(days: i)),
      cast: i.isEven ? 'Lena Hartmann, Jonas Berger' : 'Mira Okafor',
      director: i % 3 == 0 ? 'Tobias Rehm' : null,
    ),
];

late Storage _st;

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await initializeDateFormatting('de');
  });

  setUp(() async {
    L10n.lang = 'de';
    SharedPreferences.setMockInitialValues({'set_applang': 'de'});
    _st = await Storage.open(store: PreviewSecretStore());
  });

  group('Serien-Details', () {
    C14Data data({VodLibrary lib = VodLibrary.empty}) => C14Data(
          series: const VodData([], [_series]),
          details: {'k': _details},
          library: lib,
        );

    testWidgets('Weiterschauen S2 · F1, Besetzung, Gesehen-Haken',
        (tester) async {
      for (final e in _details.seasons[1]!) {
        await _st.setWatched('ep_${e.id}');
      }
      final lib = VodLibrary(const {}, [
        VodHistoryEntry(true, 'k', DateTime(2026),
            episodeId: 'k1_3', season: 1, episode: 3),
      ]);
      await pumpC14(tester, const SeriesDetailScreen(series: _series),
          data(lib: lib), Future.value(_st));
      expect(find.text('Weiterschauen S2 · F1'), findsOneWidget);
      expect(focusedTexts(), contains('Weiterschauen S2 · F1'));
      expect(find.text('Mit Anna Wolff, David Kern, Selin Aydın'),
          findsOneWidget);
      expect(find.byKey(const ValueKey('trailer-button')), findsOneWidget);
      // Reiter der nächsten Folge ist gewählt (Staffel 2 zeigt ihre Folgen).
      expect(find.byKey(const ValueKey('ep-k2_1')), findsOneWidget);
      expect(find.text('0/2'), findsOneWidget); // Staffel 2: 0 von 2 gesehen
      expect(find.text('3/3'), findsOneWidget); // Staffel 1 komplett
      await c14Done(tester);
    });

    testWidgets('D-Pad: ◀▶ über die Reiter, ▼ in die Folgen, ▲ zurück',
        (tester) async {
      await pumpC14(tester, const SeriesDetailScreen(series: _series), data(),
          Future.value(_st));
      expect(focusedTexts(), contains('S1 F1 ansehen'));
      // ▼ vom Knopf erreicht die Staffel-Reiter.
      for (var i = 0; i < 4 && !focusInType('_SeasonTab'); i++) {
        await c14Key(tester, _down);
      }
      expect(focusInType('_SeasonTab'), isTrue);
      await focusKey(tester, const ValueKey('season-tab-1'));
      expect(focusUnderKey(const ValueKey('season-tab-1')), isTrue);
      expect(find.byKey(const ValueKey('ep-k1_1')), findsOneWidget);

      await c14Key(tester, _right);
      expect(focusUnderKey(const ValueKey('season-tab-2')), isTrue);
      expect(find.byKey(const ValueKey('ep-k2_1')), findsOneWidget);
      expect(find.byKey(const ValueKey('ep-k1_1')), findsNothing);

      await c14Key(tester, _right);
      await c14Key(tester, _right); // Rand: bleibt auf Staffel 3
      expect(focusUnderKey(const ValueKey('season-tab-3')), isTrue);
      expect(find.byKey(const ValueKey('ep-k3_1')), findsOneWidget);

      await c14Key(tester, _left);
      expect(focusUnderKey(const ValueKey('season-tab-2')), isTrue);

      await c14Key(tester, _down);
      expect(focusUnderKey(const ValueKey('ep-k2_1')), isTrue);
      await c14Key(tester, _down);
      expect(focusUnderKey(const ValueKey('ep-k2_2')), isTrue);
      await c14Key(tester, _up);
      await c14Key(tester, _up); // erste Folge → zurück zum Reiter
      expect(focusUnderKey(const ValueKey('season-tab-2')), isTrue);

      await focusKey(tester, const ValueKey('season-tab-1'));
      await c14Key(tester, _left); // Rand links: bleibt
      expect(focusUnderKey(const ValueKey('season-tab-1')), isTrue);
      await c14Done(tester);
    });

    testWidgets('Alle Folgen gesehen → Serie gilt als gesehen',
        (tester) async {
      for (final l in _details.seasons.values) {
        for (final e in l) {
          await _st.setWatched('ep_${e.id}');
        }
      }
      await pumpC14(tester, const SeriesDetailScreen(series: _series), data(),
          Future.value(_st));
      await tester.pump();
      expect(_st.isWatched('series_k'), isTrue);
      await c14Done(tester);
    });
  });

  group('Nächste Folge', () {
    late StreamController<Duration> pos, len;
    late List<PlayRequest> played;
    late int exits;
    late bool started;
    final playerFocus = FocusNode(debugLabel: 'player');
    final hostKey = GlobalKey<NextEpisodeHostState>();

    PlayRequest request({bool hasNext = true}) => PlayRequest(
          title: 'Kaltes Land',
          url: 'http://s/1/3',
          resumeKey: 'ep_k1_3',
          nextUp: () async => hasNext
              ? NextUp(
                  label: 'S2 · F1 – Folge 2-1',
                  request: const PlayRequest(
                      title: 'Kaltes Land',
                      url: 'http://s/2/1',
                      resumeKey: 'ep_k2_1'),
                  onStart: () => started = true,
                )
              : null,
        );

    Future<void> pump(WidgetTester tester, {bool hasNext = true}) async {
      pos = StreamController<Duration>.broadcast();
      len = StreamController<Duration>.broadcast();
      played = [];
      exits = 0;
      started = false;
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ProviderScope(
        overrides: [
          storageProvider.overrideWith((ref) => Future.value(_st)),
          isTvProvider.overrideWithValue(true),
        ],
        child: MaterialApp(
          home: Consumer(builder: (context, ref, _) {
            ref.watch(storageProvider);
            return Scaffold(
              backgroundColor: Colors.black,
              body: Focus(
                focusNode: playerFocus,
                autofocus: true,
                child: Stack(fit: StackFit.expand, children: [
                  const ColoredBox(color: Colors.black),
                  NextEpisodeHost(
                    key: hostKey,
                    request: request(hasNext: hasNext),
                    position: pos.stream,
                    duration: len.stream,
                    returnFocus: playerFocus,
                    onPlay: played.add,
                    onExit: () => exits++,
                  ),
                ]),
              ),
            );
          }),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 100));
    }

    Future<void> credits(WidgetTester tester) async {
      len.add(const Duration(minutes: 45));
      await tester.pump();
      pos.add(const Duration(minutes: 44)); // noch 60 s: nichts
      await tester.pump();
      expect(find.byKey(const ValueKey('next-episode-card')), findsNothing);
      pos.add(const Duration(minutes: 44, seconds: 31)); // Abspann
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
    }

    testWidgets('Abspann: Karte, OK spielt sofort die nächste Folge',
        (tester) async {
      await pump(tester);
      await credits(tester);
      expect(find.text('Nächste Folge in 10 s'), findsOneWidget);
      expect(find.text('S2 · F1 – Folge 2-1'), findsOneWidget);
      expect(focusedTexts(), contains('Jetzt abspielen'));
      // ▲▼ verlassen die Karte nicht, ◀▶ wechseln die Knöpfe.
      await c14Key(tester, _up);
      expect(focusedTexts(), contains('Jetzt abspielen'));
      await c14Key(tester, _right);
      expect(focusedTexts(), contains('Abbrechen'));
      await c14Key(tester, _left);
      expect(focusedTexts(), contains('Jetzt abspielen'));
      await c14Key(tester, _ok);
      expect(played.single.url, 'http://s/2/1');
      expect(started, isTrue);
      expect(_st.isWatched('ep_k1_3'), isTrue);
      expect(find.byKey(const ValueKey('next-episode-card')), findsNothing);
      await c14Done(tester);
    });

    testWidgets('Zurück bricht ab; am Ende schließt der Player',
        (tester) async {
      await pump(tester);
      await credits(tester);
      await c14Key(tester, _back);
      expect(find.byKey(const ValueKey('next-episode-card')), findsNothing);
      expect(played, isEmpty);
      expect(playerFocus.hasFocus, isTrue);
      // Kein zweites Erscheinen, Folge endet → Player schließt.
      pos.add(const Duration(minutes: 44, seconds: 50));
      await tester.pump(const Duration(seconds: 11));
      expect(played, isEmpty);
      expect(hostKey.currentState!.onCompleted(), isFalse);
      await c14Done(tester);
    });

    testWidgets('Zeitablauf: nach 10 s automatisch weiter', (tester) async {
      await pump(tester);
      await credits(tester);
      await tester.pump(const Duration(seconds: 5));
      expect(find.text('Nächste Folge in 5 s'), findsOneWidget);
      expect(played, isEmpty);
      await tester.pump(const Duration(seconds: 6));
      expect(played.single.url, 'http://s/2/1');
      await c14Done(tester);
    });

    testWidgets('Ende ohne Abspann-Karte: Karte erscheint am Ende',
        (tester) async {
      await pump(tester);
      len.add(const Duration(minutes: 45));
      await tester.pump();
      expect(hostKey.currentState!.onCompleted(), isTrue);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byKey(const ValueKey('next-episode-card')), findsOneWidget);
      await c14Key(tester, _back);
      expect(exits, 1); // abgebrochen nach dem Ende → Player schließen
      await c14Done(tester);
    });

    testWidgets('Letzte Folge: keine Karte, Player schließt am Ende',
        (tester) async {
      await pump(tester, hasNext: false);
      expect(hostKey.currentState!.onCompleted(), isTrue);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byKey(const ValueKey('next-episode-card')), findsNothing);
      expect(exits, 1);
      await c14Done(tester);
    });

    testWidgets('Einstellung aus: keine Karte', (tester) async {
      await _st.setFlag(autoNextFlag, false);
      await pump(tester);
      len.add(const Duration(minutes: 45));
      pos.add(const Duration(minutes: 44, seconds: 40));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const ValueKey('next-episode-card')), findsNothing);
      expect(hostKey.currentState!.onCompleted(), isFalse);
      await c14Done(tester);
    });

    testWidgets('Einstellungs-Schalter per OK', (tester) async {
      await pumpC14(
          tester,
          const Scaffold(body: Center(child: NextEpisodeTile())),
          const C14Data(),
          Future.value(_st));
      await focusKey(tester, const ValueKey('next-episode-tile'));
      expect(_st.flag(autoNextFlag, fallback: true), isTrue);
      await c14Key(tester, _ok);
      expect(_st.flag(autoNextFlag, fallback: true), isFalse);
      await c14Done(tester);
    });
  });

  group('Stöbern', () {
    const data = C14Data(movies: VodData([], []));
    C14Data withMovies() =>
        C14Data(movies: VodData(const [Category(id: 'all', name: 'Alle')], _movies));

    testWidgets('Genre, Jahrzehnt/Jahr, Ungesehen – mit dem D-Pad',
        (tester) async {
      expect(data.movies.items, isEmpty);
      await _st.setWatched('movie_m0');
      await pumpC14(tester, const VodBrowseScreen(series: false), withMovies(),
          Future.value(_st));
      expect(find.text('24 Titel'), findsOneWidget);
      // Start im Raster.
      expect(focusInType('PosterCard'), isTrue);
      // ▲ führt in die Chip-Reihen.
      await c14Key(tester, _up);
      expect(focusInType('TvChip'), isTrue);
      // Genre „Drama“ (12 Titel) per OK.
      await focusKey(tester, const ValueKey('genre-drama'));
      expect(focusedTexts(), contains('Drama · 12'));
      await c14Key(tester, _ok);
      expect(find.text('12 Titel'), findsOneWidget);
      // ▶ zum nächsten Genre, OK.
      await c14Key(tester, _right);
      await c14Key(tester, _ok);
      expect(find.textContaining(' Titel'), findsWidgets);
      await focusKey(tester, const ValueKey('genre-all'));
      await c14Key(tester, _ok);
      expect(find.text('24 Titel'), findsOneWidget);
      // Jahrzehnt 2000er → Jahre erscheinen; Jahr 2004 wählen.
      await focusKey(tester, const ValueKey('decade-2000'));
      await c14Key(tester, _ok);
      expect(find.text('5 Titel'), findsOneWidget); // 2000..2008, gerade Jahre
      expect(find.byKey(const ValueKey('year-2004')), findsOneWidget);
      await c14Key(tester, _right); // erstes Jahr (neueste zuerst): 2008
      await c14Key(tester, _ok);
      expect(find.text('1 Titel'), findsOneWidget);
      await focusKey(tester, const ValueKey('decade-all'));
      await c14Key(tester, _ok);
      // Ungesehen blendet den gesehenen Film aus.
      await focusKey(tester, const ValueKey('filter-unseen'));
      await c14Key(tester, _ok);
      expect(find.text('23 Titel'), findsOneWidget);
      // ▼ ins Raster.
      for (var i = 0; i < 3 && !focusInType('PosterCard'); i++) {
        await c14Key(tester, _down);
      }
      expect(focusInType('PosterCard'), isTrue);
      await c14Done(tester);
    });

    testWidgets('Neueste zuerst und Gesehen-Haken', (tester) async {
      await _st.setWatched('movie_m23');
      await pumpC14(
          tester,
          const VodBrowseScreen(
              series: false, initial: VodFilter(sort: VodSort.newest)),
          withMovies(),
          Future.value(_st));
      // Neuester Film (m23) steht vorn und trägt den Haken.
      final first = find.byType(GridView);
      expect(first, findsOneWidget);
      expect(focusedTexts(), contains('Film 23'));
      expect(find.byKey(const ValueKey('watched-badge')), findsOneWidget);
      await c14Done(tester);
    });
  });

  group('Personensuche', () {
    testWidgets('„Personen“ in der Suche, OK zeigt ihre Titel',
        (tester) async {
      await pumpC14(
          tester,
          const Scaffold(body: SearchScreen()),
          // Handy-Oberfläche (Texteingabe direkt); Bedienung per Tasten.
          C14Data(movies: VodData(const [], _movies), tv: false),
          Future.value(_st));
      await tester.enterText(find.byType(TextField), 'hartm');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Personen'), findsOneWidget);
      final tile = find.byKey(const ValueKey('person-Lena Hartmann'));
      expect(tile, findsOneWidget);
      expect(find.text('12 Titel'), findsOneWidget);
      await focusKey(tester, const ValueKey('person-Lena Hartmann'));
      await c14Key(tester, _ok);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(PersonScreen), findsOneWidget);
      expect(find.text('Lena Hartmann'), findsWidgets);
      expect(focusInType('PosterCard'), isTrue);
      // Zurück (Fernbedienung/System) → wieder in der Suche.
      await tester.binding.handlePopRoute();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(PersonScreen), findsNothing);
      // Regie wird erkannt.
      await tester.enterText(find.byType(TextField), 'rehm');
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Regie · 8 Titel'), findsOneWidget);
      await c14Done(tester);
    });
  });

  group('Startseite', () {
    final now = DateTime.now();
    const cats = [
      Category(id: 'de', name: 'DE | Vollprogramm'),
      Category(id: 'sp', name: 'DE | Sport'),
    ];
    Channel ch(String id, String cat) => Channel(
        id: id, name: 'Sender $id', categoryId: cat, streamUrl: 'u', epgId: id);
    EpgEntry show(String ch, String t) => EpgEntry(
        channelEpgId: ch,
        title: t,
        start: now.subtract(const Duration(minutes: 20)),
        end: now.add(const Duration(minutes: 70)));
    C14Data home({VodLibrary lib = VodLibrary.empty}) => C14Data(
          live: LiveData(cats, [ch('a', 'de'), ch('b', 'de'), ch('c', 'sp')]),
          epg: {
            'a': [show('a', 'Sportschau live')],
            'b': [show('b', 'Transport-Giganten')],
            'c': [show('c', 'Sky Sport News')],
          },
          movies: VodData(const [], _movies),
          library: lib,
        );

    testWidgets('Sport live, Empfehlung, Neue Filme; Gast ohne Empfehlung',
        (tester) async {
      final lib = VodLibrary(const {}, [
        VodHistoryEntry(false, 'm1', DateTime(2026)), // Komödie
      ]);
      await pumpC14(tester, HomeScreen(onOpenTab: (_) {}), home(lib: lib),
          Future.value(_st));
      expect(find.byKey(const ValueKey('home-sport')), findsOneWidget);
      expect(find.text('Sender a'), findsOneWidget);
      expect(find.text('Sender c'), findsOneWidget);
      expect(find.text('Sender b'), findsNothing); // „Transport“ ist kein Sport
      expect(find.byKey(const ValueKey('home-recs')), findsOneWidget);
      expect(find.text('WEIL DU FILM 1 GESCHAUT HAST'), findsOneWidget);
      await tester.scrollUntilVisible(
          find.byKey(const ValueKey('home-new-movies')), 200,
          scrollable: find.byType(Scrollable).first);
      expect(find.byKey(const ValueKey('home-new-movies')), findsOneWidget);
      await c14Done(tester);

      // Gastmodus: keine Empfehlung.
      await _st.setFlag(Storage.guestFlag, true);
      await pumpC14(tester, HomeScreen(onOpenTab: (_) {}), home(lib: lib),
          Future.value(_st));
      expect(find.byKey(const ValueKey('home-recs')), findsNothing);
      expect(find.byKey(const ValueKey('home-sport')), findsOneWidget);
      await c14Done(tester);
    });
  });
}
