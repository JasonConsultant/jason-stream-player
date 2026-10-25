import 'dart:isolate';
import 'dart:typed_data';

import '../models/models.dart';
import 'vod_meta.dart';

/// Gruppen-Übersicht für Filme/Serien (1.9): Kategorie, Genre, Jahr und
/// Sprache. Rein (ohne Flutter); große Listen werden in einem Isolate
/// gruppiert – hinüber gehen nur Texte/Zahlen, zurück Positionen.

enum VodGroupMode { category, genre, year, language }

/// Schlüssel der Sammelgruppen.
abstract final class VodGroupKey {
  /// Ohne Genre / Jahr / Sprache.
  static const none = '_none';

  /// Jahr vor [VodGroups.firstYear] („Vor 1980“).
  static const before = '_before';
}

class VodGroup {
  /// Kategorie-ID, Genre-Schlüssel, Jahr („2019“), Sprachkürzel („DE“)
  /// oder [VodGroupKey.none]/[VodGroupKey.before].
  final String key;

  /// Kategorie- bzw. Genre-Name aus den Daten; bei Jahr/Sprache der
  /// Schlüssel (die Oberfläche übersetzt).
  final String label;

  /// Positionen in [VodGroups.items] (Listenreihenfolge).
  final Int32List idx;
  const VodGroup(this.key, this.label, this.idx);

  int get count => idx.length;

  @override
  String toString() => '$label ($count)';
}

class VodGroups {
  /// Jahre davor werden zusammengefasst.
  static const firstYear = 1980;

  final List<VodItem> items;
  final Map<VodGroupMode, List<VodGroup>> _byMode;

  VodGroups._(this.items, this._byMode);

  List<VodGroup> of(VodGroupMode mode) => _byMode[mode] ?? const [];

  List<VodItem> itemsOf(VodGroup g) => [for (final i in g.idx) items[i]];

  /// Mindestens ein Titel mit Genre-Angabe.
  bool get hasGenres => of(VodGroupMode.genre).any((g) => g.key != VodGroupKey.none);

  VodGroup? find(VodGroupMode mode, String key) {
    for (final g in of(mode)) {
      if (g.key == key) return g;
    }
    return null;
  }

  /// Sofort (kleine Listen, Tests).
  factory VodGroups.build(List<VodItem> items, List<Category> categories) =>
      VodGroups._(items, _decode(_group(_input(items, categories))));

  /// Ab [isolateFrom] Titeln im Hintergrund.
  static Future<VodGroups> buildAsync(
      List<VodItem> items, List<Category> categories,
      {bool isolate = true, int isolateFrom = 2000}) async {
    if (!isolate || items.length < isolateFrom) {
      return VodGroups.build(items, categories);
    }
    final input = _input(items, categories);
    final raw =
        await Isolate.run(() => _group(input), debugName: 'vod-groups');
    return VodGroups._(items, _decode(raw));
  }
}

typedef _Input = ({
  List<String> names,
  List<String?> genres,
  List<int?> years,
  List<String> cats,
  List<(String, String)> categories,
});

typedef _Raw = Map<int, List<(String, String, Int32List)>>;

_Input _input(List<VodItem> items, List<Category> categories) => (
      names: [for (final m in items) m.name],
      genres: [for (final m in items) m.genre],
      years: [for (final m in items) m.year],
      cats: [for (final m in items) m.categoryId],
      categories: [for (final c in categories) (c.id, c.name)],
    );

Map<VodGroupMode, List<VodGroup>> _decode(_Raw raw) => {
      for (final e in raw.entries)
        VodGroupMode.values[e.key]: [
          for (final (k, l, idx) in e.value) VodGroup(k, l, idx),
        ],
    };

