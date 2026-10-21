import 'dart:isolate';
import 'dart:typed_data';

import '../models/models.dart';

/// Reine Hilfsfunktionen rund um Film-/Serien-Metadaten (ohne Flutter):
/// Genres zerlegen und zählen, Jahrzehnte, „Neueste zuerst“, Trailer-IDs,
/// nächste Folge und Empfehlungen. Alles ist auf große Listen (100 000
/// Titel) ausgelegt und wird in state/discover.dart zwischengespeichert.

// ---------------------------------------------------------------------------
// Genres
// ---------------------------------------------------------------------------

final _genreSplit = RegExp(r'\s*(?:[,/|·;&+]|\s-\s)\s*');
final _nonWord = RegExp(r'[^\p{L}\p{N}]+', unicode: true);

/// Gleiche Genres in verschiedenen Schreibweisen/Sprachen → ein Schlüssel.
const _aliases = <String, String>{
  'scifi': 'sciencefiction',
  'sf': 'sciencefiction',
  'bilimkurgu': 'sciencefiction',
  'komödie': 'comedy',
  'komoedie': 'comedy',
  'komedi': 'comedy',
  'dram': 'drama',
  'korku': 'horror',
  'gerilim': 'thriller',
  'animasyon': 'animation',
  'zeichentrick': 'animation',
  'anime': 'animation',
  'dokumentation': 'documentary',
  'dokumentarfilm': 'documentary',
  'doku': 'documentary',
  'belgesel': 'documentary',
  'familie': 'family',
  'aile': 'family',
  'krimi': 'crime',
  'suç': 'crime',
  'romantik': 'romance',
  'romantisch': 'romance',
  'liebesfilm': 'romance',
  'romantizm': 'romance',
  'krieg': 'war',
  'kriegsfilm': 'war',
  'savaş': 'war',
  'fantastik': 'fantasy',
  'fantasie': 'fantasy',
  'gizem': 'mystery',
  'abenteuer': 'adventure',
  'macera': 'adventure',
  'aksiyon': 'action',
  'musik': 'music',
  'müzik': 'music',
  'historie': 'history',
  'geschichte': 'history',
  'historisch': 'history',
  'tarih': 'history',
  'kinder': 'kids',
  'çocuk': 'kids',
  'kinderfilm': 'kids',
  'children': 'kids',
  'biografie': 'biography',
  'biyografi': 'biography',
  'biopic': 'biography',
  'tvmovie': 'tvmovie',
  'tvfilm': 'tvmovie',
};

const _junk = {'na', 'null', 'none', 'unknown', 'other', 'diğer', 'sonstige'};

/// Schlüssel eines Genres („Science-Fiction“ → „sciencefiction“) oder
/// null für leere/unbrauchbare Angaben.
String? genreKey(String raw) {
  final k = raw.toLowerCase().replaceAll(_nonWord, '');
  if (k.length < 2 || _junk.contains(k) || int.tryParse(k) != null) {
    return null;
  }
  return _aliases[k] ?? k;
}

/// „Action, Abenteuer / Sci-Fi | Drama“ → einzelne Genres (Originaltext,
/// getrimmt, ohne Doppelte desselben Schlüssels).
List<String> splitGenres(String? raw) {
  if (raw == null) return const [];
  final t = raw.trim();
  if (t.isEmpty) return const [];
  final seen = <String>{};
  final out = <String>[];
  for (final part in t.split(_genreSplit)) {
    final p = part.trim();
    final k = genreKey(p);
    if (k == null || !seen.add(k)) continue;
    out.add(p);
  }
  return out;
}

/// Schlüssel aller Genres eines Eintrags.
Set<String> genreKeysOf(String? raw) =>
    {for (final g in splitGenres(raw)) genreKey(g)!};

class GenreCount {
  final String key;

  /// Häufigste Schreibweise in den Daten (erster Buchstabe groß).
  final String label;
  final int count;
  const GenreCount(this.key, this.label, this.count);
  @override
  String toString() => '$label ($count)';
}

/// Genre-Verzeichnis einer Liste: Schlüssel → Positionen in [items].
class GenreIndex {
  final List<VodItem> items;
  final Map<String, List<int>> byKey;
  final List<GenreCount> counts; // häufigste zuerst

  GenreIndex._(this.items, this.byKey, this.counts);

  /// Sofort (für kleine Listen und Tests).
  factory GenreIndex.build(List<VodItem> items) {
    final (byKey, counts) = _parseGenres([for (final m in items) m.genre]);
    return GenreIndex._(items, byKey, counts);
  }

