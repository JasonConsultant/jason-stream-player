import 'package:flutter_test/flutter_test.dart';
import 'package:jason_stream_player/data/epg_matcher.dart';
import 'package:jason_stream_player/data/xmltv_parser.dart';
import 'package:jason_stream_player/models/models.dart';

Channel ch(String id, String name, [String? epg]) => Channel(
    id: id, name: name, categoryId: 'c', streamUrl: 'http://x/$id.ts', epgId: epg);

void main() {
  test('Namen normalisieren', () {
    expect(EpgMatcher.nameKey('DE: ZDF HD'), 'zdf');
    expect(EpgMatcher.nameKey('DE • Das Erste FHD'), 'daserste');
    expect(EpgMatcher.nameKey('|DE| RTL (RAW)'), 'rtl');
    expect(EpgMatcher.nameKey('ProSieben HD+'), EpgMatcher.nameKey('ProSieben'));
    expect(EpgMatcher.idKey('ZDF.de'), 'zdf');
    expect(EpgMatcher.idKey('DasErste.de'), 'daserste');
    expect(EpgMatcher.idKey('TRT1.tr'), 'trt1');
  });

  test('Zuordnung: Kennung, Groß/Klein, Name', () async {
    final channels = [
      ch('1', 'DE: ZDF HD', 'ZDF.de'),
      ch('2', 'DE • ZDF RAW'), // keine Kennung → über den Namen
      ch('3', 'Das Erste FHD', 'daserste.DE'), // andere Schreibweise
      ch('4', 'Unbekannt XY'),
    ];
    final m = EpgMatcher(channels);
    expect(m.wants('ZDF.de'), isTrue);
    expect(m.wants('DasErste.de'), isTrue);
    expect(m.wants('Sat1.de'), isFalse);

    final d = DateTime.now().toUtc().add(const Duration(hours: 1));
    String f(DateTime t) =>
        '${t.year}${t.month.toString().padLeft(2, '0')}${t.day.toString().padLeft(2, '0')}'
        '${t.hour.toString().padLeft(2, '0')}0000 +0000';
    final a = f(d), b = f(d.add(const Duration(hours: 1)));
    final xml = '''<tv>
<programme start="$a" stop="$b" channel="ZDF.de"><title>Heute</title></programme>
<programme start="$a" stop="$b" channel="DasErste.de"><title>Tagesschau</title></programme>
<programme start="$a" stop="$b" channel="Sat1.de"><title>X</title></programme>
</tv>''';
    final parsed = await XmltvParser.parse(xml);
    final out = m.assign(parsed);
    expect(epgOf(out, channels[0]).single.title, 'Heute');
    expect(epgOf(out, channels[1]).single.title, 'Heute');
    expect(epgOf(out, channels[2]).single.title, 'Tagesschau');
    expect(epgOf(out, channels[3]), isEmpty);
  });
}
