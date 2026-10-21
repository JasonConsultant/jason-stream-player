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
import 'package:jason_stream_player/state/providers.dart';
import 'package:jason_stream_player/state/vod_library.dart';
import 'package:jason_stream_player/ui/home/home_screen.dart';
import 'package:jason_stream_player/ui/player/next_episode.dart';
import 'package:jason_stream_player/ui/search/person_screen.dart';
import 'package:jason_stream_player/ui/search/search_screen.dart';
import 'package:jason_stream_player/ui/settings/settings_screen.dart';
import 'package:jason_stream_player/ui/shell/accent.dart' show accentOptionKey;
import 'package:jason_stream_player/ui/shell/text_size_chooser.dart';
import 'package:jason_stream_player/ui/vod/series_detail_screen.dart';
import 'package:jason_stream_player/ui/vod/vod_browse_screen.dart';
import 'package:jason_stream_player/ui/widgets/artwork.dart';
import 'package:jason_stream_player/ui/widgets/voice_search.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/app_fonts.dart';
import 'helpers/content14_harness.dart';

/// Bildschirmfotos der 1.4-Neuerungen (TV, 1920×1080, dpr 2, echte
/// Schriften): Startseite mit neuen Reihen, Stöbern, Serien-Reiter,
/// „Nächste Folge“-Karte, Personensuche. Nur mit `TV_SHOTS=ordner`.

final _shotDir = Platform.environment['TV_SHOTS'];

Future<void> _shot(WidgetTester tester, String name) =>
    writeShot(tester, c14ShotKey, name);

const _genres = [
  'Drama', 'Komödie', 'Action, Thriller', 'Drama, Krimi', 'Science-Fiction',
  'Familie, Animation', 'Dokumentation', 'Horror',
];
const _titles = [
  'Die Stunde der Wölfe', 'Nebelgrenze', 'Orbit 9', 'Familie Kowalski',
  'Das Erbe von Falkenstein', 'Codename: Polarstern', 'Die Glasstadt',
  'Ein Hund namens Keks', 'Mitternachtsexpress', 'Wie Sand im Wind',
  'Hochzeit mit Hindernissen', 'Signal aus der Tiefe', 'Funkel', 'Fünf Tage im Mai',
  'Feuerlinie', 'Opa auf Abwegen', 'Kalter Hafen', 'Die letzte Fähre',
];
const _actors = [
  'Lena Hartmann', 'Jonas Berger', 'Mira Okafor', 'Anna Wolff', 'David Kern',
  'Selin Aydın', 'Paul Brandt', 'Elif Demir',
];

final _movies = [
  for (var i = 0; i < 36; i++)
    VodItem(
      id: 'm$i',
      name: _titles[i % _titles.length] + (i >= _titles.length ? ' II' : ''),
      categoryId: 'all',
      streamUrl: 'http://m/$i',
      genre: _genres[i % _genres.length],
      year: 1979 + (i * 17) % 47,
      rating: 5.8 + (i * 7 % 30) / 10,
      added: DateTime(2026, 10, 20).subtract(Duration(days: i)),
      cast: '${_actors[i % 8]}, ${_actors[(i + 3) % 8]}',
      director: i % 4 == 0 ? 'Tobias Rehm' : 'Sabine Lorenz',
    ),
];

Episode _ep(int s, int n) => Episode(
    id: 'k${s}_$n',
    season: s,
    number: n,
    title: const ['Ankunft', 'Der Fremde', 'Alte Rechnungen', 'Funkstille',
        'Unter Wasser', 'Das Versprechen', 'Gegenwind', 'Die Wahrheit'][(n + s) % 8],
    streamUrl: 'http://s/$s/$n',
    plot: 'Neue Spuren führen in eine unerwartete Richtung – und nicht jeder '
        'ist, wer er zu sein scheint.',
    duration: Duration(minutes: 42 + n));

const _series = VodItem(
  id: 'k',
  name: 'Kaltes Land',
  categoryId: 'drama',
  streamUrl: '',
  isSeries: true,
  genre: 'Drama, Krimi',
  year: 2024,
  rating: 8.4,
  trailer: 'aqz-KE-bpKQ',
  added: null,
  plot: 'Eine Familie, ein Geheimnis und ein Sommer, der alte Wunden wieder '
      'aufreißt. Leise erzählt, mit großer Wucht.',
);

