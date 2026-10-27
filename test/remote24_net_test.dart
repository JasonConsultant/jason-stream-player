import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jason_stream_player/core/remote/crypto.dart';
import 'package:jason_stream_player/core/remote/net.dart';
import 'package:jason_stream_player/core/remote/pairing.dart';
import 'package:jason_stream_player/core/remote/peers.dart';
import 'package:jason_stream_player/core/remote/protocol.dart';
import 'package:jason_stream_player/core/remote/transport.dart';

/// 2.4: TV-Server + Handy-Verbindung über Loopback (ohne NSD).
class FakeHost implements RemoteTvHost {
  final phones = <String, RemotePeer>{};
  final received = <Map<String, Object?>>[];
  final codes = StreamController<String>.broadcast();
  String? shownCode;
  bool pairedShown = false;
  final connectedIds = <String>[];
  final disconnectedIds = <String>[];
  Completer<void>? slowReq;

  @override
  String get tvId => 'tv-1';
  @override
  String get tvName => 'Wohnzimmer';
  @override
  Map<String, Object?> get caps => {'volume': true};

  @override
  RemotePeer? phone(String id) => phones[id];

  @override
  Future<void> addPhone(RemotePeer p) async => phones[p.id] = p;

  @override
  void showPairingCode(String code, String phoneName) {
    shownCode = code;
    codes.add(code);
  }

  @override
  void hidePairingCode({bool paired = false, String? phoneName}) {
    shownCode = null;
    pairedShown = paired;
  }

  @override
  void connected(String id) => connectedIds.add(id);
  @override
  void disconnected(String id) => disconnectedIds.add(id);

  @override
  Future<Map<String, Object?>?> handle(
      String id, Map<String, Object?> msg) async {
    received.add(msg);
    if (msg['t'] != 'req') return null;
    switch (msg['m']) {
      case 'echo':
        return {'ok': true, 'v': msg['v']};
      case 'slow':
        await (slowReq = Completer<void>()).future;
        return {'ok': true};
    }
    return {'err': RemoteError.bad};
  }
}

