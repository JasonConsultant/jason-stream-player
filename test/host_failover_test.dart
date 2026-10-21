import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jason_stream_player/data/host_failover.dart';
import 'package:jason_stream_player/data/m3u_repository.dart';
import 'package:jason_stream_player/data/net.dart';
import 'package:jason_stream_player/data/repository.dart';
import 'package:jason_stream_player/data/xtream_repository.dart';
import 'package:jason_stream_player/models/models.dart';

/// Ersatz-Adressen: Fällt der Hauptserver aus (Zeitüberschreitung,
/// Verbindungsfehler, 5xx), wird automatisch die nächste Adresse genommen
/// und gemerkt – für API und Streams. Falsche Zugangsdaten (401/403) lösen
/// keinen Wechsel aus. Dazu: Header aus „Erweitert“ gehen an den Server.
void main() {
  const xtream = Portal(
    id: 'x1',
    name: 'X',
    type: PortalType.xtream,
    url: 'http://main.tv:8080',
    username: 'u',
    password: 'p',
    altUrls: ['http://backup1.tv:8080', 'http://backup2.tv'],
    userAgent: 'MyUA',
    referer: 'https://ref.tv/',
  );

  final requests = <http.Request>[];
  final persisted = <String, int>{};

  String okLogin() => jsonEncode({
        'user_info': {'auth': 1, 'status': 'Active', 'exp_date': null},
      });

  setUp(() {
    HostFailover.reset();
    requests.clear();
    persisted.clear();
    HostFailover.persist = (id, i) => persisted[id] = i;
  });

  tearDown(() {
    Net.client = http.Client();
    HostFailover.persist = null;
  });

  test('Hauptserver: Zeitüberschreitung → Ersatz 1: 500 → Ersatz 2 klappt',
      () async {
    Net.client = MockClient((req) async {
      requests.add(req);
      switch (req.url.host) {
        case 'main.tv':
          throw TimeoutException('zu langsam');
        case 'backup1.tv':
          return http.Response('kaputt', 502);
        default:
          return http.Response(okLogin(), 200);
      }
    });
    final repo = XtreamRepository(xtream);
    final acc = await repo.login();
    expect(acc?.status, 'Active');
    expect([for (final r in requests) r.url.host],
        ['main.tv', 'backup1.tv', 'backup2.tv']);
    // Gemerkt (auch dauerhaft) …
    expect(HostFailover.activeBase(xtream), 'http://backup2.tv');
    expect(persisted['x1'], 2);
    // … und beim nächsten Mal zuerst probiert.
    requests.clear();
    await repo.login();
    expect([for (final r in requests) r.url.host], ['backup2.tv']);
    // Portal-Header (User-Agent, Referer) gehen mit.
    expect(requests.single.headers['User-Agent'], 'MyUA');
    expect(requests.single.headers['Referer'], 'https://ref.tv/');
  });

  test('Streams werden auf die funktionierende Adresse umgeschrieben',
      () async {
    HostFailover.restore('x1', 1);
    final repo = XtreamRepository(xtream);
    const c = Channel(
        id: '7',
        name: 'A',
        categoryId: '1',
        streamUrl: 'http://main.tv:8080/live/u/p/7.ts');
    expect(await repo.resolveStreamUrl(c),
        'http://backup1.tv:8080/live/u/p/7.ts');
    expect(HostFailover.streamCandidates(xtream, c.streamUrl), [
      'http://backup1.tv:8080/live/u/p/7.ts',
      'http://main.tv:8080/live/u/p/7.ts',
      'http://backup2.tv/live/u/p/7.ts',
    ]);
    // Fremde Server (z. B. CDN) bleiben unverändert.
    expect(HostFailover.rewrite(xtream, 'http://cdn.other/x.ts'),
        'http://cdn.other/x.ts');
  });

  test('Falsche Zugangsdaten (403) → kein Wechsel auf Ersatz-Adressen',
      () async {
    Net.client = MockClient((req) async {
      requests.add(req);
      return http.Response('nein', 403);
    });
    await expectLater(XtreamRepository(xtream).login(),
        throwsA(isA<RepositoryException>()));
    expect(requests.length, 1);
    expect(HostFailover.activeIndex(xtream), 0);
  });

  test('Alle Adressen tot → erster Fehler wird gemeldet', () async {
    Net.client = MockClient((req) async {
      requests.add(req);
      throw http.ClientException('Connection refused', req.url);
    });
    await expectLater(
        XtreamRepository(xtream).login(), throwsA(isA<http.ClientException>()));
    expect(requests.length, 3);
  });

  test('M3U: Spiegel-Playlist, Streams auf gleichem Server umgeschrieben',
      () async {
    const m3u = Portal(
      id: 'm1',
      name: 'M',
      type: PortalType.m3u,
      url: 'http://list.tv/get.php?u=1',
      altUrls: ['http://mirror.tv:81/get.php?u=1'],
    );
    Net.client = MockClient((req) async {
      requests.add(req);
      if (req.url.host == 'list.tv') return http.Response('weg', 503);
      return http.Response(
          '#EXTM3U\n#EXTINF:-1,Eins\nhttp://list.tv/live/1.ts\n'
          '#EXTINF:-1,Zwei\nhttp://cdn.other/2.ts\n',
          200);
    });
    final repo = M3uRepository(m3u);
    final chans = await repo.liveChannels();
    expect(chans.length, 2);
    expect(HostFailover.activeIndex(m3u), 1);
    expect(await repo.resolveStreamUrl(chans[0]), 'http://mirror.tv:81/live/1.ts');
    expect(await repo.resolveStreamUrl(chans[1]), 'http://cdn.other/2.ts');
  });

  test('Fehlerarten', () {
    expect(HostFailover.isHostFailure(TimeoutException('x')), isTrue);
    expect(HostFailover.isHostFailure(RepositoryException('x', statusCode: 500)),
        isTrue);
    expect(HostFailover.isHostFailure(RepositoryException('x', statusCode: 404)),
        isTrue);
    expect(HostFailover.isHostFailure(RepositoryException('x', statusCode: 401)),
        isFalse);
    expect(HostFailover.isHostFailure(RepositoryException('x')), isFalse);
    expect(HostFailover.isHostFailure(const FormatException('json')), isFalse);
  });
}
