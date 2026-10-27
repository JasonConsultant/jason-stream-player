import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'crypto.dart';
import 'lan.dart';
import 'pairing.dart';
import 'peers.dart';
import 'protocol.dart';
import 'transport.dart';

export 'lan.dart' show findPrivateLanAddress, isPrivateLan;

/// Netz-Teil der Handy-Fernbedienung (`dart:io`): WebSocket-Server am
/// Fernseher und Verbindung vom Handy.

/// Server am Fernseher starten. [bindAddress] nur für Tests (Loopback);
/// sonst die private WLAN-/LAN-Adresse – ohne private Adresse startet er
/// nicht (wirft [StateError]).
Future<RemoteServerHandle> startRemoteServer(RemoteTvHost host,
    {InternetAddress? bindAddress,
    FailureGate? pairGate,
    FailureGate? authGate,
    Duration pairTimeout = const Duration(minutes: 3)}) async {
  final address = bindAddress ?? await findPrivateLanAddress();
  if (address == null) throw StateError('no private network');
  if (!address.isLoopback && !isPrivateLan(address)) {
    throw StateError('not a private address');
  }
  final server = await HttpServer.bind(address, 0);
  server
    ..autoCompress = false
    ..idleTimeout = const Duration(seconds: 20)
    ..serverHeader = null;
  return _RemoteServer(server, host, address.isLoopback,
      pairGate ?? FailureGate(),
      authGate ??
          FailureGate(
              maxFails: 5,
              baseLock: const Duration(minutes: 5),
              maxLock: const Duration(hours: 1)),
      pairTimeout);
}

class _RemoteServer implements RemoteServerHandle {
  final HttpServer _server;
  final RemoteTvHost host;
  final bool _loopback;
  final FailureGate pairGate;
  final FailureGate authGate;
  final Duration pairTimeout;
  final _conns = <_TvConn>{};

  /// Läuft gerade eine Kopplung (nur eine gleichzeitig)?
  _TvConn? pairing;
  static const _maxConns = 8;

  _RemoteServer(this._server, this.host, this._loopback, this.pairGate,
      this.authGate, this.pairTimeout) {
    _server.listen((req) {
      _accept(req).catchError((Object _) {});
    }, onError: (Object _) {});
  }

  @override
  int get port => _server.port;

  @override
  String get address => _server.address.address;

  @override
  int get clients => _conns.where((c) => c.deviceId != null).length;

  Future<void> _accept(HttpRequest req) async {
    final peer = req.connectionInfo?.remoteAddress;
    if (peer == null || !isAllowedPeer(peer, loopbackServer: _loopback)) {
      req.response.statusCode = HttpStatus.forbidden;
      await req.response.close();
      return;
    }
    if (req.uri.path != remotePath ||
        !WebSocketTransformer.isUpgradeRequest(req) ||
        _conns.length >= _maxConns) {
      req.response.statusCode = HttpStatus.notFound;
      await req.response.close();
      return;
    }
    final ws = await WebSocketTransformer.upgrade(req);
    ws.pingInterval = const Duration(seconds: 10);
    final c = _TvConn(this, ws, peer.address);
    _conns.add(c);
    c.start();
  }

  void _gone(_TvConn c) {
    _conns.remove(c);
    if (identical(pairing, c)) {
      pairing = null;
      host.hidePairingCode();
    }
  }

  @override
  Future<void> broadcast(Map<String, Object?> msg) async {
    for (final c in _conns.toList()) {
      if (c.deviceId != null) unawaited(c.sendSecure(msg));
    }
  }

  @override
  void disconnect(String deviceId) {
    for (final c in _conns.toList()) {
      if (c.deviceId == deviceId) c.close();
    }
  }

  @override
  Future<void> close() async {
    for (final c in _conns.toList()) {
      c.close();
    }
    await _server.close(force: true);
  }
}

/// Eine Verbindung am Fernseher.
class _TvConn {
  final _RemoteServer s;
  final WebSocket ws;
  final String ip;
  final Uint8List nonce = RemoteCrypto.random(16);
  String? deviceId;
  SecureChannel? _chan;
  TvPairing? _pair;
  String _pairName = '';
  Timer? _timer;
  bool _closed = false;
  Future<void> _sendChain = Future.value();
  Future<void> _rx = Future.value();

  _TvConn(this.s, this.ws, this.ip);

