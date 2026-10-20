import 'package:flutter_test/flutter_test.dart';
import 'package:jason_stream_player/data/repository.dart';
import 'package:jason_stream_player/data/stalker_repository.dart';
import 'package:jason_stream_player/models/models.dart';

List<String> _cands(String url) =>
    StalkerRepository.endpointCandidates(url).map((u) => '$u').toList();

void main() {
  group('Stalker – Endpunkte', () {
    test('…/c/ → server/load.php eine Ebene höher', () {
      expect(_cands('http://srv.example:8080/c/'), [
        'http://srv.example:8080/server/load.php',
        'http://srv.example:8080/portal.php',
        'http://srv.example:8080/stalker_portal/server/load.php',
      ]);
    });

    test('…/stalker_portal/c/ ohne Duplikate', () {
      expect(_cands('http://srv.example:8080/stalker_portal/c/'), [
        'http://srv.example:8080/stalker_portal/server/load.php',
        'http://srv.example:8080/portal.php',
      ]);
    });

    test('nur Host (auch ohne Schema und ohne /)', () {
      expect(_cands('srv.example:8080'), [
        'http://srv.example:8080/server/load.php',
        'http://srv.example:8080/portal.php',
        'http://srv.example:8080/stalker_portal/server/load.php',
      ]);
      expect(_cands('http://srv.example/'), [
        'http://srv.example/server/load.php',
        'http://srv.example/portal.php',
        'http://srv.example/stalker_portal/server/load.php',
      ]);
    });

    test('portal.php direkt angegeben → zuerst', () {
      final c = _cands('https://srv.example/portal.php');
      expect(c.first, 'https://srv.example/portal.php');
      expect(c, contains('https://srv.example/stalker_portal/server/load.php'));
      expect(c.toSet().length, c.length);
    });

    test('…/c ohne Schrägstrich und c/index.html', () {
      expect(_cands('http://srv.example:80/c').first,
          'http://srv.example/server/load.php');
      expect(_cands('http://srv.example:88/stalker_portal/c/index.html').first,
          'http://srv.example:88/stalker_portal/server/load.php');
    });

    test('Portal-Wurzel', () {
      expect('${StalkerRepository.portalRoot('http://a.example:8080/c/')}',
          'http://a.example:8080/');
    });
  });

  group('Stalker – MAC-Adresse', () {
    test('normalisiert auf Großbuchstaben', () {
      expect(StalkerRepository.normalizeMac(' 00:1a:79:ab:cd:ef '),
          '00:1A:79:AB:CD:EF');
      expect(StalkerRepository.normalizeMac('00-1A-79-AB-CD-EF'),
          '00:1A:79:AB:CD:EF');
    });

    test('lehnt ungültige Formate ab', () {
      for (final bad in [null, '', '00:1A:79:AB:CD', '001A79ABCDEF',
          '00:1A:79:AB:CD:EG', '00:1A:79:AB:CD:EF:00']) {
        expect(() => StalkerRepository.normalizeMac(bad),
            throwsA(isA<RepositoryException>()), reason: '$bad');
      }
    });
  });

  group('Stalker – cmd', () {
    test('entfernt Player-Präfixe', () {
      expect(StalkerRepository.stripCmd('ffmpeg http://x.example/ch/1'),
          'http://x.example/ch/1');
      expect(StalkerRepository.stripCmd('ffrt http://x.example/1'),
          'http://x.example/1');
      expect(StalkerRepository.stripCmd('auto  http://x.example/1 '),
          'http://x.example/1');
      expect(StalkerRepository.stripCmd('http://x.example/1'),
          'http://x.example/1');
      expect(StalkerRepository.stripCmd(null), '');
    });
  });

  group('Stalker – Sender', () {
    final root = Uri.parse('http://p.example:8080/');

    test('Felder als String oder Zahl, relatives Logo', () {
      final js = {
        'js': {
          'total_items': 3,
          'data': [
            {
              'id': '101',
              'name': 'Das Erste HD',
              'number': '1',
              'cmd': 'ffmpeg http://localhost/ch/101',
              'logo': '/stalker_portal/misc/logos/320/101.png',
              'tv_genre_id': '5',
              'tv_archive': '1',
              'tv_archive_duration': '72',
            },
            {
              'id': 102,
              'name': 'ZDF',
              'number': 2,
              'cmd': 'ffrt http://localhost/ch/102',
              'logo': 'https://cdn.example/zdf.png',
              'tv_genre_id': 5,
              'tv_archive': 1,
              'tv_archive_duration': 0,
            },
            {
              'id': '103',
              'name': 'Arte',
              'cmd': 'http://cdn.example/arte.m3u8',
              'logo': '',
              'tv_archive': 0,
            },
            {'id': '104', 'name': 'ohne cmd'},
          ],
        },
      };
      final ch = StalkerRepository.parseChannels(js, root);
      expect(ch.length, 3);

      expect(ch[0].id, '101');
      expect(ch[0].epgId, '101');
      expect(ch[0].number, 1);
      expect(ch[0].categoryId, '5');
      expect(ch[0].streamUrl, 'ffmpeg http://localhost/ch/101');
      expect(ch[0].logoUrl,
          'http://p.example:8080/stalker_portal/misc/logos/320/101.png');
      expect(ch[0].catchupDays, 0); // Catch-up für MAC-Portale folgt später

      expect(ch[1].id, '102');
      expect(ch[1].number, 2);
      expect(ch[1].categoryId, '5');
      expect(ch[1].logoUrl, 'https://cdn.example/zdf.png');
      expect(ch[1].catchupDays, 0);

      expect(ch[2].logoUrl, isNull);
      expect(ch[2].catchupDays, 0);
      expect(ch[2].number, 0);
    });

    test('blockiert fremde Logo-Schemata', () {
      final ch = StalkerRepository.parseChannels([
        {'id': '1', 'name': 'x', 'cmd': 'c', 'logo': 'file:///etc/passwd'},
      ], root);
      expect(ch.single.logoUrl, isNull);
    });

    test('Genres ohne „Alle“', () {
      final g = StalkerRepository.parseGenres({
        'js': [
          {'id': '*', 'title': 'All'},
          {'id': 5, 'title': 'Deutschland'},
        ],
      });
      expect(g.map((c) => c.id), ['5']);
      expect(g.single.name, 'Deutschland');
    });
  });

  group('Stalker – EPG', () {
    final js = {
      'js': {
        'data': {
          '101': [
            {
              'name': 'Tagesschau',
              'descr': 'Nachrichten',
              'start_timestamp': '1700003600',
              'stop_timestamp': 1700004500,
            },
            {
              'name': 'Morgenmagazin',
              'start_timestamp': 1700000000,
              'stop_timestamp': '1700003600',
            },
          ],
          '102': [
            {
              'name': 'heute',
              'time': '2024-01-01 19:00:00',
              'time_to': '2024-01-01 19:20:00',
            },
            {'name': 'kaputt', 'start_timestamp': 0},
          ],
        },
      },
    };

    test('mappt und sortiert', () {
      final epg = StalkerRepository.parseEpg(js);
      expect(epg.keys.toSet(), {'101', '102'});
      expect(epg['101']!.map((e) => e.title), ['Morgenmagazin', 'Tagesschau']);
      expect(epg['101']![1].description, 'Nachrichten');
      expect(epg['101']![1].duration, const Duration(minutes: 15));
      expect(epg['101']!.first.channelEpgId, '101');
      expect(epg['102']!.single.duration, const Duration(minutes: 20));
    });

    test('Filter nach Sender-IDs', () {
      final epg = StalkerRepository.parseEpg(js, channelIds: {'102'});
      expect(epg.keys, ['102']);
    });

    test('leere/ungültige Antwort → leer', () {
      expect(StalkerRepository.parseEpg(null), isEmpty);
      expect(StalkerRepository.parseEpg({'js': []}), isEmpty);
    });
  });

  group('Stalker – Profil und Konto', () {
    test('profileError', () {
      expect(StalkerRepository.profileError({'js': {'id': '12', 'status': 0}}),
          isNull);
      expect(StalkerRepository.profileError({'id': 12}), isNull);
      expect(StalkerRepository.profileError({'js': {'id': '12', 'status': '1'}}),
          isNotNull);
      expect(StalkerRepository.profileError({'js': {'id': null}}), isNotNull);
      expect(StalkerRepository.profileError({'js': []}), isNotNull);
    });

    test('Ablaufdatum in verschiedenen Formaten', () {
      expect(StalkerRepository.parseExpiry('December 31, 2025, 11:59 pm'),
          DateTime(2025, 12, 31, 23, 59));
      expect(StalkerRepository.parseExpiry('2025-12-31 23:59:59'),
          DateTime(2025, 12, 31, 23, 59, 59));
      expect(StalkerRepository.parseExpiry('31.12.2025'),
          DateTime(2025, 12, 31, 23, 59));
      expect(StalkerRepository.parseExpiry('unbegrenzt'), isNull);
    });

    test('Kontoinfos', () {
      final a = StalkerRepository.parseAccount(
          {'js': {'phone': 'March 3, 2026', 'mac': '00:1A:79:00:00:01'}});
      expect(a!.expires, DateTime(2026, 3, 3, 23, 59));
      expect(a.status, 'Active');
    });
  });

  test('Catch-up und VOD vorerst nicht unterstützt', () {
    final r = StalkerRepository(const Portal(
        id: 's', name: 'S', type: PortalType.stalker,
        url: 'http://p.example/c/', username: '00:1A:79:00:00:01'));
    expect(r.supportsVod, isFalse);
    final c = const Channel(
        id: '1', name: 'x', categoryId: '', streamUrl: 'c', catchupDays: 3);
    final e = EpgEntry(
        channelEpgId: '1', title: 't',
        start: DateTime(2024), end: DateTime(2024, 1, 1, 1));
    expect(r.catchupUrl(c, e), isNull);
  });
}
