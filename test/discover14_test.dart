import 'package:flutter_test/flutter_test.dart';
import 'package:jason_stream_player/data/sport_detect.dart';
import 'package:jason_stream_player/data/vod_meta.dart';
import 'package:jason_stream_player/l10n/strings.dart';
import 'package:jason_stream_player/models/models.dart';
import 'package:jason_stream_player/state/discover.dart';
import 'package:jason_stream_player/ui/search/search_engine.dart';
import 'package:jason_stream_player/ui/vod/vod_browse_screen.dart'
    show decadeLabel;

/// 1.4 Entdecken: Genres, Jahrzehnte, Neueste, Sport, Empfehlungen,
/// nächste Folge, Trailer-IDs, Personensuche.

VodItem _m(String id,
        {String? genre,
        int? year,
        double? rating,
        DateTime? added,
        String? cast,
        String? director,
        bool series = false}) =>
    VodItem(
      id: id,
      name: 'Titel $id',
      categoryId: 'c',
      streamUrl: 'http://x/$id',
      genre: genre,
      year: year,
      rating: rating,
      added: added,
      cast: cast,
      director: director,
      isSeries: series,
    );

Episode _e(int s, int n) => Episode(
    id: 's${s}e$n', season: s, number: n, title: 'F$n', streamUrl: 'u');

