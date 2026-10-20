import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:jason_stream_player/data/epg_matcher.dart';
import 'package:jason_stream_player/data/xmltv_parser.dart';
import 'package:jason_stream_player/data/xmltv_scanner.dart';
import 'package:jason_stream_player/models/models.dart';
import 'package:jason_stream_player/state/providers.dart';

Channel ch(String id, String name, {String? epg, String? logo}) => Channel(
    id: id,
    name: name,
    categoryId: 'c',
    streamUrl: 'http://x/$id.ts',
    epgId: epg,
    logoUrl: logo,
    number: 7,
    catchupDays: 3);

void main() {
  test('ChannelOverride: JSON hin und zurück', () {
    final o = ChannelOverride(name: 'ZDF', logoUrl: 'https://l/z.png', epgId: 'ZDF.de');
    final back = ChannelOverride.fromJson(
        jsonDecode(jsonEncode(o.toJson())) as Map<String, dynamic>);
    expect(back.name, 'ZDF');
    expect(back.logoUrl, 'https://l/z.png');
    expect(back.epgId, 'ZDF.de');

    // „Kein EPG“ ('') muss erhalten bleiben, null-Felder fallen weg.
    final none = ChannelOverride(epgId: '');
    final j = none.toJson();
    expect(j.containsKey('name'), isFalse);
    expect(ChannelOverride.fromJson(j).epgId, '');
    expect(ChannelOverride().isEmpty, isTrue);
    expect(none.isEmpty, isFalse);
  });

  test('Überschreibungen auf eine Senderliste anwenden', () {
    final data = LiveData(const [Category(id: 'c', name: 'TV')], [
      ch('1', 'DE: ZDF HD', epg: 'zdf.auto', logo: 'http://a/1.png'),
      ch('2', 'RTL', epg: 'rtl.de'),
      ch('3', 'Sat1'),
    ]);
    final out = LiveNotifier.applyOverrides(data, {
      '1': ChannelOverride(name: 'ZDF', epgId: 'ZDF.de'),
      '2': ChannelOverride(epgId: ''), // kein EPG
      '3': ChannelOverride(logoUrl: 'https://l/sat1.png'),
    });
    expect(out.categories, same(data.categories));
    final a = out.channels[0];
    expect(a.name, 'ZDF');
    expect(a.epgId, 'ZDF.de');
    expect(a.logoUrl, 'http://a/1.png'); // unverändert
    expect(a.streamUrl, data.channels[0].streamUrl);
    expect(a.number, 7);
    expect(a.catchupDays, 3);
    final b = out.channels[1];
    expect(b.epgId, '');
    expect(epgKeyOf(b), '@2'); // „Kein EPG“ → keine Zuordnung
    expect(b.name, 'RTL');
    expect(out.channels[2].logoUrl, 'https://l/sat1.png');
    expect(out.channels[2].epgId, isNull);

    // Keine Überschreibungen → gleiche Instanz.
    expect(LiveNotifier.applyOverrides(data, const {}), same(data));
    // Leere Überschreibung ändert nichts.
    expect(data.channels[2].withOverride(ChannelOverride()),
        same(data.channels[2]));
  });

  test('Manuelle Kennung wird vom Matcher exakt übernommen', () async {
    final c = ch('1', 'Irgendwas', epg: 'ZDF.de');
    final m = EpgMatcher([c]);
    expect(m.wants('ZDF.de'), isTrue);
    final now = DateTime.now();
    final e = EpgEntry(
        channelEpgId: 'ZDF.de',
        title: 'heute',
        start: now,
        end: now.add(const Duration(hours: 1)));
    final out = m.assign({
      'ZDF.de': [e]
    });
    expect(out['ZDF.de'], [e]);
  });

  test('„Kein EPG“ (epgId = \'\') schaltet auch die Namens-Zuordnung ab',
      () async {
    final off = ch('1', 'ZDF HD', epg: '');
    final auto = ch('2', 'ZDF HD');
    final m = EpgMatcher([off, auto]);
    final now = DateTime.now();
    final e = EpgEntry(
        channelEpgId: 'ZDF.de',
        title: 'heute',
        start: now,
        end: now.add(const Duration(hours: 1)));
    final out = m.assign({
      'ZDF.de': [e]
    });
    expect(out.containsKey('@1'), isFalse);
    expect(out['@2'], [e]);
  });

  test('Scanner sammelt <channel>-Anzeigenamen (auch über Stückgrenzen)', () async {
    const xml = '''<?xml version="1.0"?>
<tv>
  <channel id="ZDF.de"><icon src="x"/><display-name lang="de">ZDF HD</display-name><display-name>ZDF</display-name></channel>
  <channel id="Tom&amp;Jerry.de">
    <display-name>Tom &amp; Jerry</display-name>
  </channel>
  <channel id="leer.de"></channel>
  <programme start="20200101000000 +0000" stop="20200101010000 +0000" channel="ZDF.de"><title>alt</title></programme>
  <channel id="spaet.de"><display-name>Spät</display-name></channel>
</tv>''';
    final one = XmltvScanner(null)..write(xml);
    one.finish();
    expect(one.channelNames['ZDF.de'], 'ZDF HD');
    expect(one.channelNames['Tom&Jerry.de'], 'Tom & Jerry');
    expect(one.channelNames['leer.de'], 'leer.de');
    expect(one.channelNames['spaet.de'], 'Spät');

    // In kleinen Stücken (Elemente werden an beliebigen Stellen geteilt).
    final chunked = XmltvScanner(null);
    for (var i = 0; i < xml.length; i += 7) {
      chunked.write(xml.substring(i, i + 7 > xml.length ? xml.length : i + 7));
    }
    chunked.finish();
    expect(chunked.channelNames, one.channelNames);

    // Über den Parser: Namen landen in namesOut.
    final names = <String, String>{};
    await XmltvParser.parseBytes(utf8.encode(xml),
        channelIds: {'nix'}, namesOut: names);
    expect(names['ZDF.de'], 'ZDF HD');

    // Register für den Provider.
    EpgChannelNames.reset();
    EpgChannelNames.addAll({'a': 'A'});
    EpgChannelNames.addAll({'a': 'B', 'c': 'C'});
    expect(EpgChannelNames.snapshot(), {'a': 'A', 'c': 'C'});
    EpgChannelNames.reset();
    expect(EpgChannelNames.snapshot(), isEmpty);
  });
  _perfGuard();
}

