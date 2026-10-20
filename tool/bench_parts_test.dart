import 'package:flutter_test/flutter_test.dart';
import 'package:jason_stream_player/data/xmltv_parser.dart';
import 'package:jason_stream_player/models/models.dart';

void main() {
  test('Teile', () {
    const n = 1000000;
    var sw = Stopwatch()..start();
    DateTime? d;
    for (var i = 0; i < n; i++) {
      d = XmltvParser.parseTime('20261019120000 +0200');
    }
    // ignore: avoid_print
    print('parseTime x1M: ${sw.elapsedMilliseconds} ms $d');
    sw = Stopwatch()..start();
    final re = RegExp(r'''([\w:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')''');
    const attrs = ' start="20261019120000 +0000" stop="20261019130000 +0000" channel="ch12.de"';
    var c = 0;
    for (var i = 0; i < n; i++) {
      for (final m in re.allMatches(attrs)) {
        c += m[1]!.length;
      }
    }
    // ignore: avoid_print
    print('Attribut-RegExp x1M: ${sw.elapsedMilliseconds} ms $c');
    sw = Stopwatch()..start();
    final l = <EpgEntry>[];
    final t = DateTime.now();
    for (var i = 0; i < n; i++) {
      l.add(EpgEntry(channelEpgId: 'a', title: 'x', start: t, end: t));
    }
    // ignore: avoid_print
    print('EpgEntry x1M: ${sw.elapsedMilliseconds} ms ${l.length}');
  });
}
