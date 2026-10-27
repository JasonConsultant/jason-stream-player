import 'dart:math';
import 'dart:typed_data';

import 'package:clock/clock.dart';

import 'crypto.dart';

/// Koppeln Handy ↔ Fernseher mit einem 4-stelligen Code.
///
/// Der Fernseher zeigt einen frischen Zufallscode. Beide Seiten tauschen
/// X25519-Schlüssel aus und prüfen danach den Code **ziffernweise** mit
/// Commit/Reveal (wie „Passkey Entry“ bei Bluetooth):
///
///   Runde i (0…3): Handy → Commit Cp = HMAC(np_i, "P"|i|pubP|pubT|Ziffer_i)
///                  TV    → Commit Ct = HMAC(nt_i, "T"|i|pubP|pubT|Ziffer_i)
///                  Handy → np_i (TV prüft Cp mit seiner Ziffer)
///                  TV    → nt_i (Handy prüft Ct mit seiner Ziffer)
///
/// Wer den Code nicht kennt (fremdes Handy im WLAN, Mittelsmann), muss jede
/// Ziffer raten, bevor die Gegenseite etwas verrät: Erfolg 1 : 10 000 je
/// Versuch, und nach wenigen Fehlversuchen sperrt der Fernseher das Koppeln
/// ([FailureGate]). Ein Mitlesen des Austauschs verrät den Code nicht
/// brauchbar – ein neuer Versuch bekommt einen neuen Code.
///
/// Danach: Geräteschlüssel K = HKDF(X25519, salt = SHA256(pubP|pubT),
/// info = "…pair|Code") und gegenseitige Bestätigung (HMAC mit K).
abstract final class PairingMath {
  static const digits = 4;

  /// Neuer Zufallscode, z. B. "0427".
  static String newCode([Random? r]) {
    final rnd = r ?? Random.secure();
    return List.generate(digits, (_) => rnd.nextInt(10)).join();
  }

  static bool validCode(String s) => RegExp(r'^\d{4}$').hasMatch(s);

  static Uint8List commit(String role, int round, List<int> nonce,
          List<int> phonePub, List<int> tvPub, String digit) =>
      RemoteCrypto.hmac(
          nonce,
          RemoteCrypto.concat([
            RemoteCrypto.label('jsp-remote v1 commit|$role|$round|'),
            phonePub,
            tvPub,
            RemoteCrypto.label('|$digit'),
          ]));

  static Uint8List deviceKey(
          List<int> shared, List<int> phonePub, List<int> tvPub, String code) =>
      RemoteCrypto.hkdf(shared,
          salt: RemoteCrypto.sha256(RemoteCrypto.concat([phonePub, tvPub])),
          info: RemoteCrypto.label('jsp-remote v1 pair|$code'));

  static Uint8List confirm(List<int> key, String role,
          {required String tvId,
          required String deviceId,
          required List<int> phonePub,
          required List<int> tvPub}) =>
      RemoteCrypto.hmac(
          key,
          RemoteCrypto.concat([
            RemoteCrypto.label('jsp-remote v1 confirm|$role|$tvId|$deviceId|'),
            phonePub,
            tvPub,
          ]));
}

/// Koppeln fehlgeschlagen (falscher Code, Protokollfehler).
class PairingFailed implements Exception {
  /// `code` = Ziffer stimmte nicht; `protocol` = Ablauf/Format.
  final String reason;
  const PairingFailed(this.reason);
  bool get wrongCode => reason == 'code';
  @override
  String toString() => 'PairingFailed($reason)';
}

/// Fernseher-Seite einer Kopplung (ein Versuch, ein Code).
class TvPairing {
  final String tvId;
  final String deviceId;
  final String code;
  final RemoteKeyPair _kp;
  final Uint8List phonePub;
  final Uint8List _shared;
  final _nonces = <Uint8List>[];
  Uint8List? _phoneCommit;
  int _round = 0;
  bool _waitingReveal = false;
  Uint8List? _key;

  TvPairing._(this.tvId, this.deviceId, this.code, this._kp, this.phonePub,
      this._shared);