  /// Große Listen im Hintergrund (eigener Isolate): hinüber gehen nur die
  /// Genre-Texte, zurück Schlüssel und Positionen.
  static Future<GenreIndex> buildAsync(List<VodItem> items,
      {bool isolate = true}) async {
    if (!isolate || items.length < 2000) return GenreIndex.build(items);
    final genres = [for (final m in items) m.genre];
    final (byKey, counts) = await Isolate.run(() => _parseGenres(genres),
        debugName: 'genre-index');
    return GenreIndex._(items, byKey, counts);
  }

  static String _bestLabel(Map<String, int> s) {
    var best = s.keys.first;
    for (final e in s.entries) {
      if (e.value > s[best]!) best = e.key;
    }
    return best.isEmpty ? best : best[0].toUpperCase() + best.substring(1);
  }

  /// Die [max] häufigsten Genres.
  List<GenreCount> top([int max = 24]) =>
      counts.length <= max ? counts : counts.sublist(0, max);

  /// Titel eines Genres (Schlüssel), in Listenreihenfolge.
  List<VodItem> itemsOf(String key) =>
      [for (final i in byKey[key] ?? const <int>[]) items[i]];

  String? labelOf(String key) {
    for (final c in counts) {
      if (c.key == key) return c.label;
    }
    return null;
  }
}

(Map<String, List<int>>, List<GenreCount>) _parseGenres(List<String?> raw) {
  final byKey = <String, List<int>>{};
  final spellings = <String, Map<String, int>>{};
  // Gleiche Genre-Texte kommen tausendfach vor → einmal zerlegen.
  final memo = <String, List<(String, String)>>{};
  for (var i = 0; i < raw.length; i++) {
    final r = raw[i];
    if (r == null || r.isEmpty) continue;
    final parts = memo.putIfAbsent(
        r, () => [for (final g in splitGenres(r)) (genreKey(g)!, g)]);
    for (final (k, label) in parts) {
      (byKey[k] ??= <int>[]).add(i);
      final s = spellings[k] ??= <String, int>{};
      s[label] = (s[label] ?? 0) + 1;
    }
  }
  final counts = [
    for (final e in byKey.entries)
      GenreCount(e.key, GenreIndex._bestLabel(spellings[e.key]!), e.value.length),
  ]..sort((a, b) {
      final c = b.count.compareTo(a.count);
      return c != 0 ? c : a.label.compareTo(b.label);
    });
  return (
    {for (final e in byKey.entries) e.key: Int32List.fromList(e.value)},
    counts,
  );
}

// ---------------------------------------------------------------------------
// Jahre / Jahrzehnte
// ---------------------------------------------------------------------------

/// Plausibles Erscheinungsjahr oder null (0, 1, 20250 … verwerfen).
int? sanitizeYear(int? y) => y == null || y < 1890 || y > 2100 ? null : y;

/// 1994 → 1990.
int? decadeOf(int? year) {
  final y = sanitizeYear(year);
  return y == null ? null : y - y % 10;
}

/// Jahrzehnte mit Anzahl, neueste zuerst.
List<(int decade, int count)> decadesOf(Iterable<VodItem> items) {
  final m = <int, int>{};
  for (final it in items) {
    final d = decadeOf(it.year);
    if (d != null) m[d] = (m[d] ?? 0) + 1;
  }
  return [for (final e in m.entries) (e.key, e.value)]
    ..sort((a, b) => b.$1.compareTo(a.$1));
}

/// Jahre (mit Anzahl) innerhalb eines Jahrzehnts, neueste zuerst.
List<(int year, int count)> yearsIn(Iterable<VodItem> items, int decade) {
  final m = <int, int>{};
  for (final it in items) {
    final y = sanitizeYear(it.year);
    if (y != null && y - y % 10 == decade) m[y] = (m[y] ?? 0) + 1;
  }
  return [for (final e in m.entries) (e.key, e.value)]
    ..sort((a, b) => b.$1.compareTo(a.$1));
}

// ---------------------------------------------------------------------------
// Sortierung
// ---------------------------------------------------------------------------

enum VodSort { standard, newest, rating, title, year }

/// Neueste zuerst: nach Anbieter-Zeitstempel ([VodItem.added], bei Serien
/// last_modified). Ohne Zeitstempel zählt die Listenreihenfolge – Anbieter
/// hängen Neues meist hinten an, also spätere Einträge zuerst. Einträge
/// mit Zeitstempel stehen vor denen ohne.
List<VodItem> sortNewest(List<VodItem> items) {
  final idx = [for (var i = 0; i < items.length; i++) i];
  idx.sort((a, b) {
    final da = items[a].added, db = items[b].added;
    if (da != null && db != null) {
      final c = db.compareTo(da);
      return c != 0 ? c : b.compareTo(a);
    }
    if (da != null) return -1;
    if (db != null) return 1;
    return b.compareTo(a);
  });
  return [for (final i in idx) items[i]];
}

