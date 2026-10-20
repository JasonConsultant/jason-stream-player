import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/models.dart';
import 'providers.dart';

/// Ein Eintrag im Verlauf von Filmen/Serien.
class VodHistoryEntry {
  final bool series;
  final String id; // Film- bzw. Serien-ID
  final String? episodeId;
  final int? season, episode;
  final DateTime at;
  const VodHistoryEntry(this.series, this.id, this.at,
      {this.episodeId, this.season, this.episode});

  Map<String, Object?> toJson() => {
        's': series,
        'id': id,
        'e': episodeId,
        'sn': season,
        'en': episode,
        't': at.millisecondsSinceEpoch,
      };

  factory VodHistoryEntry.fromJson(Map<String, dynamic> j) => VodHistoryEntry(
        j['s'] == true,
        j['id'] as String,
        DateTime.fromMillisecondsSinceEpoch(j['t'] as int),
        episodeId: j['e'] as String?,
        season: j['sn'] as int?,
        episode: j['en'] as int?,
      );
}

/// Favoriten („Meine Liste“) und Verlauf für Filme & Serien – pro Portal.
class VodLibrary {
  final Set<String> favorites; // 'm:<id>' bzw. 's:<id>'
  final List<VodHistoryEntry> history; // neueste zuerst
  const VodLibrary(this.favorites, this.history);
  static const empty = VodLibrary({}, []);

  static String keyOf(VodItem m) => '${m.isSeries ? 's' : 'm'}:${m.id}';
  bool isFavorite(VodItem m) => favorites.contains(keyOf(m));

  VodHistoryEntry? lastOf(VodItem m) {
    for (final h in history) {
      if (h.series == m.isSeries && h.id == m.id) return h;
    }
    return null;
  }
}

class VodLibraryNotifier extends AsyncNotifier<VodLibrary> {
  @override
  Future<VodLibrary> build() async {
    final s = await ref.watch(storageProvider.future);
    final p = await ref.watch(activePortalProvider.future);
    if (p == null) return VodLibrary.empty;
    try {
      final favs = (jsonDecode(s.option('vodfav_${p.id}', '[]')) as List)
          .cast<String>()
          .toSet();
      final hist = (jsonDecode(s.option('vodhist_${p.id}', '[]')) as List)
          .map((e) => VodHistoryEntry.fromJson(e as Map<String, dynamic>))
          .toList();
      return VodLibrary(favs, hist);
    } catch (_) {
      return VodLibrary.empty;
    }
  }

  Future<void> _save(VodLibrary lib) async {
    final s = await ref.read(storageProvider.future);
    final p = await ref.read(activePortalProvider.future);
    if (p == null) return;
    await s.setOption('vodfav_${p.id}', jsonEncode(lib.favorites.toList()));
    await s.setOption('vodhist_${p.id}',
        jsonEncode([for (final h in lib.history) h.toJson()]));
    state = AsyncData(lib);
  }

  /// Wartet aufs Laden – sonst würde ein Schreiben während des Ladens
  /// Favoriten und Verlauf überschreiben.
  Future<VodLibrary> _lib() async {
    try {
      return await future;
    } catch (_) {
      return state.value ?? VodLibrary.empty;
    }
  }

  Future<void> toggleFavorite(VodItem m) async {
    final lib = await _lib();
    final k = VodLibrary.keyOf(m);
    final f = {...lib.favorites};
    f.contains(k) ? f.remove(k) : f.add(k);
    return _save(VodLibrary(f, lib.history));
  }

  Future<void> _push(VodHistoryEntry e) async {
    final lib = await _lib();
    final h = [
      e,
      for (final x in lib.history)
        if (!(x.series == e.series && x.id == e.id)) x,
    ];
    return _save(VodLibrary(lib.favorites, h.length > 40 ? h.sublist(0, 40) : h));
  }

  Future<void> watchedMovie(VodItem m) =>
      _push(VodHistoryEntry(false, m.id, DateTime.now()));

  Future<void> watchedEpisode(VodItem s, Episode e) => _push(VodHistoryEntry(
      true, s.id, DateTime.now(),
      episodeId: e.id, season: e.season, episode: e.number));

  Future<void> remove(VodItem m) async {
    final lib = await _lib();
    return _save(VodLibrary(lib.favorites, [
      for (final x in lib.history)
        if (!(x.series == m.isSeries && x.id == m.id)) x,
    ]));
  }
}

final vodLibraryProvider =
    AsyncNotifierProvider<VodLibraryNotifier, VodLibrary>(VodLibraryNotifier.new);
