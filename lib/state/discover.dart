import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/people_index.dart';
import '../data/sport_detect.dart';
import '../data/storage.dart';
import '../data/vod_meta.dart';
import '../models/models.dart';
import 'emby.dart';
import 'profile_mode.dart';
import 'providers.dart';
import 'vod_library.dart';

/// Entdecken (1.4): „Neu hinzugefügt“, Stöbern nach Genre/Jahrzehnt,
/// Personen, „Jetzt live im Sport“ und Empfehlungen. Alle Listen kommen aus
/// den sichtbaren Daten (Kinder-, Länder- und Erwachsenenfilter angewandt).

// ---------------------------------------------------------------------------
// Katalog je Liste (Filme/Serien) – aufwendige Teile erst bei Bedarf.
// ---------------------------------------------------------------------------

class VodCatalog {
  final List<VodItem> items;
  VodCatalog(this.items);

  /// Alle Titel, neueste zuerst (nur für „Stöbern“ – sortiert alles).
  late final List<VodItem> newest = sortNewest(items);

  /// Die 15 neuesten für Reihen (ein Durchgang statt Sortieren).
  late final List<VodItem> newestTop = topNewest(items, 15);
  late final List<(int, int)> decades = decadesOf(items);

  /// ID → Titel (für Verlauf → Titel).
  late final Map<String, VodItem> byId = {for (final m in items) m.id: m};
}

/// [series]: true = Serien, false = Filme. null, solange nicht geladen.
final vodCatalogProvider = Provider.family<VodCatalog?, bool>((ref, series) {
  final d = ref
      .watch(series ? visibleSeriesProvider : visibleMoviesProvider)
      .value;
  return d == null ? null : VodCatalog(d.items);
});

/// Emby-Katalog (Filme/Serien des Emby-Servers, Kindermodus angewandt).
final embyCatalogProvider = Provider.family<VodCatalog?, bool>((ref, series) {
  final d = ref
      .watch(series ? visibleEmbySeriesProvider : visibleEmbyMoviesProvider)
      .value;
  return d == null ? null : VodCatalog(d.items);
});

/// Katalog der gewählten Quelle ([emby] = Emby-Server statt Portal).
VodCatalog? watchCatalog(WidgetRef ref, bool series, {bool emby = false}) =>
    ref.watch(emby ? embyCatalogProvider(series) : vodCatalogProvider(series));

/// Filme bzw. Serien für Suche und Personen: Portal und Emby zusammen.
/// Ohne Emby-Titel genau die Portal-Liste (gleiches Objekt).
List<VodItem>? _combined(Ref ref, bool series) {
  final p = ref
      .watch(series ? visibleSeriesProvider : visibleMoviesProvider)
      .value
      ?.items;
  final e = ref
      .watch(series ? visibleEmbySeriesProvider : visibleEmbyMoviesProvider)
      .value
      ?.items;
  if (e == null || e.isEmpty) return p;
  if (p == null || p.isEmpty) return e;
  return [...p, ...e];
}

final searchMoviesProvider =
    Provider<List<VodItem>?>((ref) => _combined(ref, false));
final searchSeriesProvider =
    Provider<List<VodItem>?>((ref) => _combined(ref, true));

/// Im Hintergrund statt Isolates rechnen (Widget-Tests mit großen Listen).
@visibleForTesting
bool debugDiscoverSync = false;

/// Genre-Verzeichnis je Liste – große Listen im Hintergrund gebaut.
/// Achtung: Während eines Neuaufbaus liefert `.value` noch das alte
/// Verzeichnis; Nutzer prüfen `identical(index.items, catalog.items)`
/// (siehe [genreIndexFor]).
final genreIndexProvider =
    FutureProvider.family<GenreIndex?, bool>((ref, series) async {
  final cat = ref.watch(vodCatalogProvider(series));
  if (cat == null) return null;
  return GenreIndex.buildAsync(cat.items, isolate: !debugDiscoverSync);
});

