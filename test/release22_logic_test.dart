import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jason_stream_player/data/downloads/download_models.dart';
import 'package:jason_stream_player/data/downloads/download_queue.dart';
import 'package:jason_stream_player/data/downloads/download_rules.dart';
import 'package:jason_stream_player/data/downloads/download_transfer.dart';
import 'package:jason_stream_player/data/downloads/url_vault.dart';
import 'package:jason_stream_player/models/models.dart';

/// Fake-Server für Dateien: Range ja/nein, Abbruch nach N Bytes, Anhalten.
class FakeFileServer {
  final Map<String, Uint8List> files = {};
  bool supportsRange = true;

  /// Verbindung nach so vielen Bytes (je Antwort) abreißen lassen.
  int? dropAfter;

  /// Antworten so lange zurückhalten.
  Completer<void>? hold;
  int? status;
  String contentType = 'video/x-matroska';
  final requests = <http.BaseRequest>[];

  /// Bytes je Teilstück der Antwort.
  int chunk = 64 * 1024;

  late final client = MockClient.streaming((req, _) async {
    requests.add(req);
    if (status != null) {
      return http.StreamedResponse(Stream.value(utf8.encode('nein')), status!);
    }
    final key = req.url.path;
    final data = files[key];
    if (data == null) {
      return http.StreamedResponse(const Stream.empty(), 404);
    }
    var from = 0;
    var code = 200;
    final headers = <String, String>{'content-type': contentType};
    final range = req.headers['Range'];
    if (range != null && supportsRange) {
      from = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)![1]!);
      if (from >= data.length) {
        return http.StreamedResponse(const Stream.empty(), 416,
            headers: {'content-range': 'bytes */${data.length}'});
      }
      code = 206;
      headers['content-range'] = 'bytes $from-${data.length - 1}/${data.length}';
    }
    final body = data.sublist(from);
    final drop = dropAfter;
    Stream<List<int>> stream() async* {
      if (hold != null) await hold!.future;
      var sent = 0;
      for (var i = 0; i < body.length; i += chunk) {
        final end = (i + chunk).clamp(0, body.length);
        if (drop != null && sent + (end - i) > drop) {
          yield body.sublist(i, i + (drop - sent));
          throw const SocketExceptionLike();
        }
        sent += end - i;
        yield body.sublist(i, end);
        await Future<void>.delayed(Duration.zero);
      }
    }

    return http.StreamedResponse(stream(), code,
        contentLength: body.length, headers: headers);
  });
}

class SocketExceptionLike implements Exception {
  const SocketExceptionLike();
}

Uint8List _bytes(int n) =>
    Uint8List.fromList(List<int>.generate(n, (i) => (i * 7) & 0xff));

DownloadItem _item(String id,
        {String scope = 'p1',
        VodSource source = VodSource.portal,
        String url = '\u0000U\u0000/film.mkv',
        bool episode = false,
        String category = 'c1',
        bool adult = false}) =>
    DownloadItem(
      id: DownloadItem.idOf(scope, id),
      scope: scope,
      source: source,
      itemId: id,
      title: 'Film $id',
      categoryId: category,
      maskedUrl: url,
      ext: 'mkv',
      added: DateTime(2026, 10, 25),
      isEpisode: episode,
      adult: adult,
    );

/// Fake-Umgebung für die Warteschlange.
class FakeHost extends DownloadHost {
  final FakeFileServer server;
  FakeHost(this.server);

  DownloadEnv envValue = const DownloadEnv();
  int free = 50 * 1024 * 1024 * 1024;
  final sinks = <String, MemorySink>{};
  final deleted = <String>[];
  List<Map<String, Object?>> saved = const [];
  List<DownloadItem> initial = const [];
  Map<String, String> secrets = {'U': 'http://srv/movie/hans/geheim'};

  @override
  Future<List<DownloadItem>> load() async => initial;

  @override
  Future<void> save(List<DownloadItem> items) async {
    saved = [for (final d in items) d.toJson()];
  }

  @override
  Future<ResolvedUrl?> resolve(DownloadItem d, String maskedUrl) async {
    final u = UrlVault.unmask(maskedUrl, secrets);
    return u == null ? null : (url: u, headers: const <String, String>{});
  }

