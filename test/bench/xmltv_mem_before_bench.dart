// Messung: flutter test test/bench/xmltv_mem_before_bench.dart
// 1.4-Ablauf: komplette Datei im Haupt-Isolate puffern, dann ins Parse-
// Isolate kopieren.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jason_stream_player/data/net.dart';
import 'package:jason_stream_player/data/xmltv_parser.dart';

import 'xmltv_mem_common.dart';

Future<int> _parse((Uint8List, Set<String>?) j) async =>
    (await XmltvParser.parseBytes(j.$1, channelIds: j.$2))
        .values
        .fold<int>(0, (a, l) => a + l.length);

void main() {
  const gz = bool.fromEnvironment('XM_GZ', defaultValue: true);
  {
    test('before gz=$gz', () async {
      final dir = Directory.systemTemp.createTempSync('xm_');
      final f = await writeXmltv(dir, gz: gz);
      final server = await serve(f);
      final url = Uri.parse(
          'http://127.0.0.1:${server.port}/epg.xml${gz ? '.gz' : ''}');
      final ids = {for (var c = 0; c < 3000; c += 3) 'ch$c.de'};
      final (n, mb) = await peakRss(() async {
        final bytes = await Net.get(url, maxBytes: 300 << 20);
        return compute(_parse, (bytes, ids));
      });
      // ignore: avoid_print
      print('BENCH xmltv before gz=$gz file=${f.lengthSync() >> 20}MB '
          'entries=$n peakRssDelta=${mb}MB');
      await server.close(force: true);
      dir.deleteSync(recursive: true);
      expect(n, greaterThan(0));
    }, timeout: Timeout.none);
  }
}