final embyGenreIndexProvider =
    FutureProvider.family<GenreIndex?, bool>((ref, series) async {
  final cat = ref.watch(embyCatalogProvider(series));
  if (cat == null || cat.items.isEmpty) return null;
  return GenreIndex.buildAsync(cat.items, isolate: !debugDiscoverSync);
});

GenreIndex? _embyGenreIndexFor(Ref ref, bool series) {
  final cat = ref.watch(embyCatalogProvider(series));
  final idx = ref.watch(embyGenreIndexProvider(series)).value;
  if (cat == null || idx == null || !identical(idx.items, cat.items)) {
    return null;
  }
  return idx;
}

/// Genre-Verzeichnis passend zur aktuell sichtbaren Liste, sonst null
/// (noch im Aufbau – z. B. direkt nach Wechsel in den Kindermodus).
GenreIndex? genreIndexFor(Ref ref, bool series) {
  final cat = ref.watch(vodCatalogProvider(series));
  final idx = ref.watch(genreIndexProvider(series)).value;
  if (cat == null || idx == null || !identical(idx.items, cat.items)) {
    return null;
  }
  return idx;
}

/// Wie [genreIndexFor], für Widgets. [emby]: Emby-Katalog.
GenreIndex? watchGenreIndex(WidgetRef ref, bool series, {bool emby = false}) {
  final cat = ref.watch(
      emby ? embyCatalogProvider(series) : vodCatalogProvider(series));
  final idx = ref
      .watch(emby ? embyGenreIndexProvider(series) : genreIndexProvider(series))
      .value;
  if (cat == null || idx == null || !identical(idx.items, cat.items)) {
    return null;
  }
  return idx;
}

// ---------------------------------------------------------------------------
// Gesehen
// ---------------------------------------------------------------------------

String watchedKeyOf(VodItem m) =>
    m.isSeries ? 'series_${m.id}' : 'movie_${m.id}';

/// Film zu Ende gesehen bzw. Serie komplett gesehen (Emby: auch laut
/// Server).
bool isSeen(Storage? st, VodItem m) =>
    (st != null && st.isWatched(watchedKeyOf(m))) || m.serverPlayed;

// ---------------------------------------------------------------------------
// Personen-Zwischenspeicher (Besetzung/Regie aus Detailseiten)
// ---------------------------------------------------------------------------

typedef People = ({String? cast, String? director});

/// Listen enthalten die Besetzung oft nicht (Xtream liefert sie meist nur
/// in get_vod_info). Wird eine Detailseite geöffnet, merken wir uns
/// Besetzung und Regie – damit findet die Suche Personen auch dort.
/// Gastmodus: nur im Speicher, nichts wird geschrieben.
class PeopleCacheNotifier extends Notifier<Map<String, People>> {
  /// Alles liegt in den SharedPreferences (beim Start komplett geladen) –
  /// deshalb klein halten.
  static const maxEntries = 1000;

  /// Besetzung gekürzt auf so viele Namen (Hauptrollen genügen).
  static const maxCast = 10;

  /// Zuletzt gelesener Text → Ergebnis. Der Speicher wird nach jeder
  /// Wiedergabe neu geladen; derselbe Inhalt soll dann nicht die
  /// Personensuche neu aufbauen.
  static ({String key, String raw, Map<String, People> map})? _memo;

  @override
  Map<String, People> build() {
    final st = ref.watch(storageProvider).value;
    final p = ref.watch(activePortalProvider).value;
    if (st == null || p == null) return const {};
    final key = 'people_${p.id}';
    final text = st.option(key, '{}');
    final memo = _memo;
    if (memo != null && memo.key == key && memo.raw == text) return memo.map;
    try {
      final raw = jsonDecode(text) as Map;
      final map = LinkedHashMap<String, People>.of({
        for (final e in raw.entries)
          if (e.key is String && e.value is List && (e.value as List).length == 2)
            e.key as String: (
              cast: (e.value as List)[0] as String?,
              director: (e.value as List)[1] as String?,
            ),
      });
      _memo = (key: key, raw: text, map: map);
      return map;
    } catch (_) {
      return const {};
    }
  }