final _details = SeriesDetails(
  series: _series,
  cast: 'Anna Wolff, David Kern, Selin Aydın',
  seasons: {
    for (var s = 1; s <= 3; s++) s: [for (var n = 1; n <= 8; n++) _ep(s, n)],
  },
);

const _cats = [
  Category(id: 'de', name: 'DE | Vollprogramm'),
  Category(id: 'sp', name: 'DE | Sport'),
  Category(id: 'tr', name: 'TR | Spor'),
];

final _channels = [
  for (final (i, n, c) in [
    (0, 'Das Erste HD', 'de'), (1, 'ZDF HD', 'de'), (2, 'Sky Sport 1 HD', 'sp'),
    (3, 'DAZN 1 FHD', 'sp'), (4, 'TR: beIN Sports 1', 'tr'),
    (5, 'Eurosport 1 HD', 'sp'), (6, 'n-tv', 'de'),
  ])
    Channel(id: 'c$i', name: n, categoryId: c, streamUrl: 'http://s/$i',
        number: i + 1),
];

Map<String, List<EpgEntry>> _epg(DateTime now) {
  EpgEntry e(int ch, String t, int startMin) => EpgEntry(
      channelEpgId: '@c$ch',
      title: t,
      start: now.add(Duration(minutes: startMin)),
      end: now.add(Duration(minutes: startMin + 110)));
  return {
    '@c0': [e(0, 'Sportschau – Bundesliga am Samstag', -35)],
    '@c1': [e(1, 'Transport-Giganten', -20)],
    '@c2': [e(2, 'Bundesliga: Bayern München – Borussia Dortmund', -50)],
    '@c3': [e(3, 'UEFA Champions League: Real Madrid – Inter', -10)],
    '@c4': [e(4, 'Süper Lig: Galatasaray – Fenerbahçe', -70)],
    '@c5': [e(5, 'Tennis: ATP Finals, Halbfinale', -25)],
    '@c6': [e(6, 'Nachrichten', -5)],
  };
}

late Storage _st;