_Raw _group(_Input d) {
  final n = d.names.length;

  // Kategorie: Reihenfolge des Anbieters, leere weglassen.
  final byCat = <String, List<int>>{};
  for (var i = 0; i < n; i++) {
    (byCat[d.cats[i]] ??= <int>[]).add(i);
  }
  final catGroups = <(String, String, Int32List)>[];
  final catLang = <String, String?>{};
  for (final (id, name) in d.categories) {
    catLang[id] = detectLanguage(name);
    final l = byCat[id];
    if (l == null || l.isEmpty) continue;
    catGroups.add((id, name, Int32List.fromList(l)));
  }

  // Genre: wie der Genre-Index (gleiche Schlüssel/Aliasse).
  final byGenre = <String, List<int>>{};
  final spellings = <String, Map<String, int>>{};
  final noGenre = <int>[];
  final memo = <String, List<(String, String)>>{};
  for (var i = 0; i < n; i++) {
    final r = d.genres[i];
    final parts = r == null || r.isEmpty
        ? const <(String, String)>[]
        : memo.putIfAbsent(
            r, () => [for (final g in splitGenres(r)) (genreKey(g)!, g)]);
    if (parts.isEmpty) {
      noGenre.add(i);
      continue;
    }
    for (final (k, label) in parts) {
      (byGenre[k] ??= <int>[]).add(i);
      final s = spellings[k] ??= <String, int>{};
      s[label] = (s[label] ?? 0) + 1;
    }
  }
  final genreGroups = [
    for (final e in byGenre.entries)
      (e.key, _bestLabel(spellings[e.key]!), Int32List.fromList(e.value)),
  ]..sort(_byCount);
  if (genreGroups.isNotEmpty && noGenre.isNotEmpty) {
    genreGroups.add((VodGroupKey.none, '', Int32List.fromList(noGenre)));
  }

  // Jahr: Feld, sonst aus dem Titel; vor 1980 zusammengefasst.
  final byYear = <int, List<int>>{};
  final before = <int>[], noYear = <int>[];
  for (var i = 0; i < n; i++) {
    final y = sanitizeYear(d.years[i]) ?? yearFromTitle(d.names[i]);
    if (y == null) {
      noYear.add(i);
    } else if (y < VodGroups.firstYear) {
      before.add(i);
    } else {
      (byYear[y] ??= <int>[]).add(i);
    }
  }
  final years = byYear.keys.toList()..sort((a, b) => b.compareTo(a));
  final yearGroups = [
    for (final y in years) ('$y', '$y', Int32List.fromList(byYear[y]!)),
    if (before.isNotEmpty)
      (VodGroupKey.before, '', Int32List.fromList(before)),
    if (noYear.isNotEmpty && (years.isNotEmpty || before.isNotEmpty))
      (VodGroupKey.none, '', Int32List.fromList(noYear)),
  ];

  // Sprache: Kennzeichnung der Kategorie, sonst des Titels.
  final byLang = <String, List<int>>{};
  final noLang = <int>[];
  for (var i = 0; i < n; i++) {
    final c = catLang[d.cats[i]] ?? detectLanguage(d.names[i], title: true);
    if (c == null) {
      noLang.add(i);
    } else {
      (byLang[c] ??= <int>[]).add(i);
    }
  }
  final langGroups = [
    for (final e in byLang.entries) (e.key, e.key, Int32List.fromList(e.value)),
  ]..sort(_byCount);
  if (noLang.isNotEmpty) {
    langGroups.add((VodGroupKey.none, '', Int32List.fromList(noLang)));
  }

  return {
    VodGroupMode.category.index: catGroups,
    VodGroupMode.genre.index: genreGroups,
    VodGroupMode.year.index: yearGroups,
    VodGroupMode.language.index: langGroups,
  };
}

int _byCount((String, String, Int32List) a, (String, String, Int32List) b) {
  final c = b.$3.length.compareTo(a.$3.length);
  return c != 0 ? c : a.$2.toLowerCase().compareTo(b.$2.toLowerCase());
}

String _bestLabel(Map<String, int> s) {
  var best = s.keys.first;
  for (final e in s.entries) {
    if (e.value > s[best]!) best = e.key;
  }
  return best.isEmpty ? best : best[0].toUpperCase() + best.substring(1);
}

// ---------------------------------------------------------------------------
// Jahr aus dem Titel
// ---------------------------------------------------------------------------

final _yearBracket = RegExp(r'[\(\[]\s*((?:19|20)\d\d)\s*[\)\]]');
final _yearTrailing = RegExp(r'(?:^|[\s\-–|•·,])((?:19|20)\d\d)\s*$');

/// „Titel (2019)“, „Titel [2019]“, „Titel - 2019“ → 2019. Jahre in der
/// Zukunft (mehr als 2 Jahre) zählen nicht („Blade Runner 2049“).
int? yearFromTitle(String name, {DateTime? now}) {
  final m = _yearBracket.firstMatch(name) ?? _yearTrailing.firstMatch(name);
  if (m == null) return null;
  final y = int.parse(m.group(1)!);
  final max = (now ?? DateTime.now()).year + 2;
  return y > max ? null : sanitizeYear(y);
}

// ---------------------------------------------------------------------------
// Sprache aus Kennzeichnungen („DE |“, „TR •“, „[EN]“, „EN:“, 🇩🇪 …)
// ---------------------------------------------------------------------------