  void start() {
    _sendPlain({
      't': 'hello',
      'v': remoteProtocolVersion,
      'id': s.host.tvId,
      'name': s.host.tvName,
      'n': RemoteCrypto.b64(nonce),
    });
    // Ohne Anmeldung nicht lange offen halten.
    _timer = Timer(const Duration(seconds: 15), close);
    // Nacheinander verarbeiten (Reihenfolge der Tasten, Zähler).
    ws.listen((d) => _rx = _rx.then((_) => _onData(d)),
        onDone: _onDone, onError: (Object _) => close(), cancelOnError: true);
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _timer?.cancel();
    ws.close(WebSocketStatus.normalClosure).catchError((Object _) {});
    _onDone();
  }

  bool _doneSent = false;
  void _onDone() {
    _closed = true;
    _timer?.cancel();
    if (_doneSent) return;
    _doneSent = true;
    s._gone(this);
    final id = deviceId;
    if (id != null) s.host.disconnected(id);
  }

  void _sendPlain(Map<String, Object?> m) {
    if (_closed) return;
    _sendChain = _sendChain.then((_) {
      if (!_closed) ws.add(jsonEncode(m));
    }).catchError((Object _) {});
  }

  /// Verschlüsselt senden – nacheinander, damit die Zähler in Reihenfolge
  /// ankommen.
  Future<void> sendSecure(Map<String, Object?> m) {
    final ch = _chan;
    if (ch == null || _closed) return Future.value();
    return _sendChain = _sendChain.then((_) async {
      if (_closed) return;
      final f = await ch.encode(m);
      if (!_closed) ws.add(f);
    }).catchError((Object _) {});
  }

  Future<void> _onData(dynamic data) async {
    if (_closed) return;
    final len = data is String ? data.length : (data as List<int>).length;
    if (len > remoteMaxMessage) {
      close();
      return;
    }
    try {
      if (_chan != null) {
        if (data is! List<int>) return close();
        await _onSecure(data);
      } else {
        if (data is! String) return close();
        final j = jsonDecode(data);
        if (j is! Map<String, Object?>) return close();
        await _onPlain(j);
      }
    } on FrameRejected {
      close();
    } on FormatException {
      close();
    } on PairingFailed catch (e) {
      _pairFailed(e.wrongCode);
    } on RemoteCryptoException {
      close();
    }
  }

  Future<void> _onPlain(Map<String, Object?> m) async {
    switch (m['t']) {
      case 'auth':
        return _auth(m);
      case 'pair':
        return _pairStart(m);
      case 'pc':
        final p = _pair, i = Wire.integer(m, 'i', max: 3);
        final c = RemoteCrypto.unb64(m['c'], length: 32);
        if (p == null || i == null || c == null) return close();
        _sendPlain({'t': 'tc', 'i': i, 'c': RemoteCrypto.b64(p.onPhoneCommit(i, c))});
      case 'pr':
        final p = _pair, i = Wire.integer(m, 'i', max: 3);
        final r = RemoteCrypto.unb64(m['r'], length: 16);
        if (p == null || i == null || r == null) return close();
        _sendPlain({'t': 'tr', 'i': i, 'r': RemoteCrypto.b64(p.onPhoneReveal(i, r))});
      case 'pok':
        final p = _pair;
        final mac = RemoteCrypto.unb64(m['mac'], length: 32);
        if (p == null || mac == null || !p.roundsDone) return close();
        final reply = p.onPhoneConfirm(mac);
        await s.host.addPhone(RemotePeer(
            id: p.deviceId,
            name: _pairName,
            key: p.deviceKey,
            pairedAt: DateTime.now()));
        s.pairGate.success('pair');
        _pair = null;
        if (identical(s.pairing, this)) s.pairing = null;
        s.host.hidePairingCode(paired: true, phoneName: _pairName);
        _sendPlain({'t': 'pok', 'mac': RemoteCrypto.b64(reply)});
        // Handy meldet sich danach neu an.
        Timer(const Duration(milliseconds: 300), close);
      default:
        close();
    }
  }

  Future<void> _auth(Map<String, Object?> m) async {
    final gateKey = 'auth:$ip';
    final locked = s.authGate.lockedFor(gateKey);
    if (locked != null) {
      _sendPlain({'t': 'locked', 's': locked.inSeconds + 1});
      return _closeSoon();
    }
    final id = Wire.str(m, 'id', max: 64);
    final n = RemoteCrypto.unb64(m['n'], length: 16);
    final mac = RemoteCrypto.unb64(m['mac'], length: 32);
    if (id == null || n == null || mac == null) return close();
    final peer = s.host.phone(id);
    if (peer == null) {
      s.authGate.fail(gateKey);
      _sendPlain({'t': 'unknown'});
      return _closeSoon();
    }
    final expect = RemoteCrypto.authMac(peer.key,
        tvId: s.host.tvId, deviceId: id, tvNonce: nonce, phoneNonce: n);
    if (!RemoteCrypto.equals(expect, mac)) {
      s.authGate.fail(gateKey);
      _sendPlain({'t': 'unknown'});
      return _closeSoon();
    }
    s.authGate.success(gateKey);
    final keys = RemoteCrypto.sessionKeys(peer.key, nonce, n);
    _chan = SecureChannel(sendKey: keys.toPhone, receiveKey: keys.toTv);
    deviceId = id;
    _timer?.cancel();
    _timer = null;
    await sendSecure({'t': 'ready', 'name': s.host.tvName, 'caps': s.host.caps});
    s.host.connected(id);
  }