  static String? _shortCast(String? cast) {
    if (cast == null) return null;
    final names = splitPeople(cast);
    if (names.isEmpty) return null;
    return (names.length > maxCast ? names.sublist(0, maxCast) : names)
        .join(', ');
  }

  void remember(VodItem m) {
    if (m.cast == null && m.director == null) return;
    final key = VodLibrary.keyOf(m);
    final cast = _shortCast(m.cast);
    final director = m.director;
    final old = state[key];
    if (old != null && old.cast == cast && old.director == director) return;
    final next = LinkedHashMap<String, People>.of(state)
      ..remove(key)
      ..[key] = (cast: cast, director: director);
    while (next.length > maxEntries) {
      next.remove(next.keys.first);
    }
    state = next;
    _persist(next);
  }

  Future<void> _persist(Map<String, People> m) async {
    final st = ref.read(storageProvider).value;
    final p = ref.read(activePortalProvider).value;
    if (st == null || p == null || st.guestMode) return;
    final key = 'people_${p.id}';
    final text = jsonEncode({
      for (final e in m.entries) e.key: [e.value.cast, e.value.director],
    });
    _memo = (key: key, raw: text, map: m);
    await st.setOption(key, text);
  }
}

final peopleCacheProvider =
    NotifierProvider<PeopleCacheNotifier, Map<String, People>>(
        PeopleCacheNotifier.new);

/// Personen-Verzeichnis für die Suche, im Hintergrund gebaut. `movies`
/// und `series` sind die Listen, aus denen es entstand – die Suche nutzt
/// es nur, wenn sie noch die aktuell sichtbaren sind (Kinder-/Länderfilter).
typedef PeopleIndexFor = ({
  List<VodItem> movies,
  List<VodItem> series,
  PeopleIndex index,
});

final peopleIndexProvider = FutureProvider<PeopleIndexFor?>((ref) async {
  final movies = ref.watch(searchMoviesProvider);
  final series = ref.watch(searchSeriesProvider);
  final cache = ref.watch(peopleCacheProvider);
  if (movies == null && series == null) return null;
  final m = movies ?? const <VodItem>[];
  final s = series ?? const <VodItem>[];
  final all = [...m, ...s];
  final cast = List<String?>.filled(all.length, null);
  final director = List<String?>.filled(all.length, null);
  for (var i = 0; i < all.length; i++) {
    final p = cache.isEmpty
        ? (cast: all[i].cast, director: all[i].director)
        : peopleOf(all[i], cache);
    cast[i] = p.cast;
    director[i] = p.director;
  }
  final index = await PeopleIndex.build(all,
      cast: cast, director: director, isolate: !debugDiscoverSync);
  return (movies: m, series: s, index: index);
});

/// Besetzung/Regie eines Titels: aus der Liste oder dem Zwischenspeicher.
People peopleOf(VodItem m, Map<String, People> cache) {
  final c = cache[VodLibrary.keyOf(m)];
  return (cast: m.cast ?? c?.cast, director: m.director ?? c?.director);
}

// ---------------------------------------------------------------------------
// Jetzt live im Sport
// ---------------------------------------------------------------------------

typedef LiveShow = ({Channel channel, EpgEntry entry});

/// Laufende Sport-Sendungen: Titel/Kategorie passt (zuerst) oder Sender in
/// einer Sport-Gruppe. Höchstens [max] Einträge.
List<LiveShow> liveSport({
  required List<Category> categories,
  required List<Channel> channels,
  required Map<String, List<EpgEntry>> epg,
  required DateTime now,
  bool Function(Channel)? hidden,
  int max = 20,
}) {
  final sportGroups = {
    for (final c in categories)
      if (SportDetector.isSportGroup(c.name)) c.id,
  };
  final strong = <LiveShow>[];
  final weak = <LiveShow>[];
  for (final c in channels) {
    if (strong.length >= max) break;
    if (hidden?.call(c) ?? false) continue;
    final e = nowPlaying(epg, c, now);
    if (e == null) continue;
    if (SportDetector.isSportText(e.genre) ||
        SportDetector.isSportText(e.title)) {
      strong.add((channel: c, entry: e));
    } else if (weak.length < max && sportGroups.contains(c.categoryId)) {
      weak.add((channel: c, entry: e));
    }
  }
  final all = [...strong, ...weak];
  return all.length > max ? all.sublist(0, max) : all;
}

