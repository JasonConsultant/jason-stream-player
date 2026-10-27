import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jason_stream_player/data/channel_variants.dart';
import 'package:jason_stream_player/data/epg_window.dart';
import 'package:jason_stream_player/data/xmltv_scanner.dart';
import 'package:jason_stream_player/state/content_filter.dart';
import 'package:jason_stream_player/models/models.dart';
import 'package:jason_stream_player/state/providers.dart';
import 'package:jason_stream_player/ui/search/search_engine.dart';

import 'helpers/stress_data.dart';

/// Last-/Laufzeittests mit Großanbieter-Daten (50 000 Sender in 800 Gruppen,
/// 100 000 Filme, 20 000 Serien, XMLTV 5000 Sender × 14 Tage).
/// Gemessene Zeiten werden ausgegeben (`[stress] …`); die Grenzen sind die
/// Ziele für Desktop-CI.

int _ms(Stopwatch s) => s.elapsedMilliseconds;

class _NullSink implements StringSink {
  @override
  void write(Object? o) {}
  @override
  void writeAll(Iterable<Object?> o, [String sep = '']) {}
  @override
  void writeCharCode(int c) {}
  @override
  void writeln([Object? o = '']) {}
}

T _time<T>(String label, T Function() f, {List<int>? out}) {
  final sw = Stopwatch()..start();
  final r = f();
  sw.stop();
  // ignore: avoid_print
  print('[stress] $label: ${_ms(sw)} ms');
  out?.add(_ms(sw));
  return r;
}

/// Suche wie vor 1.3 (Kleinbuchstaben per Expando, alles bei jeder Eingabe).
int _oldSearch(String q, List<Channel> visible, Map<String, List<EpgEntry>> epg,
    List<VodItem> movies, List<VodItem> series, Expando<String> lower) {
  String l(Object o, String s) => lower[o] ??= s.toLowerCase();
  var n = 0;
  for (final c in visible) {
    if (l(c, c.name).contains(q)) n++;
    if (n >= 40) break;
  }
  final now = DateTime.now();
  final from = now.subtract(const Duration(days: 7));
  final to = now.add(const Duration(days: 2));
  final byEpg = <String, Channel>{for (final c in visible) epgKeyOf(c): c};
  final shows = <EpgEntry>[];
  for (final e in epg.entries) {
    final c = byEpg[e.key];
    if (c == null) continue;
    for (final p in e.value) {
      if (p.end.isBefore(from) || p.start.isAfter(to)) continue;
      if (p.isPastAt(now) && !c.hasCatchup) continue;
      if (l(p, p.title).contains(q)) shows.add(p);
    }
  }
  n += shows.length;
  n += movies.where((m) => l(m, m.name).contains(q)).take(30).length;
  n += series.where((m) => l(m, m.name).contains(q)).take(30).length;
  return n;
}