  Future<void> _pairStart(Map<String, Object?> m) async {
    final locked = s.pairGate.lockedFor('pair');
    if (locked != null) {
      _sendPlain({'t': 'locked', 's': locked.inSeconds + 1});
      return _closeSoon();
    }
    if (s.pairing != null && !identical(s.pairing, this)) {
      _sendPlain({'t': 'busy'});
      return _closeSoon();
    }
    final id = Wire.str(m, 'id', max: 64);
    final pk = RemoteCrypto.unb64(m['pk'], length: 32);
    if (id == null || id.isEmpty || pk == null || _pair != null) return close();
    var name = (Wire.str(m, 'name', max: 200) ?? '').trim();
    if (name.length > 60) name = name.substring(0, 60);
    _pairName = name.isEmpty ? 'Android' : name;
    s.pairing = this;
    _pair = await TvPairing.start(
        tvId: s.host.tvId, deviceId: id, phonePub: pk);
    _timer?.cancel();
    _timer = Timer(s.pairTimeout, close);
    _sendPlain({'t': 'pairKey', 'pk': RemoteCrypto.b64(_pair!.tvPub)});
    s.host.showPairingCode(_pair!.code, _pairName);
  }

  void _pairFailed(bool wrongCode) {
    if (wrongCode) s.pairGate.fail('pair');
    _pair = null;
    _sendPlain({'t': wrongCode ? 'pairFail' : 'protocol'});
    _closeSoon();
  }

  void _closeSoon() {
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 200), close);
  }

  Future<void> _onSecure(List<int> frame) async {
    final m = await _chan!.decode(frame);
    final id = deviceId;
    if (id == null) return;
    if (m['t'] != 'req') {
      // Tasten/Text: in Reihenfolge, sofort.
      await s.host.handle(id, m);
      return;
    }
    // Anfragen können dauern (PIN-Abfrage am Fernseher beim Umschalten) –
    // nicht die Tasten dahinter blockieren (die PIN kommt evtl. per
    // Zifferntasten vom Handy).
    final rid = Wire.integer(m, 'id');
    if (rid == null) return;
    unawaited(() async {
      Map<String, Object?>? res;
      try {
        res = await s.host.handle(id, m);
      } catch (_) {
        res = null;
      }
      await sendSecure({
        ...(res ?? {'err': RemoteError.bad}),
        't': 'res',
        'id': rid,
      });
    }());
  }
}

// ---------------------------------------------------------------------------
// Handy

/// Mit einem Fernseher verbinden (wartet auf dessen Begrüßung).
/// [host] muss eine private Adresse sein (oder Loopback in Tests).
Future<RemoteConnection> connectRemote(String host, int port,
    {Duration timeout = const Duration(seconds: 5),
    bool allowLoopback = false}) async {
  final addr = InternetAddress.tryParse(host);
  if (addr == null ||
      !(isPrivateLan(addr) || (allowLoopback && addr.isLoopback))) {
    throw const RemoteRejected('address');
  }
  final h = addr.type == InternetAddressType.IPv6 ? '[$host]' : host;
  final ws = await WebSocket.connect('ws://$h:$port$remotePath')
      .timeout(timeout);
  ws.pingInterval = const Duration(seconds: 10);
  final c = _PhoneConn(ws);
  try {
    await c._helloDone.future.timeout(timeout);
  } catch (e) {
    await c.close();
    rethrow;
  }
  return c;
}

class _PhoneConn implements RemoteConnection {
  final WebSocket ws;
  final _helloDone = Completer<RemoteHello>();
  final _events = StreamController<Map<String, Object?>>.broadcast();
  final _done = Completer<void>();
  final _plain = StreamController<Map<String, Object?>>.broadcast();
  final _pending = <int, Completer<Map<String, Object?>>>{};
  late RemoteHello _hello;
  Map<String, Object?> _ready = const {};
  SecureChannel? _chan;
  Completer<Map<String, Object?>>? _readyWait;
  int _nextId = 1;
  bool _open = true;
  Future<void> _sendChain = Future.value();

