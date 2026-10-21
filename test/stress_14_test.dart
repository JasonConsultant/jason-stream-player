import 'package:flutter_test/flutter_test.dart';
import 'package:jason_stream_player/data/people_index.dart';
import 'package:jason_stream_player/data/vod_meta.dart';
import 'package:jason_stream_player/models/models.dart';
import 'package:jason_stream_player/state/discover.dart';
import 'package:jason_stream_player/ui/search/search_engine.dart';

import 'helpers/stress_data.dart';

/// 1.4 unter Last: 100 000 Filme / 20 000 Serien mit Genres, Besetzung,
/// Regie, Zeitstempeln. Grenzen gelten für Debug-Tests (JIT) – im
/// Release-Build ist alles deutlich schneller.

int _ms(Stopwatch s) => s.elapsedMilliseconds;

void _log(String s) {
  // ignore: avoid_print
  print(s);
}

void main() {
  late List<VodItem> movies, series;
  setUpAll(() {
    movies = stressVod(items: 100000, rich: true).items;
    series =
        stressVod(items: 20000, series: true, cats: 120, seed: 3, rich: true)
            .items;
  });

  test(
      'Reihe „Neu hinzugefügt“: ein Durchgang statt Sortieren, gleiches Ergebnis',
      () {
    final sw = Stopwatch()..start();
    final top = VodCatalog(movies).newestTop;
    final t = _ms(sw);
    _log('newestTop 100k: $t ms');
    expect(t, lessThan(60));
    expect(top.map((m) => m.id), sortNewest(movies).take(15).map((m) => m.id));
  });

  test('Genres zählen im Hintergrund; Haupt-Isolate kaum belastet', () async {
    final sw = Stopwatch()..start();
    final fut = GenreIndex.buildAsync(movies);
    final sync = _ms(sw);
    final idx = await fut;
    _log('Genre-Index 100k: $sync ms im Haupt-Isolate, ${_ms(sw)} ms gesamt');
    expect(sync, lessThan(80));
    final ref = GenreIndex.build(movies);
    expect(idx.counts.map((c) => '$c'), ref.counts.map((c) => '$c'));
    expect(idx.itemsOf('drama').length, ref.itemsOf('drama').length);
    expect(identical(idx.items, movies), isTrue);
  });

  test('Empfehlung über den Genre-Index < 80 ms', () async {
    final gm = await GenreIndex.buildAsync(movies);
    final gs = await GenreIndex.buildAsync(series);
    final recent = [for (var i = 0; i < 10; i++) movies[i * 997]];
    final sw = Stopwatch()..start();
    final r = recommend(
      recent: recent,
      candidatesOf: (g) => [...gm.itemsOf(g), ...gs.itemsOf(g)],
      seen: (_) => false,
    );
    final t = _ms(sw);
    _log('Empfehlung: $t ms');
    expect(t, lessThan(80));
    // Gleiches Ergebnis wie der Durchlauf über alle Titel.
    final slow = recommend(
        recent: recent, candidates: [...movies, ...series], seen: (_) => false);
    expect(r!.genreKey, slow!.genreKey);
    expect(r.items.map((m) => m.rating), slow.items.map((m) => m.rating));
    expect(r.items.length, 20);
  });

  test('Personen-Verzeichnis im Hintergrund; Suche bleibt flüssig', () async {
    final all = [...movies, ...series];
    final sw = Stopwatch()..start();
    final fut = PeopleIndex.build(all,
        cast: [for (final m in all) m.cast],
        director: [for (final m in all) m.director]);
    final sync = _ms(sw);
    final idx = await fut;
    _log('Personen 120k: $sync ms im Haupt-Isolate, ${_ms(sw)} ms gesamt, '
        '${idx.length} Namen');
    expect(sync, lessThan(150));
    expect(idx.length, greaterThan(10000));

    // Suche: ohne fertiges Verzeichnis keine Personen, aber auch kein
    // Aufbau im Haupt-Isolate.
    final engine = SearchEngine(
        channels: const [],
        epg: const {},
        movies: movies,
        series: series,
        buildPeople: false);
    final first = Stopwatch()..start();
    expect(engine.search('hart', DateTime(2026)).persons, isEmpty);
    _log('Erste Suche ohne Personen: ${_ms(first)} ms');
    expect(_ms(first), lessThan(400));
    engine.personIndex = idx;
    final per = Stopwatch()..start();
    var n = 0;
    for (final q in ['har', 'hart', 'hartm', 'hartma', 'hartman']) {
      final r = engine.search(q, DateTime(2026));
      expect(r.persons, isNotEmpty);
      n++;
    }
    final perKey = per.elapsedMilliseconds / n;
    _log('Personensuche: ${perKey.toStringAsFixed(1)} ms je Taste');
    expect(perKey, lessThan(120));
  });

  test('„Jetzt live im Sport“: 50 000 Sender, alle 30 s neu < 150 ms', () {
    final live = stressLive();
    final now = DateTime.now();
    const titles = [
      'Tagesschau',
      'Kochen mit Paul',
      'Transport-Giganten',
      'Tatort',
      'Nachrichten'
    ];
    final epg = <String, List<EpgEntry>>{
      for (var i = 0; i < 5000; i++)
        'e$i': [
          EpgEntry(
              channelEpgId: 'e$i',
              // Kaum Sport im Titel: die Schleife läuft fast ganz durch.
              title: i % 997 == 0
                  ? 'Bundesliga: Topspiel'
                  : titles[i % titles.length],
              start: now.subtract(const Duration(minutes: 10)),
              end: now.add(const Duration(minutes: 50))),
        ],
    };
    liveSport(
        categories: live.categories,
        channels: live.channels,
        epg: epg,
        now: now); // Erkennung einmal gemerkt (wie nach dem ersten Mal)
    final sw = Stopwatch()..start();
    final r = liveSport(
        categories: live.categories,
        channels: live.channels,
        epg: epg,
        now: now);
    _log('Sport live 50k: ${_ms(sw)} ms, ${r.length} Treffer');
    expect(_ms(sw), lessThan(150));
    expect(r, isNotEmpty);
  });

  test('Personen: Isolate und sofortiger Aufbau liefern dasselbe', () async {
    final some = movies.sublist(0, 5000);
    final a = await PeopleIndex.build(some,
        cast: [for (final m in some) m.cast],
        director: [for (final m in some) m.director]);
    final b = PeopleIndex.buildSync(some,
        cast: [for (final m in some) m.cast],
        director: [for (final m in some) m.director]);
    expect(a.names, b.names);
    for (var i = 0; i < a.length; i += 97) {
      expect(a.titlesAt(i), b.titlesAt(i));
      expect(a.directorAt(i), b.directorAt(i));
    }
  });
}