/// Merkt sich für [liveSportProvider] das letzte Ergebnis und die
/// „Sport-Kandidaten“: Sender in Sport-Gruppen plus Sender, deren Programm
/// im Fenster [window] ab der letzten vollen Berechnung eine Sport-Sendung
/// hat. Im Minutentakt werden nur diese Kandidaten geprüft (meist wenige
/// Hundert statt aller Sender); voll gerechnet wird nur bei geänderten
/// Daten (Liste, EPG, Ausblendungen) oder wenn das Fenster abläuft.
class LiveSportMemo {
  /// Wie weit voraus die Kandidaten gelten.
  static const window = Duration(minutes: 15);

  Object? _live, _epg, _flags, _hidden;
  int _minute = -1;
  DateTime _validUntil = DateTime(0);
  List<Channel> _candidates = const [];
  List<LiveShow> _last = const [];

  /// Volle Durchläufe / Kandidaten-Durchläufe (Tests/Messungen).
  int fullScans = 0, candidateScans = 0;

  List<LiveShow> compute({
    required LiveData live,
    required Map<String, List<EpgEntry>> epg,
    required ChannelFlags flags,
    required Set<String> hiddenGroups,
    required DateTime now,
    int max = 20,
  }) {
    final minute = now.millisecondsSinceEpoch ~/ 60000;
    final same = identical(live, _live) &&
        identical(epg, _epg) &&
        identical(flags, _flags) &&
        identical(hiddenGroups, _hidden);
    if (same && minute == _minute) return _last;
    bool hidden(Channel c) =>
        flags.isHidden(c.id) || hiddenGroups.contains(c.categoryId);
    final List<LiveShow> r;
    if (same && now.isBefore(_validUntil)) {
      candidateScans++;
      r = liveSport(
          categories: live.categories,
          channels: _candidates,
          epg: epg,
          now: now,
          hidden: hidden,
          max: max);
    } else {
      fullScans++;
      _live = live;
      _epg = epg;
      _flags = flags;
      _hidden = hiddenGroups;
      _validUntil = now.add(window);
      _candidates = sportCandidates(
          categories: live.categories,
          channels: live.channels,
          epg: epg,
          from: now,
          until: _validUntil,
          hidden: hidden);
      r = liveSport(
          categories: live.categories,
          channels: _candidates,
          epg: epg,
          now: now,
          hidden: hidden,
          max: max);
    }
    _minute = minute;
    // Gleiche Auswahl → dieselbe Liste (Beobachter bauen nicht neu).
    if (_sameShows(r, _last)) return _last;
    return _last = r;
  }

  static bool _sameShows(List<LiveShow> a, List<LiveShow> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!identical(a[i].channel, b[i].channel) ||
          !identical(a[i].entry, b[i].entry)) {
        return false;
      }
    }
    return true;
  }
}

