import 'package:flutter_test/flutter_test.dart';
import 'package:jason_stream_player/data/m3u_parser.dart';
import 'package:jason_stream_player/data/m3u_repository.dart';
import 'package:jason_stream_player/data/stream_headers.dart';
import 'package:jason_stream_player/models/models.dart';

/// Header aus M3U-Playlisten (#EXTVLCOPT, #KODIPROP, #EXTHTTP, „|…“) und
/// das Zusammenführen mit den Portal-Einstellungen (User-Agent/Referer).
void main() {
  group('M3U-Optionszeilen', () {
    test('#EXTVLCOPT: user-agent, referrer, origin', () {
      expect(parseM3uOptionLine('#EXTVLCOPT:http-user-agent=Mozilla/5.0 (X11)'),
          {'User-Agent': 'Mozilla/5.0 (X11)'});
      expect(parseM3uOptionLine('#EXTVLCOPT:http-referrer=https://site.tv/'),
          {'Referer': 'https://site.tv/'});
      expect(parseM3uOptionLine('#EXTVLCOPT:http-origin=https://site.tv'),
          {'Origin': 'https://site.tv'});
      // Andere VLC-Optionen werden ignoriert.
      expect(parseM3uOptionLine('#EXTVLCOPT:network-caching=1000'), isEmpty);
    });

    test('#KODIPROP: nur Header-Angaben, keine DRM-/Lizenz-Zeilen', () {
      expect(
          parseM3uOptionLine('#KODIPROP:inputstream.adaptive.stream_headers='
              'User-Agent=Kodi%2F20&Referer=https%3A%2F%2Fa.tv%2F&X-Foo=bar'),
          {'User-Agent': 'Kodi/20', 'Referer': 'https://a.tv/'});
      expect(
          parseM3uOptionLine(
              '#KODIPROP:inputstream.adaptive.manifest_headers=Cookie=sid%3D1'),
          {'Cookie': 'sid=1'});
      for (final drm in [
        '#KODIPROP:inputstream.adaptive.license_type=clearkey',
        '#KODIPROP:inputstream.adaptive.license_key=https://lic/|User-Agent=X|R{SSM}|',
        '#KODIPROP:inputstream.adaptive.license_headers=User-Agent=X',
        '#KODIPROP:inputstreamaddon=inputstream.adaptive',
      ]) {
        expect(parseM3uOptionLine(drm), isEmpty, reason: drm);
      }
    });

    test('#EXTHTTP (JSON)', () {
      expect(
          parseM3uOptionLine(
              '#EXTHTTP:{"User-Agent":"UA1","cookie":"a=b","Authorization":"x"}'),
          {'User-Agent': 'UA1', 'Cookie': 'a=b'});
      expect(parseM3uOptionLine('#EXTHTTP:{kaputt'), isEmpty);
    });

    test('„|User-Agent=…&Referer=…“ wird von der Adresse abgetrennt', () {
      final (url, h) = splitPipeHeaders(
          'http://cdn.tv/live/1.m3u8|User-Agent=VLC%2F3.0&Referer=http://r.tv/&Origin=http://o.tv');
      expect(url, 'http://cdn.tv/live/1.m3u8');
      expect(h, {
        'User-Agent': 'VLC/3.0',
        'Referer': 'http://r.tv/',
        'Origin': 'http://o.tv',
      });
      expect(splitPipeHeaders('http://a/b.ts'), ('http://a/b.ts', const <String, String>{}));
    });

    test('Zeilenumbrüche in Werten werden entfernt (keine Header-Injection)', () {
      final h = parseHeaderQuery('User-Agent=a%0D%0AX-Evil:%201');
      expect(h['User-Agent'], 'aX-Evil: 1');
      expect(h.keys, ['User-Agent']);
    });
  });

  group('M3uParser', () {
    const playlist = '''
#EXTM3U url-tvg="http://epg.tv/e.xml"
#EXTINF:-1 tvg-id="ard.de" tvg-shift="-1.5" group-title="DE",Das Erste
#EXTVLCOPT:http-user-agent=Mozilla/5.0 Test
#EXTVLCOPT:http-referrer=https://ref.tv/
http://s.tv/ard.m3u8
#EXTINF:-1 group-title="DE",ZDF
http://s.tv/zdf.m3u8|User-Agent=Pipe%20UA&Cookie=k%3Dv
#KODIPROP:inputstream.adaptive.license_type=clearkey
#KODIPROP:inputstream.adaptive.license_key=0123:4567
#EXTINF:-1 group-title="DE" catchup="shift" catchup-days="3",Arte
http://s.tv/arte.m3u8
''';

    test('Header pro Sender, Adresse ohne Anhang, tvg-shift, Catch-up', () {
      final r = M3uParser.parse(playlist);
      expect(r.channels.length, 3);
      final ard = r.channels[0], zdf = r.channels[1], arte = r.channels[2];
      expect(ard.streamUrl, 'http://s.tv/ard.m3u8');
      expect(ard.headers,
          {'User-Agent': 'Mozilla/5.0 Test', 'Referer': 'https://ref.tv/'});
      expect(ard.epgShift, -90);
      expect(zdf.streamUrl, 'http://s.tv/zdf.m3u8');
      expect(zdf.headers, {'User-Agent': 'Pipe UA', 'Cookie': 'k=v'});
      // DRM-Zeilen vor Arte: ignoriert, keine Header übernommen.
      expect(arte.headers, isNull);
      expect(arte.catchupMode, 'shift');
      expect(arte.catchupDays, 3);
      // Header gelten nur für den nächsten Sender.
      expect(zdf.headers!.containsKey('Referer'), isFalse);
    });
  });

  group('streamHeadersFor', () {
    const portal = Portal(
      id: 'p',
      name: 'P',
      type: PortalType.m3u,
      url: 'http://s.tv/list.m3u',
      userAgent: 'PortalUA',
      referer: 'https://portal.tv/',
    );

    test('Portal-Einstellungen ohne Sender', () {
      expect(streamHeadersFor(portal, null),
          {'User-Agent': 'PortalUA', 'Referer': 'https://portal.tv/'});
      expect(portalHeaders(portal), streamHeadersFor(portal, null));
    });

    test('Sender-Angaben aus der Playlist haben Vorrang, Rest bleibt', () {
      const c = Channel(
        id: '1',
        name: 'X',
        categoryId: 'g',
        streamUrl: 'http://s.tv/x',
        headers: {'user-agent': 'ChannelUA', 'Cookie': 'a=1'},
      );
      expect(streamHeadersFor(portal, c), {
        'User-Agent': 'ChannelUA',
        'Referer': 'https://portal.tv/',
        'Cookie': 'a=1',
      });
    });

    test('ohne Einstellungen: leer (Player-Standard)', () {
      const plain = Portal(
          id: 'q', name: 'Q', type: PortalType.xtream, url: 'http://h:1');
      expect(streamHeadersFor(plain, null), isEmpty);
    });

    test('User-Agent-Vorlagen erkennen', () {
      expect(UserAgentPreset.idOf(null), 'app');
      expect(UserAgentPreset.idOf(UserAgentPreset.vlc), 'vlc');
      expect(UserAgentPreset.idOf(UserAgentPreset.browser), 'browser');
      expect(UserAgentPreset.idOf('Mein UA'), 'custom');
    });
  });

  group('tvg-shift', () {
    test('wird auf das EPG des Senders angewendet (einmal je Kennung)', () {
      final t = DateTime(2026, 10, 21, 20);
      EpgEntry e(String id) => EpgEntry(
          channelEpgId: id,
          title: 'x',
          start: t,
          end: t.add(const Duration(hours: 1)));
      final epg = {
        'a.de': [e('a.de')],
        'b.de': [e('b.de')],
      };
      const chans = [
        Channel(id: '1', name: 'A', categoryId: 'g', streamUrl: 'http://s/1',
            epgId: 'a.de', epgShift: -90),
        // Zweiter Sender mit derselben Kennung: nicht doppelt verschieben.
        Channel(id: '2', name: 'A HD', categoryId: 'g', streamUrl: 'http://s/2',
            epgId: 'a.de', epgShift: -90),
        Channel(id: '3', name: 'B', categoryId: 'g', streamUrl: 'http://s/3',
            epgId: 'b.de'),
      ];
      final out = M3uRepository.applyTvgShift(epg, chans);
      expect(out['a.de']!.single.start, t.subtract(const Duration(minutes: 90)));
      expect(out['b.de']!.single.start, t);
    });

    test('Parser: #EXTVLCOPT vor #EXTINF und globaler tvg-shift', () {
      final r = M3uParser.parse('''#EXTM3U tvg-shift="+1"
#EXTVLCOPT:http-user-agent=Box/1.0
#EXTINF:-1 tvg-id="a",A
http://h/a.ts|Referer=http%3A%2F%2Fr.example%2F
#EXTINF:-1 tvg-id="b" tvg-shift="-2",B
#KODIPROP:inputstream.adaptive.license_key=https://lic.example/x
http://h/b.ts
''');
      final a = r.channels[0], b = r.channels[1];
      expect(a.streamUrl, 'http://h/a.ts');
      expect(a.headers, {'User-Agent': 'Box/1.0', 'Referer': 'http://r.example/'});
      expect(a.epgShift, 60);
      expect(b.headers, isNull); // Lizenz-Zeile ignoriert, nichts übertragen
      expect(b.epgShift, -120);
    });
  });
}
