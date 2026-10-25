import 'package:flutter_test/flutter_test.dart';
import 'package:jason_stream_player/data/vod_groups.dart';
import 'package:jason_stream_player/models/models.dart';

VodItem _m(String id, String name,
        {String cat = 'c', String? genre, int? year}) =>
    VodItem(
        id: id,
        name: name,
        categoryId: cat,
        streamUrl: 'http://s/$id',
        genre: genre,
        year: year);

void main() {
  group('Sprache erkennen', () {
    const cases = <String, String?>{
      // Kategorien (übliche Anbieter-Schreibweisen)
      'DE | Action': 'DE',
      'DE|Action': 'DE',
      'DE · Komödie': 'DE',
      'DE - Drama': 'DE',
      'DE: Thriller': 'DE',
      'GER | Kinofilme 2024': 'DE',
      'GERMAN • Neu': 'DE',
      'Deutsch | Animation': 'DE',
      '[DE] Filme': 'DE',
      '(DE) Filme': 'DE',
      '|DE| Dokus': 'DE',
      'VOD | DE | Horror': 'DE',
      '4K | DE | Kino': 'DE',
      'Action | DE': 'DE',
      '🇩🇪 Kinofilme': 'DE',
      '🇦🇹 Austria Filme': 'DE',
      'EN: Thriller': 'EN',
      'EN | Netflix': 'EN',
      'UK | Comedy': 'EN',
      'US • Blockbuster': 'EN',
      'ENGLISH - Kids': 'EN',
      '[EN] Drama': 'EN',
      // Türkisch
      'TR • Yerli Filmler': 'TR',
      'TR | Aksiyon': 'TR',
      'TR: Komedi': 'TR',
      'TR - Dram': 'TR',
      'TÜRK | Sinema': 'TR',
      'TÜRKÇE • Dublaj': 'TR',
      'Türkçe | Altyazılı': 'TR',
      'TURKISH | Classics': 'TR',
      'YERLİ | Komedi': 'TR',
      'DİZİ | TR | Netflix': 'TR',
      '🇹🇷 Yeni Filmler': 'TR',
      '[TR] Belgesel': 'TR',
      // weitere Sprachen
      'FR | Comédie': 'FR',
      'IT | Azione': 'IT',
      'ES | Acción': 'ES',
      'NL | Familie': 'NL',
      'PL • Komedia': 'PL',
      'RU | Боевик': 'RU',
      'AR | أفلام': 'AR',
      'ARABIC | Films': 'AR',
      'KU | Fîlm': 'KU',
      'KURDÎ • Film': 'KU',
      'AL | Filma': 'AL',
      'ALB · Shqip': 'AL',
      'EX-YU | Filmovi': 'EXYU',
      'EXYU: Domaci': 'EXYU',
      'PT | Ação': 'PT',
      'GR | Ταινίες': 'GR',
      // nicht erkannt
      'Action': null,
      'Neu im Kino': null,
      'Kinder & Familie': null,
      'Marvel | Avengers': null,
      'HD | Action': null,
      '': null,
    };
    for (final e in cases.entries) {
      test('Kategorie „${e.key}“ → ${e.value}', () {
        expect(detectLanguage(e.key), e.value);
      });
    }

    test('Filmtitel: strenger (Wörter wie „It“, „Es“, „Us“)', () {
      expect(detectLanguage('It: Kapitel 2', title: true), isNull);
      expect(detectLanguage('IT: Chapter Two', title: true), isNull);
      expect(detectLanguage('Es - Teil 1', title: true), isNull);
      expect(detectLanguage('Us (2019)', title: true), isNull);
      expect(detectLanguage('Up', title: true), isNull);
      expect(detectLanguage('Spider-Man: No Way Home', title: true), isNull);
      expect(detectLanguage('X-Men', title: true), isNull);
      expect(detectLanguage('Der Pate (1972)', title: true), isNull);
      expect(detectLanguage('IT | La vita è bella', title: true), 'IT');
      expect(detectLanguage('DE: Das Boot', title: true), 'DE');
      expect(detectLanguage('EN: Heat', title: true), 'EN');
      expect(detectLanguage('TR • Babam ve Oğlum', title: true), 'TR');
      expect(detectLanguage('Kış Uykusu [TR]', title: true), 'TR');
      expect(detectLanguage('Matrix (EN)', title: true), 'EN');
      expect(detectLanguage('Avatar (HD)', title: true), isNull);
    });
  });

  group('Jahr aus dem Titel', () {
    final now = DateTime(2026, 10, 1);
    test('Klammern, Ende, Zukunft', () {
      expect(yearFromTitle('Heat (1995)', now: now), 1995);
      expect(yearFromTitle('Dune [2021]', now: now), 2021);
      expect(yearFromTitle('Oppenheimer - 2023', now: now), 2023);
      expect(yearFromTitle('Kış Uykusu 2014', now: now), 2014);
      expect(yearFromTitle('Blade Runner 2049', now: now), isNull);
      expect(yearFromTitle('Ocean\'s Eleven', now: now), isNull);
      expect(yearFromTitle('Top Gun (2026)', now: now), 2026);
      expect(yearFromTitle('Abc (1850)', now: now), isNull);
    });
  });

  group('Gruppen', () {
    final cats = [
      const Category(id: 'de', name: 'DE | Action'),
      const Category(id: 'tr', name: 'TR • Yerli Filmler'),
      const Category(id: 'mix', name: 'Neu im Kino'),
      const Category(id: 'empty', name: 'EN | Leer'),
    ];
    final items = [
      _m('1', 'Alarm', cat: 'de', genre: 'Action, Thriller', year: 2019),
      _m('2', 'Babam ve Oğlum', cat: 'tr', genre: 'Dram', year: 2005),
      _m('3', 'Heat (1995)', cat: 'mix', genre: 'Krimi / Thriller'),
      _m('4', 'EN: The Thing', cat: 'mix', genre: 'Horror', year: 1982),
      _m('5', 'Metropolis', cat: 'mix', year: 1927),
      _m('6', 'Ohne alles', cat: 'mix'),
      _m('7', 'Kış Uykusu [TR]', cat: 'mix', genre: 'Drama', year: 2014),
      _m('8', 'Nachzügler', cat: 'gone', genre: 'action'),
    ];
    final g = VodGroups.build(items, cats);

    List<String> keys(VodGroupMode m) => [for (final x in g.of(m)) x.key];
    int count(VodGroupMode m, String k) => g.find(m, k)!.count;

    test('Kategorie: Anbieter-Reihenfolge, leere ausgelassen', () {
      expect(keys(VodGroupMode.category), ['de', 'tr', 'mix']);
      expect(count(VodGroupMode.category, 'mix'), 5);
    });

    test('Genre: Aliasse zusammengeführt, „Ohne Genre“ zuletzt', () {
      final gs = g.of(VodGroupMode.genre);
      expect(g.hasGenres, isTrue);
      expect(g.find(VodGroupMode.genre, 'drama')!.count, 2); // Dram + Drama
      expect(g.find(VodGroupMode.genre, 'action')!.count, 2);
      expect(g.find(VodGroupMode.genre, 'thriller')!.count, 2);
      expect(g.find(VodGroupMode.genre, 'crime')!.count, 1); // Krimi
      expect(gs.last.key, VodGroupKey.none);
      expect(g.itemsOf(gs.last).map((m) => m.id), ['5', '6']);
    });

    test('Jahr: Feld vor Titel, vor 1980 zusammengefasst', () {
      expect(keys(VodGroupMode.year),
          ['2019', '2014', '2005', '1995', '1982', VodGroupKey.before,
           VodGroupKey.none]);
      expect(g.itemsOf(g.find(VodGroupMode.year, VodGroupKey.before)!)
          .map((m) => m.id), ['5']);
      expect(count(VodGroupMode.year, VodGroupKey.none), 2);
    });

    test('Sprache: Kategorie vor Titel, Rest „Ohne Sprache“', () {
      expect(count(VodGroupMode.language, 'DE'), 1);
      expect(count(VodGroupMode.language, 'TR'), 2); // Kategorie + [TR]
      expect(count(VodGroupMode.language, 'EN'), 1); // EN: im Titel
      expect(keys(VodGroupMode.language).last, VodGroupKey.none);
      expect(count(VodGroupMode.language, VodGroupKey.none), 4);
    });

    test('ohne Genres: keine Genre-Gruppen', () {
      final g2 = VodGroups.build([_m('a', 'A'), _m('b', 'B')], const []);
      expect(g2.hasGenres, isFalse);
      expect(g2.of(VodGroupMode.genre), isEmpty);
      expect(g2.of(VodGroupMode.year), isEmpty);
      expect(g2.of(VodGroupMode.language).single.key, VodGroupKey.none);
    });

    test('Isolate liefert dasselbe wie sofort', () async {
      final many = [
        for (var i = 0; i < 2500; i++)
          _m('$i', i.isEven ? 'DE | Film $i' : 'Film $i (${1970 + i % 50})',
              cat: i % 3 == 0 ? 'tr' : 'mix',
              genre: ['Action', 'Drama', null][i % 3]),
      ];
      final a = VodGroups.build(many, cats);
      final b = await VodGroups.buildAsync(many, cats);
      expect(identical(b.items, many), isTrue);
      for (final m in VodGroupMode.values) {
        expect(b.of(m).map((x) => '${x.key}:${x.count}'),
            a.of(m).map((x) => '${x.key}:${x.count}'));
      }
    });
  });
}
