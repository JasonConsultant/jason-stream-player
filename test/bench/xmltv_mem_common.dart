import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// XMLTV-Datei (optional gzip) streamend erzeugen: [channels] × [perChannel]
/// Sendungen im Zeitfenster um jetzt, mit Beschreibung.
Future<File> writeXmltv(Directory dir,
    {int channels = 3000, int perChannel = 100, bool gz = true}) async {
  final f = File('${dir.path}/epg.xml${gz ? '.gz' : ''}');
  final raw = f.openWrite();
  final ctl = StreamController<List<int>>();
  final done = (gz ? ctl.stream.transform(gzip.encoder) : ctl.stream).pipe(raw);
  String two(int v) => v.toString().padLeft(2, '0');
  String t(DateTime d) {
    final u = d.toUtc();
    return '${u.year}${two(u.month)}${two(u.day)}${two(u.hour)}${two(u.minute)}00 +0000';
  }

  final start = DateTime.now().subtract(const Duration(days: 2));
  // Pseudo-zufällige Wörter → realistische gzip-Rate (statt 30:1).
  var seed = 12345;
  int rnd(int n) {
    seed = (seed * 1103515245 + 12345) & 0x7fffffff;
    return seed % n;
  }

  const letters = 'abcdefghijklmnopqrstuvwxyzäöü';
  String word() => String.fromCharCodes([
        for (var i = 0; i < 3 + rnd(8); i++)
          letters.codeUnitAt(rnd(letters.length))
      ]);
  String words(int n) => [for (var i = 0; i < n; i++) word()].join(' ');
  final b = StringBuffer('<?xml version="1.0" encoding="UTF-8"?>\n<tv>\n');
  for (var c = 0; c < channels; c++) {
    b.write(
        '<channel id="ch$c.de"><display-name>Kanal $c</display-name></channel>\n');
  }
  ctl.add(utf8.encode(b.toString()));
  for (var c = 0; c < channels; c++) {
    final sb = StringBuffer();
    for (var i = 0; i < perChannel; i++) {
      final s = start.add(Duration(minutes: 60 * i));
      sb.write(
          '<programme start="${t(s)}" stop="${t(s.add(const Duration(minutes: 60)))}" '
          'channel="ch$c.de"><title lang="de">Sendung $i auf Kanal $c</title>'
          '<desc lang="de">${words(18)}</desc>'
          '<category lang="de">Kategorie ${i % 12}</category></programme>\n');
    }
    ctl.add(utf8.encode(sb.toString()));
  }
  ctl.add('</tv>\n'.codeUnits);
  await ctl.close();
  await done;
  return f;
}

Future<HttpServer> serve(File f) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    req.response.headers.contentLength = await f.length();
    await f.openRead().pipe(req.response);
  });
  return server;
}

/// Spitzen-RSS (Prozess) während [work], als Zuwachs über dem Ausgangswert.
Future<(T, int)> peakRss<T>(Future<T> Function() work) async {
  final base = ProcessInfo.currentRss;
  var peak = base;
  final t = Timer.periodic(const Duration(milliseconds: 5), (_) {
    final r = ProcessInfo.currentRss;
    if (r > peak) peak = r;
  });
  final r = await work();
  t.cancel();
  final end = ProcessInfo.currentRss;
  if (end > peak) peak = end;
  return (r, (peak - base) >> 20);
}
