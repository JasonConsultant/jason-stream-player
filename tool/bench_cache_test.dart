import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jason_stream_player/data/epg_cache/epg_cache.dart';
import 'package:jason_stream_player/data/xmltv_parser.dart';

const dir = String.fromEnvironment('BENCH');

void main() {
  test('Cache', () async {
    final bytes = Uint8List.fromList(File('$dir/epg.xml.gz').readAsBytesSync());
    final ids = {for (var i = 0; i < 2500; i++) 'ch$i.de'};
    final epg = await XmltvParser.parseBytes(bytes, channelIds: ids);
    var sw = Stopwatch()..start();
    final raw = EpgCache.debugEncode(epg);
    // ignore: avoid_print
    print('EPG-Cache schreiben: ${sw.elapsedMilliseconds} ms, ${raw.length ~/ 1024 ~/ 1024} MB');
    sw = Stopwatch()..start();
    final near = EpgCache.debugDecode(raw, near: true);
    // ignore: avoid_print
    print('EPG-Cache Schnellstart (jetzt+demnächst): ${sw.elapsedMilliseconds} ms, ${near.values.fold<int>(0, (a, l) => a + l.length)} Sendungen');
    sw = Stopwatch()..start();
    final back = EpgCache.debugDecode(raw);
    // ignore: avoid_print
    print('EPG-Cache komplett (Hintergrund): ${sw.elapsedMilliseconds} ms, ${back.values.fold<int>(0, (a, l) => a + l.length)} Sendungen');
    sw = Stopwatch()..start();
    final live = jsonDecode(File('$dir/live_streams.json').readAsStringSync());
    // ignore: avoid_print
    print('Senderliste 12.000 JSON: ${sw.elapsedMilliseconds} ms ${(live as List).length}');
  }, timeout: const Timeout(Duration(minutes: 10)));
}