C14Data _data() => C14Data(
      live: LiveData(_cats, _channels),
      epg: _epg(DateTime.now()),
      movies: VodData(const [Category(id: 'all', name: 'Alle')], _movies),
      series: const VodData([Category(id: 'drama', name: 'Drama')], [_series]),
      details: {'k': _details},
      library: VodLibrary(const {}, [
        VodHistoryEntry(true, 'k', DateTime(2026),
            episodeId: 'k2_2', season: 2, episode: 2),
        VodHistoryEntry(false, 'm3', DateTime(2026)), // Drama, Krimi
      ]),
    );

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    L10n.lang = 'de';
    await initializeDateFormatting('de');
    await loadAppFonts();
    if (_shotDir != null) Directory(_shotDir!).createSync(recursive: true);
  });

  setUp(() async {
    L10n.lang = 'de';
    SharedPreferences.setMockInitialValues({'set_applang': 'de'});
    _st = await Storage.open(store: PreviewSecretStore());
    for (var n = 1; n <= 8; n++) {
      await _st.setWatched('ep_k1_$n');
    }
    await _st.setWatched('ep_k2_1');
    await _st.setResume('ep_k2_2', 1260, 2640);
    await _st.setWatched('movie_m1');
  });

  tearDown(() => AppColors.setAccent(AppColors.defaultAccent));

  final skip = _shotDir == null;

  /// Akzentfarbe wie in der App setzen (Einstellung + Theme).
  Future<void> accent(String key) async {
    await _st.setOption(accentOptionKey, key);
    AppColors.setAccent(key);
  }

  testWidgets('Startseite mit neuen Reihen', skip: skip, (tester) async {
    await pumpC14(tester, Scaffold(body: HomeScreen(onOpenTab: (_) {})),
        _data(), Future.value(_st));
    expect(find.byKey(const ValueKey('home-sport')), findsOneWidget);
    await _shot(tester, 'v14_home_top');
    // Nach unten zu den neuen Reihen.
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -260));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('home-recs')), findsOneWidget);
    await _shot(tester, 'v14_home_rows');
    await c14Done(tester);
  });

  testWidgets('Filme stöbern', skip: skip, (tester) async {
    await pumpC14(tester, const VodBrowseScreen(series: false), _data(),
        Future.value(_st));
    await focusKey(tester, const ValueKey('genre-drama'));
    await c14Key(tester, LogicalKeyboardKey.select);
    await focusKey(tester, const ValueKey('decade-2000'));
    await c14Key(tester, LogicalKeyboardKey.select);
    await _shot(tester, 'v14_vod_browse');
    await c14Done(tester);
  });

  testWidgets('Serie mit Staffel-Reitern', skip: skip, (tester) async {
    await pumpC14(tester, const SeriesDetailScreen(series: _series), _data(),
        Future.value(_st));
    expect(find.text('Weiterschauen S2 · F2'), findsOneWidget);
    await _shot(tester, 'v14_series_detail');
    await focusKey(tester, const ValueKey('season-tab-2'));
    await c14Key(tester, LogicalKeyboardKey.arrowDown);
    await _shot(tester, 'v14_series_season_tabs');
    await c14Done(tester);
  });

  testWidgets('Nächste Folge in 10 s', skip: skip, (tester) async {
    final pos = StreamController<Duration>.broadcast();
    final len = StreamController<Duration>.broadcast();
    final next = PlayRequest(
      title: 'Kaltes Land',
      url: 'http://s/2/3',
      resumeKey: 'ep_k2_2',
      nextUp: () async => const NextUp(
          label: 'S2 · F3 – Funkstille',
          request: PlayRequest(title: 'Kaltes Land', url: 'http://s/2/3')),
    );
    await pumpC14(
        tester,
        Scaffold(
          backgroundColor: Colors.black,
          body: Stack(fit: StackFit.expand, children: [
            const NetworkArt(url: null, seed: 'Kaltes Land S2 F2'),
            const DecoratedBox(
                decoration: BoxDecoration(color: Color(0x66000000))),
            NextEpisodeHost(
              request: next,
              position: pos.stream,
              duration: len.stream,
              onPlay: (_) {},
              onExit: () {},
            ),
          ]),
        ),
        _data(),
        Future.value(_st));
    len.add(const Duration(minutes: 44));
    await tester.pump();
    pos.add(const Duration(minutes: 43, seconds: 40));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('Nächste Folge in 7 s'), findsOneWidget);
    await _shot(tester, 'v14_next_episode');
    await c14Done(tester);
  });

  testWidgets('Personensuche', skip: skip, (tester) async {
    await pumpC14(tester, const Scaffold(body: SearchScreen()), _data(),
        Future.value(_st));
    ProviderScope.containerOf(tester.element(find.byType(SearchScreen)))
        .read(searchRequestProvider.notifier)
        .request('lena');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Personen'), findsOneWidget);
    await focusKey(tester, const ValueKey('person-Lena Hartmann'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(focusUnderKey(const ValueKey('person-Lena Hartmann')), isTrue);
    await _shot(tester, 'v14_person_search');
    await c14Key(tester, LogicalKeyboardKey.select);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(PersonScreen), findsOneWidget);
    await _shot(tester, 'v14_person_titles');
    await c14Done(tester);
  });

  testWidgets('Darstellung: Akzentfarbe Blau', skip: skip, (tester) async {
    await accent('blau');
    await pumpC14(tester, const Scaffold(body: SettingsScreen()), _data(),
        Future.value(_st));
    // Zum Abschnitt „Darstellung“ (Fokus auf das gewählte Farbfeld).
    final swatch = find.byKey(const ValueKey('accent_blau'));
    await tester.ensureVisible(swatch);
    await tester.pump(const Duration(milliseconds: 200));
    Focus.of(tester.element(find.descendant(
            of: swatch, matching: find.byIcon(Icons.check_rounded))))
        .requestFocus();
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }
    expect(focusUnderKey(const ValueKey('accent_blau')), isTrue);
    expect(find.text('DARSTELLUNG'), findsOneWidget);
    await _shot(tester, 'v14_settings_accent_blau');
    await c14Done(tester);
  });

  testWidgets('Startseite in Blau', skip: skip, (tester) async {
    await accent('blau');
    await pumpC14(tester, Scaffold(body: HomeScreen(onOpenTab: (_) {})),
        _data(), Future.value(_st));
    await _shot(tester, 'v14_home_blau');
    await c14Done(tester);
  });

  testWidgets('Erster Start: Schriftgröße wählen', skip: skip, (tester) async {
    await pumpC14(tester, const TextSizeChooser(), _data(), Future.value(_st));
    await c14Key(tester, LogicalKeyboardKey.arrowRight); // „Groß“
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Wie groß soll die Schrift sein?'), findsOneWidget);
    await _shot(tester, 'v14_text_size_chooser');
    await c14Done(tester);
  });
}
