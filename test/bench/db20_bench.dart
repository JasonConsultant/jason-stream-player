// Messung 2.0 (nicht Teil von `flutter test`, Dateiname ohne _test):
//   DB20_DIR=/pfad DB20_MODE=prepare|load|search flutter test test/bench/db20_bench.dart
// Jede Stufe in einem eigenen Prozess (sauberer Speicher-Ausgangswert).
// Daten: 50 000 Sender/800 Gruppen, 60 000 Filme, 20 000 Serien (mit
// Handlung/Besetzung), EPG 3000 Sender × 14 Tage × 24 = 1 008 000 Sendungen.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jason_stream_player/data/epg_cache/epg_cache.dart';
import 'package:jason_stream_player/data/list_cache.dart';
import 'package:jason_stream_player/models/models.dart';
import 'package:jason_stream_player/state/providers.dart' show VodData;
import 'package:jason_stream_player/ui/search/search_engine.dart';

import '../helpers/stress_data.dart';

const portal = Portal(
    id: 'bench20',
    name: 'B',
    type: PortalType.xtream,
    url: 'http://srv.example:8080',
    username: 'u',
    password: 'p');

Map<String, List<EpgEntry>> benchEpg(DateTime now,
    {int channels = 3000, int days = 14, int perDay = 24}) {
  final start = DateTime(now.year, now.month, now.day)
      .subtract(Duration(days: days ~/ 2));
  final step = Duration(minutes: 24 * 60 ~/ perDay);
  const words = ['Night', 'Tatort', 'News', 'Sport', 'Love', 'Haber', 'Dizi',
    'Çocuk', 'Şahin', 'Ödül', 'Müzik', 'Wetter'];
  return {
    for (var c = 0; c < channels; c++)
      'e$c': [
        for (var p = 0; p < days * perDay; p++)
          EpgEntry(
            channelEpgId: 'e$c',
            title: '${words[(c + p) % words.length]} '
                '${words[(c * 7 + p) % words.length]} ${p % 40}',
            description: 'Folge $p der Reihe – eine Beschreibung mit etwas '
                'Text, wie sie in echten EPG-Daten vorkommt (Sender $c).',
            genre: 'Serie',
            start: start.add(step * p),
            end: start.add(step * (p + 1)),
          ),
      ],
  };
}

VodData benchSeries() {
  final s = stressVod(items: 20000, series: true, cats: 120, seed: 3, rich: true);
  return VodData(s.categories, [
    for (final m in s.items)
      m.copyWith(
          plot: 'Handlung von ${m.name}: Eine Familie zieht in eine neue '
              'Stadt und entdeckt ein Geheimnis, das alles verändert. '
              'Spannung, Drama und große Gefühle in mehreren Staffeln.',
          backdropUrl: 'http://img.example/b/${m.id}.jpg'),
  ]);
}

int rssMb() => ProcessInfo.currentRss >> 20;

void log(String s) {
  // ignore: avoid_print
  print('[db20] $s');
}

Future<T> timed<T>(String label, Future<T> Function() f) async {
  final sw = Stopwatch()..start();
  final r = await f();
  log('$label: ${sw.elapsedMilliseconds} ms');
  return r;
}

void main() {
  final dir = Platform.environment['DB20_DIR'] ?? '/tmp/db20';
  final mode = Platform.environment['DB20_MODE'] ?? 'prepare';
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    Directory(dir).createSync(recursive: true);
    ListCache.debugDirectory = dir;
  });

  test('db20 $mode', () async {
    final now = DateTime.now();
    if (mode == 'prepare') {
      final live = stressLive(channels: 50000, groups: 800);
      final movies = stressVod(items: 60000, rich: true);
      final series = benchSeries();
      await timed('save live', () => ListCache.saveLive(portal, live.categories, live.channels));
      await timed('save movies', () => ListCache.saveVod('movies', portal, movies.categories, movies.items));
      await timed('save series', () => ListCache.saveVod('series', portal, series.categories, series.items));
      final epg = benchEpg(now);
      await timed('save epg', () => EpgCache.save(portal.id, epg));
      for (final f in Directory(dir).listSync().whereType<File>()) {
        log('file ${f.uri.pathSegments.last}: ${(f.lengthSync() / 1048576).toStringAsFixed(1)} MB');
      }
      return;
    }
    if (mode == 'load') {
      final r0 = rssMb();
      final sw = Stopwatch()..start();
      final live = await ListCache.loadLive(portal);
      log('start→Senderliste (Cache gelesen): ${sw.elapsedMilliseconds} ms, ${live!.items.length} Sender');
      final r1 = rssMb();
      final movies = await timed('Filme', () => ListCache.loadVod('movies', portal));
      final series = await timed('Serien', () => ListCache.loadVod('series', portal));
      final r2 = rssMb();
      final near = await timed('EPG nah (−3 h…+30 h)', () => EpgCache.loadWindow(portal.id, near: true));
      final r3 = rssMb();
      final full = await timed('EPG ganz (Archiv)', () => EpgCache.loadWindow(portal.id));
      final r4 = rssMb();
      log('Startpfad gesamt: ${sw.elapsedMilliseconds} ms');
      log('RSS MB: Basis $r0, +Sender ${r1 - r0}, +Filme/Serien ${r2 - r1}, '
          '+EPG nah ${r3 - r2}, +EPG ganz ${r4 - r3}, gesamt ${r4 - r0}');
      var entries = 0;
      for (final l in full!.values) {
        entries += l.length;
      }
      var nearN = 0;
      for (final l in near!.values) {
        nearN += l.length;
      }
      log('Objekte im Speicher: Sender ${live.items.length}, Filme ${movies!.items.length}, '
          'Serien ${series!.items.length}, EPG-Sendungen nah $nearN / ganz $entries');
      return;
    }
    if (mode == 'search') {
      final live = (await ListCache.loadLive(portal))!;
      final movies = (await ListCache.loadVod('movies', portal))!;
      final series = (await ListCache.loadVod('series', portal))!;
      final epg = (await EpgCache.loadWindow(portal.id))!;
      final r0 = rssMb();
      final e = SearchEngine(
          channels: live.items,
          epg: epg,
          movies: movies.items,
          series: series.items,
          buildPeople: true);
      final sw = Stopwatch()..start();
      e.search('zz', now);
      log('erste Suche (Index-Aufbau inkl. EPG-Titel, Personen): ${sw.elapsedMilliseconds} ms, RSS +${rssMb() - r0} MB');
      for (final q in ['ta', 'tat', 'night', 'şahin', 'sahin', 'çocuk', 'zdf hd', 'anna']) {
        final s = Stopwatch()..start();
        final r = e.search(q, now);
        log('Suche "$q": ${s.elapsedMicroseconds / 1000} ms → '
            '${r.channels.length} Sender, ${r.shows.length} Sendungen, '
            '${r.films.length} Filme, ${r.series.length} Serien, ${r.persons.length} Personen');
      }
      return;
    }
  }, timeout: const Timeout(Duration(minutes: 20)));
}
