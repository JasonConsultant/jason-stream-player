import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jason_stream_player/data/xmltv_parser.dart';
import 'package:jason_stream_player/data/xmltv_scanner.dart';

String t(DateTime d) {
  String two(int n) => n.toString().padLeft(2, '0');
  final u = d.toUtc();
  return '${u.year}${two(u.month)}${two(u.day)}${two(u.hour)}${two(u.minute)}00 +0000';
}

void main() {
  final now = DateTime.now();
  final a = now.subtract(const Duration(hours: 1));
  final b = now.add(const Duration(hours: 1));
  final old = now.subtract(const Duration(days: 30));

  final xml = '''<?xml version="1.0" encoding="UTF-8"?>
<tv>
  <channel id="one.de"><display-name>Eins</display-name></channel>
  <programme start="${t(a)}" stop="${t(b)}" channel="one.de">
    <title lang="de">Tom &amp; Jerry – Folge 5</title>
    <title lang="en">Tom and Jerry</title>
    <desc lang="de"><![CDATA[Katze <jagt> Maus]]></desc>
    <category lang="de">Kinder</category>
  </programme>
  <programme start="${t(b)}" stop="${t(b.add(const Duration(hours: 1)))}" channel="one.de">
    <title>Nachrichten</title>
  </programme>
  <programme start="${t(old)}" stop="${t(old.add(const Duration(hours: 1)))}" channel="one.de">
    <title>Viel zu alt</title>
  </programme>
  <programme start="${t(a)}" stop="${t(b)}" channel="other.de"><title>Anderer Sender</title></programme>
  <programme start="20261019120000 +0200" stop="20261019130000 +0200" channel="tz.de"><title>Zeitzone</title></programme>
</tv>''';

  test('Inhalte korrekt (Sonderzeichen, CDATA, erste Sprache, Genre)', () async {
    final epg = await XmltvParser.parse(xml);
    final one = epg['one.de']!;
    expect(one.length, 2); // die 30 Tage alte Sendung fällt raus
    expect(one.first.title, 'Tom & Jerry – Folge 5');
    expect(one.first.description, 'Katze <jagt> Maus');
    expect(one.first.genre, 'Kinder');
    expect(one.last.title, 'Nachrichten');
    expect(one.first.start.isBefore(one.last.start), isTrue);
  });

  test('Zeitzonen werden umgerechnet', () async {
    final epg = await XmltvParser.parse(xml);
    final e = epg['tz.de'];
    if (e != null) {
      expect(e.first.start.toUtc(), DateTime.utc(2026, 10, 19, 10));
    }
    expect(XmltvParser.parseTime('20261019120000 +0200')!.toUtc(),
        DateTime.utc(2026, 10, 19, 10));
  });

  test('Filter: nur Sender aus dem Portal', () async {
    final epg = await XmltvParser.parse(xml, channelIds: {'one.de'});
    expect(epg.keys, ['one.de']);
  });

  test('gzip-komprimiertes EPG', () async {
    final gz = Uint8List.fromList(gzip.encode(utf8.encode(xml)));
    final epg = await XmltvParser.parseBytes(gz);
    expect(epg['one.de']!.first.title, 'Tom & Jerry – Folge 5');
  });

  test('Schnelle Zeit-Auswertung = genaue Zeit-Auswertung', () {
    for (final v in [
      '20261019120000 +0200',
      '20261019120000 -0530',
      '20261019120000 +0000',
      '20261019120000',
      '20261231235959 +0100',
    ]) {
      expect(XmltvScanner.fastTime(v)!.toUtc(), XmltvParser.parseTime(v)!.toUtc(),
          reason: v);
    }
    expect(XmltvScanner.fastTime('2026x019120000'), isNull);
  });

  test('Attribute mit einfachen Anführungszeichen und Leerzeichen', () async {
    final x = "<tv><programme channel='q.de'  start = \"${t(a)}\" stop='${t(b)}'><title>Q</title></programme></tv>";
    final epg = await XmltvParser.parse(x);
    expect(epg['q.de']!.single.title, 'Q');
  });
}
