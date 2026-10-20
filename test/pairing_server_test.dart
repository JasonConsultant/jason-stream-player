import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jason_stream_player/l10n/strings.dart';
import 'package:jason_stream_player/core/pairing/pairing.dart'
    show PairingException;
import 'package:jason_stream_player/core/pairing/pairing_server.dart';

class _Resp {
  final int status;
  final HttpHeaders headers;
  final String body;
  _Resp(this.status, this.headers, this.body);
}

Future<_Resp> _request(
  Uri uri, {
  String method = 'GET',
  String? body,
  String contentType = 'application/x-www-form-urlencoded',
}) async {
  final client = HttpClient();
  try {
    final req = await client.openUrl(method, uri);
    if (body != null) {
      req.headers.contentType = ContentType.parse(contentType);
      req.write(body);
    }
    final res = await req.close();
    final text = await utf8.decodeStream(res);
    return _Resp(res.statusCode, res.headers, text);
  } finally {
    client.close(force: true);
  }
}

String _form(Map<String, String> m) => Uri(queryParameters: m).query;

void main() {
  setUp(() => L10n.lang = 'de'); // Tests prüfen deutsche Texte
  late PairingSession session;

  setUp(() async {
    session =
        await PairingSession.start(bindAddress: InternetAddress.loopbackIPv4);
  });

  tearDown(() => session.cancel());

  test('URL: http, Loopback, /p/<128-Bit-Token base64url>', () {
    expect(session.url.scheme, 'http');
    expect(session.url.host, '127.0.0.1');
    expect(session.url.port, greaterThan(0));
    expect(session.url.pathSegments.first, 'p');
    final token = session.url.pathSegments[1];
    expect(token, matches(RegExp(r'^[A-Za-z0-9_-]{22}$')));
  });

  test('GET liefert Formular mit Sicherheits-Headern', () async {
    final r = await _request(session.url);
    expect(r.status, 200);
    expect(r.headers.value('cache-control'), 'no-store');
    expect(r.headers.value('content-security-policy'),
        contains("default-src 'none'"));
    expect(r.headers.value('content-security-policy'),
        contains("form-action 'self'"));
    expect(r.headers.value('x-content-type-options'), 'nosniff');
    expect(r.headers.value('referrer-policy'), 'no-referrer');
    expect(r.headers.contentType?.mimeType, 'text/html');
    expect(r.body, contains('<form method="post"'));
    expect(r.body, contains('Xtream Codes'));
    expect(r.body, contains('MAC-Portal'));
    expect(r.body, contains('selben Netzwerk'));
    expect(r.body, isNot(contains('<link')));
    expect(r.body, isNot(contains(' src=')));
  });

  test('falscher Token und andere Pfade → 404', () async {
    final base = session.url;
    for (final path in ['/p/falsch', '/', '/p/', '${base.path}x', '/favicon.ico']) {
      final r = await _request(base.replace(path: path));
      expect(r.status, 404, reason: path);
      expect(r.body, isNot(contains('<form')));
    }
  });

  test('andere Methode → 405, falscher Content-Type → 415', () async {
    expect((await _request(session.url, method: 'PUT')).status, 405);
    final r = await _request(session.url,
        method: 'POST',
        body: '{"type":"m3u"}', contentType: 'application/json');
    expect(r.status, 415);
    expect(session.isActive, isTrue);
  });

  test('gültige Xtream-Daten → Ergebnis, danach Server geschlossen', () async {
    final r = await _request(session.url,
        method: 'POST',
        body: _form({
          'type': 'xtream',
          'name': 'Mein Anbieter',
          'url': 'http://iptv.example:8080',
          'username': 'jason',
          'password': 'Geheim&123 ä',
          'mac': '',
          'epg': 'https://epg.example/guide.xml',
        }));
    expect(r.status, 200);
    expect(r.body, contains('Fertig! Schau auf deinen Fernseher.'));

    final res = await session.result.timeout(const Duration(seconds: 5));
    expect(res.type, 'xtream');
    expect(res.name, 'Mein Anbieter');
    expect(res.url, 'http://iptv.example:8080');
    expect(res.username, 'jason');
    expect(res.password, 'Geheim&123 ä');
    expect(res.mac, isNull);
    expect(res.epgUrl, 'https://epg.example/guide.xml');
    expect(res.toString(), isNot(contains('Geheim')));
    expect(session.isActive, isFalse);

    // Einmalige Nutzung: weitere Anfragen schlagen fehl.
    await expectLater(_request(session.url), throwsA(isA<SocketException>()));
  });

  test('MAC-Portal: MAC wird normalisiert', () async {
    final r = await _request(session.url,
        method: 'POST',
        body: _form({
          'type': 'stalker',
          'url': 'http://portal.example/c/',
          'mac': '00-1a-79-ab-cd-ef',
        }));
    expect(r.status, 200);
    final res = await session.result;
    expect(res.type, 'stalker');
    expect(res.mac, '00:1A:79:AB:CD:EF');
    expect(res.name, 'portal.example');
    expect(res.username, isNull);
    expect(res.password, isNull);
  });

  test('ungültige MAC → Fehler, kein Ergebnis', () async {
    final r = await _request(session.url,
        method: 'POST',
        body: _form({
          'type': 'stalker',
          'url': 'http://portal.example/c/',
          'mac': '00:1A:79:AB:CD',
        }));
    expect(r.status, 422);
    expect(r.body, contains('MAC-Adresse muss'));
    expect(session.isActive, isTrue);
  });

  test('ungültige URL → Formular mit Fehler, ohne Passwort, nicht fertig',
      () async {
    var completed = false;
    unawaited(session.result.then((_) => completed = true, onError: (_) {}));

    final r = await _request(session.url,
        method: 'POST',
        body: _form({
          'type': 'xtream',
          'name': '<script>alert(1)</script>',
          'url': 'javascript:alert(1)',
          'username': 'jason',
          'password': 'SuperGeheim99',
        }));
    expect(r.status, 422);
    expect(r.body, contains('http:// oder https://'));
    expect(r.body, contains('<form'));
    expect(r.body, isNot(contains('SuperGeheim99')));
    // HTML-escaped
    expect(r.body, isNot(contains('<script>alert(1)</script>')));
    expect(r.body, contains('&lt;script&gt;'));
    // Name und Benutzername bleiben erhalten
    expect(r.body, contains('value="jason"'));

    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(completed, isFalse);
    expect(session.isActive, isTrue);

    // Danach klappt es noch.
    final ok = await _request(session.url,
        method: 'POST',
        body: _form({
          'type': 'm3u',
          'url': 'https://list.example/get.php?username=a&password=b',
        }));
    expect(ok.status, 200);
    final res = await session.result;
    expect(res.type, 'm3u');
    expect(res.url, 'https://list.example/get.php?username=a&password=b');
  });

  test('Playlist-URL mit Zugangsdaten wird bei Fehler nicht zurückgegeben',
      () async {
    final r = await _request(session.url,
        method: 'POST',
        body: _form({
          'type': 'm3u',
          'url': 'https://list.example/get.php?username=a&password=pw777',
          'epg': 'ftp://x',
        }));
    expect(r.status, 422);
    expect(r.body, contains('EPG-URL'));
    expect(r.body, isNot(contains('pw777')));
  });

  test('Pflichtfelder Xtream', () async {
    final r = await _request(session.url,
        method: 'POST',
        body: _form({'type': 'xtream', 'url': 'http://a.example'}));
    expect(r.status, 422);
    expect(r.body, contains('Benutzernamen'));
  });

  test('Inhalt > 16 KB wird abgelehnt', () async {
    final big = _form({
      'type': 'm3u',
      'url': 'http://a.example/',
      'name': 'x' * (17 * 1024),
    });
    try {
      final r = await _request(session.url, method: 'POST', body: big);
      expect(r.status, 413);
    } on SocketException {
      // Server darf die Verbindung auch hart schließen.
    } on HttpException {
      // dito
    }
    expect(session.isActive, isTrue);
  });

  test('Inhalt > 16 KB ohne Content-Length (chunked) wird abgelehnt',
      () async {
    final client = HttpClient();
    try {
      final req = await client.postUrl(session.url);
      req.headers.contentType =
          ContentType.parse('application/x-www-form-urlencoded');
      req.headers.chunkedTransferEncoding = true;
      for (var i = 0; i < 20; i++) {
        req.write('name=${'y' * 1024}&');
      }
      final res = await req.close();
      await res.drain<void>();
      expect(res.statusCode, 413);
    } on SocketException {
      // Server darf die Verbindung auch hart schließen.
    } on HttpException {
      // dito
    } finally {
      client.close(force: true);
    }
    expect(session.isActive, isTrue);
    expect((await _request(session.url)).status, 200);
  });

  test('cancel() beendet mit Fehler und schließt den Server', () async {
    final s2 =
        await PairingSession.start(bindAddress: InternetAddress.loopbackIPv4);
    final f = expectLater(s2.result, throwsA(isA<PairingException>()));
    await s2.cancel();
    await f;
    expect(s2.isActive, isFalse);
    await expectLater(_request(s2.url), throwsA(isA<SocketException>()));
  });

  test('Ablauf → Fehler mit deutscher Meldung', () async {
    final s2 = await PairingSession.start(
      bindAddress: InternetAddress.loopbackIPv4,
      timeout: const Duration(milliseconds: 100),
    );
    await expectLater(
      s2.result,
      throwsA(isA<PairingException>()
          .having((e) => e.message, 'message', contains('abgelaufen'))),
    );
    expect(s2.isActive, isFalse);
  });

  test('pickLanAddress bevorzugt private Bereiche, ignoriert Loopback', () {
    InternetAddress a(String s) => InternetAddress(s);
    expect(
      PairingSession.pickLanAddress(
          [a('127.0.0.1'), a('100.64.1.2'), a('192.168.1.20')])?.address,
      '192.168.1.20',
    );
    expect(
      PairingSession.pickLanAddress([a('169.254.3.4'), a('10.0.0.5')])
          ?.address,
      '10.0.0.5',
    );
    expect(PairingSession.pickLanAddress([a('127.0.0.1')]), isNull);
    expect(PairingSession.pickLanAddress([]), isNull);
  });
}
