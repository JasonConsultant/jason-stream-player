/// Erkennung von Erwachsenen-Gruppen und Länderkennungen in Gruppen- und
/// Sendernamen (reine Logik, ohne Oberfläche – getestet in
/// content_filters_test.dart).
library;

/// Für die Suche vorbereiteter Text: Kleinbuchstaben, türkisches İ/I wie i
/// (sonst wird „YETİŞKİN“ zu „yeti̇şki̇n“ mit Extra-Punkt).
String _norm(String s) => s
    .replaceAll('İ', 'i')
    .replaceAll('I', 'i')
    .replaceAll('ı', 'i')
    .toLowerCase();

/// Erwachsenen-Gruppen am Namen erkennen (XXX, Adult, 18+, Erwachsene,
/// Yetişkin, porn, Hustler, Playboy, Brazzers, Private …) – nur ganze
/// Wörter, damit z. B. „Essex“ oder „Sexy“ nicht gesperrt werden.
class AdultDetector {
  AdultDetector._();

  static final _words = RegExp(
    r'(?<![\p{L}\p{N}])('
    r'x{3,}'
    r'|adult(?:s|os|as|es|e|i|o)?'
    r'|erwachsene\p{L}*'
    r'|yeti[sş]kin\p{L}*'
    r'|porn\p{L}*'
    r'|hustler|playboy|brazzers|private|penthouse|dorcel|redlight'
    r')(?![\p{L}\p{N}])',
    unicode: true,
  );

  /// 18+ / +18 / 18 + (ohne Nachbarziffern, z. B. nicht „118+“ oder „+180“).
  static final _eighteen = RegExp(
    r'(?<![\p{N}])(?:18\s?\+|\+\s?18)(?![\p{N}])',
    unicode: true,
  );

  /// Bekannte harmlose Namen, die sonst passen würden.
  static final _harmless = RegExp(r'adult\s*swim', unicode: true);

  static bool isAdult(String name) {
    final n = _norm(name);
    if (n.isEmpty) return false;
    if (_eighteen.hasMatch(n)) return true;
    final m = _words.firstMatch(n);
    if (m == null) return false;
    if (_harmless.hasMatch(n) &&
        _words.allMatches(n).length == 1 &&
        m.group(1)!.startsWith('adult')) {
      return false;
    }
    return true;
  }
}

/// Länderkennung aus Gruppen-/Sendernamen („DE | Sport“, „[TR] TRT 1“,
/// „UK: BBC One“, „EX-YU“, „Germany“, „Türkiye“ …).
class CountryDetector {
  CountryDetector._();

  /// Sammelbecken für alles ohne erkennbares Land.
  static const none = '_none';

  /// Reihenfolge für die Anzeige.
  static const codes = [
    'DE',
    'AT',
    'CH',
    'TR',
    'UK',
    'AL',
    'FR',
    'IT',
    'ES',
    'PT',
    'NL',
    'BE',
    'PL',
    'RO',
    'EXYU',
    'GR',
    'BG',
    'HU',
    'CZ',
    'RU',
    'UA',
    'SE',
    'NO',
    'DK',
    'FI',
    'KU',
    'AR',
    'IR',
    'IN',
    'PK',
    'AF',
    'US',
    'CA',
    'LATAM',
  ];