void main() {
  late Map<String, List<EpgEntry>> bigEpg;
  late LiveData live;
  late VodData movies, series;

  setUpAll(() {
    live = stressLive();
    movies = stressVod(items: 100000);
    series = stressVod(items: 20000, series: true, cats: 120, seed: 3);
  });

  test('Daten wie erwartet', () {
    expect(live.channels, hasLength(50000));
    expect(live.categories, hasLength(800));
    expect(movies.items, hasLength(100000));
    expect(series.items, hasLength(20000));
  });

  test('Varianten zusammenfassen + Länderfilter < 300 ms (50 000 Sender)', () {
    // Aufwärmen (JIT), dann messen.
    groupVariants(live.channels.take(5000).toList());
    final groups = _time('groupVariants 50k', () => groupVariants(live.channels));
    final idx = _time(
        'VariantIndex.of',
        () => VariantIndex.of(groups,
            favorites: {'c1', 'c99'}, hidden: {'c5'}, locked: {'c7'}));
    final merged =
        _time('collapse', () => LiveData(live.categories, idx.collapse(live.channels)));
    final filtered = _time(
        'Länderfilter DE+TR',
        () => applyContentFilters(merged,
            adultLocked: false, countries: {'DE', 'TR'}));
    // Minimum aus 3 Läufen (Desktop-CI schwankt).
    var best = 1 << 30;
    for (var k = 0; k < 3; k++) {
      final total = Stopwatch()..start();
      final g2 = groupVariants(live.channels);
      final i2 = VariantIndex.of(g2);
      final m2 = LiveData(live.categories, i2.collapse(live.channels));
      applyContentFilters(m2, adultLocked: false, countries: {'DE', 'TR'});
      total.stop();
      if (_ms(total) < best) best = _ms(total);
    }
    // ignore: avoid_print
    print('[stress] gesamt (gruppieren+index+collapse+filter): $best ms; '
        '${groups.length} Gruppen, sichtbar ${merged.channels.length}, '
        'nach Filter ${filtered.channels.length}');
    expect(groups.length, greaterThan(5000));
    expect(merged.channels.length, lessThan(live.channels.length));
    expect(filtered.channels, isNotEmpty);
    // Geteilte CI-Rechner (GitHub Actions) sind langsamer und schwanken stark;
    // dort reicht die doppelte Grenze, lokal gilt weiter < 300 ms.
    final ci = Platform.environment['CI'] == 'true';
    expect(best, lessThan(ci ? 600 : 300));
  });

  test('Große Listen: Gruppierung im Hintergrund blockiert kaum', () async {
    final main = Stopwatch()..start();
    final fut = groupVariantsInBackground(live.channels);
    main.stop(); // synchroner Anteil (Namen/Gruppen-IDs einsammeln)
    final all = Stopwatch()..start();
    final groups = await fut;
    all.stop();
    // ignore: avoid_print
    print('[stress] groupVariantsInBackground: synchron ${_ms(main)} ms, '
        'gesamt ${_ms(all)} ms');
    expect(groups.length, greaterThan(5000));
    expect(_ms(main), lessThan(50));
  });

  test('Länder erkennen (Auswahl-Liste) und VOD-Filter', () {
    CountryFilter.detect(LiveData(live.categories, live.channels.take(2000).toList()), const []);
    final counts = _time('CountryFilter.detect live+vod (170k)',
        () => CountryFilter.detect(live, [movies, series]));
    expect(counts['DE'], greaterThan(0));
    final v = _time('VOD-Filter 100k Filme DE+TR',
        () => applyVodContentFilters(movies,
            adultLocked: false, countries: {'DE', 'TR'}));
    expect(v.items.length, lessThan(movies.items.length));
  });

  test('Kein O(n²): doppelte Menge ≈ doppelte Zeit', () {
    final small = stressLive(channels: 25000, groups: 400, seed: 5).channels;
    final big = stressLive(channels: 100000, groups: 1600, seed: 5).channels;
    groupVariants(small);
    final a = Stopwatch()..start();
    groupVariants(small);
    a.stop();
    final b = Stopwatch()..start();
    groupVariants(big);
    b.stop();
    // ignore: avoid_print
    print('[stress] groupVariants 25k: ${_ms(a)} ms, 100k: ${_ms(b)} ms');
    // 4× Daten: linear ≈ 4×, quadratisch ≈ 16×.
    expect(b.elapsedMicroseconds, lessThan(a.elapsedMicroseconds * 9));
  });

  test('XMLTV 5000 Sender × 14 Tage: Lesezeit und Speicher', () async {
    final now = DateTime.now();
    final rssBefore = ProcessInfo.currentRss;
    // Nur Erzeugen (ohne Lesen), um es von der Lesezeit abzuziehen.
    final gen = Stopwatch()..start();
    writeStressXmltv(_NullSink(), now: now);
    gen.stop();
    final scanner = XmltvScanner(null);
    final sw = Stopwatch()..start();
    writeStressXmltv(scanner, now: now);
    final epg = scanner.finish();
    final parse = _ms(sw) - _ms(gen);
    final capped = _time('EpgWindow.cap', () => EpgWindow.cap(epg));
    sw.stop();
    final rssAfter = ProcessInfo.currentRss;
    var n = 0, chars = 0;
    for (final l in capped.values) {
      n += l.length;
      for (final p in l) {
        chars += p.title.length + (p.description?.length ?? 0) +
            (p.genre?.length ?? 0) + p.channelEpgId.length;
      }
    }
    // Schätzung: Objekt ~64 B + 2 DateTime à ~24 B + Strings (~1 B/Zeichen
    // bei Latin-1, + ~16 B Kopf je String).
    final est = n * (64 + 48 + 4 * 16) + chars;
    // ignore: avoid_print
    print('[stress] XMLTV lesen 5000×14 Tage: $parse ms (+ ${_ms(gen)} ms Erzeugen), $n Sendungen, '
        'Schätzung ${est >> 20} MB, RSS +${(rssAfter - rssBefore) >> 20} MB');
    expect(n, greaterThan(1000000));
    expect(n, lessThanOrEqualTo(EpgWindow.maxTotal));
    bigEpg = capped;
  });

  test('Suche: < 50 ms je Tastendruck (50k Sender, 1 Mio. Sendungen, 120k VOD)',
      () {
    final visible = LiveData(live.categories,
            VariantIndex.of(groupVariants(live.channels)).collapse(live.channels))
        .channels;
    const typed = ['ni', 'nig', 'nigh', 'night', 'night ', 'night d'];
    // Vorher: alles bei jeder Eingabe (erster Durchlauf berechnet Expando).
    final lower = Expando<String>();
    final old = <int>[];
    for (final q in ['xy', ...typed]) {
      final sw = Stopwatch()..start();
      _oldSearch(q, visible, bigEpg, movies.items, series.items, lower);
      old.add(_ms(sw));
    }
    // Nachher: SearchEngine (Index beim ersten Suchen, dann Weitersuche).
    // Zeitmessung: Andere Testdateien laufen parallel (u. a. Isolates in
    // stress_14) – bis zu drei Durchläufe mit frischem Index, der beste zählt.
    late SearchEngine engine;
    late Stopwatch first;
    var keys = <int>[];
    SearchResults? r;
    final now = DateTime.now();
    for (var attempt = 0; attempt < 3; attempt++) {
      final e = SearchEngine(
          channels: visible,
          epg: bigEpg,
          movies: movies.items,
          series: series.items);
      final f = Stopwatch()..start();
      e.search('xy', now);
      f.stop();
      final k = <int>[];
      for (final q in typed) {
        final sw = Stopwatch()..start();
        r = e.search(q, now);
        k.add(_ms(sw));
      }
      int maxOf(List<int> l) => l.reduce((a, b) => a > b ? a : b);
      if (attempt == 0 || maxOf(k) < maxOf(keys)) {
        engine = e;
        first = f;
        keys = k;
      }
      if (maxOf(keys) < 50) break;
    }
    // Neuer Anfang (kein Weitersuchen möglich): alles durchsuchen.
    final fresh = Stopwatch()..start();
    engine.search('st', now);
    fresh.stop();
    // ignore: avoid_print
    print('[stress] Suche vorher (ms je Taste, 1. inkl. Kleinschreibung): $old');
    // ignore: avoid_print
    print('[stress] Suche nachher: Index ${_ms(first)} ms, Tasten $keys, '
        'neuer Begriff ${_ms(fresh)} ms; Treffer „night d“: '
        '${r!.channels.length}/${r.shows.length}/${r.films.length}/${r.series.length}');
    expect(r.shows, isNotEmpty);
    expect(keys.reduce((a, b) => a > b ? a : b), lessThan(50));
    expect(_ms(fresh), lessThan(150));
  });
}