/// Sender (in Listenreihenfolge), die zwischen [from] und [until] in
/// [liveSport] auftauchen können: Sport-Gruppe, oder eine Sendung in diesem
/// Zeitraum ist Sport.
List<Channel> sportCandidates({
  required List<Category> categories,
  required List<Channel> channels,
  required Map<String, List<EpgEntry>> epg,
  required DateTime from,
  required DateTime until,
  bool Function(Channel)? hidden,
}) {
  final sportGroups = {
    for (final c in categories)
      if (SportDetector.isSportGroup(c.name)) c.id,
  };
  final out = <Channel>[];
  for (final c in channels) {
    if (hidden?.call(c) ?? false) continue;
    final list = epg[epgKeyOf(c)];
    if (list == null || list.isEmpty) continue;
    if (sportGroups.contains(c.categoryId)) {
      out.add(c);
      continue;
    }
    // Letzte Sendung, die bis [from] begonnen hat (binäre Suche) …
    var lo = 0, hi = list.length - 1, i = 0;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (!list[mid].start.isAfter(from)) {
        i = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    // … und alle, die bis [until] beginnen.
    for (; i < list.length && !list[i].start.isAfter(until); i++) {
      final e = list[i];
      if (!e.end.isAfter(from)) continue;
      if (SportDetector.isSportText(e.genre) ||
          SportDetector.isSportText(e.title)) {
        out.add(c);
        break;
      }
    }
  }
  return out;
}

final liveSportMemoProvider = Provider<LiveSportMemo>((_) => LiveSportMemo());

final liveSportProvider = Provider<List<LiveShow>>((ref) {
  ref.watch(minuteTickProvider);
  final live = ref.watch(visibleLiveDataProvider).value;
  final epg = ref.watch(epgProvider).value;
  if (live == null || epg == null || epg.isEmpty) return const [];
  final flags = ref.watch(channelFlagsProvider).value ?? ChannelFlags.empty;
  final hiddenGroups =
      ref.watch(sortOrderProvider).value?.hiddenGroups ?? const <String>{};
  return ref.read(liveSportMemoProvider).compute(
        live: live,
        epg: epg,
        flags: flags,
        hiddenGroups: hiddenGroups,
        now: DateTime.now(),
      );
});

// ---------------------------------------------------------------------------
// Empfehlungen „Weil du … geschaut hast“
// ---------------------------------------------------------------------------

/// Verlauf-Schlüssel der letzten 10 Titel (ändert sich selten – nur dann
/// wird neu empfohlen).
final _recentHistoryProvider = Provider<List<String>>((ref) {
  final keys = ref.watch(vodLibraryProvider.select((a) => [
        for (final h in (a.value?.history ?? const <VodHistoryEntry>[]).take(10))
          '${h.series ? 's' : 'm'}:${h.id}',
      ].join('|')));
  return keys.isEmpty ? const [] : keys.split('|');
});

final recommendationProvider = Provider<Recommendation?>((ref) {
  if (ref.watch(guestModeProvider)) return null;
  final hist = ref.watch(_recentHistoryProvider);
  if (hist.isEmpty) return null;
  final movies = ref.watch(vodCatalogProvider(false));
  final series = ref.watch(vodCatalogProvider(true));
  // Genre-Verzeichnisse (im Hintergrund gebaut) – bis dahin keine Reihe.
  final gm = movies == null ? null : genreIndexFor(ref, false);
  final gs = series == null ? null : genreIndexFor(ref, true);
  if ((movies != null && gm == null) || (series != null && gs == null)) {
    return null;
  }
  // Emby-Titel (falls eingerichtet) zählen genauso.
  final em = ref.watch(embyCatalogProvider(false));
  final es = ref.watch(embyCatalogProvider(true));
  final hasEm = em != null && em.items.isNotEmpty;
  final hasEs = es != null && es.items.isNotEmpty;
  final gem = hasEm ? _embyGenreIndexFor(ref, false) : null;
  final ges = hasEs ? _embyGenreIndexFor(ref, true) : null;
  if ((hasEm && gem == null) || (hasEs && ges == null)) return null;
  final st = ref.watch(storageProvider).value;
  VodItem? find(String k) {
    final s = k.startsWith('s:');
    final id = k.substring(2);
    return (s ? series : movies)?.byId[id] ?? (s ? es : em)?.byId[id];
  }

  final recent = <VodItem>[
    for (final k in hist)
      if (find(k) case final VodItem m) m,
  ];
  return recommend(
    recent: recent,
    candidatesOf: (g) => [
      ...?gm?.itemsOf(g),
      ...?gs?.itemsOf(g),
      ...?gem?.itemsOf(g),
      ...?ges?.itemsOf(g),
    ],
    seen: (m) => isSeen(st, m),
  );
});
