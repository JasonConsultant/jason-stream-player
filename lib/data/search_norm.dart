/// Such-Normalisierung (Suchindex in der Datenbank und Suchbegriff).
///
/// Wie bisher Kleinbuchstaben + „enthält“, zusätzlich ohne Akzente und mit
/// türkischen Sonderfällen: „ş“ findet „s“ und umgekehrt, „ı“, „I“ und „İ“
/// werden zu „i“, „ß“ zu „ss“. So findet „sahin“ auch „Şahin“ und „cocuk“
/// auch „Çocuk“ – „Şahin“ findet weiterhin „Şahin“.
String foldSearch(String s) {
  if (s.isEmpty) return s;
  // Schneller Weg: reines ASCII.
  var ascii = true;
  for (var i = 0; i < s.length; i++) {
    if (s.codeUnitAt(i) > 0x7f) {
      ascii = false;
      break;
    }
  }
  if (ascii) return s.toLowerCase();
  final out = StringBuffer();
  for (final r in s.runes) {
    if (r < 0x80) {
      out.writeCharCode(r >= 0x41 && r <= 0x5a ? r + 32 : r);
      continue;
    }
    final m = _map[r];
    if (m != null) {
      out.write(m);
      continue;
    }
    // Kleinbuchstaben; kombinierende Zeichen (U+0300–U+036F) entfallen.
    for (final x in String.fromCharCode(r).toLowerCase().runes) {
      if (x >= 0x0300 && x <= 0x036f) continue;
      out.write(_map[x] ?? String.fromCharCode(x));
    }
  }
  return out.toString();
}

const Map<int, String> _map = {
  0x0130: 'i', // İ
  0x0131: 'i', // ı
  0x0049: 'i', // I
  0x00df: 'ss', // ß
  0x1e9e: 'ss', // ẞ
  0x00e0: 'a', 0x00e1: 'a', 0x00e2: 'a', 0x00e3: 'a', 0x00e4: 'a',
  0x00e5: 'a', 0x0101: 'a', 0x0103: 'a', 0x0105: 'a',
  0x00e7: 'c', 0x0107: 'c', 0x010d: 'c',
  0x010f: 'd', 0x0111: 'd',
  0x00e8: 'e', 0x00e9: 'e', 0x00ea: 'e', 0x00eb: 'e', 0x0113: 'e',
  0x0117: 'e', 0x0119: 'e', 0x011b: 'e',
  0x011f: 'g', // ğ
  0x00ec: 'i', 0x00ed: 'i', 0x00ee: 'i', 0x00ef: 'i', 0x012b: 'i',
  0x012f: 'i',
  0x0142: 'l', 0x013e: 'l',
  0x00f1: 'n', 0x0144: 'n', 0x0148: 'n',
  0x00f2: 'o', 0x00f3: 'o', 0x00f4: 'o', 0x00f5: 'o', 0x00f6: 'o',
  0x00f8: 'o', 0x014d: 'o', 0x0151: 'o',
  0x0155: 'r', 0x0159: 'r',
  0x015b: 's', 0x015f: 's', 0x0161: 's', 0x0219: 's', // ś ş š ș
  0x0163: 't', 0x0165: 't', 0x021b: 't',
  0x00f9: 'u', 0x00fa: 'u', 0x00fb: 'u', 0x00fc: 'u', 0x016b: 'u',
  0x016f: 'u', 0x0171: 'u', 0x0173: 'u',
  0x00fd: 'y', 0x00ff: 'y',
  0x017a: 'z', 0x017c: 'z', 0x017e: 'z',
};
