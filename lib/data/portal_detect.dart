/// „Einfügen & erkennen“: Aus beliebigem Text, den ein Anbieter geschickt
/// hat (Xtream-Link, M3U-Adresse, Stalker-Portal + MAC oder Zeilen wie
/// „Host: … / Benutzer: … / Passwort: …“), die Zugangsdaten herauslesen.
///
/// Reine Funktion ohne Netz, ohne Logging – der Text enthält Zugangsdaten.
library;

import '../models/models.dart';

/// Erkannte Zugangsdaten (noch nicht gespeichert).
class PortalDraft {
  final PortalType type;

  /// Xtream: Basis-Adresse (http://host:port). M3U: Playlist-Adresse.
  /// MAC-Portal: Portal-Adresse (…/c/).
  final String url;
  final String? username;
  final String? password;

  /// MAC-Portal: normalisierte MAC (AA:BB:CC:DD:EE:FF).
  final String? mac;

  /// Zusätzlich gefundene XMLTV-Adresse (optional).
  final String? epgUrl;

  const PortalDraft({
    required this.type,
    required this.url,
    this.username,
    this.password,
    this.mac,
    this.epgUrl,
  });

  /// „host:port“ für die Anzeige („Erkannt: Xtream · host:port“).
  String get hostLabel {
    final u = Uri.tryParse(url);
    if (u == null || u.host.isEmpty) return url;
    return u.hasPort ? '${u.host}:${u.port}' : u.host;
  }

  @override
  String toString() => 'PortalDraft(${type.name}, $hostLabel)';
}

final _urlRe = RegExp(r'''https?://[^\s<>"'`]+''', caseSensitive: false);
final _macRe = RegExp(
    r'(?<![0-9A-Za-z:-])([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}(?![0-9A-Za-z:-])');

/// Beschriftungen (de/en/tr), kleingeschrieben, ohne Sonderzeichen.
const _hostLabels = {
  'host', 'hostname', 'server', 'serveur', 'servidor', 'url', 'adresse',
  'address', 'portal', 'portal url', 'server url', 'dns', 'domain', 'link',
  'sunucu', 'adres', 'host adresi', 'sunucu adresi', 'ip',
};
const _portLabels = {'port', 'puerto', 'bağlantı noktası', 'baglanti noktasi'};
const _userLabels = {
  'username', 'user', 'user name', 'login', 'benutzer', 'benutzername',
  'nutzer', 'nutzername', 'kullanıcı', 'kullanici', 'kullanıcı adı',
  'kullanici adi', 'kullanıcı adi', 'usuario', 'utilisateur',
};
const _passLabels = {
  'password', 'pass', 'pwd', 'passwort', 'kennwort', 'şifre', 'sifre',
  'parola', 'contraseña', 'mot de passe',
};
const _macLabels = {'mac', 'mac adresse', 'mac address', 'mac adresi'};

