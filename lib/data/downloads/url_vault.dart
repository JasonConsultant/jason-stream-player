/// Download-Adressen ohne Zugangsdaten speichern (wie die Listen seit 2.0):
/// Benutzername, Passwort bzw. Medienserver-Token werden vor dem Speichern
/// durch benannte Platzhalter ersetzt und erst beim Laden wieder
/// eingesetzt. Benannt (nicht durchnummeriert), damit geänderte
/// Zugangsdaten beim Fortsetzen richtig eingesetzt werden.
class UrlVault {
  UrlVault._();

  static const _mark = '\u0000';

  /// Platzhalter → Wert. Die Reihenfolge zählt beim Maskieren (längste
  /// zuerst, damit kurze Werte nicht in längeren ersetzt werden).
  static Map<String, String> secretsOf(
      {String? username, String? password, String? token}) {
    final out = <String, String>{};
    void add(String name, String? v) {
      if (v == null || v.length < 2) return;
      out[name] = v;
      final enc = Uri.encodeComponent(v);
      if (enc != v) out['${name}e'] = enc;
      final q = Uri.encodeQueryComponent(v);
      if (q != v && q != enc) out['${name}q'] = q;
    }

    add('U', username);
    add('P', password);
    add('T', token);
    return out;
  }

  /// Zugangsdaten durch Platzhalter ersetzen.
  static String mask(String url, Map<String, String> secrets) {
    final order = secrets.entries.toList()
      ..sort((a, b) => b.value.length.compareTo(a.value.length));
    var s = url;
    for (final e in order) {
      s = s.replaceAll(e.value, '$_mark${e.key}$_mark');
    }
    return s;
  }

  /// Platzhalter wieder einsetzen. null = ein Platzhalter ist nicht
  /// auflösbar (Zugangsdaten fehlen inzwischen).
  static String? unmask(String masked, Map<String, String> secrets) {
    if (!masked.contains(_mark)) return masked;
    final out = masked.replaceAllMapped(
        RegExp('$_mark([A-Za-z]{1,3})$_mark'),
        (m) => secrets[m[1]] ?? '$_mark?$_mark');
    return out.contains(_mark) ? null : out;
  }

  /// Für Anzeige/Logs: Platzhalter sichtbar machen (nie Zugangsdaten).
  static String display(String masked) =>
      masked.replaceAllMapped(RegExp('$_mark([A-Za-z]{1,3})$_mark'),
          (m) => '{${m[1]}}');
}
