import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import '../l10n/strings.dart';

/// Schutz von Zugangsdaten und Eingaben.
///
/// - [Redactor] entfernt Benutzername/Passwort aus allem, was angezeigt wird.
/// - [UrlPolicy] lässt nur sichere Adress-Schemata zu.
/// - [PinHasher] speichert die Kindersicherungs-PIN nur als Hash.
class Redactor {
  static final _secrets = <String>{};

  /// Zugangsdaten eines Portals merken, damit sie überall ausgeblendet werden.
  static void register(String? username, String? password) {
    for (final s in [username, password]) {
      if (s == null || s.length < 2) continue;
      _secrets
        ..add(s)
        ..add(Uri.encodeComponent(s))
        ..add(Uri.encodeQueryComponent(s));
    }
  }

  /// Zugangsdaten aus einer Playlist-Adresse (…?username=…&password=…).
  static void registerUrl(String url) {
    final u = Uri.tryParse(url);
    if (u == null) return;
    final q = u.queryParameters;
    register(q['username'] ?? q['user'], q['password'] ?? q['pass']);
    if (u.userInfo.isNotEmpty) {
      final parts = u.userInfo.split(':');
      register(parts.first, parts.length > 1 ? parts[1] : null);
    }
    // Tokens in Pfaden/Parametern
    for (final k in ['token', 'key', 'auth']) {
      if (q[k] != null) register(q[k], null);
    }
  }

  static void clear() => _secrets.clear();

  /// Text ohne Zugangsdaten.
  static String redact(String text) {
    var out = text;
    // Längste zuerst, damit Teilstrings nicht übrig bleiben.
    final sorted = _secrets.toList()..sort((a, b) => b.length.compareTo(a.length));
    for (final s in sorted) {
      out = out.replaceAll(s, '•••');
    }
    // Für den Fall, dass ein Geheimnis noch nicht registriert war:
    out = out.replaceAllMapped(
      RegExp(r'(username|password|pass|user|token|key)=([^&\s"]+)',
          caseSensitive: false),
      (m) => '${m[1]}=•••',
    );
    out = out.replaceAllMapped(
      RegExp(r'/(live|movie|series|timeshift)/[^/\s]+/[^/\s]+/'),
      (m) => '/${m[1]}/•••/•••/',
    );
    return out;
  }

  /// Verständliche, bereinigte Fehlermeldung für die Oberfläche.
  static String friendly(Object e) {
    if (e is TimeoutException) {
      return tr('Der Server antwortet nicht (Zeitüberschreitung).');
    }
    final type = e.runtimeType.toString();
    if (type.contains('Handshake') || type.contains('TlsException')) {
      return tr('Sichere Verbindung fehlgeschlagen – Zertifikat ungültig.');
    }
    if (type.contains('SocketException')) {
      return tr('Server nicht erreichbar. Internetverbindung und Adresse prüfen.');
    }
    if (e is FormatException) {
      return tr('Der Server hat eine ungültige Antwort geschickt.');
    }
    if (type.contains('PlatformException') || type.contains('MissingPlugin')) {
      return tr('Interner Fehler beim Zugriff auf das Gerät.');
    }
    final s = e.toString();
    if (s.contains('ClientException') || s.contains('Failed host lookup')) {
      return tr('Server nicht erreichbar. Internetverbindung und Adresse prüfen.');
    }
    return redact(s.replaceFirst('Exception: ', ''));
  }
}

class UrlPolicy {
  /// Erlaubt für Portal, Playlist, EPG und Bilder.
  static bool isWeb(String? url) {
    final u = Uri.tryParse(url?.trim() ?? '');
    return u != null &&
        (u.scheme == 'http' || u.scheme == 'https') &&
        u.host.isNotEmpty;
  }

  static const _streamSchemes = {
    'http', 'https', 'rtmp', 'rtmps', 'rtsp', 'rtsps', 'rtp', 'udp', 'mms',
    'mmsh', 'srt',
  };

  /// Erlaubt für Streams. Blockiert u. a. file:, content:, data:, javascript:
  /// – sonst könnte eine manipulierte Playlist lokale Dateien öffnen.
  static bool isStream(String? url) {
    final u = Uri.tryParse(url?.trim() ?? '');
    if (u == null || !_streamSchemes.contains(u.scheme.toLowerCase())) {
      return false;
    }
    return u.host.isNotEmpty || u.scheme == 'udp' || u.scheme == 'rtp';
  }

  /// Bild-URL nur, wenn http(s) – sonst null.
  static String? image(String? url) => isWeb(url) ? url!.trim() : null;

  static bool isUnencrypted(String url) =>
      Uri.tryParse(url.trim())?.scheme == 'http';
}

/// PBKDF2-HMAC-SHA256 für die PIN, mit zufälligem Salz.
class PinHasher {
  static const iterations = 30000;

  static String newSalt() {
    final r = Random.secure();
    return base64Encode(List<int>.generate(16, (_) => r.nextInt(256)));
  }

  static String hash(String pin, String salt) {
    final hmac = Hmac(sha256, utf8.encode(pin));
    final saltBytes = base64Decode(salt);
    // Ein Block (32 Byte) genügt.
    var u = hmac.convert([...saltBytes, 0, 0, 0, 1]).bytes;
    final out = List<int>.from(u);
    for (var i = 1; i < iterations; i++) {
      u = hmac.convert(u).bytes;
      for (var j = 0; j < out.length; j++) {
        out[j] ^= u[j];
      }
    }
    return base64Encode(out);
  }

  /// Vergleich in konstanter Zeit.
  static bool equals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}