  /// Kürzel am Namensanfang bzw. als eigener Abschnitt → Land.
  static const _codeMap = {
    'DE': 'DE',
    'GER': 'DE',
    'DEU': 'DE',
    'AT': 'AT',
    'AUT': 'AT',
    'CH': 'CH',
    'SUI': 'CH',
    'TR': 'TR',
    'TUR': 'TR',
    'TRK': 'TR',
    'UK': 'UK',
    'GB': 'UK',
    'ENG': 'UK',
    'GBR': 'UK',
    'AL': 'AL',
    'ALB': 'AL',
    'FR': 'FR',
    'FRA': 'FR',
    'IT': 'IT',
    'ITA': 'IT',
    'ES': 'ES',
    'ESP': 'ES',
    'SPA': 'ES',
    'PT': 'PT',
    'POR': 'PT',
    'NL': 'NL',
    'NLD': 'NL',
    'NED': 'NL',
    'BE': 'BE',
    'BEL': 'BE',
    'PL': 'PL',
    'POL': 'PL',
    'RO': 'RO',
    'ROU': 'RO',
    'ROM': 'RO',
    'RS': 'EXYU',
    'SRB': 'EXYU',
    'EXYU': 'EXYU',
    'EX-YU': 'EXYU',
    'YU': 'EXYU',
    'HR': 'EXYU',
    'HRV': 'EXYU',
    'BA': 'EXYU',
    'BIH': 'EXYU',
    'MK': 'EXYU',
    'SI': 'EXYU',
    'SLO': 'EXYU',
    'ME': 'EXYU',
    'CG': 'EXYU',
    'GR': 'GR',
    'GRE': 'GR',
    'BG': 'BG',
    'BUL': 'BG',
    'HU': 'HU',
    'HUN': 'HU',
    'CZ': 'CZ',
    'CZE': 'CZ',
    'SK': 'CZ',
    'RU': 'RU',
    'RUS': 'RU',
    'UA': 'UA',
    'UKR': 'UA',
    'SE': 'SE',
    'SWE': 'SE',
    'NO': 'NO',
    'NOR': 'NO',
    'DK': 'DK',
    'DAN': 'DK',
    'FI': 'FI',
    'FIN': 'FI',
    'KU': 'KU',
    'KUR': 'KU',
    'AR': 'AR',
    'ARA': 'AR',
    'ARAB': 'AR',
    'IR': 'IR',
    'PER': 'IR',
    'IN': 'IN',
    'IND': 'IN',
    'PK': 'PK',
    'PAK': 'PK',
    'AF': 'AF',
    'AFG': 'AF',
    'US': 'US',
    'USA': 'US',
    'CA': 'CA',
    'CAN': 'CA',
    'LAT': 'LATAM',
    'LATAM': 'LATAM',
    'LATINO': 'LATAM',
    'MX': 'LATAM',
  };

  /// Ländernamen irgendwo im Gruppennamen (ganze Wörter, klein).
  static const _nameMap = {
    'germany': 'DE',
    'deutschland': 'DE',
    'german': 'DE',
    'deutsch': 'DE',
    'almanya': 'DE',
    'austria': 'AT',
    'österreich': 'AT',
    'osterreich': 'AT',
    'switzerland': 'CH',
    'schweiz': 'CH',
    'swiss': 'CH',
    'suisse': 'CH',
    'turkey': 'TR',
    'türkiye': 'TR',
    'turkiye': 'TR',
    'türkei': 'TR',
    'turkish': 'TR',
    'türk': 'TR',
    'turk': 'TR',
    'united kingdom': 'UK',
    'england': 'UK',
    'british': 'UK',
    'albania': 'AL',
    'albanien': 'AL',
    'shqip': 'AL',
    'shqiperia': 'AL',
    'france': 'FR',
    'french': 'FR',
    'frankreich': 'FR',
    'italy': 'IT',
    'italia': 'IT',
    'italien': 'IT',
    'italian': 'IT',
    'spain': 'ES',
    'españa': 'ES',
    'espana': 'ES',
    'spanien': 'ES',
    'portugal': 'PT',
    'netherlands': 'NL',
    'nederland': 'NL',
    'holland': 'NL',
    'dutch': 'NL',
    'niederlande': 'NL',
    'belgium': 'BE',
    'belgien': 'BE',
    'poland': 'PL',
    'polska': 'PL',
    'polen': 'PL',
    'romania': 'RO',
    'rumänien': 'RO',
    'serbia': 'EXYU',
    'srbija': 'EXYU',
    'ex-yu': 'EXYU',
    'exyu': 'EXYU',
    'balkan': 'EXYU',
    'yugoslavia': 'EXYU',
    'croatia': 'EXYU',
    'bosnia': 'EXYU',
    'hrvatska': 'EXYU',
    'greece': 'GR',
    'griechenland': 'GR',
    'bulgaria': 'BG',
    'hungary': 'HU',
    'czech': 'CZ',
    'russia': 'RU',
    'russland': 'RU',
    'ukraine': 'UA',
    'sweden': 'SE',
    'norway': 'NO',
    'denmark': 'DK',
    'finland': 'FI',
    'kurdish': 'KU',
    'kurdistan': 'KU',
    'kurdî': 'KU',
    'arabic': 'AR',
    'arab': 'AR',
    'arabisch': 'AR',
    'iran': 'IR',
    'persian': 'IR',
    'india': 'IN',
    'indian': 'IN',
    'pakistan': 'PK',
    'afghanistan': 'AF',
    'usa': 'US',
    'united states': 'US',
    'canada': 'CA',
    'latino': 'LATAM',
    'latin': 'LATAM',
    'mexico': 'LATAM',
  };

