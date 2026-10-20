import 'dart:math';

import '../core/platform_info.dart';
import '../models/models.dart';
import 'repository.dart';

/// Demo-Quelle mit erfundenen Sendern, Programmen, Filmen und Serien.
/// Damit lässt sich die App ohne eigenes Portal ausprobieren.
/// Alle Namen sind frei erfunden.
class DemoRepository extends IptvRepository {
  @override
  final Portal portal;
  DemoRepository(this.portal);

  /// Öffentlicher Test-Stream (Open-Source-Film, CC-BY).
  static String get testStream => PlatformInfo.launchParams['localvideo'] == '1'
      ? Uri.base.resolve('preview.webm').toString() // nur Web-Vorschau
      : 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8';

  static final _cats = [
    const Category(id: 'de', name: 'Deutschland'),
    const Category(id: 'sport', name: 'Sport'),
    const Category(id: 'film', name: 'Filme & Serien'),
    const Category(id: 'doku', name: 'Dokumentation'),
    const Category(id: 'news', name: 'Nachrichten'),
    const Category(id: 'kids', name: 'Kinder'),
    const Category(id: 'music', name: 'Musik'),
  ];

  static const _channelDefs = <(String, String, int)>[
    ('Nordlicht 1 HD', 'de', 7),
    ('Kanal Mitte HD', 'de', 7),
    ('Rheinwelle FHD', 'de', 7),
    ('Alpenblick TV', 'de', 3),
    ('Hafenstadt HD', 'de', 7),
    ('Ostsee Eins', 'de', 0),
    ('Arena Sport 1 HD', 'sport', 3),
    ('Arena Sport 2 HD', 'sport', 3),
    ('Torjäger TV FHD', 'sport', 1),
    ('Motorhaus 4K', 'sport', 0),
    ('Matchball HD', 'sport', 2),
    ('Kino Prime HD', 'film', 7),
    ('Serienwerk HD', 'film', 7),
    ('Nachtkino', 'film', 0),
    ('Thrill+ FHD', 'film', 3),
    ('Komödienhaus', 'film', 2),
    ('Planet Wild HD', 'doku', 7),
    ('Zeitreise TV', 'doku', 3),
    ('Tiefsee Doku', 'doku', 0),
    ('Wissen Plus HD', 'doku', 7),
    ('Info 24 HD', 'news', 7),
    ('Wirtschaft Live', 'news', 1),
    ('Weltblick News', 'news', 7),
    ('Kinderinsel', 'kids', 3),
    ('Toonbox HD', 'kids', 0),
    ('Lernzwerge', 'kids', 0),
    ('Beat FM TV', 'music', 0),
    ('Schlagerwelle', 'music', 1),
    ('Club Visions HD', 'music', 0),
  ];

  static const _titles = <String, List<String>>{
    'de': [
      'Guten Morgen Nord', 'Küstenwache', 'Die Rätselshow', 'Tagesbild',
      'Wetter & Meer', 'Hof der Familie Brandt', 'Quiz um Zwölf',
      'Abendschau', 'Der Landarzt von Lüttdorf', 'Tatort Hafenkante',
      'Spätgespräch', 'Unsere Heimat', 'Kochen mit Klaus', 'Talk am Kamin',
    ],
    'sport': [
      'Liga Live: Konferenz', 'Sport am Abend', 'Tennis: Halbfinale',
      'Motorsport Magazin', 'Fußball: Highlights', 'Basketball live',
      'Die Analyse', 'Golf: Finalrunde', 'Handball: Topspiel',
      'Boxen: Titelkampf', 'Radsport: Etappe 14',
    ],
    'film': [
      'Der letzte Sommer', 'Schatten über Brennberg', 'Nachtzug nach Riga',
      'Der Leuchtturmwärter', 'Kalter Atem', 'Das Haus am See',
      'Zwischen den Zeilen', 'Grenzgänger', 'Die Akte Lorenz',
      'Herzklopfen in Hamburg', 'Funkstille', 'Stille Wasser',
    ],
    'doku': [
      'Wilde Wälder Europas', 'Geheimnisse der Tiefsee', 'Das Römische Reich',
      'Planet der Insekten', 'Mega-Bauwerke', 'Die Arktis im Wandel',
      'Leben in der Savanne', 'Kosmos – Reise zu den Sternen',
      'Vulkane: Feuer der Erde', 'Die Seidenstraße',
    ],
    'news': [
      'Nachrichten', 'Wirtschaft kompakt', 'Weltjournal', 'Börse am Mittag',
      'Brennpunkt', 'Das Interview', 'Nachrichten am Abend', 'Wetter',
    ],
    'kids': [
      'Fuchs & Freunde', 'Die Weltraumkatze', 'Bastelzeit', 'Ritter Rudi',
      'Das Wissensboot', 'Pixel Piraten', 'Gute-Nacht-Geschichte',
    ],
    'music': [
      'Top 40 Countdown', 'Club Session', 'Schlager-Hits', 'Live im Studio',
      'Nachtmix', '90er Classics', 'Unplugged',
    ],
  };

