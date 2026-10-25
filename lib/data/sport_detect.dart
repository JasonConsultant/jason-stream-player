/// Erkennt Sport-Sendungen und Sport-Gruppen (Deutsch, Englisch, Türkisch)
/// anhand von Titel, EPG-Kategorie und Gruppenname. Wortbasiert, damit
/// „Sportschau“ oder „Motorsport“ zählen, „Transport“ aber nicht.
class SportDetector {
  SportDetector._();

  static final _word = RegExp(r'[\p{L}\p{N}]+', unicode: true);

  /// Einzelwörter (klein), die immer Sport bedeuten.
  static const _words = {
    'fußball', 'fussball', 'football', 'soccer', 'futbol', 'bundesliga',
    'tennis', 'f1', 'formel1', 'formula1', 'motogp', 'nascar', 'basketball',
    'basketbol', 'voleybol', 'volleyball', 'handball', 'hentbol', 'ufc',
    'mma', 'boxen', 'boxing', 'boks', 'wrestling', 'wwe', 'nba', 'nfl',
    'nhl', 'mlb', 'uefa', 'fifa', 'dfb', 'eishockey', 'hockey', 'darts',
    'snooker', 'biathlon', 'skispringen', 'leichtathletik', 'athletics',
    'atletizm', 'radsport', 'cycling', 'bisiklet', 'rugby', 'cricket',
    'golf', 'superbowl', 'maç', 'mac', 'derbi', 'derby', 'olympia',
    'olympics', 'olimpiyat', 'liga', 'ligi', 'pokal', 'kupa', 'grand',
    'esports', 'esport', 'pga', 'atp', 'wta', 'euroleague',
  };

  /// Wörter, die nur zusammen mit einem anderen Wort Sport bedeuten
  /// (z. B. „Champions League“, „Formel 1“, „Süper Lig“).
  static const _pairs = {
    ('champions', 'league'), ('europa', 'league'), ('conference', 'league'),
    ('premier', 'league'), ('la', 'liga'), ('serie', 'a'), ('süper', 'lig'),
    ('super', 'lig'), ('formel', '1'), ('formula', '1'), ('tour', 'de'),
    ('grand', 'prix'), ('world', 'cup'), ('dünya', 'kupası'),
    ('ski', 'alpin'), ('ski', 'weltcup'),
  };

  /// Allein zu unsicher (Sendernamen, Alltagswörter) – nur in Verbindung.
  static const _weak = {'liga', 'ligi', 'pokal', 'kupa', 'grand', 'mac',
    'derby', 'golf'};

  /// Wortanfänge, die *kein* Sport sind, obwohl „sport“ darin steckt.
  static const _notSport = ['transport', 'passport', 'disport', 'sporad',
    'sporen', 'spore'];

  /// Wörter, ohne die [isSportText] nie anschlägt (außer „…sport…“-
  /// Wörtern) – für schnelle Vorprüfungen (Sport-Hub).
  static final Set<String> triggerWords = {
    ..._words,
    for (final p in _pairs) p.$1,
  };

  static final _cache = <String, bool>{};

  static bool _sportToken(String t) {
    if (t.contains('sport') || t.startsWith('spor')) {
      for (final n in _notSport) {
        if (t.startsWith(n)) return false;
      }
      // „transportes“, „Teleport“ … – Sport muss am Wortanfang stehen oder
      // als zusammengesetztes Wort enden („Motorsport“, „Wintersport“).
      final i = t.indexOf('spor');
      if (i == 0) return true;
      final at = t.indexOf('sport');
      return at > 0 && (t.endsWith('sport') || t.endsWith('sports'));
    }
    return false;
  }

  /// Ist dieser Text (Titel, Kategorie) Sport? Ergebnis wird gemerkt.
  static bool isSportText(String? text) {
    if (text == null || text.isEmpty) return false;
    final hit = _cache[text];
    if (hit != null) return hit;
    final r = _detect(text);
    if (_cache.length > 20000) _cache.clear();
    _cache[text] = r;
    return r;
  }

  static bool _detect(String text) {
    final toks = [
      for (final m in _word.allMatches(text.toLowerCase())) m.group(0)!,
    ];
    for (var i = 0; i < toks.length; i++) {
      final t = toks[i];
      if (_sportToken(t)) return true;
      if (_words.contains(t) && !_weak.contains(t)) return true;
      if (i + 1 < toks.length && _pairs.contains((t, toks[i + 1]))) {
        return true;
      }
    }
    return false;
  }

  /// Gruppen wie „DE | Sport“, „TR: Spor“, „Sports HD“.
  static bool isSportGroup(String? name) {
    if (name == null || name.isEmpty) return false;
    for (final m in _word.allMatches(name.toLowerCase())) {
      if (_sportToken(m.group(0)!)) return true;
    }
    return false;
  }

  /// Sendung zählt als Sport: Titel oder Kategorie passt, oder sie läuft
  /// auf einem Sender einer Sport-Gruppe.
  static bool isSportProgramme(
      {required String title, String? genre, bool sportGroup = false}) =>
      sportGroup || isSportText(genre) || isSportText(title);
}