  static final _prefix = RegExp(
      r'^[\s|\[\(#*•\-~★]*([A-Za-z]{2,6}(?:-[A-Za-z]{2})?)($|[\s:|\]\)•\-_./,]|[^\x00-\x7F])');

  /// Kürzel, die auch normale Wörter sein können („IN“, „ME“, „IT“, „NO“,
  /// „US“ …): nur mit klarem Trenner (:, |, ], -, •), nicht nur Leerzeichen.
  static const _ambiguous = {
    'IN',
    'ME',
    'IT',
    'NO',
    'US',
    'CA',
    'SI',
    'BA',
    'AF',
    'ES',
    'SE',
    'BE',
    'CG',
    'MX',
    'AR',
    'PER',
    'CAN',
    'LAT',
    'SPA',
    'DAN',
    'FIN',
    'POR',
    'ARAB',
    // Auch Sendernamen: „HR Fernsehen“ (Hessischer Rundfunk), „AL Jazeera“.
    'HR',
    'AL',
    'SK',
    'RS',
  };
  static final _segments = RegExp(r'[|:\[\]•()]');
  static final _nameRe = RegExp(
    r'(?<![\p{L}\p{N}])('
    '${(_nameMap.keys.toList()..sort((a, b) => b.length.compareTo(a.length))).map(RegExp.escape).join('|')}'
    r')(?![\p{L}\p{N}])',
    unicode: true,
  );

  /// Bekanntes Länderkürzel („GER“ → „DE“), sonst null.
  static String? normalizeCode(String token) => _codeMap[token.toUpperCase()];

  /// Kürzel am Anfang oder als eigener Abschnitt („VIP | DE | Sport“).
  /// Nur Großschreibung zählt („Al Jazeera“ ist nicht Albanien).
  static String? fromPrefix(String name) {
    final m = _prefix.firstMatch(name);
    if (m != null) {
      final tok = m.group(1)!;
      final sep = m.group(2)!;
      // „RS - Pink“: nach dem Leerzeichen folgt noch ein klarer Trenner.
      final rest = name.substring(m.end - sep.length).trimLeft();
      final strongAfterSpace = sep.trim().isEmpty &&
          rest.isNotEmpty &&
          ':|]-)•'.contains(rest[0]);
      final weak = (sep.trim().isEmpty && !strongAfterSpace) ||
          sep == '.' ||
          sep == '_';
      if (tok == tok.toUpperCase() && !(weak && _ambiguous.contains(tok))) {
        final c = _codeMap[tok];
        if (c != null) return c;
      }
    }
    if (_segments.hasMatch(name)) {
      for (final part in name.split(_segments)) {
        final t = part.trim();
        if (t.length < 2 || t.length > 6 || t != t.toUpperCase()) continue;
        final c = _codeMap[t];
        if (c != null) return c;
      }
    }
    return null;
  }

  /// Land einer Gruppe: Kürzel oder ausgeschriebener Ländername.
  static String? fromGroup(String name) {
    final p = fromPrefix(name);
    if (p != null) return p;
    final m = _nameRe.firstMatch(name.toLowerCase());
    return m == null ? null : _nameMap[m.group(1)!];
  }

  /// Land eines Senders/Titels: eigenes Kürzel, sonst das der Gruppe.
  static String? forItem(String name, String? groupCode) =>
      fromPrefix(name) ?? groupCode;

  /// Filter: [allowed] leer = alles; [none] steht für „ohne Länderkennung“.
  static bool passes(String? code, Set<String> allowed) =>
      allowed.isEmpty || allowed.contains(code ?? none);
}
