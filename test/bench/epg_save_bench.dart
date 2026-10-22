// Messung: flutter test test/bench/epg_save_bench.dart
// EpgCache.save mit 500 000 Sendungen: vorher (ganzes EPG ins Isolate
// kopieren und dort kodieren) vs. nachher (Bytes kommen fertig aus dem
// Parse-Isolate, nur noch schreiben).
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:jason_stream_player/data/epg_cache/epg_cache.dart';
import 'package:jason_stream_player/data/list_cache.dart';
import 'package:jason_stream_player/models/models.dart';

import '../helpers/xtream_stress.dart';

Map<String, List<EpgEntry>> build500k() {
  final now = DateTime.now();
  final out = <String, List<EpgEntry>>{};
  for (var c = 0; c < 2000; c++) {
    final key = 'ch$c.de';
    out[key] = [
      for (var i = 0; i < 250; i++)
        EpgEntry(
          channelEpgId: key,
          title: 'Sendung ${i % 40}',
          description: 'Beschreibung $c/$i – etwas längerer Text zur Sendung.',
          genre: i % 3 == 0 ? 'Film' : null,
          start: now.add(Duration(minutes: 40 * (i - 125))),
          end: now.add(Duration(minutes: 40 * (i - 124))),
        )
    ];
  }
  return out;
}

(Map<String, List<EpgEntry>>, (dynamic, String)) buildEncoded() {
  final m = build500k();
  return (m, EpgCache.encodeWithHash(m));
}

Future<T> best<T>(int n, Future<(T, int)> Function() f, List<int> out) async {
  late T r;
  var min = 1 << 30;
  for (var i = 0; i < n; i++) {
    final (v, ms) = await f();
    r = v;
    if (ms < min) min = ms;
  }
  out.add(min);
  return r;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final dir = Directory.systemTemp.createTempSync('bench15e_');
  ListCache.debugDirectory = dir.path;
  tearDownAll(() => dir.deleteSync(recursive: true));

  test('EPG save 500k', () async {
    final before = <int>[], recv = <int>[], after = <int>[];
    for (var round = 0; round < 3; round++) {
      // Vorher: EPG liegt im Haupt-Isolate (aus dem Parse-Isolate erhalten).
      final epg = await Isolate.run(build500k);
      final (_, b) = await measureMainStall(() => EpgCache.save('a', epg));
      before.add(b);
      // Nachher: Ergebnis + fertige Bytes aus dem Isolate.
      final (r, rc) = await measureMainStall(() => Isolate.run(buildEncoded));
      recv.add(rc);
      final (m, (bytes, hash)) = r;
      EpgCache.attach(m, bytes, hash);
      final (_, a) = await measureMainStall(() => EpgCache.save('b', m));
      after.add(a);
    }
    before.sort();
    recv.sort();
    after.sort();
    // ignore: avoid_print
    print('BENCH epg save 500k: main stall before=${before.first}ms '
        '(median ${before[1]}) after=${after.first}ms (median ${after[1]}); '
        'receive result+bytes=${recv.first}ms (same in both)');
  }, timeout: Timeout.none);
}
