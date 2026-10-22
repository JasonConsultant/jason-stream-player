// Messung: flutter test test/bench/xmltv_mem_after_bench.dart
// 1.5: Laden + Entpacken + Parsen + Kodieren als Datenstrom in einem
// Hintergrund-Isolate (das Isolate lädt selbst).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jason_stream_player/data/epg_cache/epg_cache.dart';
import 'package:jason_stream_player/data/xmltv_parser.dart';

import 'xmltv_mem_common.dart';

void main() {
  const gz = bool.fromEnvironment('XM_GZ', defaultValue: true);
  {
    test('after gz=$gz', () async {
      final dir = Directory.systemTemp.createTempSync('xm_');
      final f = await writeXmltv(dir, gz: gz);
      final server = await serve(f);
      final url = 'http://127.0.0.1:${server.port}/epg.xml${gz ? '.gz' : ''}';
      final ids = {for (var c = 0; c < 3000; c += 3) 'ch$c.de'};
      final (epg, mb) = await peakRss(
          () => XmltvParser.loadSources([(url, 0)], channelIds: ids));
      final n = epg.values.fold<int>(0, (a, l) => a + l.length);
      // ignore: avoid_print
      print('BENCH xmltv after gz=$gz file=${f.lengthSync() >> 20}MB '
          'entries=$n peakRssDelta=${mb}MB (incl. cache bytes '
          '${EpgCache.hashOf(epg) != null})');
      await server.close(force: true);
      dir.deleteSync(recursive: true);
      expect(n, greaterThan(0));
    }, timeout: Timeout.none);
  }
}