  Future<void> _rx = Future.value();

  _PhoneConn(this.ws) {
    ws.listen((d) => _rx = _rx.then((_) => _onData(d)),
        onDone: _finish, onError: (Object _) => _finish(), cancelOnError: true);
  }

  @override
  RemoteHello get hello => _hello;

  @override
  Map<String, Object?> get ready => _ready;

  @override
  Stream<Map<String, Object?>> get events => _events.stream;

  @override
  Future<void> get done => _done.future;

  @override
  bool get isOpen => _open;

  void _finish() {
    if (!_open) return;
    _open = false;
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(const RemoteRejected('closed'));
    }
    _pending.clear();
    final r = _readyWait;
    if (r != null && !r.isCompleted) {
      r.completeError(const RemoteRejected('closed'));
    }
    if (!_helloDone.isCompleted) {
      _helloDone.completeError(const RemoteRejected('closed'));
    }
    _events.close();
    _plain.close();
    if (!_done.isCompleted) _done.complete();
  }

  Future<void> _onData(dynamic data) async {
    final len = data is String ? data.length : (data as List<int>).length;
    if (len > remoteMaxMessage) return close();
    try {
      final ch = _chan;
      if (ch != null && data is List<int>) {
        final m = await ch.decode(data);
        if (m['t'] == 'ready') {
          _ready = m;
          final r = _readyWait;
          if (r != null && !r.isCompleted) r.complete(m);
          return;
        }
        if (m['t'] == 'res') {
          final id = Wire.integer(m, 'id');
          final c = id == null ? null : _pending.remove(id);
          if (c != null && !c.isCompleted) c.complete(m);
          return;
        }
        if (!_events.isClosed) _events.add(m);
        return;
      }
      if (data is! String) return await close();
      final j = jsonDecode(data);
      if (j is! Map<String, Object?>) return await close();
      if (j['t'] == 'hello' && !_helloDone.isCompleted) {
        final id = Wire.str(j, 'id', max: 64);
        final n = RemoteCrypto.unb64(j['n'], length: 16);
        if (id == null || n == null) return await close();
        _hello = RemoteHello(id, Wire.str(j, 'name', max: 100) ?? 'TV',
            Wire.integer(j, 'v') ?? 0, n);
        _helloDone.complete(_hello);
        return;
      }
      if (!_plain.isClosed) _plain.add(j);
    } on FrameRejected {
      await close();
    } on FormatException {
      await close();
    }
  }

  void _sendPlain(Map<String, Object?> m) {
    _sendChain = _sendChain.then((_) {
      if (_open) ws.add(jsonEncode(m));
    }).catchError((Object _) {});
  }

  /// Nächste Klartext-Antwort des Fernsehers (Anmelden/Koppeln).
  Future<Map<String, Object?>> _nextPlain(
      {Duration timeout = const Duration(seconds: 10)}) {
    if (!_open) return Future.error(const RemoteRejected('closed'));
    final c = Completer<Map<String, Object?>>();
    late StreamSubscription<Map<String, Object?>> sub;
    sub = _plain.stream.listen((m) {
      sub.cancel();
      if (!c.isCompleted) c.complete(m);
    }, onDone: () {
      if (!c.isCompleted) c.completeError(const RemoteRejected('closed'));
    });
    return c.future.timeout(timeout, onTimeout: () {
      sub.cancel();
      throw const RemoteRejected('timeout');
    });
  }

  static RemoteRejected _rejected(Map<String, Object?> m) => switch (m['t']) {
        'unknown' => const RemoteRejected('unknown'),
        'locked' => RemoteRejected('locked',
            lockedFor: Duration(seconds: Wire.integer(m, 's') ?? 60)),
        'busy' => const RemoteRejected('busy'),
        'pairFail' => const RemoteRejected('code'),
        _ => const RemoteRejected('protocol'),
      };

  @override
  Future<void> authenticate(String deviceId, Uint8List key) async {
    final n = RemoteCrypto.random(16);
    final mac = RemoteCrypto.authMac(key,
        tvId: _hello.tvId, deviceId: deviceId, tvNonce: _hello.nonce,
        phoneNonce: n);
    final keys = RemoteCrypto.sessionKeys(key, _hello.nonce, n);
    _chan = SecureChannel(sendKey: keys.toTv, receiveKey: keys.toPhone);
    final wait = _readyWait = Completer<Map<String, Object?>>();
    // Ablehnung kommt im Klartext.
    final plain = _nextPlain(timeout: const Duration(seconds: 8));
    _sendPlain({
      't': 'auth',
      'id': deviceId,
      'n': RemoteCrypto.b64(n),
      'mac': RemoteCrypto.b64(mac),
    });
    final first = await Future.any<Object>([
      wait.future,
      plain.then<Object>((m) => m),
    ]).catchError((Object e) => e);
    if (first is Map<String, Object?> && first['t'] == 'ready') return;
    _chan = null;
    await close();
    if (first is Map<String, Object?>) throw _rejected(first);
    if (first is RemoteRejected) throw first;
    throw const RemoteRejected('protocol');
  }

  @override
  Future<RemotePairingFlow> pair(String deviceId, String deviceName) async {
    final p = await PhonePairing.start(tvId: _hello.tvId, deviceId: deviceId);
    final reply = _nextPlain(timeout: const Duration(seconds: 10));
    _sendPlain({
      't': 'pair',
      'id': deviceId,
      'name': deviceName,
      'pk': RemoteCrypto.b64(p.phonePub),
    });
    final m = await reply;
    if (m['t'] != 'pairKey') {
      await close();
      throw _rejected(m);
    }
    final pk = RemoteCrypto.unb64(m['pk'], length: 32);
    if (pk == null) {
      await close();
      throw const RemoteRejected('protocol');
    }
    await p.setTvKey(pk);
    return _PairFlow(this, p);
  }

  @override
  Future<void> send(Map<String, Object?> msg) {
    final ch = _chan;
    if (ch == null || !_open) return Future.value();
    return _sendChain = _sendChain.then((_) async {
      if (!_open) return;
      final f = await ch.encode(msg);
      if (_open) ws.add(f);
    }).catchError((Object _) {});
  }

  @override
  Future<Map<String, Object?>> request(String method,
      [Map<String, Object?> args = const {},
      Duration timeout = const Duration(seconds: 8)]) {
    if (!_open || _chan == null) {
      return Future.error(const RemoteRejected('closed'));
    }
    final id = _nextId++;
    final c = _pending[id] = Completer<Map<String, Object?>>();
    unawaited(send({...args, 't': 'req', 'id': id, 'm': method}));
    return c.future.timeout(timeout, onTimeout: () {
      _pending.remove(id);
      throw TimeoutException('remote $method');
    });
  }

  @override
  Future<void> close() async {
    if (_open) {
      try {
        await ws.close(WebSocketStatus.normalClosure);
      } catch (_) {}
    }
    _finish();
  }
}