  static const _genres = <String, String>{
    'de': 'Unterhaltung',
    'sport': 'Sport',
    'film': 'Spielfilm',
    'doku': 'Dokumentation',
    'news': 'Nachrichten',
    'kids': 'Kinder',
    'music': 'Musik',
  };

  late final List<Channel> _channels = [
    for (var i = 0; i < _channelDefs.length; i++)
      Channel(
        id: 'demo_$i',
        name: _channelDefs[i].$1,
        categoryId: _channelDefs[i].$2,
        catchupDays: _channelDefs[i].$3,
        number: i + 1,
        epgId: 'demo_$i',
        streamUrl: testStream,
      ),
  ];

  @override
  bool get supportsVod => true;

  @override
  Future<AccountInfo?> login() async => AccountInfo(
        status: 'Active',
        expires: DateTime.now().add(const Duration(days: 214)),
        maxConnections: 2,
        activeConnections: 1,
      );

  @override
  Future<List<Category>> liveCategories() async => _cats;

  @override
  Future<List<Channel>> liveChannels() async => _channels;

  @override
  Future<Map<String, List<EpgEntry>>> loadEpg(
      {Set<String>? channelIds, List<Channel>? channels, EpgProgress? progress}) async {
    final now = DateTime.now();
    final anchor = DateTime(now.year, now.month, now.day, now.hour)
        .subtract(const Duration(hours: 26));
    final result = <String, List<EpgEntry>>{};
    for (final c in _channels) {
      final rnd = Random(c.id.hashCode);
      final titles = _titles[c.categoryId]!;
      var t = anchor.add(Duration(minutes: rnd.nextInt(4) * 15));
      final list = <EpgEntry>[];
      final end = now.add(const Duration(hours: 30));
      while (t.isBefore(end)) {
        final len = switch (c.categoryId) {
          'news' => [15, 30, 30, 45][rnd.nextInt(4)],
          'film' => [90, 105, 120, 45][rnd.nextInt(4)],
          'kids' => [25, 30, 30][rnd.nextInt(3)],
          _ => [30, 45, 60, 60, 90][rnd.nextInt(5)],
        };
        final title = titles[rnd.nextInt(titles.length)];
        list.add(EpgEntry(
          channelEpgId: c.epgId!,
          title: title,
          genre: _genres[c.categoryId],
          description: _describe(title, c.categoryId),
          start: t,
          end: t.add(Duration(minutes: len)),
        ));
        t = t.add(Duration(minutes: len));
      }
      result[c.epgId!] = list;
    }
    return result;
  }

  static String _describe(String title, String cat) => switch (cat) {
        'sport' =>
          'Live-Übertragung mit Vorberichten, Analysen und allen Höhepunkten. Moderation aus dem Studio, Kommentar vom Spielfeldrand.',
        'film' =>
          '„$title“ – ein Drama über Schuld, Vertrauen und einen Sommer, der alles verändert. Mit viel Atmosphäre und starken Darstellern.',
        'doku' =>
          'Eine Reise mit spektakulären Aufnahmen und Experten, die erklären, wie unsere Welt funktioniert.',
        'news' => 'Aktuelle Meldungen aus Deutschland und der Welt, mit Wetter.',
        'kids' => 'Spannende Abenteuer und Geschichten für Kinder ab 4 Jahren.',
        'music' => 'Die besten Songs und Live-Auftritte, präsentiert von unseren Moderatoren.',
        _ => 'Unterhaltung für die ganze Familie.',
      };

  @override
  String? catchupUrl(Channel c, EpgEntry e) =>
      c.catchupDays > 0 ? testStream : null;

  // ------------------------------------------------------------ Filme

  static final _movieCats = [
    const Category(id: 'new', name: 'Neu hinzugefügt'),
    const Category(id: 'action', name: 'Action'),
    const Category(id: 'drama', name: 'Drama'),
    const Category(id: 'comedy', name: 'Komödie'),
    const Category(id: 'scifi', name: 'Sci-Fi'),
    const Category(id: 'family', name: 'Familie'),
  ];

  static const _movieDefs = <(String, String, int, double, int)>[
    ('Die Stunde der Wölfe', 'action', 2025, 7.4, 118),
    ('Nebelgrenze', 'drama', 2024, 7.9, 104),
    ('Orbit 9', 'scifi', 2026, 8.1, 131),
    ('Familie Kowalski im Urlaub', 'comedy', 2025, 6.8, 96),
    ('Das Erbe von Falkenstein', 'drama', 2023, 7.2, 112),
    ('Codename: Polarstern', 'action', 2026, 7.0, 109),
    ('Die Glasstadt', 'scifi', 2024, 7.6, 124),
    ('Ein Hund namens Keks', 'family', 2025, 7.1, 88),
    ('Mitternachtsexpress', 'action', 2024, 6.9, 101),
    ('Wie Sand im Wind', 'drama', 2026, 8.3, 127),
    ('Hochzeit mit Hindernissen', 'comedy', 2024, 6.5, 93),
    ('Signal aus der Tiefe', 'scifi', 2025, 7.3, 115),
    ('Der kleine Drache Funkel', 'family', 2026, 7.8, 82),
    ('Fünf Tage im Mai', 'drama', 2025, 7.5, 99),
    ('Feuerlinie', 'action', 2025, 6.7, 106),
    ('Opa auf Abwegen', 'comedy', 2026, 7.0, 91),
  ];