/// Erkennt Zugangsdaten in [text]. `null`, wenn nichts Verwertbares drin ist.
PortalDraft? detectPortalInput(String text) {
  final src = text.trim();
  if (src.isEmpty) return null;

  // 1) Adressen einsammeln (ohne Satzzeichen am Ende).
  final urls = <Uri>[];
  for (final m in _urlRe.allMatches(src)) {
    var s = m.group(0)!;
    s = s.replaceFirst(RegExp(r'''[.,;:!?)\]}'"»”]+$'''), '');
    final u = Uri.tryParse(s);
    if (u != null && u.host.isNotEmpty) urls.add(u);
  }

  // 2) Beschriftete Zeilen („Benutzer: …“).
  final fields = _labeledFields(src);

  // 3) MAC irgendwo im Text (oder beschriftet).
  String? mac;
  final macField = fields['mac'];
  final macMatch = macField != null ? _macRe.firstMatch(macField) : null;
  final anyMac = macMatch ?? _macRe.firstMatch(src);
  if (anyMac != null) mac = _normalizeMac(anyMac.group(0)!);

  // XMLTV-Adressen zählen nur als EPG, nicht als Portal.
  String? epgUrl;
  final mainUrls = <Uri>[];
  for (final u in urls) {
    if (_isEpgUrl(u)) {
      epgUrl ??= u.toString();
    } else {
      mainUrls.add(u);
    }
  }

  // 4) Xtream-Link (get.php / player_api.php / username+password im Query).
  for (final u in mainUrls) {
    final q = _rawQuery(u);
    final user = q['username'];
    final pass = q['password'];
    final file = _lastSegment(u).toLowerCase();
    final xtreamFile = file == 'get.php' ||
        file == 'player_api.php' ||
        file == 'panel_api.php' ||
        file == 'xmltv.php';
    if ((user != null && pass != null) || xtreamFile) {
      final type = q['type'];
      final isM3uList = (type != null && type.startsWith('m3u')) ||
          file == 'get.php';
      if (user != null && pass != null && user.isNotEmpty && pass.isNotEmpty) {
        return PortalDraft(
          type: PortalType.xtream,
          url: _xtreamBase(u),
          username: user,
          password: pass,
          epgUrl: epgUrl,
        );
      }
      if (isM3uList) {
        // get.php ohne Zugangsdaten im Link → als Playlist übernehmen.
        return PortalDraft(
            type: PortalType.m3u, url: u.toString(), epgUrl: epgUrl);
      }
    }
  }

  // 5) Stalker/MAC-Portal: MAC vorhanden (oder /c/-Pfad) + Adresse.
  final stalkerUrl = mainUrls.where(_looksStalker).firstOrNull;
  if (mac != null || stalkerUrl != null) {
    final base = stalkerUrl ?? mainUrls.firstOrNull;
    String? url;
    if (base != null) {
      url = _stalkerUrl(base);
    } else {
      final host = _hostFromFields(fields);
      if (host != null) url = _stalkerUrl(host);
    }
    if (url != null && (mac != null || fields['user'] == null)) {
      return PortalDraft(
        type: PortalType.stalker,
        url: url,
        mac: mac,
        epgUrl: epgUrl,
      );
    }
  }

  // 6) Beschriftete Zugangsdaten + Adresse/Host.
  final user = fields['user'];
  final pass = fields['pass'];
  if (user != null && pass != null) {
    Uri? base = mainUrls.firstOrNull;
    base ??= _hostFromFields(fields);
    if (base != null) {
      final port = fields['port'];
      if (port != null && !base.hasPort) {
        final p = int.tryParse(port);
        if (p != null && p > 0 && p < 65536) base = base.replace(port: p);
      }
      return PortalDraft(
        type: PortalType.xtream,
        url: _xtreamBase(base),
        username: user,
        password: pass,
        epgUrl: epgUrl,
      );
    }
  }

  // 7) Nur eine Adresse: Playlist-Datei → M3U, nackter Server → Xtream.
  final only = mainUrls.firstOrNull;
  if (only != null) {
    if (_looksM3u(only)) {
      return PortalDraft(
          type: PortalType.m3u, url: only.toString(), epgUrl: epgUrl);
    }
    final path = only.path.replaceAll(RegExp(r'/+$'), '');
    if (path.isEmpty && !only.hasQuery) {
      return PortalDraft(
        type: PortalType.xtream,
        url: _xtreamBase(only),
        username: user,
        password: pass,
        epgUrl: epgUrl,
      );
    }
    // Unbekannter Pfad: am ehesten eine Playlist.
    return PortalDraft(
        type: PortalType.m3u, url: only.toString(), epgUrl: epgUrl);
  }

  // 8) Host (+ Port) ohne Schema, ggf. nur mit Benutzername.
  final host = _hostFromFields(fields);
  if (host != null) {
    var base = host;
    final port = fields['port'];
    if (port != null && !base.hasPort) {
      final p = int.tryParse(port);
      if (p != null && p > 0 && p < 65536) base = base.replace(port: p);
    }
    return PortalDraft(
      type: PortalType.xtream,
      url: _xtreamBase(base),
      username: user,
      password: pass,
      epgUrl: epgUrl,
    );
  }
  return null;
}

// -----------------------------------------------------------------------------

/// Zeilen „Label: Wert“ bzw. „Label = Wert“ → {'host','port','user','pass','mac'}.
/// Erster Treffer je Feld gewinnt.
Map<String, String> _labeledFields(String src) {
  final out = <String, String>{};
  final lineRe = RegExp(r'^\s*([^\n:=]{1,40}?)\s*[:=]\s*(.+?)\s*$');
  for (final raw in src.split(RegExp(r'\r?\n'))) {
    // Mehrere Felder in einer Zeile („Benutzer: a  Passwort: b“) trennen.
    for (final line in _splitInline(raw)) {
      final m = lineRe.firstMatch(line);
      if (m == null) continue;
      final label = _normLabel(m.group(1)!);
      var value = m.group(2)!.trim();
      // „Passwort: "abc"“ → abc
      if (value.length >= 2 &&
          ((value.startsWith('"') && value.endsWith('"')) ||
              (value.startsWith("'") && value.endsWith("'")) ||
              (value.startsWith('„') && value.endsWith('“')))) {
        value = value.substring(1, value.length - 1);
      }
      if (value.isEmpty) continue;
      String? key;
      if (_userLabels.contains(label)) {
        key = 'user';
      } else if (_passLabels.contains(label)) {
        key = 'pass';
      } else if (_macLabels.contains(label)) {
        key = 'mac';
      } else if (_portLabels.contains(label)) {
        key = 'port';
      } else if (_hostLabels.contains(label)) {
        key = 'host';
      }
      if (key == null) continue;
      if (key == 'host' && value.startsWith('http')) {
        // „URL: http://host:8080“ – die Adresse wird separat gefunden.
        out.putIfAbsent('host', () => value);
        continue;
      }
      out.putIfAbsent(key, () => value);
    }
  }
  return out;
}