  /// [code] nur für Tests vorgeben; sonst Zufall.
  static Future<TvPairing> start(
      {required String tvId,
      required String deviceId,
      required List<int> phonePub,
      String? code}) async {
    final kp = await RemoteCrypto.newKeyPair();
    final shared = await RemoteCrypto.shared(kp, phonePub);
    return TvPairing._(tvId, deviceId, code ?? PairingMath.newCode(), kp,
        Uint8List.fromList(phonePub), shared);
  }

  Uint8List get tvPub => _kp.publicKey;
  bool get roundsDone => _round >= PairingMath.digits;

  /// Commit des Handys für Runde [round] → eigener Commit.
  Uint8List onPhoneCommit(int round, List<int> c) {
    if (round != _round || _waitingReveal || c.length != 32) {
      throw const PairingFailed('protocol');
    }
    _phoneCommit = Uint8List.fromList(c);
    final n = RemoteCrypto.random(16);
    _nonces.add(n);
    _waitingReveal = true;
    return PairingMath.commit('T', round, n, phonePub, tvPub, code[round]);
  }

  /// Zufallswert des Handys für Runde [round] → eigener Zufallswert.
  /// Wirft [PairingFailed] (`code`), wenn die Ziffer nicht stimmt.
  Uint8List onPhoneReveal(int round, List<int> nonce) {
    if (round != _round || !_waitingReveal || nonce.length != 16) {
      throw const PairingFailed('protocol');
    }
    final expect = PairingMath.commit(
        'P', round, nonce, phonePub, tvPub, code[round]);
    if (!RemoteCrypto.equals(expect, _phoneCommit!)) {
      throw const PairingFailed('code');
    }
    _waitingReveal = false;
    _round++;
    if (roundsDone) {
      _key = PairingMath.deviceKey(_shared, phonePub, tvPub, code);
    }
    return _nonces[round];
  }

  /// Bestätigung des Handys prüfen → eigene Bestätigung. Danach ist
  /// [deviceKey] gültig.
  Uint8List onPhoneConfirm(List<int> mac) {
    final k = _key;
    if (k == null) throw const PairingFailed('protocol');
    final expect = PairingMath.confirm(k, 'phone',
        tvId: tvId, deviceId: deviceId, phonePub: phonePub, tvPub: tvPub);
    if (!RemoteCrypto.equals(expect, mac)) {
      throw const PairingFailed('code');
    }
    return PairingMath.confirm(k, 'tv',
        tvId: tvId, deviceId: deviceId, phonePub: phonePub, tvPub: tvPub);
  }

  Uint8List get deviceKey {
    final k = _key;
    if (k == null) throw StateError('not paired');
    return k;
  }
}

/// Handy-Seite einer Kopplung.
class PhonePairing {
  final String tvId;
  final String deviceId;
  final RemoteKeyPair _kp;
  Uint8List? _tvPub;
  Uint8List? _shared;
  String? _code;
  final _nonces = <Uint8List>[];
  Uint8List? _tvCommit;
  int _round = 0;
  Uint8List? _key;

  PhonePairing._(this.tvId, this.deviceId, this._kp);

  static Future<PhonePairing> start(
          {required String tvId, required String deviceId}) async =>
      PhonePairing._(tvId, deviceId, await RemoteCrypto.newKeyPair());

  Uint8List get phonePub => _kp.publicKey;
  int get round => _round;
  bool get roundsDone => _round >= PairingMath.digits;

  Future<void> setTvKey(List<int> tvPub) async {
    _tvPub = Uint8List.fromList(tvPub);
    _shared = await RemoteCrypto.shared(_kp, tvPub);
  }

  /// Code vom Fernseher (Eingabe des Nutzers) – vor der ersten Runde.
  void setCode(String code) {
    if (!PairingMath.validCode(code)) throw const PairingFailed('format');
    _code = code;
    _nonces.clear();
    _round = 0;
  }