void main() {
  late FakeHost host;
  late RemoteServerHandle server;

  Future<RemoteConnection> connect() => connectRemote('127.0.0.1', server.port,
      allowLoopback: true);

  setUp(() async {
    host = FakeHost();
    server = await startRemoteServer(host,
        bindAddress: InternetAddress.loopbackIPv4,
        pairGate: FailureGate(maxFails: 2));
  });

  tearDown(() async {
    await server.close();
  });

  Future<Uint8List> pairOk() async {
    final c = await connect();
    expect(c.hello.tvId, 'tv-1');
    expect(c.hello.name, 'Wohnzimmer');
    final codeF = host.codes.stream.first;
    final flow = await c.pair('ph-1', 'Pixel 9');
    final code = await codeF;
    expect(PairingMath.validCode(code), isTrue);
    final key = await flow.submit(code);
    expect(host.phones['ph-1']!.key, key);
    expect(host.phones['ph-1']!.name, 'Pixel 9');
    expect(host.pairedShown, isTrue);
    return key;
  }

  test('Koppeln mit Code, danach verschlüsselte Anfragen und Tasten', () async {
    final key = await pairOk();
    final c = await connect();
    await c.authenticate('ph-1', key);
    expect(c.ready['name'], 'Wohnzimmer');
    expect((c.ready['caps'] as Map)['volume'], isTrue);
    final r = await c.request('echo', {'v': 'hallo'});
    expect(r['ok'], isTrue);
    expect(r['v'], 'hallo');
    await c.send({'t': 'key', 'k': 'down', 'a': 'tap'});
    await c.send({'t': 'key', 'k': 'ok', 'a': 'tap'});
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(host.received.where((m) => m['t'] == 'key').map((m) => m['k']),
        ['down', 'ok']);
    expect(host.connectedIds, ['ph-1']);
    expect(server.clients, 1);
    // TV → Handy: Status-Ereignis.
    final ev = c.events.first;
    await server.broadcast({'t': 'status', 'kind': 'live', 'title': 'ZDF'});
    expect((await ev)['title'], 'ZDF');
    await c.close();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(host.disconnectedIds, ['ph-1']);
  });

  test('lange Anfrage (PIN am TV) blockiert die Tasten dahinter nicht',
      () async {
    final key = await pairOk();
    final c = await connect();
    await c.authenticate('ph-1', key);
    final slow = c.request('slow', const {}, const Duration(seconds: 5));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await c.send({'t': 'key', 'k': '1', 'a': 'tap'});
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(host.received.last['k'], '1');
    host.slowReq!.complete();
    expect((await slow)['ok'], isTrue);
    await c.close();
  });

  test('falscher Code → abgelehnt, nach 2 Fehlern gesperrt', () async {
    for (var i = 0; i < 2; i++) {
      final c = await connect();
      final codeF = host.codes.stream.first;
      final flow = await c.pair('ph-x', 'Fremd');
      final code = await codeF;
      final wrong = code == '9999' ? '0000' : '9999';
      await expectLater(flow.submit(wrong),
          throwsA(isA<RemoteRejected>().having((e) => e.reason, 'r', 'code')));
      expect(host.phones, isEmpty);
    }
    final c = await connect();
    await expectLater(c.pair('ph-x', 'Fremd'),
        throwsA(isA<RemoteRejected>()
            .having((e) => e.reason, 'r', 'locked')
            .having((e) => e.lockedFor!.inSeconds, 's', greaterThan(30))));
  });

  test('nicht gekoppelt bzw. falscher Schlüssel → keine Befehle', () async {
    final c = await connect();
    await expectLater(c.authenticate('nobody', RemoteCrypto.random(32)),
        throwsA(isA<RemoteRejected>().having((e) => e.reason, 'r', 'unknown')));
    await pairOk();
    final c2 = await connect();
    await expectLater(c2.authenticate('ph-1', RemoteCrypto.random(32)),
        throwsA(isA<RemoteRejected>().having((e) => e.reason, 'r', 'unknown')));
    expect(host.received, isEmpty);
    expect(host.connectedIds, isEmpty);
  });

  test('zu viele falsche Anmeldungen von einer Adresse → gesperrt', () async {
    for (var i = 0; i < 5; i++) {
      final c = await connect();
      await expectLater(c.authenticate('nobody', RemoteCrypto.random(32)),
          throwsA(isA<RemoteRejected>()));
    }
    final key = await pairOk();
    final c = await connect();
    // Auch der richtige Schlüssel muss jetzt warten.
    await expectLater(c.authenticate('ph-1', key),
        throwsA(isA<RemoteRejected>().having((e) => e.reason, 'r', 'locked')));
  });

  test('roher Client: Klartext-Befehl ohne Anmeldung und wiederholter '
      'Rahmen trennen die Verbindung', () async {
    final key = await pairOk();
    // 1) Befehl ohne Anmeldung.
    var ws = await WebSocket.connect(
        'ws://127.0.0.1:${server.port}$remotePath');
    final it = StreamIterator(ws);
    expect(await it.moveNext(), isTrue); // hello
    ws.add(jsonEncode({'t': 'key', 'k': 'ok', 'a': 'tap'}));
    expect(await it.moveNext().timeout(const Duration(seconds: 2)), isFalse);
    expect(host.received, isEmpty);

    // 2) Anmelden, gültigen Rahmen zweimal schicken.
    ws = await WebSocket.connect('ws://127.0.0.1:${server.port}$remotePath');
    final it2 = StreamIterator(ws);
    expect(await it2.moveNext(), isTrue);
    final hello = jsonDecode(it2.current as String) as Map<String, Object?>;
    final tvNonce = RemoteCrypto.unb64(hello['n'])!;
    final n = RemoteCrypto.random(16);
    ws.add(jsonEncode({
      't': 'auth',
      'id': 'ph-1',
      'n': RemoteCrypto.b64(n),
      'mac': RemoteCrypto.b64(RemoteCrypto.authMac(key,
          tvId: 'tv-1', deviceId: 'ph-1', tvNonce: tvNonce, phoneNonce: n)),
    }));
    expect(await it2.moveNext(), isTrue); // ready (verschlüsselt)
    final keys = RemoteCrypto.sessionKeys(key, tvNonce, n);
    final out = FrameCipher(keys.toTv);
    final frame =
        await out.seal(utf8.encode(jsonEncode({'t': 'key', 'k': 'up', 'a': 'tap'})));
    ws.add(frame);
    ws.add(frame); // Wiederholung
    expect(await it2.moveNext().timeout(const Duration(seconds: 2)), isFalse);
    expect(host.received.where((m) => m['k'] == 'up').length, 1);
  });

  test('falscher Pfad / kein WebSocket → 404', () async {
    final client = HttpClient();
    final req = await client.get('127.0.0.1', server.port, '/');
    final res = await req.close();
    expect(res.statusCode, 404);
    client.close(force: true);
  });

  test('Handy verbindet nie zu öffentlichen Adressen', () async {
    await expectLater(connectRemote('8.8.8.8', 80),
        throwsA(isA<RemoteRejected>()));
    await expectLater(connectRemote('127.0.0.1', server.port),
        throwsA(isA<RemoteRejected>()));
  });

  test('Gerät entfernt → Verbindung getrennt, Anmeldung danach abgelehnt',
      () async {
    final key = await pairOk();
    final c = await connect();
    await c.authenticate('ph-1', key);
    host.phones.clear();
    server.disconnect('ph-1');
    await c.done.timeout(const Duration(seconds: 2));
    expect(c.isOpen, isFalse);
    final c2 = await connect();
    await expectLater(c2.authenticate('ph-1', key),
        throwsA(isA<RemoteRejected>().having((e) => e.reason, 'r', 'unknown')));
  });
}
