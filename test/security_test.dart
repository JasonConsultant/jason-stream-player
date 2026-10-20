import 'package:flutter_test/flutter_test.dart';
import 'package:jason_stream_player/l10n/strings.dart';
import 'package:jason_stream_player/core/security.dart';
import 'package:jason_stream_player/data/m3u_parser.dart';

void main() {
  setUp(() => L10n.lang = 'de'); // Tests prüfen deutsche Texte
  group('Redactor – Zugangsdaten nie anzeigen', () {
    setUp(Redactor.clear);

    test('entfernt registriertes Passwort und Benutzername', () {
      Redactor.register('jason77', 'Geheim!123');
      final msg = Redactor.redact(
          'ClientException: Connection failed, uri=http://srv.example:8080/'
          'player_api.php?username=jason77&password=Geheim%21123');
      expect(msg, isNot(contains('jason77')));
      expect(msg, isNot(contains('Geheim')));
    });

    test('maskiert auch nicht registrierte Query-Parameter', () {
      final msg = Redactor.redact('get.php?username=bob&password=xyz789&type=m3u');
      expect(msg, contains('username=•••'));
      expect(msg, contains('password=•••'));
      expect(msg, isNot(contains('xyz789')));
    });

    test('maskiert Xtream-Stream-Pfade', () {
      final msg = Redactor.redact('Fehler bei http://h:80/live/bob/pw42/123.ts');
      expect(msg, isNot(contains('pw42')));
      expect(msg, contains('/live/•••/•••/'));
    });

    test('Zugangsdaten aus M3U-Adresse werden erkannt', () {
      Redactor.registerUrl(
          'http://h.example/get.php?username=anna&password=s3cr3t&type=m3u_plus');
      expect(Redactor.redact('Login s3cr3t für anna'), 'Login ••• für •••');
    });
  });

  group('UrlPolicy – nur sichere Adressen', () {
    test('Streams: http/https/rtmp erlaubt', () {
      expect(UrlPolicy.isStream('http://a.b/1.ts'), isTrue);
      expect(UrlPolicy.isStream('https://a.b/x.m3u8'), isTrue);
      expect(UrlPolicy.isStream('rtmp://a.b/live'), isTrue);
    });
    test('Streams: lokale/gefährliche Schemata blockiert', () {
      expect(UrlPolicy.isStream('file:///data/data/de.jasonstream.player/x'), isFalse);
      expect(UrlPolicy.isStream('content://media/external/1'), isFalse);
      expect(UrlPolicy.isStream('javascript:alert(1)'), isFalse);
      expect(UrlPolicy.isStream('data:text/plain,hi'), isFalse);
    });
    test('Bilder/Portal: nur http(s) mit Host', () {
      expect(UrlPolicy.isWeb('https://x.y/logo.png'), isTrue);
      expect(UrlPolicy.isWeb('file:///sdcard/a.png'), isFalse);
      expect(UrlPolicy.isWeb('http://'), isFalse);
      expect(UrlPolicy.image('ftp://a/b.png'), isNull);
    });
    test('http wird als unverschlüsselt erkannt', () {
      expect(UrlPolicy.isUnencrypted('http://a.b'), isTrue);
      expect(UrlPolicy.isUnencrypted('https://a.b'), isFalse);
    });
  });

  group('PinHasher', () {
    test('gleiche PIN + Salz → gleicher Hash, andere PIN → anderer', () {
      final salt = PinHasher.newSalt();
      final h = PinHasher.hash('1234', salt);
      expect(PinHasher.equals(h, PinHasher.hash('1234', salt)), isTrue);
      expect(PinHasher.equals(h, PinHasher.hash('1235', salt)), isFalse);
    });
    test('Salz ist zufällig – gleiche PIN ergibt verschiedene Hashes', () {
      final a = PinHasher.hash('0000', PinHasher.newSalt());
      final b = PinHasher.hash('0000', PinHasher.newSalt());
      expect(a == b, isFalse);
    });
    test('Hash enthält die PIN nicht im Klartext', () {
      expect(PinHasher.hash('987654', PinHasher.newSalt()), isNot(contains('987654')));
    });
  });

  group('M3U – manipulierte Playlist', () {
    test('unsichere Einträge werden verworfen, sichere bleiben', () {
      const m3u = '''#EXTM3U x-tvg-url="file:///etc/epg.xml"
#EXTINF:-1 tvg-logo="file:///sdcard/x.png" group-title="A",Gut
http://srv.example/live/1.ts
#EXTINF:-1 group-title="A",Böse
file:///data/data/de.jasonstream.player/shared_prefs/x.xml
#EXTINF:-1 group-title="A",Auch böse
content://com.android.contacts/contacts
''';
      final r = M3uParser.parse(m3u);
      expect(r.channels.map((c) => c.name), ['Gut']);
      expect(r.channels.first.logoUrl, isNull);
      expect(r.epgUrl, isNull);
    });
  });
}