void main() {
  setUp(() => L10n.lang = 'de');

  group('Genres', () {
    test('zerlegen an , / | · & und normalisieren', () {
      expect(splitGenres('Action, Abenteuer / Sci-Fi | Drama'),
          ['Action', 'Abenteuer', 'Sci-Fi', 'Drama']);
      expect(splitGenres('Action · Thriller'), ['Action', 'Thriller']);
      expect(splitGenres('Action & Adventure'), ['Action', 'Adventure']);
      expect(splitGenres('  '), isEmpty);
      expect(splitGenres(null), isEmpty);
      // Doppelte (gleicher Schlüssel) nur einmal, Müll raus.
      expect(splitGenres('Drama, drama, N/A, 2019, -'), ['Drama']);
    });

    test('Schreibweisen und Sprachen ergeben denselben Schlüssel', () {
      expect(genreKey('Science-Fiction'), 'sciencefiction');
      expect(genreKey('Sci-Fi'), 'sciencefiction');
      expect(genreKey('Science Fiction'), 'sciencefiction');
      expect(genreKey('Komödie'), 'comedy');
      expect(genreKey('Komedi'), 'comedy');
      expect(genreKey('Comedy'), 'comedy');
      expect(genreKey('Krimi'), 'crime');
      expect(genreKey('Belgesel'), 'documentary');
    });

    test('Index zählt, sortiert und wählt die häufigste Schreibweise', () {
      final items = [
        _m('1', genre: 'Drama, Komödie'),
        _m('2', genre: 'Drama'),
        _m('3', genre: 'drama / Comedy'),
        _m('4', genre: 'Horror'),
        _m('5'),
      ];
      final idx = GenreIndex.build(items);
      expect(idx.counts.first.key, 'drama');
      expect(idx.counts.first.count, 3);
      expect(idx.counts.first.label, 'Drama');
      final comedy = idx.counts.firstWhere((g) => g.key == 'comedy');
      expect(comedy.count, 2);
      expect(idx.itemsOf('comedy').map((m) => m.id), ['1', '3']);
      expect(idx.top(2).length, 2);
      expect(idx.itemsOf('western'), isEmpty);
    });
  });

  group('Jahrzehnte', () {
    test('Jahrzehnt, Plausibilität, Zählung', () {
      expect(decadeOf(1994), 1990);
      expect(decadeOf(2020), 2020);
      expect(decadeOf(0), isNull);
      expect(decadeOf(20251), isNull);
      final items = [
        _m('a', year: 2021),
        _m('b', year: 2024),
        _m('c', year: 2015),
        _m('d', year: 1999),
        _m('e'),
      ];
      expect(decadesOf(items), [(2020, 2), (2010, 1), (1990, 1)]);
      expect(yearsIn(items, 2020), [(2024, 1), (2021, 1)]);
    });

    test('Beschriftung je Sprache', () {
      expect(decadeLabel(2010), '2010er');
      L10n.lang = 'tr';
      expect(decadeLabel(1990), "1990'lar");
      expect(decadeLabel(2020), "2020'ler");
      expect(decadeLabel(2000), "2000'ler");
      L10n.lang = 'de';
    });
  });

  group('Neueste zuerst', () {
    test('nach Zeitstempel, Gleichstand und fehlende nach Listenposition', () {
      final t = DateTime(2026, 1, 1);
      final items = [
        _m('alt', added: t),
        _m('ohne1'),
        _m('neu', added: t.add(const Duration(days: 3))),
        _m('mitte', added: t.add(const Duration(days: 1))),
        _m('ohne2'),
      ];
      expect(sortNewest(items).map((m) => m.id),
          ['neu', 'mitte', 'alt', 'ohne2', 'ohne1']);
    });

    test('ohne Zeitstempel: spätere Listeneinträge zuerst', () {
      final items = [for (var i = 0; i < 4; i++) _m('$i')];
      expect(sortNewest(items).map((m) => m.id), ['3', '2', '1', '0']);
    });

    test('weitere Sortierungen', () {
      final items = [
        _m('b', rating: 6, year: 2001),
        _m('a', rating: 9, year: 1990),
        _m('c', rating: 7, year: 2020),
      ];
      expect(sortVod(items, VodSort.rating).map((m) => m.id), ['a', 'c', 'b']);
      expect(sortVod(items, VodSort.year).map((m) => m.id), ['c', 'b', 'a']);
      expect(sortVod(items, VodSort.title).map((m) => m.id), ['a', 'b', 'c']);
      expect(identical(sortVod(items, VodSort.standard), items), isTrue);
    });
  });

  group('Sport', () {
    test('Sport-Titel und -Kategorien (de/en/tr)', () {
      for (final t in [
        'Sportschau',
        'Bundesliga: Bayern – Dortmund',
        'Fußball: DFB-Pokal',
        'UEFA Champions League',
        'Süper Lig: Galatasaray - Fenerbahçe',
        'Spor Haberleri',
        'Formel 1: Großer Preis von Monaco',
        'F1 Qualifying',
        'Tennis: Wimbledon',
        'NBA Basketball',
        'UFC Fight Night',
        'Boxen live',
        'Motorsport aktuell',
        'Premier League Highlights',
      ]) {
        expect(SportDetector.isSportText(t), isTrue, reason: t);
      }
    });

    test('keine Fehlalarme', () {
      for (final t in [
        'Transport-Giganten',
        'Passport to Paris',
        'Tagesschau',
        'Golf von Neapel – Reisebericht',
        'Die Liga der außergewöhnlichen Gentlemen',
        'Mac & Cheese Kochshow',
        'Sporen im Wald',
        'Tatort',
      ]) {
        expect(SportDetector.isSportText(t), isFalse, reason: t);
      }
    });

    test('Gruppen', () {
      expect(SportDetector.isSportGroup('DE | Sport'), isTrue);
      expect(SportDetector.isSportGroup('TR: Spor'), isTrue);
      expect(SportDetector.isSportGroup('UK: Sports HD'), isTrue);
      expect(SportDetector.isSportGroup('DE | Transport & Logistik'), isFalse);
      expect(SportDetector.isSportGroup('DE | Vollprogramm'), isFalse);
    });

    test('liveSport: Treffer im Titel vor Sport-Gruppe, nur laufende', () {
      final now = DateTime(2026, 10, 21, 20, 30);
      EpgEntry e(String ch, String title, {String? genre, int from = -30}) =>
          EpgEntry(
              channelEpgId: ch,
              title: title,
              genre: genre,
              start: now.add(Duration(minutes: from)),
              end: now.add(Duration(minutes: from + 90)));
      const cats = [
        Category(id: 'de', name: 'DE | Vollprogramm'),
        Category(id: 'sp', name: 'DE | Sport'),
      ];
      Channel c(String id, String cat) => Channel(
          id: id, name: 'Sender $id', categoryId: cat, streamUrl: 'u', epgId: id);
      final chans = [
        c('ard', 'de'), c('zdf', 'de'), c('sky', 'sp'), c('n24', 'de'),
        c('dsf', 'de'),
      ];
      final epg = {
        'ard': [e('ard', 'Sportschau')],
        'zdf': [e('zdf', 'Transport-Giganten')],
        'sky': [e('sky', 'Sky Sport News')],
        'n24': [e('n24', 'Doku', genre: 'Sports')],
        'dsf': [e('dsf', 'Fußball live', from: 30)], // erst später
      };
      final r = liveSport(
          categories: cats, channels: chans, epg: epg, now: now);
      expect(r.map((x) => x.channel.id), ['ard', 'sky', 'n24']);
      final hidden = liveSport(
          categories: cats,
          channels: chans,
          epg: epg,
          now: now,
          hidden: (ch) => ch.id == 'ard');
      expect(hidden.map((x) => x.channel.id), ['sky', 'n24']);
    });
  });

  group('Empfehlungen', () {
    final watchedDrama = _m('w1', genre: 'Drama, Krimi', rating: 7);
    final watchedComedy = _m('w2', genre: 'Komödie');
    final candidates = [
      watchedDrama,
      watchedComedy,
      _m('d1', genre: 'Drama', rating: 6.5),
      _m('d2', genre: 'Drama', rating: 8.9),
      _m('d3', genre: 'Drama', rating: 9.5),
      _m('s1', genre: 'Drama', rating: 7.7, series: true),
      _m('c1', genre: 'Comedy', rating: 9.9),
    ];

    test('häufigstes Genre der zuletzt gesehenen → ungesehene, beste zuerst',
        () {
      final r = recommend(
        recent: [watchedDrama, watchedComedy],
        candidates: candidates,
        seen: (m) => m.id == 'd3', // schon gesehen
      )!;
      expect(r.because.id, 'w1');
      expect(r.genreKey, 'drama');
      expect(r.items.map((m) => m.id), ['d2', 's1', 'd1']);
    });

    test('ohne Verlauf/Genres keine Empfehlung', () {
      expect(
          recommend(recent: const [], candidates: candidates, seen: (_) => false),
          isNull);
      expect(
          recommend(
              recent: [_m('x')], candidates: candidates, seen: (_) => false),
          isNull);
    });

    test('Kindermodus: nur aus den freigegebenen Kandidaten', () {
      final r = recommend(
        recent: [watchedComedy],
        candidates: [watchedComedy, _m('k1', genre: 'Komödie', rating: 5)],
        seen: (_) => false,
      )!;
      expect(r.items.map((m) => m.id), ['k1']);
    });

    test('Bestes Genre ohne Vorschläge → nächstes Genre', () {
      final r = recommend(
        recent: [_m('h', genre: 'Western, Comedy')],
        candidates: [_m('c9', genre: 'Komödie', rating: 3)],
        seen: (_) => false,
      )!;
      expect(r.genreKey, 'comedy');
    });
  });

  group('Nächste Folge', () {
    final seasons = {
      2: [_e(2, 1), _e(2, 2)],
      1: [_e(1, 1), _e(1, 2), _e(1, 3)],
    };

    test('innerhalb der Staffel und über das Staffelende', () {
      expect(nextEpisodeOf(seasons, _e(1, 1))!.id, 's1e2');
      expect(nextEpisodeOf(seasons, _e(1, 3))!.id, 's2e1');
      expect(nextEpisodeOf(seasons, _e(2, 2)), isNull);
      expect(nextEpisodeOf(seasons, _e(9, 9)), isNull);
    });

    test('Weiterschauen-Ziel', () {
      final watched = {'s1e1', 's1e2', 's1e3'};
      final r = resumeTarget(seasons,
          lastEpisodeId: 's1e3',
          progress: (_) => null,
          watched: (e) => watched.contains(e.id))!;
      expect(r.episode.id, 's2e1');
      expect(r.resume, isFalse);
      final r2 = resumeTarget(seasons,
          lastEpisodeId: 's1e2',
          progress: (e) => e.id == 's1e2' ? 0.4 : null,
          watched: (_) => false)!;
      expect(r2.episode.id, 's1e2');
      expect(r2.resume, isTrue);
      final r3 = resumeTarget(seasons,
          progress: (_) => null, watched: (e) => e.id == 's1e1')!;
      expect(r3.episode.id, 's1e2');
      expect(resumeTarget(const {}, progress: (_) => null, watched: (_) => false),
          isNull);
    });
  });

  group('Trailer', () {
    test('YouTube-IDs aus allen gängigen Formen', () {
      const id = 'aqz-KE-bpKQ';
      for (final s in [
        id,
        ' $id ',
        'https://www.youtube.com/watch?v=$id',
        'http://youtube.com/watch?feature=share&v=$id&t=10',
        'https://youtu.be/$id',
        'https://youtu.be/$id?si=abc',
        'https://www.youtube.com/embed/$id',
        'https://www.youtube-nocookie.com/embed/$id?rel=0',
        'https://m.youtube.com/shorts/$id',
        'vnd.youtube:$id',
      ]) {
        expect(youtubeId(s), id, reason: s);
      }
    });

    test('ungültig → null', () {
      for (final s in [
        null,
        '',
        'abc',
        'https://vimeo.com/123456789',
        'https://www.youtube.com/watch?v=short',
        'https://www.youtube.com/watch?v=aqz-KE-bpKQX', // 12 Zeichen
      ]) {
        expect(youtubeId(s), isNull, reason: '$s');
      }
    });
  });

  group('Personen', () {
    test('Namen zerlegen', () {
      expect(splitPeople('Tom Hanks, Robin Wright / Gary Sinise; Tom Hanks'),
          ['Tom Hanks', 'Robin Wright', 'Gary Sinise']);
      expect(splitPeople(', ,  '), isEmpty);
    });

    test('Suche findet Besetzung und Regie (Liste + Zwischenspeicher)', () {
      final movies = [
        _m('1', cast: 'Lena Hartmann, Jonas Berger', director: 'Tobias Rehm'),
        _m('2', cast: 'Lena Hartmann'),
        _m('3'), // Besetzung nur aus der Detailseite bekannt
      ];
      final series = [_m('s1', cast: 'Jonas Berger', series: true)];
      final engine = SearchEngine(
        channels: const [],
        epg: const {},
        movies: movies,
        series: series,
        people: {'m:3': (cast: 'Lena Hartmann', director: null)},
      );
      final r = engine.search('hartmann', DateTime(2026));
      expect(r.persons.map((p) => p.name), ['Lena Hartmann']);
      expect(r.persons.single.titles.map((m) => m.id), ['1', '2', '3']);
      final j = engine.search('jonas', DateTime(2026)).persons.single;
      expect(j.titles.map((m) => m.id), ['1', 's1']);
      final d = engine.search('rehm', DateTime(2026)).persons.single;
      expect(d.director, isTrue);
      expect(engine.titlesOf('lena hartmann').length, 3);
      // Unter 3 Zeichen keine Personen (zu viele Treffer).
      expect(engine.search('le', DateTime(2026)).persons, isEmpty);
    });

    test('100 000 Titel: Tippen bleibt schnell', () {
      const first = ['Anna', 'Jonas', 'Lena', 'Mehmet', 'Elif', 'Paul', 'Sofia'];
      const last = ['Berger', 'Yılmaz', 'Hartmann', 'Demir', 'Kern', 'Wolff'];
      final movies = [
        for (var i = 0; i < 100000; i++)
          _m('$i',
              genre: 'Drama',
              cast: '${first[i % 7]} ${last[i % 6]}$i, '
                  '${first[(i + 3) % 7]} ${last[(i + 1) % 6]}'),
      ];
      final engine = SearchEngine(
          channels: const [], epg: const {}, movies: movies, series: const []);
      engine.search('xx', DateTime(2026)); // Index aufbauen
      final sw = Stopwatch()..start();
      var n = 0;
      for (final q in ['ha', 'har', 'hart', 'hartm', 'hartma', 'hartman']) {
        engine.search(q, DateTime(2026));
        n++;
      }
      final perKey = sw.elapsedMilliseconds / n;
      // ignore: avoid_print
      print('Personensuche: ${perKey.toStringAsFixed(1)} ms je Taste');
      // Ziel im Release-Build < 50 ms; im Debug-Test großzügiger.
      expect(perKey, lessThan(250), reason: '$perKey ms je Taste');
    });
  });
}