/// „Benutzer: a   Passwort: b“ → zwei Zeilen. Getrennt wird nur vor einer
/// bekannten Beschriftung, damit Werte mit Doppelpunkt (http://…) heil bleiben.
Iterable<String> _splitInline(String line) {
  final labels = [
    ..._userLabels, ..._passLabels, ..._macLabels, ..._portLabels,
    ..._hostLabels,
  ]..sort((a, b) => b.length.compareTo(a.length));
  final alt = labels.map(RegExp.escape).join('|');
  final re = RegExp('(?<=\\S)\\s{2,}(?=(?:$alt)\\s*[:=])|'
      '(?<=\\S)\\s*[,;|]\\s*(?=(?:$alt)\\s*[:=])', caseSensitive: false);
  return line.split(re);
}

String _normLabel(String s) => s
    .toLowerCase()
    .replaceAll(RegExp(r'[*_\-#()\[\]"„“]'), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

/// Query-Parameter ohne „+ → Leerzeichen“: Anbieter setzen Zugangsdaten
/// unkodiert in den Link; `%xx` wird aber aufgelöst.
Map<String, String> _rawQuery(Uri u) {
  final out = <String, String>{};
  if (!u.hasQuery) return out;
  for (final part in u.query.split('&')) {
    if (part.isEmpty) continue;
    final i = part.indexOf('=');
    final k = i < 0 ? part : part.substring(0, i);
    final v = i < 0 ? '' : part.substring(i + 1);
    String dec(String s) {
      try {
        return Uri.decodeComponent(s);
      } catch (_) {
        return s;
      }
    }
    out.putIfAbsent(dec(k).toLowerCase(), () => dec(v));
  }
  return out;
}

String _lastSegment(Uri u) =>
    u.pathSegments.isEmpty ? '' : u.pathSegments.last;

bool _isEpgUrl(Uri u) {
  final file = _lastSegment(u).toLowerCase();
  if (file == 'xmltv.php') return true;
  final path = u.path.toLowerCase();
  return path.endsWith('.xml') || path.endsWith('.xml.gz') ||
      path.endsWith('.xmltv');
}

bool _looksM3u(Uri u) {
  final path = u.path.toLowerCase();
  if (path.endsWith('.m3u') || path.endsWith('.m3u8')) return true;
  final q = _rawQuery(u);
  final type = q['type'] ?? '';
  final output = q['output'] ?? '';
  return type.startsWith('m3u') || output.isNotEmpty;
}

bool _looksStalker(Uri u) {
  final p = u.path.toLowerCase();
  return p.contains('/stalker_portal') ||
      p == '/c' ||
      p == '/c/' ||
      p.endsWith('/c/') ||
      p.endsWith('/portal.php') ||
      p.endsWith('/load.php');
}

/// Xtream-Basis: Schema + Host + Port (+ Pfad-Präfix vor der PHP-Datei).
String _xtreamBase(Uri u) {
  var path = u.path;
  if (_lastSegment(u).toLowerCase().endsWith('.php')) {
    path = path.substring(0, path.lastIndexOf('/'));
  }
  path = path.replaceAll(RegExp(r'/+$'), '');
  final scheme = u.scheme.isEmpty ? 'http' : u.scheme.toLowerCase();
  final port = u.hasPort ? ':${u.port}' : '';
  return '$scheme://${u.host}$port$path';
}

/// Portal-Adresse für MAC-Portale: Pfad bis …/c/ bzw. …/stalker_portal/c/.
String _stalkerUrl(Uri u) {
  final scheme = u.scheme.isEmpty ? 'http' : u.scheme.toLowerCase();
  final port = u.hasPort ? ':${u.port}' : '';
  var path = u.path;
  final lower = path.toLowerCase();
  if (lower.endsWith('.php')) {
    path = path.substring(0, path.lastIndexOf('/') + 1);
    if (path.toLowerCase().endsWith('/server/')) {
      path = path.substring(0, path.length - 'server/'.length);
    }
  }
  if (!path.endsWith('/')) path = '$path/';
  if (path == '/') {
    path = '/c/';
  } else if (!path.toLowerCase().endsWith('/c/')) {
    path = '${path}c/';
  }
  return '$scheme://${u.host}$port$path';
}

Uri? _hostFromFields(Map<String, String> f) {
  final raw = f['host'];
  if (raw == null) return null;
  var s = raw.trim().replaceAll(RegExp(r'/+$'), '');
  if (s.isEmpty) return null;
  if (!s.contains('://')) s = 'http://$s';
  final u = Uri.tryParse(s);
  if (u == null || u.host.isEmpty) return null;
  return u;
}

String _normalizeMac(String m) => m.toUpperCase().replaceAll('-', ':');
