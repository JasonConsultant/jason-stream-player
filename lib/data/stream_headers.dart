import 'dart:convert';

import '../models/models.dart';
import 'net.dart';

/// HTTP-Header für Portal-Anfragen (API, Playlist, EPG) und Streams.
///
/// Erlaubt sind nur **User-Agent, Referer, Origin und Cookie** – alles
/// andere aus Playlisten (z. B. DRM-/Lizenzangaben) wird bewusst ignoriert.

/// User-Agent-Vorlagen für „Erweitert“ beim Portal.
class UserAgentPreset {
  final String id;
  final String label;

  /// null = App-Standard (kein eigener Header).
  final String? value;
  const UserAgentPreset(this.id, this.label, this.value);

  static const vlc = 'VLC/3.0.20 LibVLC/3.0.20';
  static const browser =
      'Mozilla/5.0 (Linux; Android 11; Android TV) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  /// Die Bezeichnungen sind Eigennamen bzw. werden in der UI übersetzt.
  static const all = [
    UserAgentPreset('app', 'App', null),
    UserAgentPreset('vlc', 'VLC', vlc),
    UserAgentPreset('browser', 'Mozilla/5.0 …', browser),
  ];

  /// Passende Vorlage zu einem gespeicherten Wert ('custom' = eigener Text).
  static String idOf(String? ua) {
    if (ua == null || ua.trim().isEmpty) return 'app';
    for (final p in all) {
      if (p.value == ua) return p.id;
    }
    return 'custom';
  }
}

/// Kanonische Schreibweise erlaubter Header, null = nicht erlaubt.
String? canonicalHeader(String name) {
  switch (name.trim().toLowerCase()) {
    case 'user-agent':
    case 'useragent':
    case 'http-user-agent':
      return 'User-Agent';
    case 'referer':
    case 'referrer':
    case 'http-referrer':
    case 'http-referer':
      return 'Referer';
    case 'origin':
    case 'http-origin':
      return 'Origin';
    case 'cookie':
    case 'http-cookie':
      return 'Cookie';
  }
  return null;
}

/// Zeilenumbrüche/Steuerzeichen entfernen (Header-Injection verhindern).
String? _cleanValue(String? v) {
  if (v == null) return null;
  final s = v.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '').trim();
  return s.isEmpty || s.length > 2048 ? null : s;
}

void _put(Map<String, String> out, String name, String? value) {
  final k = canonicalHeader(name);
  final v = _cleanValue(value);
  if (k != null && v != null) out[k] = v;
}

String _decode(String v) {
  try {
    return Uri.decodeComponent(v.replaceAll('+', '%20'));
  } catch (_) {
    return v;
  }
}

/// `a=b&c=d` (Werte ggf. URL-kodiert) → erlaubte Header.
Map<String, String> parseHeaderQuery(String s) {
  final out = <String, String>{};
  for (final part in s.split('&')) {
    final eq = part.indexOf('=');
    if (eq <= 0) continue;
    _put(out, _decode(part.substring(0, eq)), _decode(part.substring(eq + 1)));
  }
  return out;
}

/// Header aus einer M3U-Zeile (#EXTVLCOPT, #KODIPROP, #EXTHTTP).
/// Lizenz-/DRM-Angaben liefern immer ein leeres Ergebnis.
Map<String, String> parseM3uOptionLine(String line) {
  final out = <String, String>{};
  final l = line.trim();
  if (l.toUpperCase().startsWith('#EXTVLCOPT:')) {
    final body = l.substring(11).trim();
    final eq = body.indexOf('=');
    if (eq > 0) _put(out, body.substring(0, eq), body.substring(eq + 1));
    return out;
  }
  if (l.toUpperCase().startsWith('#KODIPROP:')) {
    final body = l.substring(10).trim();
    final eq = body.indexOf('=');
    if (eq <= 0) return out;
    final key = body.substring(0, eq).trim().toLowerCase();
    // Nur reine Header-Angaben – nie license_key/license_type/… (DRM).
    const headerProps = {
      'inputstream.adaptive.stream_headers',
      'inputstream.adaptive.manifest_headers',
      'inputstream.adaptive.common_headers',
    };
    if (!headerProps.contains(key)) return out;
    return parseHeaderQuery(body.substring(eq + 1).trim());
  }
  if (l.toUpperCase().startsWith('#EXTHTTP:')) {
    try {
      final j = jsonDecode(l.substring(9).trim());
      if (j is Map) {
        for (final e in j.entries) {
          if (e.value is String) _put(out, '${e.key}', e.value as String);
        }
      }
    } catch (_) {}
    return out;
  }
  return out;
}

/// Stream-Adresse mit „|User-Agent=…&Referer=…“-Anhang: Adresse ohne
/// Anhang und die erlaubten Header daraus.
(String url, Map<String, String> headers) splitPipeHeaders(String url) {
  final i = url.indexOf('|');
  if (i < 0) return (url, const {});
  return (url.substring(0, i).trim(), parseHeaderQuery(url.substring(i + 1)));
}

/// Header für Anfragen an das Portal selbst (API, Playlist, EPG):
/// eigener User-Agent und Referer aus „Erweitert“.
Map<String, String> portalHeaders(Portal p) {
  final out = <String, String>{};
  _put(out, 'User-Agent', p.userAgent);
  _put(out, 'Referer', p.referer);
  return out;
}

/// Header zum Abspielen: Portal-Einstellungen, überschrieben von den
/// Angaben des Senders aus der Playlist (die sind spezifischer).
/// Leere Map = Player-Standard verwenden.
Map<String, String> streamHeadersFor(Portal p, Channel? c) {
  final out = portalHeaders(p);
  final ch = c?.headers;
  if (ch != null) {
    for (final e in ch.entries) {
      _put(out, e.key, e.value);
    }
  }
  return out;
}

/// User-Agent, den die App ohne eigene Einstellung sendet.
String get appUserAgent => Net.userAgent;