/// Bekannte Kürzel/Namen → Sprachgruppe. Kurze Kürzel zählen nur in
/// Großbuchstaben („It“/„Es“/„Us“ sind Filmtitel).
const languageAliases = <String, String>{
  'DE': 'DE', 'GER': 'DE', 'DEU': 'DE', 'AT': 'DE', 'GERMAN': 'DE',
  'DEUTSCH': 'DE', 'ALMAN': 'DE', 'ALMANCA': 'DE',
  'EN': 'EN', 'ENG': 'EN', 'UK': 'EN', 'US': 'EN', 'USA': 'EN', 'GB': 'EN',
  'ENGLISH': 'EN', 'ENGLISCH': 'EN', 'INGILIZCE': 'EN', 'İNGİLİZCE': 'EN',
  'TR': 'TR', 'TUR': 'TR', 'TURK': 'TR', 'TÜRK': 'TR', 'TURKISH': 'TR',
  'TÜRKÇE': 'TR', 'TURKCE': 'TR', 'TÜRKISCH': 'TR', 'TURKIYE': 'TR',
  'TÜRKIYE': 'TR', 'TÜRKİYE': 'TR', 'YERLİ': 'TR', 'YERLI': 'TR',
  'FR': 'FR', 'FRA': 'FR', 'FRE': 'FR', 'FRENCH': 'FR', 'FRANCAIS': 'FR',
  'FRANÇAIS': 'FR', 'FRANZÖSISCH': 'FR',
  'IT': 'IT', 'ITA': 'IT', 'ITALIAN': 'IT', 'ITALIANO': 'IT',
  'ITALIENISCH': 'IT',
  'ES': 'ES', 'ESP': 'ES', 'SPA': 'ES', 'SPANISH': 'ES', 'ESPANOL': 'ES',
  'ESPAÑOL': 'ES', 'LATINO': 'ES', 'SPANISCH': 'ES',
  'NL': 'NL', 'NLD': 'NL', 'DUT': 'NL', 'DUTCH': 'NL', 'NEDERLANDS': 'NL',
  'PL': 'PL', 'POL': 'PL', 'POLISH': 'PL', 'POLSKI': 'PL', 'POLSKA': 'PL',
  'RU': 'RU', 'RUS': 'RU', 'RUSSIAN': 'RU',
  'AR': 'AR', 'ARA': 'AR', 'ARAB': 'AR', 'ARABIC': 'AR', 'عربي': 'AR',
  'KU': 'KU', 'KUR': 'KU', 'KRD': 'KU', 'KURD': 'KU', 'KURDISH': 'KU',
  'KURDÎ': 'KU', 'KURDI': 'KU', 'KÜRTÇE': 'KU', 'KURTCE': 'KU',
  'AL': 'AL', 'ALB': 'AL', 'SQ': 'AL', 'ALBANIAN': 'AL', 'SHQIP': 'AL',
  'PT': 'PT', 'POR': 'PT', 'BR': 'PT', 'PORTUGUESE': 'PT',
  'GR': 'GR', 'GRE': 'GR', 'ELL': 'GR', 'GREEK': 'GR',
  'RO': 'RO', 'ROM': 'RO', 'RON': 'RO', 'ROMANIAN': 'RO',
  'BG': 'BG', 'BUL': 'BG', 'BULGARIAN': 'BG',
  'HU': 'HU', 'HUN': 'HU', 'HUNGARIAN': 'HU',
  'CZ': 'CZ', 'CZE': 'CZ', 'CS': 'CZ', 'CZECH': 'CZ',
  'EXYU': 'EXYU', 'YU': 'EXYU', 'HR': 'EXYU', 'SRB': 'EXYU', 'RS': 'EXYU',
  'BIH': 'EXYU', 'BA': 'EXYU',
  'SE': 'SV', 'SV': 'SV', 'SWE': 'SV', 'SWEDISH': 'SV',
  'NO': 'NO', 'NOR': 'NO', 'NORWEGIAN': 'NO',
  'DK': 'DA', 'DA': 'DA', 'DAN': 'DA', 'DANISH': 'DA',
  'FI': 'FI', 'FIN': 'FI', 'FINNISH': 'FI',
  'FA': 'FA', 'IR': 'FA', 'PER': 'FA', 'PERSIAN': 'FA', 'FARSI': 'FA',
  'HI': 'HI', 'IN': 'HI', 'IND': 'HI', 'HINDI': 'HI',
  'UR': 'UR', 'PK': 'UR', 'URDU': 'UR',
  'ZH': 'ZH', 'CN': 'ZH', 'CHI': 'ZH', 'CHINESE': 'ZH',
  'JA': 'JA', 'JP': 'JA', 'JPN': 'JA', 'JAPANESE': 'JA',
  'KO': 'KO', 'KR': 'KO', 'KOR': 'KO', 'KOREAN': 'KO',
  'AZ': 'AZ', 'AZE': 'AZ', 'AZERBAIJANI': 'AZ',
};

/// Kürzel, die vor „:“ bzw. „-“ in Filmtiteln auch Wörter sein können
/// („IT: Kapitel 2“, „NO - …“) – dort nur mit | • · oder Klammern.
const _ambiguousInTitles = {'IT', 'ES', 'NO', 'IN', 'US', 'AL', 'AR', 'BR'};

