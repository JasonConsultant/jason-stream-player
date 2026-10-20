/// Sprachen für Ton- und Untertitelspuren.
///
/// Streams kennzeichnen Sprachen sehr unterschiedlich: „de“, „deu“, „ger“,
/// „German“, „Deutsch“ … – [TrackLanguage.matches] erkennt alle Varianten.
class TrackLanguage {
  final String code;
  final String label;
  final List<String> aliases;
  const TrackLanguage(this.code, this.label, this.aliases);

  bool matches(String? lang, [String? title]) {
    final candidates = [lang, title]
        .whereType<String>()
        .map((s) => s.toLowerCase().trim())
        .where((s) => s.isNotEmpty);
    for (final c in candidates) {
      for (final a in aliases) {
        if (c == a || c.startsWith('$a-') || c.startsWith('${a}_')) return true;
        // Titel wie „Deutsch (AC3)“ oder „German 5.1“
        if (a.length > 3 && c.contains(a)) return true;
      }
    }
    return false;
  }

  static const all = <TrackLanguage>[
    TrackLanguage('de', 'Deutsch', ['de', 'deu', 'ger', 'german', 'deutsch']),
    TrackLanguage('en', 'English', ['en', 'eng', 'english', 'englisch']),
    TrackLanguage('tr', 'Türkçe', ['tr', 'tur', 'turkish', 'türkçe', 'turkce', 'türkisch']),
    TrackLanguage('fr', 'Français', ['fr', 'fra', 'fre', 'french', 'français']),
    TrackLanguage('es', 'Español', ['es', 'spa', 'spanish', 'español']),
    TrackLanguage('it', 'Italiano', ['it', 'ita', 'italian', 'italiano']),
    TrackLanguage('pl', 'Polski', ['pl', 'pol', 'polish', 'polski']),
    TrackLanguage('ru', 'Русский', ['ru', 'rus', 'russian', 'русский']),
    TrackLanguage('ar', 'العربية', ['ar', 'ara', 'arabic', 'العربية']),
    TrackLanguage('sq', 'Shqip', ['sq', 'sqi', 'alb', 'albanian', 'shqip']),
    TrackLanguage('hr', 'Hrvatski / Srpski / Bosanski',
        ['hr', 'hrv', 'scr', 'sr', 'srp', 'scc', 'bs', 'bos', 'croatian', 'serbian', 'bosnian']),
    TrackLanguage('ku', 'Kurdî', ['ku', 'kur', 'kurdish', 'kurdî']),
  ];

  static TrackLanguage? byCode(String? code) {
    for (final l in all) {
      if (l.code == code) return l;
    }
    return null;
  }

  /// Lesbarer Name einer Spur: Sprache + ggf. Titel.
  static String describe(String? lang, String? title, String fallback) {
    TrackLanguage? hit;
    for (final l in all) {
      if (l.matches(lang)) {
        hit = l;
        break;
      }
    }
    final t = (title ?? '').trim();
    if (hit == null) {
      final parts = [if (t.isNotEmpty) t, if ((lang ?? '').isNotEmpty) lang!];
      return parts.isEmpty ? fallback : parts.join(' · ');
    }
    // Titel weglassen, wenn er nur den Sprachnamen wiederholt („German“).
    if (t.isEmpty || hit.aliases.contains(t.toLowerCase())) return hit.label;
    return '${hit.label} · $t';
  }
}

/// Auswahl der passenden Spur nach Vorliebe.
/// [prefCode]: Sprachcode, 'auto' (nicht eingreifen) oder 'off' (nur Untertitel).
/// Liefert den Index in [tracks] oder null (nichts ändern), -1 = ausschalten.
int? pickTrack(
    List<({String id, String? language, String? title})> tracks, String prefCode,
    {bool allowOff = false}) {
  if (prefCode == 'auto') return null;
  if (prefCode == 'off') return allowOff ? -1 : null;
  final lang = TrackLanguage.byCode(prefCode);
  if (lang == null) return null;
  for (var i = 0; i < tracks.length; i++) {
    final t = tracks[i];
    if (t.id == 'auto' || t.id == 'no') continue;
    if (lang.matches(t.language, t.title)) return i;
  }
  return allowOff ? -1 : null; // Untertitel: Sprache fehlt → aus
}
