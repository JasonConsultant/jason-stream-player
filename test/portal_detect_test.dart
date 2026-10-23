import 'package:flutter_test/flutter_test.dart';
import 'package:jason_stream_player/data/portal_detect.dart';
import 'package:jason_stream_player/models/models.dart';

/// „Einfügen & erkennen“: Zugangsdaten aus beliebigem Anbieter-Text.
void main() {
  group('Xtream-Links', () {
    test('get.php mit type=m3u_plus', () {
      final d = detectPortalInput(
          'http://host.example:8080/get.php?username=U&password=P&type=m3u_plus')!;
      expect(d.type, PortalType.xtream);
      expect(d.url, 'http://host.example:8080');
      expect(d.username, 'U');
      expect(d.password, 'P');
      expect(d.hostLabel, 'host.example:8080');
    });

    test('player_api.php, https ohne Port', () {
      final d = detectPortalInput(
          '  https://tv.example.com/player_api.php?username=jason&password=geheim  ')!;
      expect(d.type, PortalType.xtream);
      expect(d.url, 'https://tv.example.com');
      expect(d.username, 'jason');
      expect(d.password, 'geheim');
      expect(d.hostLabel, 'tv.example.com');
    });

    test('Sonderzeichen in den Zugangsdaten (roh und %-kodiert)', () {
      final d = detectPortalInput(
          'http://h:8080/get.php?username=ab%40cd&password=p%26w+x!%23&type=m3u')!;
      expect(d.username, 'ab@cd');
      // „+“ bleibt „+“ (kein Formular-Leerzeichen), %26 → &, %23 → #.
      expect(d.password, 'p&w+x!#');
    });

    test('Pfad-Präfix vor get.php bleibt erhalten', () {
      final d = detectPortalInput(
          'http://h.example/xc/get.php?username=a&password=b')!;
      expect(d.url, 'http://h.example/xc');
    });

    test('Link im Fließtext mit Satzzeichen danach, EPG-Link dazu', () {
      final d = detectPortalInput('Hallo, dein Zugang: '
          'http://h.example:25461/get.php?username=u1&password=p1&type=m3u_plus&output=ts. '
          'EPG: http://h.example:25461/xmltv.php?username=u1&password=p1.')!;
      expect(d.type, PortalType.xtream);
      expect(d.username, 'u1');
      expect(d.password, 'p1');
      expect(d.epgUrl, startsWith('http://h.example:25461/xmltv.php'));
    });

    test('nackte Server-Adresse → Xtream ohne Zugangsdaten', () {
      final d = detectPortalInput('http://server.example:8080/')!;
      expect(d.type, PortalType.xtream);
      expect(d.url, 'http://server.example:8080');
      expect(d.username, isNull);
    });
  });

  group('M3U', () {
    test('Playlist-Datei', () {
      final d = detectPortalInput('https://cdn.example/lists/free.m3u8')!;
      expect(d.type, PortalType.m3u);
      expect(d.url, 'https://cdn.example/lists/free.m3u8');
      expect(d.hostLabel, 'cdn.example');
    });

    test('get.php ohne Zugangsdaten im Link → Playlist', () {
      final d = detectPortalInput('http://h/get.php?token=abc&type=m3u_plus')!;
      expect(d.type, PortalType.m3u);
    });

    test('unbekannter Pfad → Playlist', () {
      final d = detectPortalInput('http://h.example/some/playlist')!;
      expect(d.type, PortalType.m3u);
    });
  });

  group('MAC-Portal', () {
    test('Portal-URL /c/ und MAC', () {
      final d = detectPortalInput(
          'Portal: http://mag.example:8080/c/\nMAC: 00:1A:79:12:34:56')!;
      expect(d.type, PortalType.stalker);
      expect(d.url, 'http://mag.example:8080/c/');
      expect(d.mac, '00:1A:79:12:34:56');
      expect(d.username, isNull);
    });

    test('stalker_portal, MAC mit Bindestrichen und Kleinbuchstaben', () {
      final d = detectPortalInput(
          'http://mag.example/stalker_portal/c/ 00-1a-79-ab-cd-ef')!;
      expect(d.type, PortalType.stalker);
      expect(d.url, 'http://mag.example/stalker_portal/c/');
      expect(d.mac, '00:1A:79:AB:CD:EF');
    });

    test('Host ohne /c/ plus MAC → /c/ ergänzt', () {
      final d = detectPortalInput('http://mag.example:88 mac 00:1A:79:00:00:01')!;
      expect(d.type, PortalType.stalker);
      expect(d.url, 'http://mag.example:88/c/');
    });

    test('portal.php → Portal-Adresse', () {
      final d = detectPortalInput(
          'http://mag.example/portal.php\nMAC 00:1A:79:00:00:02')!;
      expect(d.type, PortalType.stalker);
      expect(d.url, 'http://mag.example/c/');
    });

    test('Host ohne Schema mit MAC', () {
      final d = detectPortalInput('Server: mag.example:8080\nMAC: 00:1A:79:0A:0B:0C')!;
      expect(d.type, PortalType.stalker);
      expect(d.url, 'http://mag.example:8080/c/');
      expect(d.mac, '00:1A:79:0A:0B:0C');
    });

    test('MAC gewinnt nicht gegen Xtream-Link mit Zugangsdaten', () {
      final d = detectPortalInput(
          'http://h:80/get.php?username=u&password=p 00:1A:79:00:00:03')!;
      expect(d.type, PortalType.xtream);
    });
  });

  group('Freitext mit Beschriftungen', () {
    test('deutsch, Port in eigener Zeile, Leerzeichen am Rand', () {
      final d = detectPortalInput('''
Host: server.example.de
Port: 8080
Benutzer: jason77
Passwort: Geheim123
''')!;
      expect(d.type, PortalType.xtream);
      expect(d.url, 'http://server.example.de:8080');
      expect(d.username, 'jason77');
      expect(d.password, 'Geheim123');
      expect(d.hostLabel, 'server.example.de:8080');
    });

    test('türkisch', () {
      final d = detectPortalInput('''
Sunucu: http://tr.example:2095
Kullanıcı Adı: ahmet
Şifre: s!fre#2024
''')!;
      expect(d.type, PortalType.xtream);
      expect(d.url, 'http://tr.example:2095');
      expect(d.username, 'ahmet');
      expect(d.password, 's!fre#2024');
    });

    test('englisch mit „=“ und Anführungszeichen, https-URL', () {
      final d = detectPortalInput('''
URL = https://secure.example
username = "john.doe"
password = 'p:a=s&s'
''')!;
      expect(d.url, 'https://secure.example');
      expect(d.username, 'john.doe');
      expect(d.password, 'p:a=s&s');
    });

    test('mehrere Felder in einer Zeile', () {
      final d = detectPortalInput(
          'Server: h.example:8000, Username: a1, Password: b2')!;
      expect(d.url, 'http://h.example:8000');
      expect(d.username, 'a1');
      expect(d.password, 'b2');
    });

    test('Port aus eigener Zeile wird nicht doppelt gesetzt', () {
      final d = detectPortalInput('''
URL: http://h.example:9000
Port: 8080
User: u
Pass: p
''')!;
      expect(d.url, 'http://h.example:9000');
    });

    test('„Name:“ ist kein Benutzername', () {
      final d = detectPortalInput('''
Name: Mein Anbieter
Server: h.example:8080
Username: real
Password: pw
''')!;
      expect(d.username, 'real');
    });

    test('Zugangsdaten ohne Adresse → nichts erkannt', () {
      expect(detectPortalInput('Benutzer: a\nPasswort: b'), isNull);
    });
  });

  group('Nichts erkannt', () {
    test('leer / Prosa', () {
      expect(detectPortalInput(''), isNull);
      expect(detectPortalInput('   \n  '), isNull);
      expect(detectPortalInput('Viel Spaß mit deinem Abo!'), isNull);
    });

    test('nur eine MAC ohne Adresse', () {
      expect(detectPortalInput('00:1A:79:12:34:56'), isNull);
    });

    test('Zeitangabe wird nicht als MAC gelesen', () {
      expect(detectPortalInput('Abo bis 12:30:45:00:00:00:99 Uhr'), isNull);
    });
  });
}