// Regression: _channels() suchte für jede Sendung bis zum Ende des Stücks
// nach „<channel “ → quadratisch (11 MB EPG: 85 s). Jetzt gecacht.
void _perfGuard() {
  test('Scanner: Senderliste kostet nicht pro Sendung eine Volltextsuche',
      () async {
    final b = StringBuffer('<tv>');
    for (var i = 0; i < 200; i++) {
      b.write('<channel id="c$i"><display-name>K$i</display-name></channel>');
    }
    for (var i = 0; i < 40000; i++) {
      b.write('<programme start="20300101000000 +0000" '
          'stop="20300101010000 +0000" channel="c${i % 200}">'
          '<title>T</title><desc>Etwas längerer Text für die Beschreibung '
          'dieser Sendung, damit das Stück realistisch groß wird.</desc>'
          '</programme>');
    }
    b.write('</tv>');
    final xml = b.toString(); // ~8 MB
    final sw = Stopwatch()..start();
    final sc = XmltvScanner({'c1'});
    const step = 1024 * 1024;
    for (var i = 0; i < xml.length; i += step) {
      sc.write(xml.substring(i, i + step > xml.length ? xml.length : i + step));
    }
    sc.finish();
    expect(sc.channelNames.length, 200);
    expect(sw.elapsed, lessThan(const Duration(seconds: 10)));
  });
}
