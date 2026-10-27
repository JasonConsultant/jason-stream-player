import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;
import 'package:cryptography/cryptography.dart';

/// Kryptografie der Handy-Fernbedienung.
///
/// - Schlüsselaustausch: X25519 (Paket `cryptography`).
/// - Ableitung: HKDF-SHA256 (RFC 5869), HMAC-SHA256 (Paket `crypto`).
/// - Rahmen: AES-256-GCM, je Richtung ein eigener Schlüssel, 64-bit-Zähler
///   als Nonce und zusätzliche Daten; nur streng steigende Zähler werden
///   angenommen (Schutz gegen Wiederholung und Umsortieren). Schlüssel
///   gelten nur für eine Verbindung (aus frischen Zufallswerten beider
///   Seiten abgeleitet) – alte Mitschnitte passen nie wieder.
abstract final class RemoteCrypto {
  static final _rnd = Random.secure();

  static Uint8List random(int n) =>
      Uint8List.fromList(List<int>.generate(n, (_) => _rnd.nextInt(256)));

  static Uint8List hmac(List<int> key, List<int> data) =>
      Uint8List.fromList(c.Hmac(c.sha256, key).convert(data).bytes);

  static Uint8List sha256(List<int> data) =>
      Uint8List.fromList(c.sha256.convert(data).bytes);

  /// HKDF-SHA256 (Extract + Expand).
  static Uint8List hkdf(List<int> ikm,
      {List<int> salt = const [], required List<int> info, int length = 32}) {
    final prk = hmac(salt.isEmpty ? List<int>.filled(32, 0) : salt, ikm);
    final out = BytesBuilder();
    var t = <int>[];
    var i = 1;
    while (out.length < length) {
      t = hmac(prk, [...t, ...info, i]);
      out.add(t);
      i++;
    }
    return Uint8List.fromList(out.takeBytes().sublist(0, length));
  }

  /// Vergleich in konstanter Zeit (bei gleicher Länge).
  static bool equals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var d = 0;
    for (var i = 0; i < a.length; i++) {
      d |= a[i] ^ b[i];
    }
    return d == 0;
  }

  static Uint8List concat(List<List<int>> parts) {
    final b = BytesBuilder(copy: false);
    for (final p in parts) {
      b.add(p);
    }
    return b.takeBytes();
  }

  static List<int> label(String s) => utf8.encode(s);

  static String b64(List<int> bytes) => base64Url.encode(bytes);

  /// base64url → Bytes; `null` bei ungültigem Text oder falscher Länge.
  static Uint8List? unb64(Object? s, {int? length, int max = 4096}) {
    if (s is! String || s.length > max) return null;
    try {
      final b = base64Url.decode(s);
      if (length != null && b.length != length) return null;
      return b;
    } on FormatException {
      return null;
    }
  }

  // ---------------------------------------------------------------- X25519

  static final _x25519 = X25519();

  static Future<RemoteKeyPair> newKeyPair() async {
    final kp = await _x25519.newKeyPair();
    final pub = await kp.extractPublicKey();
    return RemoteKeyPair._(kp, Uint8List.fromList(pub.bytes));
  }

  /// Gemeinsames Geheimnis (32 Bytes). Wirft bei ungültigem Schlüssel.
  static Future<Uint8List> shared(RemoteKeyPair mine, List<int> remotePub) async {
    if (remotePub.length != 32) throw const RemoteCryptoException('key');
    final k = await _x25519.sharedSecretKey(
        keyPair: mine._kp,
        remotePublicKey:
            SimplePublicKey(remotePub, type: KeyPairType.x25519));
    final bytes = Uint8List.fromList(await k.extractBytes());
    // Alles-null = schwacher Gegenschlüssel (kleine Untergruppe).
    if (bytes.every((b) => b == 0)) throw const RemoteCryptoException('weak');
    return bytes;
  }

  // ---------------------------------------------------------------- Sitzung

  /// Schlüssel einer Verbindung aus dem gemeinsamen Geräteschlüssel und den
  /// Zufallswerten beider Seiten.
  static ({Uint8List toTv, Uint8List toPhone}) sessionKeys(
      List<int> deviceKey, List<int> tvNonce, List<int> phoneNonce) {
    final salt = concat([tvNonce, phoneNonce]);
    return (
      toTv: hkdf(deviceKey, salt: salt, info: label('jsp-remote v1 p2t')),
      toPhone: hkdf(deviceKey, salt: salt, info: label('jsp-remote v1 t2p')),
    );
  }

  /// Anmeldung eines gekoppelten Handys: beweist den Geräteschlüssel, ohne
  /// ihn zu zeigen (an Verbindung, TV und Gerät gebunden).
  static Uint8List authMac(List<int> deviceKey,
          {required String tvId,
          required String deviceId,
          required List<int> tvNonce,
          required List<int> phoneNonce}) =>
      hmac(
          deviceKey,
          concat([
            label('jsp-remote v1 auth|$tvId|$deviceId|'),
            tvNonce,
            phoneNonce,
          ]));
}

