import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../data/tmdb/tmdb.dart';
import '../data/tmdb/tmdb_cache_db.dart';
import '../l10n/strings.dart';
import '../models/models.dart';
import '../player/data_saver.dart';
import 'profile_mode.dart' show kidsModeProvider;
import 'providers.dart';

export '../data/tmdb/tmdb.dart';

/// HTTP für TMDB (Tests: Fake).
final tmdbHttpProvider = Provider<http.Client>((ref) {
  final c = http.Client();
  ref.onDispose(c.close);
  return c;
});

/// Zwischenspeicher (Datenbank; ohne Datenbank im Speicher).
final tmdbCacheProvider = Provider<TmdbCache>((_) => DbTmdbCache());

/// Einstellungen: Schlüssel (verschlüsselt), Quelle.
class TmdbSettings {
  final String key;
  final TmdbSource source;
  const TmdbSettings(this.key, this.source);
  bool get hasKey => key.isNotEmpty;

  /// TMDB wird nur mit Schlüssel und nicht „Nur Anbieter“ gefragt.
  bool get active => hasKey && source != TmdbSource.provider;

  @override
  bool operator ==(Object other) =>
      other is TmdbSettings && other.key == key && other.source == source;
  @override
  int get hashCode => Object.hash(key, source);
}

final tmdbSettingsProvider = Provider<TmdbSettings>((ref) {
  final st = ref.watch(storageProvider).value;
  if (st == null) return const TmdbSettings('', TmdbSource.mix);
  return TmdbSettings(st.tmdbKey ?? '',
      TmdbSource.fromId(st.option(TmdbSource.optionKey, TmdbSource.mix.id)));
});

/// Client – null ohne Schlüssel bzw. bei „Nur Anbieter“ (dann gibt es
/// keinerlei Netzverkehr zu TMDB).
final tmdbClientProvider = Provider<TmdbClient?>((ref) {
  final s = ref.watch(tmdbSettingsProvider);
  if (!s.active) return null;
  ref.watch(appLangProvider);
  return TmdbClient(
    key: s.key,
    client: ref.watch(tmdbHttpProvider),
    cache: ref.watch(tmdbCacheProvider),
    lang: L10n.lang,
  );
});

/// Suchanfrage für einen Titel (Schlüssel für die Provider-Familie).
class TmdbQuery {
  final String title;
  final int? year;
  final bool tv;
  final String? tmdbId;
  const TmdbQuery(this.title, this.year, this.tv, this.tmdbId);

  factory TmdbQuery.of(VodItem m) =>
      TmdbQuery(m.name, m.year, m.isSeries, m.tmdbId);

  @override
  bool operator ==(Object other) =>
      other is TmdbQuery &&
      other.title == title &&
      other.year == year &&
      other.tv == tv &&
      other.tmdbId == tmdbId;
  @override
  int get hashCode => Object.hash(title, year, tv, tmdbId);
}

/// TMDB-Angaben zu einem Titel (null: aus, nicht gefunden oder Fehler –
/// die Detailseite zeigt dann einfach die Anbieter-Daten).
final tmdbInfoProvider =
    FutureProvider.family<TmdbInfo?, TmdbQuery>((ref, q) async {
  final c = ref.watch(tmdbClientProvider);
  if (c == null) return null;
  try {
    return await c.lookup(
        title: q.title, year: q.year, tv: q.tv, tmdbId: q.tmdbId);
  } on TmdbException {
    return null;
  }
});

/// Anbieter-Daten mit TMDB ergänzt bzw. (Quelle „TMDB bevorzugt“) ersetzt.
VodItem mergeTmdb(VodItem m, TmdbInfo? t,
    {required TmdbSource source, bool saver = false}) {
  if (t == null || source == TmdbSource.provider) return m;
  final prefer = source == TmdbSource.tmdb;
  String? pick(String? own, String? theirs) {
    final has = own != null && own.trim().isNotEmpty;
    if (theirs == null || theirs.isEmpty) return own;
    return (prefer || !has) ? theirs : own;
  }

  final cast = t.cast.isEmpty ? null : t.cast.map((c) => c.name).join(', ');
  return m.copyWith(
    posterUrl: pick(m.posterUrl, TmdbImages.poster(t.posterPath, saver: saver)),
    backdropUrl:
        pick(m.backdropUrl, TmdbImages.backdrop(t.backdropPath, saver: saver)),
    plot: pick(m.plot, t.overview),
    genre: pick(m.genre, t.genres.isEmpty ? null : t.genres.join(', ')),
    cast: pick(m.cast, cast),
    director: pick(m.director, t.director),
    trailer: pick(m.trailer, t.trailerKey),
    rating: (prefer || m.rating == null || m.rating == 0) && t.rating != null
        ? double.parse(t.rating!.toStringAsFixed(1))
        : m.rating,
    year: m.year ?? t.year,
    duration: (m.duration == null || m.duration!.inMinutes == 0) &&
            t.runtimeMinutes != null
        ? Duration(minutes: t.runtimeMinutes!)
        : m.duration,
    tmdbId: m.tmdbId ?? '${t.id}',
  );
}

/// Ergebnis für die Detailseiten: zusammengeführter Titel und die
/// TMDB-Angaben (Besetzung mit Fotos) – oder nur der Titel.
typedef TmdbDetail = ({VodItem item, TmdbInfo? info});

/// Film/Serie für die Detailseite anreichern.
TmdbDetail tmdbDetail(WidgetRef ref, VodItem m) {
  final s = ref.watch(tmdbSettingsProvider);
  if (!s.active || m.isEmby) return (item: m, info: null);
  final info = ref.watch(tmdbInfoProvider(TmdbQuery.of(m))).value;
  return (
    item: mergeTmdb(m, info,
        source: s.source, saver: ref.watch(dataSaverActiveProvider)),
    info: info,
  );
}

/// Filmografie einer Person (null ohne TMDB, im Kindermodus oder bei
/// Fehlern). Kinder bekommen keine unbeschränkte Personensuche.
final tmdbPersonProvider =
    FutureProvider.family<TmdbPerson?, ({String name, int? id})>(
        (ref, p) async {
  if (ref.watch(kidsModeProvider)) return null;
  final c = ref.watch(tmdbClientProvider);
  if (c == null) return null;
  try {
    return await c.person(p.name, id: p.id);
  } on TmdbException {
    return null;
  }
});

/// Ordnet TMDB-Titel den Titeln im Portal zu (Titel + Jahr ±1).
class PortalTitleIndex {
  final Map<String, List<VodItem>> _byTitle = {};

  PortalTitleIndex(Iterable<VodItem> items) {
    for (final m in items) {
      final c = TmdbMatch.clean(m.name);
      final k = '${m.isSeries ? 't' : 'm'}:${TmdbMatch.norm(c.title)}';
      (_byTitle[k] ??= []).add(m);
    }
  }

  VodItem? find(TmdbPersonCredit c) {
    for (final t in {c.title, if (c.originalTitle != null) c.originalTitle!}) {
      final list = _byTitle['${c.tv ? 't' : 'm'}:${TmdbMatch.norm(t)}'];
      if (list == null) continue;
      for (final m in list) {
        final y = m.year ?? TmdbMatch.clean(m.name).year;
        if (y == null || c.year == null || (y - c.year!).abs() <= 1) {
          return m;
        }
      }
    }
    return null;
  }
}