class _PairFlow implements RemotePairingFlow {
  final _PhoneConn c;
  final PhonePairing p;
  _PairFlow(this.c, this.p);

  Future<Map<String, Object?>> _expect(String t) async {
    final m = await c._nextPlain(timeout: const Duration(seconds: 10));
    if (m['t'] != t) throw _PhoneConn._rejected(m);
    return m;
  }

  @override
  Future<Uint8List> submit(String code) async {
    try {
      p.setCode(code);
      for (var i = 0; i < PairingMath.digits; i++) {
        var wait = c._nextPlain();
        c._sendPlain({'t': 'pc', 'i': i, 'c': RemoteCrypto.b64(p.commit())});
        var m = await wait;
        if (m['t'] != 'tc' || Wire.integer(m, 'i') != i) {
          throw _PhoneConn._rejected(m);
        }
        p.onTvCommit(i, RemoteCrypto.unb64(m['c'], length: 32) ??
            (throw const RemoteRejected('protocol')));
        wait = c._nextPlain();
        c._sendPlain({'t': 'pr', 'i': i, 'r': RemoteCrypto.b64(p.reveal())});
        m = await wait;
        if (m['t'] != 'tr' || Wire.integer(m, 'i') != i) {
          throw _PhoneConn._rejected(m);
        }
        p.onTvReveal(i, RemoteCrypto.unb64(m['r'], length: 16) ??
            (throw const RemoteRejected('protocol')));
      }
      final wait = _expect('pok');
      c._sendPlain({'t': 'pok', 'mac': RemoteCrypto.b64(p.confirm())});
      final m = await wait;
      p.onTvConfirm(RemoteCrypto.unb64(m['mac'], length: 32) ??
          (throw const RemoteRejected('protocol')));
      return p.deviceKey;
    } on PairingFailed catch (e) {
      throw RemoteRejected(e.wrongCode ? 'code' : 'protocol');
    } finally {
      await c.close();
    }
  }

  @override
  Future<void> cancel() => c.close();
}