class RemoteCryptoException implements Exception {
  final String reason;
  const RemoteCryptoException(this.reason);
  @override
  String toString() => 'RemoteCryptoException($reason)';
}

/// X25519-Schlüsselpaar (öffentlicher Teil als [publicKey]).
class RemoteKeyPair {
  final SimpleKeyPair _kp;
  final Uint8List publicKey;
  RemoteKeyPair._(this._kp, this.publicKey);
}

/// Ein Rahmen wurde abgelehnt (Manipulation, Wiederholung, Format).
class FrameRejected implements Exception {
  final String reason;
  const FrameRejected(this.reason);
  @override
  String toString() => 'FrameRejected($reason)';
}

/// Ver- bzw. Entschlüsseln einer Richtung einer Verbindung.
///
/// Rahmen: 8 Bytes Zähler (big endian) ‖ Chiffretext ‖ 16 Bytes GCM-Tag.
/// Nonce = 4 Null-Bytes ‖ Zähler; der Zähler steckt zusätzlich in den
/// authentisierten Daten.
class FrameCipher {
  static final _gcm = AesGcm.with256bits();
  static const _aadLabel = [0x6a, 0x73, 0x70, 0x31]; // "jsp1"

  final SecretKey _key;

  /// Senden: zuletzt benutzter Zähler. Empfangen: zuletzt angenommener.
  int _counter = 0;

  FrameCipher(List<int> key) : _key = SecretKey(List<int>.of(key)) {
    if (key.length != 32) throw ArgumentError('key length');
  }

  int get counter => _counter;

  static Uint8List _counterBytes(int n) {
    final b = ByteData(8)..setUint64(0, n);
    return b.buffer.asUint8List();
  }

  static List<int> _nonce(Uint8List counter) => [0, 0, 0, 0, ...counter];

  Future<Uint8List> seal(List<int> plain) async {
    final n = ++_counter;
    final cb = _counterBytes(n);
    final box = await _gcm.encrypt(plain,
        secretKey: _key, nonce: _nonce(cb), aad: [..._aadLabel, ...cb]);
    return RemoteCrypto.concat([cb, box.cipherText, box.mac.bytes]);
  }

  /// Entschlüsselt einen Rahmen. Wirft [FrameRejected] bei falschem Tag,
  /// Wiederholung (Zähler nicht größer als der letzte) oder Format.
  Future<Uint8List> open(List<int> frame) async {
    if (frame.length < 8 + 16) throw const FrameRejected('short');
    final cb = Uint8List.fromList(frame.sublist(0, 8));
    final n = ByteData.sublistView(cb).getUint64(0);
    if (n <= _counter) throw const FrameRejected('replay');
    final body = frame.sublist(8, frame.length - 16);
    final tag = frame.sublist(frame.length - 16);
    try {
      final plain = await _gcm.decrypt(
          SecretBox(body, nonce: _nonce(cb), mac: Mac(tag)),
          secretKey: _key,
          aad: [..._aadLabel, ...cb]);
      // Erneut prüfen (gleichzeitiges Öffnen): nie rückwärts zählen.
      if (n <= _counter) throw const FrameRejected('replay');
      _counter = n;
      return Uint8List.fromList(plain);
    } on SecretBoxAuthenticationError {
      throw const FrameRejected('auth');
    }
  }
}

/// Verschlüsselte JSON-Verbindung (beide Richtungen).
class SecureChannel {
  final FrameCipher _out;
  final FrameCipher _in;
  SecureChannel({required List<int> sendKey, required List<int> receiveKey})
      : _out = FrameCipher(sendKey),
        _in = FrameCipher(receiveKey);

  Future<Uint8List> encode(Map<String, Object?> msg) =>
      _out.seal(utf8.encode(jsonEncode(msg)));

  /// Wirft [FrameRejected] (auch bei ungültigem JSON).
  Future<Map<String, Object?>> decode(List<int> frame) async {
    final plain = await _in.open(frame);
    try {
      final j = jsonDecode(utf8.decode(plain));
      if (j is Map<String, Object?> && j['t'] is String) return j;
    } on FormatException {
      // unten
    }
    throw const FrameRejected('json');
  }
}