/// Die [k] neuesten Einträge (Reihenfolge wie [sortNewest]) in einem
/// Durchgang – für Startseiten-Reihen, ohne 100 000 Titel zu sortieren.
List<VodItem> topNewest(List<VodItem> items, int k) {
  if (k <= 0 || items.isEmpty) return const [];
  // true, wenn Position a vor Position b gehört.
  bool before(int a, int b) {
    final da = items[a].added, db = items[b].added;
    if (da != null && db != null) {
      final c = db.compareTo(da);
      return c != 0 ? c < 0 : a > b;
    }
    if (da != null) return true;
    if (db != null) return false;
    return a > b;
  }

  final top = <int>[]; // sortiert, bestes zuerst
  for (var i = 0; i < items.length; i++) {
    if (top.length == k && !before(i, top.last)) continue;
    var j = top.length;
    while (j > 0 && before(i, top[j - 1])) {
      j--;
    }
    top.insert(j, i);
    if (top.length > k) top.removeLast();
  }
  return [for (final i in top) items[i]];
}

/// Die [k] besten Einträge nach Bewertung (Gleichstand: Listenreihenfolge).
List<VodItem> topRated(Iterable<VodItem> items, int k) {
  final top = <VodItem>[];
  for (final m in items) {
    final r = m.rating ?? 0;
    if (top.length == k && r <= (top.last.rating ?? 0)) continue;
    var j = top.length;
    while (j > 0 && r > (top[j - 1].rating ?? 0)) {
      j--;
    }
    top.insert(j, m);
    if (top.length > k) top.removeLast();
  }
  return top;
}