  Uint8List commit() {
    final tv = _tvPub, code = _code;
    if (tv == null || code == null || roundsDone) {
      throw const PairingFailed('protocol');
    }
    final n = RemoteCrypto.random(16);
    _nonces.add(n);
    return PairingMath.commit('P', _round, n, phonePub, tv, code[_round]);
  }

  void onTvCommit(int round, List<int> c) {
    if (round != _round || c.length != 32) throw const PairingFailed('protocol');
    _tvCommit = Uint8List.fromList(c);
  }

  Uint8List reveal() {
    if (_tvCommit == null || _nonces.length != _round + 1) {
      throw const PairingFailed('protocol');
    }
    return _nonces[_round];
  }

  /// Wirft [PairingFailed] (`code`), wenn der Fernseher die Ziffer nicht
  /// kennt (Mittelsmann).
  void onTvReveal(int round, List<int> nonce) {
    final tv = _tvPub, code = _code, c = _tvCommit;
    if (round != _round || tv == null || code == null || c == null ||
        nonce.length != 16) {
      throw const PairingFailed('protocol');
    }
    final expect =
        PairingMath.commit('T', round, nonce, phonePub, tv, code[round]);
    if (!RemoteCrypto.equals(expect, c)) throw const PairingFailed('code');
    _tvCommit = null;
    _round++;
    if (roundsDone) {
      _key = PairingMath.deviceKey(_shared!, phonePub, tv, code);
    }
  }

  Uint8List confirm() {
    final k = _key;
    if (k == null) throw const PairingFailed('protocol');
    return PairingMath.confirm(k, 'phone',
        tvId: tvId, deviceId: deviceId, phonePub: phonePub, tvPub: _tvPub!);
  }

  void onTvConfirm(List<int> mac) {
    final k = _key;
    if (k == null) throw const PairingFailed('protocol');
    final expect = PairingMath.confirm(k, 'tv',
        tvId: tvId, deviceId: deviceId, phonePub: phonePub, tvPub: _tvPub!);
    if (!RemoteCrypto.equals(expect, mac)) throw const PairingFailed('code');
  }

  Uint8List get deviceKey {
    final k = _key;
    if (k == null) throw StateError('not paired');
    return k;
  }
}

/// Begrenzung von Fehlversuchen (Koppeln, Anmelden) je Schlüssel
/// (z. B. Absender-Adresse oder global „pair“).
///
/// Nach [maxFails] Fehlern in Folge ist der Schlüssel gesperrt: zuerst
/// [baseLock], jede weitere Sperre doppelt so lang, höchstens [maxLock].
/// Ein Erfolg setzt den Schlüssel zurück.
class FailureGate {
  final int maxFails;
  final Duration baseLock;
  final Duration maxLock;
  final _fails = <String, int>{};
  final _locks = <String, int>{};
  final _until = <String, DateTime>{};

  FailureGate(
      {this.maxFails = 3,
      this.baseLock = const Duration(minutes: 1),
      this.maxLock = const Duration(minutes: 15)});

  /// Restdauer der Sperre oder null.
  Duration? lockedFor(String key) {
    final u = _until[key];
    if (u == null) return null;
    final left = u.difference(clock.now());
    if (left <= Duration.zero) {
      _until.remove(key);
      return null;
    }
    return left;
  }

  bool allowed(String key) => lockedFor(key) == null;

  void fail(String key) {
    final n = (_fails[key] ?? 0) + 1;
    if (n < maxFails) {
      _fails[key] = n;
      return;
    }
    _fails.remove(key);
    final locks = (_locks[key] ?? 0) + 1;
    _locks[key] = locks;
    var d = baseLock * (1 << (locks - 1).clamp(0, 16));
    if (d > maxLock) d = maxLock;
    _until[key] = clock.now().add(d);
    // Speicher begrenzen (viele Absender): älteste Einträge vergessen.
    if (_until.length > 256) _until.remove(_until.keys.first);
    if (_locks.length > 256) _locks.remove(_locks.keys.first);
  }

  void success(String key) {
    _fails.remove(key);
    _locks.remove(key);
    _until.remove(key);
  }
}
