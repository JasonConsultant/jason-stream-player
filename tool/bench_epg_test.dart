import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jason_stream_player/data/xmltv_parser.dart';

const dir = String.fromEnvironment('BENCH');
const file = String.fromEnvironment('EPG', defaultValue: 'epg.xml');
const filter = bool.fromEnvironment('FILTER');

void main() {
  test('NACHHER', () async {
    final bytes = Uint8List.fromList(File('$dir/$file').readAsBytesSync());
    final ids = filter ? {for (var i = 0; i < 2500; i++) 'ch$i.de'} : null;
    final rssBefore = ProcessInfo.currentRss;
    final sw = Stopwatch()..start();
    final epg = await XmltvParser.parseBytes(bytes, channelIds: ids);
    final n = epg.values.fold<int>(0, (a, l) => a + l.length);
    // ignore: avoid_print
    print('$file filter=$filter: ${sw.elapsedMilliseconds} ms, ${epg.length} Sender, '
        '$n Sendungen, Speicher-Zuwachs max ~${(ProcessInfo.maxRss - rssBefore) ~/ 1024 ~/ 1024} MB');
  }, timeout: const Timeout(Duration(minutes: 10)));
}