List<VodItem> sortVod(List<VodItem> items, VodSort sort) {
  switch (sort) {
    case VodSort.standard:
      return items;
    case VodSort.newest:
      return sortNewest(items);
    case VodSort.rating:
      return [...items]
        ..sort((a, b) => (b.rating ?? 0).compareTo(a.rating ?? 0));
    case VodSort.title:
      return [...items]..sort((a, b) =>
          a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    case VodSort.year:
      return [...items]..sort((a, b) =>
          (sanitizeYear(b.year) ?? 0).compareTo(sanitizeYear(a.year) ?? 0));
  }
}

// ---------------------------------------------------------------------------
// Trailer
// ---------------------------------------------------------------------------

final _ytId = RegExp(r'^[A-Za-z0-9_-]{11}$');
final _ytUrl = RegExp(
    r'(?:youtube(?:-nocookie)?\.com/(?:watch\?(?:.*&)?v=|embed/|v/|shorts/|live/)|youtu\.be/|vnd\.youtube:)([A-Za-z0-9_-]{11})(?![A-Za-z0-9_-])',
    caseSensitive: false);

/// YouTube-Video-ID aus einer Anbieter-Angabe (nackte ID, watch-, embed-,
/// shorts-, youtu.be- oder vnd.youtube-Adresse). Sonst null.
String? youtubeId(String? raw) {
  final s = raw?.trim();
  if (s == null || s.isEmpty) return null;
  if (_ytId.hasMatch(s)) return s;
  return _ytUrl.firstMatch(s)?.group(1);
}

// ---------------------------------------------------------------------------
// Serien: nächste Folge, Weiterschauen
// ---------------------------------------------------------------------------

/// Alle Folgen in Abspielreihenfolge (Staffeln aufsteigend).
List<Episode> episodesInOrder(Map<int, List<Episode>> seasons) {
  final keys = seasons.keys.toList()..sort();
  return [for (final k in keys) ...seasons[k]!];
}

/// Folge nach [current] – auch über das Staffelende hinweg. null am Ende
/// der Serie oder wenn [current] nicht (mehr) in der Liste steht.
Episode? nextEpisodeOf(Map<int, List<Episode>> seasons, Episode current) {
  final all = episodesInOrder(seasons);
  final i = all.indexWhere((e) => e.id == current.id);
  if (i < 0 || i + 1 >= all.length) return null;
  return all[i + 1];
}

/// Wo „Weiterschauen“ ansetzt: zuletzt gesehene Folge [lastEpisodeId] –
/// angefangen → dort fortsetzen, zu Ende gesehen → nächste Folge (auch in
/// der nächsten Staffel). Ohne Verlauf: erste angefangene, sonst erste
/// ungesehene, sonst erste Folge.
({Episode episode, bool resume})? resumeTarget(
  Map<int, List<Episode>> seasons, {
  String? lastEpisodeId,
  required double? Function(Episode) progress,
  required bool Function(Episode) watched,
}) {
  final all = episodesInOrder(seasons);
  if (all.isEmpty) return null;
  final li =
      lastEpisodeId == null ? -1 : all.indexWhere((e) => e.id == lastEpisodeId);
  if (li >= 0) {
    final e = all[li];
    if ((progress(e) ?? 0) > 0) return (episode: e, resume: true);
    if (watched(e) && li + 1 < all.length) {
      return (episode: all[li + 1], resume: (progress(all[li + 1]) ?? 0) > 0);
    }
    return (episode: e, resume: false);
  }
  for (final e in all) {
    if ((progress(e) ?? 0) > 0) return (episode: e, resume: true);
  }
  for (final e in all) {
    if (!watched(e)) return (episode: e, resume: false);
  }
  return (episode: all.first, resume: false);
}

// ---------------------------------------------------------------------------
// Empfehlungen
// ---------------------------------------------------------------------------

class Recommendation {
  /// Titel, auf den sich „Weil du … geschaut hast“ bezieht.
  final VodItem because;
  final String genreKey;
  final List<VodItem> items;
  const Recommendation(this.because, this.genreKey, this.items);
}

/// Empfehlungen aus dem Verlauf (auf dem Gerät berechnet): Häufigstes Genre
/// der zuletzt gesehenen Titel (neuere zählen mehr) → andere, noch nicht
/// gesehene Titel dieses Genres, beste Bewertung zuerst.
///
/// [recent]: zuletzt gesehene Titel, neueste zuerst. [candidates]: alle
/// sichtbaren Filme und Serien (Kinder-/Länderfilter schon angewandt).
///
/// [candidatesOf]: Titel eines Genres direkt aus einem [GenreIndex] (große
/// Listen: kein Durchlauf über alle [candidates]).
Recommendation? recommend({
  required List<VodItem> recent,
  List<VodItem> candidates = const [],
  Iterable<VodItem> Function(String genreKey)? candidatesOf,
  required bool Function(VodItem) seen,
  int lookBack = 10,
  int max = 20,
}) {
  if (recent.isEmpty) return null;
  final weight = <String, double>{};
  final window = recent.length > lookBack ? recent.sublist(0, lookBack) : recent;
  for (var i = 0; i < window.length; i++) {
    for (final k in genreKeysOf(window[i].genre)) {
      weight[k] = (weight[k] ?? 0) + (lookBack - i) / lookBack;
    }
  }
  if (weight.isEmpty) return null;
  final ranked = weight.entries.toList()
    ..sort((a, b) {
      final c = b.value.compareTo(a.value);
      return c != 0 ? c : a.key.compareTo(b.key);
    });
  String keyOf(VodItem m) => '${m.isSeries ? 's' : 'm'}:${m.id}';
  final exclude = {for (final m in recent) keyOf(m)};
  // Bestes Genre mit mindestens einem Vorschlag.
  for (final g in ranked) {
    final because =
        window.firstWhere((m) => genreKeysOf(m.genre).contains(g.key));
    final memo = <String, bool>{};
    final Iterable<VodItem> pool = candidatesOf != null
        ? candidatesOf(g.key)
        : candidates.where((m) =>
            m.genre != null &&
            (memo[m.genre!] ??= genreKeysOf(m.genre).contains(g.key)));
    final picks = topRated(
        pool.where((m) => !exclude.contains(keyOf(m)) && !seen(m)), max);
    if (picks.isNotEmpty) return Recommendation(because, g.key, picks);
  }
  return null;
}

// ---------------------------------------------------------------------------
// Personen (Besetzung/Regie)
// ---------------------------------------------------------------------------

final _personSplit = RegExp(r'\s*[,;/|]\s*');
final _spaces = RegExp(r'\s{2,}|[\t\n\r]');
final _letter = RegExp(r'\p{L}', unicode: true);

/// „Tom Hanks, Robin Wright / Gary Sinise“ → einzelne Namen.
List<String> splitPeople(String? raw) {
  if (raw == null) return const [];
  final out = <String>[];
  final seen = <String>{};
  for (final p in raw.split(_personSplit)) {
    // Ohne neue RegExp je Name: das läuft für Hunderttausende Namen.
    var n = p.trim();
    if (n.contains(_spaces)) n = n.replaceAll(RegExp(r'\s+'), ' ');
    if (n.length < 3 || n.length > 60) continue;
    if (!_letter.hasMatch(n)) continue; // nur Satzzeichen/Zahlen
    final k = n.toLowerCase();
    if (_junk.contains(k)) continue;
    if (seen.add(k)) out.add(n);
  }
  return out;
}