/// Allgemeine Vorsätze vor der Sprache („VOD | DE | Action“).
const _generic = {
  'VOD', 'MOVIE', 'MOVIES', 'FILM', 'FILME', 'FILMS', 'FILMLER', 'SERIES',
  'SERIEN', 'SERIE', 'DIZI', 'DİZİ', 'DIZILER', 'DİZİLER', '4K', 'UHD',
  'FHD', 'HD', 'SD', 'HEVC', 'NEW', 'NEU', 'TOP', 'TV', 'KIDS',
};

/// Flaggen-Land → Sprache.
const _flagLang = <String, String>{
  'DE': 'DE', 'AT': 'DE', 'CH': 'DE', 'GB': 'EN', 'US': 'EN', 'CA': 'EN',
  'AU': 'EN', 'IE': 'EN', 'TR': 'TR', 'FR': 'FR', 'BE': 'FR', 'IT': 'IT',
  'ES': 'ES', 'MX': 'ES', 'AR': 'ES', 'NL': 'NL', 'PL': 'PL', 'RU': 'RU',
  'SA': 'AR', 'AE': 'AR', 'EG': 'AR', 'MA': 'AR', 'IQ': 'AR', 'AL': 'AL',
  'XK': 'AL', 'PT': 'PT', 'BR': 'PT', 'GR': 'GR', 'RO': 'RO', 'BG': 'BG',
  'HU': 'HU', 'CZ': 'CZ', 'HR': 'EXYU', 'RS': 'EXYU', 'BA': 'EXYU',
  'SE': 'SV', 'NO': 'NO', 'DK': 'DA', 'FI': 'FI', 'IR': 'FA', 'IN': 'HI',
  'PK': 'UR', 'CN': 'ZH', 'JP': 'JA', 'KR': 'KO', 'AZ': 'AZ',
};

const _seps = r'\|•·:\-–—►»›/';
final _exYu = RegExp(r'^\W*ex[\s\-]?yu\b', caseSensitive: false);
final _bracketStart = RegExp(r'^[\[\(\|]\s*([^\]\)\|\s]{2,12})\s*[\]\)\|]');
final _bracketEnd = RegExp(r'[\[\(]\s*([^\]\)\s]{2,12})\s*[\]\)]\s*$');
final _suffix = RegExp(r'[\|•·]\s*([^\s\|•·]{2,12})\s*$');
final _prefix = RegExp('^([^\\s$_seps\\[\\]\\(\\)]{2,12})\\s*([$_seps])\\s*(.*)\$');

String? _code(String token) {
  final up = token.toUpperCase();
  final c = languageAliases[up] ?? languageAliases[token];
  if (c == null) return null;
  // Kurze Kürzel nur in Großbuchstaben („It“, „Es“ sind Titel).
  if (token.runes.length <= 3 && token != up) return null;
  return c;
}

String? _flag(String s) {
  final r = s.runes.take(2).toList();
  if (r.length < 2) return null;
  const a = 0x1F1E6, z = 0x1F1FF;
  if (r[0] < a || r[0] > z || r[1] < a || r[1] > z) return null;
  final cc = String.fromCharCodes([r[0] - a + 65, r[1] - a + 65]);
  return _flagLang[cc];
}

/// Sprachgruppe aus einer Kennzeichnung am Anfang („DE | Action“,
/// „TR • Yerli“, „[EN] Drama“, „DE · Komödie“, „EN: Thriller“,
/// „VOD | DE | …“, „🇩🇪 Filme“) oder am Ende („Titel [EN]“, „Action | DE“).
/// null = nicht erkannt. [title]: Filmtitel (strenger bei „IT:“ usw.).
String? detectLanguage(String raw, {bool title = false}) {
  final s = raw.trimLeft();
  if (s.isEmpty) return null;
  final f = _flag(s);
  if (f != null) return f;
  if (_exYu.hasMatch(s)) return 'EXYU';
  final b = _bracketStart.firstMatch(s);
  if (b != null) {
    final c = _code(b.group(1)!);
    if (c != null) return c;
  }
  var rest = s;
  for (var round = 0; round < 2; round++) {
    final m = _prefix.firstMatch(rest);
    if (m == null) break;
    final token = m.group(1)!, sep = m.group(2)!;
    final c = _code(token);
    if (c != null) {
      final weak = sep == ':' || sep == '-' || sep == '/';
      if (title && weak && _ambiguousInTitles.contains(token.toUpperCase())) {
        break;
      }
      return c;
    }
    // „VOD | DE | …“: nur nach allgemeinem Vorsatz eine zweite Stufe.
    if (!_generic.contains(token.toUpperCase())) break;
    rest = m.group(3)!;
  }
  final e = _bracketEnd.firstMatch(s) ?? _suffix.firstMatch(s);
  if (e != null) return _code(e.group(1)!);
  return null;
}