  static const _seriesDefs = <(String, String, int, double, int)>[
    ('Kaltes Land', 'drama', 2024, 8.4, 3),
    ('Station Hyperion', 'scifi', 2025, 8.0, 2),
    ('Die Brandts', 'drama', 2023, 7.6, 4),
    ('WG Chaos', 'comedy', 2025, 7.2, 2),
    ('Spur 17', 'action', 2026, 7.9, 1),
    ('Die Zeitdetektive', 'family', 2024, 7.4, 3),
    ('Hafenkrimi', 'action', 2025, 7.1, 5),
    ('Neuland', 'scifi', 2026, 8.2, 1),
  ];

  static const _plots = <String, String>{
    'action':
        'Als ein Routineeinsatz aus dem Ruder läuft, bleibt nur eine Nacht, um die Wahrheit ans Licht zu bringen – und die eigenen Leute zu schützen.',
    'drama':
        'Eine Familie, ein Geheimnis und ein Sommer, der alte Wunden wieder aufreißt. Leise erzählt, mit großer Wucht.',
    'comedy':
        'Was als perfekt geplanter Ausflug beginnt, wird zur Kette herrlicher Katastrophen – mit viel Herz und noch mehr Chaos.',
    'scifi':
        'Ein Signal aus den Tiefen des Alls stellt alles in Frage, was die Menschheit über sich zu wissen glaubte.',
    'family':
        'Ein Abenteuer voller Mut, Freundschaft und Fantasie – für Groß und Klein.',
  };

  static const _genreNames = <String, String>{
    'action': 'Action · Thriller',
    'drama': 'Drama',
    'comedy': 'Komödie',
    'scifi': 'Science-Fiction',
    'family': 'Familie · Animation',
  };

  @override
  Future<List<Category>> movieCategories() async => _movieCats;

  @override
  Future<List<VodItem>> movies() async => [
        for (var i = 0; i < _movieDefs.length; i++)
          VodItem(
            id: 'm$i',
            name: _movieDefs[i].$1,
            categoryId: _movieDefs[i].$2,
            year: _movieDefs[i].$3,
            rating: _movieDefs[i].$4,
            duration: Duration(minutes: _movieDefs[i].$5),
            genre: _genreNames[_movieDefs[i].$2],
            plot: _plots[_movieDefs[i].$2],
            cast: 'Lena Hartmann, Jonas Berger, Mira Okafor',
            director: 'Tobias Rehm',
            added: DateTime.now().subtract(Duration(days: i * 3)),
            streamUrl: testStream,
          ),
      ];

  @override
  Future<List<Category>> seriesCategories() async =>
      _movieCats.where((c) => c.id != 'new').toList();

  @override
  Future<List<VodItem>> series() async => [
        for (var i = 0; i < _seriesDefs.length; i++)
          VodItem(
            id: 's$i',
            name: _seriesDefs[i].$1,
            categoryId: _seriesDefs[i].$2,
            year: _seriesDefs[i].$3,
            rating: _seriesDefs[i].$4,
            genre: _genreNames[_seriesDefs[i].$2],
            plot: _plots[_seriesDefs[i].$2],
            streamUrl: '',
            isSeries: true,
          ),
      ];

  static const _episodeTitles = [
    'Ankunft', 'Der Fremde', 'Alte Rechnungen', 'Funkstille', 'Unter Wasser',
    'Das Versprechen', 'Gegenwind', 'Die Wahrheit', 'Spuren im Schnee',
    'Der Bruch', 'Rückkehr', 'Finale',
  ];

  @override
  Future<SeriesDetails> seriesDetails(VodItem s) async {
    await Future<void>.delayed(const Duration(milliseconds: 120));
    final idx = int.tryParse(s.id.substring(1)) ?? 0;
    final seasons = _seriesDefs[idx % _seriesDefs.length].$5;
    final rnd = Random(s.id.hashCode);
    return SeriesDetails(series: s, cast: 'Anna Wolff, David Kern, Selin Aydın', seasons: {
      for (var season = 1; season <= seasons; season++)
        season: [
          for (var e = 1; e <= 8; e++)
            Episode(
              id: '${s.id}_${season}_$e',
              season: season,
              number: e,
              title: _episodeTitles[(e + season * 3) % _episodeTitles.length],
              duration: Duration(minutes: 42 + rnd.nextInt(16)),
              plot:
                  'Folge $e: Neue Spuren führen in eine unerwartete Richtung – und nicht jeder ist, wer er zu sein scheint.',
              streamUrl: testStream,
            ),
        ],
    });
  }
}
