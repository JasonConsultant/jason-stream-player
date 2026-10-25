import 'dart:convert';
import 'dart:math' show Random;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show Hmac, sha256;
import 'package:cryptography/cryptography.dart'
    show AesGcm, Mac, SecretBox, SecretBoxAuthenticationError, SecretKey;

import 'backup_gzip_stub.dart' if (dart.library.io) 'backup_gzip_io.dart';

/// Sicherungsdatei (`.jspbackup`) für den Umzug auf ein neues Gerät.
///
/// Aufbau: JSON → gzip → AES-256-GCM. Der Schlüssel wird mit
/// PBKDF2-HMAC-SHA256 (150 000 Runden, 16 Byte Salz) aus dem vom Nutzer
/// gewählten Passwort abgeleitet. Die Datei enthält Portal-Zugangsdaten,
/// deshalb ist das Passwort Pflicht.
///
/// Datei: `JSPB1` (5 Byte) · Salz (16) · Nonce (12) · Chiffretext · MAC (16)
class BackupCodec {
  static const magic = 'JSPB1';
  static const extension = '.jspbackup';
  static const mimeType = 'application/octet-stream';
  static const minPasswordLength = 6;
  static const iterations = 150000;
  static const _saltLen = 16;
  static const _nonceLen = 12;
  static const _macLen = 16;

  /// Vorgeschlagener Dateiname, z. B. `jason-sicherung-2026-10-20.jspbackup`.
  static String suggestedName([DateTime? now]) {
    final d = now ?? DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return 'jason-sicherung-${d.year}-${two(d.month)}-${two(d.day)}$extension';
  }

  static Future<Uint8List> encrypt(
      Map<String, Object?> data, String password) async {
    if (password.length < minPasswordLength) {
      throw BackupException(BackupError.weakPassword);
    }
    final rnd = Random.secure();
    final salt = Uint8List.fromList(
        List.generate(_saltLen, (_) => rnd.nextInt(256)));
    final nonce = Uint8List.fromList(
        List.generate(_nonceLen, (_) => rnd.nextInt(256)));
    final key = deriveKey(password, salt);
    final plain = gzipEncode(utf8.encode(jsonEncode(data)));
    final box = await AesGcm.with256bits().encrypt(
      plain,
      secretKey: SecretKey(key),
      nonce: nonce,
    );
    final out = BytesBuilder(copy: false)
      ..add(ascii.encode(magic))
      ..add(salt)
      ..add(nonce)
      ..add(box.cipherText)
      ..add(box.mac.bytes);
    return out.toBytes();
  }

  /// Wirft [BackupException]: keine Sicherung, falsches Passwort oder
  /// veränderte Datei (die letzten beiden sind nicht unterscheidbar).
  static Future<Map<String, Object?>> decrypt(
      Uint8List bytes, String password) async {
    final head = magic.length + _saltLen + _nonceLen;
    if (bytes.length < head + _macLen ||
        ascii.decode(bytes.sublist(0, magic.length), allowInvalid: true) !=
            magic) {
      throw BackupException(BackupError.notABackup);
    }
    var o = magic.length;
    final salt = bytes.sublist(o, o += _saltLen);
    final nonce = bytes.sublist(o, o += _nonceLen);
    final cipher = bytes.sublist(o, bytes.length - _macLen);
    final mac = bytes.sublist(bytes.length - _macLen);
    final key = deriveKey(password, salt);
    final List<int> plain;
    try {
      plain = await AesGcm.with256bits().decrypt(
        SecretBox(cipher, nonce: nonce, mac: Mac(mac)),
        secretKey: SecretKey(key),
      );
    } on SecretBoxAuthenticationError {
      throw BackupException(BackupError.wrongPasswordOrCorrupt);
    }
    try {
      final json = jsonDecode(utf8.decode(gzipDecode(plain)));
      if (json is Map) return json.cast<String, Object?>();
    } catch (_) {
      // unten
    }
    throw BackupException(BackupError.notABackup);
  }

  /// PBKDF2-HMAC-SHA256 mit 32 Byte Schlüssel (ein Block, Nummer 1).
  static Uint8List deriveKey(String password, List<int> salt,
      {int rounds = iterations}) {
    final mac = Hmac(sha256, utf8.encode(password));
    var u = Uint8List.fromList(mac.convert([...salt, 0, 0, 0, 1]).bytes);
    final out = Uint8List.fromList(u);
    for (var i = 1; i < rounds; i++) {
      u = Uint8List.fromList(mac.convert(u).bytes);
      for (var j = 0; j < out.length; j++) {
        out[j] ^= u[j];
      }
    }
    return out;
  }
}

enum BackupError { weakPassword, notABackup, wrongPasswordOrCorrupt }

class BackupException implements Exception {
  final BackupError error;
  BackupException(this.error);
  @override
  String toString() => 'BackupException(${error.name})';
}

/// Kurzübersicht über den Inhalt einer Sicherung (für die Rückfrage vor dem
/// Wiederherstellen). Liest nur die von [Storage.exportAll] erzeugte Struktur.
class BackupSummary {
  final int portals;
  final int favorites;
  final int myGroups;
  final int vodFavorites;
  final DateTime? created;
  final List<String> portalNames;

  /// Ab 2.3: Anzahl der Profile (ältere Sicherungen: 0).
  final int profiles;

  const BackupSummary({
    this.profiles = 0,
    required this.portals,
    required this.favorites,
    required this.myGroups,
    required this.vodFavorites,
    required this.created,
    required this.portalNames,
  });

  static BackupSummary of(Map<String, Object?> data) {
    final portals = (data['portals'] as List?) ?? const [];
    final prefs = (data['prefs'] as Map?) ?? const {};
    var favorites = 0;
    var groups = 0;
    var vodFavs = 0;
    for (final e in prefs.entries) {
      final full = e.key as String;
      // Profil-Daten (p.<id>.fav_…) zählen mit.
      final dot = full.startsWith('p.') ? full.indexOf('.', 2) : -1;
      final k = dot > 0 ? full.substring(dot + 1) : full;
      final v = e.value;
      if (k.startsWith('fav_') && v is List) favorites += v.length;
      if (k.startsWith('set_mygroups_') && v is String) {
        try {
          groups += (jsonDecode(v) as List).length;
        } catch (_) {
          // ignorieren
        }
      }
      if (k.startsWith('set_vodfav_') && v is String) {
        try {
          vodFavs += (jsonDecode(v) as List).length;
        } catch (_) {
          // ignorieren
        }
      }
    }
    return BackupSummary(
      profiles: (data['profiles'] as List?)?.length ?? 0,
      portals: portals.length,
      favorites: favorites,
      myGroups: groups,
      vodFavorites: vodFavs,
      created: DateTime.tryParse(data['created'] as String? ?? ''),
      portalNames: [
        for (final p in portals)
          if (p is Map && p['name'] is String) p['name'] as String,
      ],
    );
  }
}