  @override
  Future<DownloadItem> prepare(DownloadItem d) async =>
      d.copyWith(path: '/dl/${d.itemId}.mkv');

  @override
  Future<DownloadSink> sinkFor(DownloadItem d) async =>
      sinks.putIfAbsent(d.id, MemorySink.new);

  @override
  Future<(String, DownloadSink)?> subtitleSink(
          DownloadItem d, DownloadSub s, int index) async =>
      ('/dl/${d.itemId}.$index.srt', sinks.putIfAbsent('${d.id}#$index', MemorySink.new));

  @override
  Future<int> freeSpace(DownloadItem d) async => free;

  @override
  Future<void> deleteFiles(DownloadItem d) async => deleted.add(d.id);

  @override
  DownloadEnv env() => envValue;

  @override
  http.Client get httpClient => server.client;
}

Future<void> _idle([int n = 30]) async {
  for (var i = 0; i < n; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('Platzhalter-Adressen', () {
    test('Zugangsdaten werden ersetzt und wieder eingesetzt', () {
      const url = 'http://srv:8080/movie/hans%20m/p%40ss!/123.mkv';
      final sec = UrlVault.secretsOf(username: 'hans m', password: 'p@ss!');
      final masked = UrlVault.mask(url, sec);
      expect(masked.contains('hans'), isFalse);
      expect(masked.contains('p%40ss'), isFalse);
      expect(UrlVault.unmask(masked, sec), url);
      expect(UrlVault.display(masked), 'http://srv:8080/movie/{Ue}/{Pe}/123.mkv');
    });

    test('Neue Zugangsdaten werden beim Fortsetzen eingesetzt', () {
      final old = UrlVault.secretsOf(username: 'anna', password: 'alt1');
      final masked = UrlVault.mask('http://s/movie/anna/alt1/5.mp4', old);
      final neu = UrlVault.secretsOf(username: 'anna', password: 'neu22');
      expect(UrlVault.unmask(masked, neu), 'http://s/movie/anna/neu22/5.mp4');
    });

    test('Fehlende Zugangsdaten → null statt halber Adresse', () {
      final masked = UrlVault.mask('http://e/Items/1/Download?api_key=tok123',
          UrlVault.secretsOf(token: 'tok123'));
      expect(masked.contains('tok123'), isFalse);
      expect(UrlVault.unmask(masked, const {}), isNull);
      expect(UrlVault.unmask(masked, UrlVault.secretsOf(token: 'xyz9')),
          'http://e/Items/1/Download?api_key=xyz9');
    });
  });

  group('Regeln', () {
    test('WLAN/Mobilfunk/Datensparmodus', () {
      DownloadWait r(
              {bool connected = true,
              bool cellular = false,
              bool metered = false,
              bool mobile = false,
              bool saver = false}) =>
          networkRule(
              connected: connected,
              cellular: cellular,
              metered: metered,
              mobileAllowed: mobile,
              dataSaverActive: saver);
      expect(r(), DownloadWait.none);
      expect(r(connected: false), DownloadWait.network);
      expect(r(cellular: true, metered: true), DownloadWait.cellular);
      expect(r(cellular: true, metered: true, mobile: true), DownloadWait.none);
      // Datensparmodus: Mobilfunk/Hotspot gesperrt, WLAN frei.
      expect(r(cellular: true, metered: true, mobile: true, saver: true),
          DownloadWait.dataSaver);
      expect(r(metered: true, saver: true), DownloadWait.dataSaver);
      expect(r(saver: true), DownloadWait.none);
    });

    test('Speicherplatz', () {
      const mb = 1024 * 1024;
      expect(enoughSpace(-1, 5000 * mb), isTrue); // unbekannt → versuchen
      expect(enoughSpace(2000 * mb, 1500 * mb), isTrue);
      expect(enoughSpace(1700 * mb, 1500 * mb), isFalse); // 300 MB Reserve
      expect(enoughSpace(1200 * mb, null), isFalse); // unbekannte Größe: 1 GB + Reserve
      expect(enoughSpace(1400 * mb, null), isTrue);
    });

    test('Verbindungslimit für Portal-Downloads', () {
      expect(portalDownloadSlots(setting: 2, maxConnections: null), 2);
      expect(portalDownloadSlots(setting: 2, maxConnections: 1), 1);
      expect(
          portalDownloadSlots(
              setting: 2, maxConnections: 1, otherConnections: 1),
          0);
      expect(portalDownloadSlots(setting: 2, maxConnections: 2), 2);
      expect(
          portalDownloadSlots(
              setting: 2, maxConnections: 2, keepLiveFree: true),
          1);
      expect(
          portalDownloadSlots(
              setting: 2,
              maxConnections: 3,
              otherConnections: 1,
              keepLiveFree: true),
          1);
      expect(
          portalDownloadSlots(
              setting: 1,
              maxConnections: 2,
              otherConnections: 1,
              keepLiveFree: true),
          0);
    });

    test('Kinderschutz und Erwachsenen-Sperre in der Liste', () {
      final film = _item('1', category: 'k');
      final serie = _item('2', category: 's9', episode: true);
      final adult = _item('3', adult: true);
      final emby = _item('4', scope: '__emby', source: VodSource.emby, category: 'lib');
      final other = _item('5', scope: 'p2', category: 'k');
      bool vis(DownloadItem d, {bool adultLocked = true, bool kids = false}) =>
          downloadVisible(d,
              adultLocked: adultLocked,
              kids: kids,
              portalId: 'p1',
              kidsVod: const {'m:k', 's:s9'},
              kidsEmby: const {'m:lib'});
      expect(vis(adult), isFalse);
      expect(vis(adult, adultLocked: false), isTrue);
      expect(vis(adult, adultLocked: false, kids: true), isFalse);
      expect(vis(film, kids: true), isTrue);
      expect(vis(serie, kids: true), isTrue);
      expect(vis(_item('6', category: 'x'), kids: true), isFalse);
      expect(vis(emby, kids: true), isTrue);
      expect(vis(other, kids: true), isFalse);
      expect(vis(other), isTrue);
    });

    test('Downloadbare Adressen und Dateinamen', () {
      expect(isDownloadableUrl('http://s/movie/u/p/1.mkv'), isTrue);
      expect(isDownloadableUrl('http://s/movie/u/p/1.m3u8'), isFalse);
      expect(isDownloadableUrl('file:///x/1.mkv'), isFalse);
      final d = _item('77').copyWith();
      expect(downloadFileName(d), 'Film 77 [77].mkv');
      final ep = DownloadItem(
          id: 'p|e1',
          scope: 'p',
          source: VodSource.portal,
          itemId: 'e1',
          title: 'Pilot: Teil/1',
          categoryId: 'c',
          maskedUrl: 'x',
          ext: 'mp4',
          added: DateTime(2026),
          isEpisode: true,
          seriesName: 'Die Serie',
          season: 1,
          episode: 2);
      expect(downloadFileName(ep), 'Die Serie S01E02 Pilot Teil 1 [e1].mp4');
    });

    test('JSON hin und zurück, laufend → wartet beim Neustart', () {
      final d = _item('9').copyWith(
          state: DownloadState.running,
          bytes: 100,
          total: 1000,
          rangeOk: true,
          subs: const [DownloadSub(maskedUrl: 'u', language: 'de')]);
      final back = DownloadItem.fromJson(jsonDecode(jsonEncode(d.toJson())))!;
      expect(back.state, DownloadState.queued);
      expect(back.bytes, 100);
      expect(back.total, 1000);
      expect(back.subs.single.language, 'de');
      expect(back.resumeKey, 'movie_9');
    });
  });

  group('Übertragung mit Range', () {
    late FakeFileServer server;
    setUp(() {
      server = FakeFileServer()..files['/f.mkv'] = _bytes(300000);
    });

    test('Neu: ganze Datei', () async {
      final sink = MemorySink();
      final o = await DownloadTransfer(server.client, blockSize: 50000).run(
          url: 'http://s/f.mkv', sink: sink, token: TransferToken());
      expect(o.end, TransferEnd.complete);
      expect(o.total, 300000);
      expect(sink.data.toBytes(), server.files['/f.mkv']);
      expect(server.requests.single.headers['Range'], isNull);
    });

    test('Abbruch mitten drin, dann Fortsetzen ab Position (206)', () async {
      final sink = MemorySink();
      server.dropAfter = 120000;
      final t = DownloadTransfer(server.client, blockSize: 30000);
      final o1 =
          await t.run(url: 'http://s/f.mkv', sink: sink, token: TransferToken());
      expect(o1.end, TransferEnd.failed);
      expect(o1.error, 'network');
      expect(sink.data.length, 120000);
      server.dropAfter = null;
      final o2 = await t.run(
          url: 'http://s/f.mkv',
          sink: sink,
          token: TransferToken(),
          knownTotal: o1.total);
      expect(o2.end, TransferEnd.complete);
      expect(o2.rangeOk, isTrue);
      expect(server.requests.last.headers['Range'], 'bytes=120000-');
      expect(sink.lastAppend, isTrue);
      expect(sink.data.toBytes(), server.files['/f.mkv']);
    });

    test('Server ohne Range → von vorne (Datei geleert)', () async {
      final sink = MemorySink();
      await sink.write(_bytes(50000));
      server.supportsRange = false;
      final o = await DownloadTransfer(server.client).run(
          url: 'http://s/f.mkv', sink: sink, token: TransferToken());
      expect(o.end, TransferEnd.complete);
      expect(o.rangeOk, isFalse);
      expect(sink.lastAppend, isFalse);
      expect(sink.data.toBytes(), server.files['/f.mkv']);
    });

    test('Ziel kann nicht anhängen (SAF) → von vorne', () async {
      final sink = MemorySink()..noAppend = true;
      await sink.write(_bytes(70000));
      final o = await DownloadTransfer(server.client).run(
          url: 'http://s/f.mkv', sink: sink, token: TransferToken());
      expect(o.end, TransferEnd.complete);
      expect(server.requests.first.headers['Range'], 'bytes=70000-');
      expect(server.requests.last.headers['Range'], isNull);
      expect(sink.data.toBytes(), server.files['/f.mkv']);
    });

    test('416 bei vollständiger Datei → fertig', () async {
      final sink = MemorySink();
      await sink.write(server.files['/f.mkv']!);
      final o = await DownloadTransfer(server.client).run(
          url: 'http://s/f.mkv', sink: sink, token: TransferToken());
      expect(o.end, TransferEnd.complete);
      expect(o.bytes, 300000);
    });

    test('Fehlercodes und keine Datei', () async {
      final t = DownloadTransfer(server.client);
      var o = await t.run(
          url: 'http://s/fehlt.mkv', sink: MemorySink(), token: TransferToken());
      expect(o.error, 'notfound');
      server.status = 401;
      o = await t.run(
          url: 'http://s/f.mkv', sink: MemorySink(), token: TransferToken());
      expect(o.error, 'auth');
      server.status = 429;
      o = await t.run(
          url: 'http://s/f.mkv', sink: MemorySink(), token: TransferToken());
      expect(o.error, 'busy');
      server.status = null;
      server.contentType = 'application/vnd.apple.mpegurl';
      o = await t.run(
          url: 'http://s/f.mkv', sink: MemorySink(), token: TransferToken());
      expect(o.error, 'notfile');
    });

    test('Anhalten behält die Teildatei', () async {
      final sink = MemorySink();
      final token = TransferToken();
      server.chunk = 10000;
      final f = DownloadTransfer(server.client, blockSize: 20000).run(
          url: 'http://s/f.mkv',
          sink: sink,
          token: token,
          onProgress: (b, _) {
            if (b > 0) token.stop();
          });
      final o = await f;
      expect(o.end, TransferEnd.stopped);
      expect(sink.data.length, o.bytes);
      expect(o.bytes, lessThan(300000));
      expect(o.bytes, greaterThanOrEqualTo(20000));
    });

    test('Keine Adresse in Fehlern (Zugangsdaten)', () async {
      server.status = 500;
      final o = await DownloadTransfer(server.client).run(
          url: 'http://s/movie/hans/geheim/f.mkv',
          sink: MemorySink(),
          token: TransferToken());
      expect(o.error, 'server');
      expect('${o.error}'.contains('geheim'), isFalse);
    });
  });

  group('Warteschlange', () {
    late FakeFileServer server;
    late FakeHost host;
    setUp(() {
      server = FakeFileServer();
      for (var i = 1; i <= 4; i++) {
        server.files['/movie/hans/geheim/$i.mkv'] = _bytes(200000 + i);
      }
      host = FakeHost(server);
    });

    DownloadItem film(int i) =>
        _item('$i', url: '\u0000U\u0000/$i.mkv');

    test('Einer nach dem anderen (Einstellung 1), Speicher ohne Zugangsdaten',
        () async {
      final q = DownloadQueue(host);
      server.hold = Completer<void>();
      await q.add([film(1), film(2)]);
      await _idle();
      expect(q.running, {'p1|1'});
      expect(q.byId('p1|2')!.state, DownloadState.queued);
      server.hold!.complete();
      server.hold = null;
      for (var i = 0; i < 50 && q.byId('p1|2')!.state != DownloadState.done; i++) {
        await _idle();
      }
      expect(q.byId('p1|1')!.state, DownloadState.done);
      expect(q.byId('p1|2')!.state, DownloadState.done);
      expect(host.sinks['p1|2']!.data.length, 200002);
      await q.flush();
      final saved = jsonEncode(host.saved);
      expect(saved.contains('geheim'), isFalse);
      expect(saved.contains('hans'), isFalse);
    });

    test('Zwei gleichzeitig (Einstellung 2)', () async {
      host.envValue = const DownloadEnv(concurrency: 2);
      server.hold = Completer<void>();
      final q = DownloadQueue(host);
      await q.add([film(1), film(2), film(3)]);
      await _idle();
      expect(q.running, {'p1|1', 'p1|2'});
      server.hold!.complete();
    });

    test('Nur WLAN: Mobilfunk wartet, WLAN startet', () async {
      host.envValue = const DownloadEnv(cellular: true, metered: true);
      final q = DownloadQueue(host);
      await q.add([film(1)]);
      await _idle();
      expect(q.byId('p1|1')!.state, DownloadState.waiting);
      expect(q.byId('p1|1')!.wait, DownloadWait.cellular);
      host.envValue = const DownloadEnv();
      await q.envChanged();
      for (var i = 0; i < 20 && q.byId('p1|1')!.state != DownloadState.done; i++) {
        await _idle();
      }
      expect(q.byId('p1|1')!.state, DownloadState.done);
    });

    test('WLAN weg während des Downloads → wartet, danach Fortsetzen per Range',
        () async {
      server.chunk = 20000;
      server.hold = Completer<void>();
      final q = DownloadQueue(host);
      await q.add([film(1)]);
      await _idle();
      server.hold!.complete();
      server.hold = null;
      await _idle(4);
      host.envValue = const DownloadEnv(connected: false);
      await q.envChanged();
      await _idle();
      final d = q.byId('p1|1')!;
      expect(d.state, DownloadState.waiting);
      expect(d.wait, DownloadWait.network);
      expect(d.bytes, greaterThan(0));
      expect(d.bytes, lessThan(200001));
      host.envValue = const DownloadEnv();
      await q.envChanged();
      for (var i = 0; i < 40 && q.byId('p1|1')!.state != DownloadState.done; i++) {
        await _idle();
      }
      expect(q.byId('p1|1')!.state, DownloadState.done);
      expect(server.requests.last.headers['Range'], 'bytes=${d.bytes}-');
      expect(host.sinks['p1|1']!.data.toBytes(),
          server.files['/movie/hans/geheim/1.mkv']);
    });

    test('Zu wenig Platz → wartet', () async {
      host.free = 100 * 1024 * 1024;
      final q = DownloadQueue(host);
      await q.add([film(1)]);
      await _idle();
      expect(q.byId('p1|1')!.wait, DownloadWait.space);
      expect(server.requests, isEmpty);
    });

    test('Anbieter mit 1 Verbindung und laufender Aufnahme → wartet', () async {
      var busy = 1;
      host.envValue = DownloadEnv(
          maxConnections: (_) => 1, busyConnections: (_) => busy);
      final q = DownloadQueue(host);
      await q.add([film(1)]);
      await _idle();
      expect(q.byId('p1|1')!.wait, DownloadWait.connections);
      busy = 0;
      await q.envChanged();
      for (var i = 0; i < 20 && q.byId('p1|1')!.state != DownloadState.done; i++) {
        await _idle();
      }
      expect(q.byId('p1|1')!.state, DownloadState.done);
    });

    test('Fehlende Zugangsdaten → gescheitert, ohne Anfrage', () async {
      host.secrets = const {};
      final q = DownloadQueue(host);
      await q.add([film(1)]);
      await _idle();
      expect(q.byId('p1|1')!.state, DownloadState.failed);
      expect(q.byId('p1|1')!.error, 'credentials');
      expect(server.requests, isEmpty);
    });

    test('Netzfehler → neuer Versuch nach Pause, 404 → endgültig', () {
      fakeAsync((fa) {
        server.dropAfter = 50000;
        final q = DownloadQueue(host);
        q.add([film(1)]);
        fa.elapse(const Duration(seconds: 1));
        var d = q.byId('p1|1')!;
        expect(d.state, DownloadState.waiting);
        expect(d.wait, DownloadWait.retry);
        expect(d.attempts, 1);
        server.dropAfter = null;
        fa.elapse(const Duration(seconds: 6));
        d = q.byId('p1|1')!;
        expect(d.state, DownloadState.done);
        expect(server.requests.last.headers['Range'], 'bytes=50000-');

        server.files.remove('/movie/hans/geheim/2.mkv');
        q.add([film(2)]);
        fa.elapse(const Duration(seconds: 1));
        expect(q.byId('p1|2')!.state, DownloadState.failed);
        expect(q.byId('p1|2')!.error, 'notfound');
        q.dispose();
      });
    });

    test('Pause, Fortsetzen, Löschen', () async {
      server.chunk = 10000;
      server.hold = Completer<void>();
      final q = DownloadQueue(host);
      await q.add([film(1), film(2)]);
      await _idle();
      await q.pause('p1|1');
      await _idle();
      expect(q.byId('p1|1')!.state, DownloadState.paused);
      // Der nächste rückt nach.
      expect(q.running, {'p1|2'});
      await q.remove('p1|2');
      expect(q.byId('p1|2'), isNull);
      expect(host.deleted, ['p1|2']);
      server.hold!.complete();
      server.hold = null;
      await q.resume('p1|1');
      for (var i = 0; i < 30 && q.byId('p1|1')!.state != DownloadState.done; i++) {
        await _idle();
      }
      expect(q.byId('p1|1')!.state, DownloadState.done);
    });

    test('Untertitel werden mitgeladen', () async {
      server.files['/sub/0.srt'] = Uint8List.fromList(utf8.encode('1\n00:00'));
      final q = DownloadQueue(host);
      await q.add([
        film(1).copyWith(subs: const [
          DownloadSub(maskedUrl: 'http://srv/sub/0.srt', language: 'de')
        ])
      ]);
      for (var i = 0; i < 30 && q.byId('p1|1')!.state != DownloadState.done; i++) {
        await _idle();
      }
      final d = q.byId('p1|1')!;
      expect(d.state, DownloadState.done);
      expect(d.subs.single.path, '/dl/1.0.srt');
    });

    test('Gespeicherter Stand wird geladen, laufende wieder gestartet', () async {
      host.initial = [
        film(1).copyWith(state: DownloadState.done, bytes: 5, total: 5),
        DownloadItem.fromJson(
            jsonDecode(jsonEncode(film(2).copyWith(state: DownloadState.running).toJson())))!,
      ];
      final q = DownloadQueue(host);
      await q.init();
      for (var i = 0; i < 30 && q.byId('p1|2')!.state != DownloadState.done; i++) {
        await _idle();
      }
      expect(q.byId('p1|1')!.state, DownloadState.done);
      expect(q.byId('p1|2')!.state, DownloadState.done);
    });
  });
}
