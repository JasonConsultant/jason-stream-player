import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/emby/emby_client.dart' show embyScope;
import '../data/emby/emby_mapper.dart' show isEmbyId;
import '../data/storage.dart';
import '../models/models.dart';
import 'profile_mode.dart' show guestModeProvider;
import 'profiles.dart' show activeProfileIdProvider;
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

/// Favoriten („Meine Liste“) und Verlauf für Filme & Serien – pro Portal;
/// Emby-Titel (ID `emby_…`) liegen portalunabhängig unter [embyScope].
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
    ref.watch(activeProfileIdProvider); // Meine Liste/Verlauf je Profil
    // Gastmodus: „Meine Liste“ und Verlauf ausblenden.
    if (ref.watch(guestModeProvider)) return VodLibrary.empty;
    final portal = p == null ? VodLibrary.empty : _read(s, p.id);
    final emby = _read(s, embyScope);
    if (emby.favorites.isEmpty && emby.history.isEmpty) return portal;
    final hist = [...portal.history, ...emby.history]
      ..sort((a, b) => b.at.compareTo(a.at));
    return VodLibrary({...portal.favorites, ...emby.favorites}, hist);
  }

  static VodLibrary _read(Storage s, String scope) {
    try {
      final favs = (jsonDecode(s.option('vodfav_$scope', '[]')) as List)
          .cast<String>()
          .toSet();
      final hist = (jsonDecode(s.option('vodhist_$scope', '[]')) as List)
          .map((e) => VodHistoryEntry.fromJson(e as Map<String, dynamic>))
          .toList();
      return VodLibrary(favs, hist);
    } catch (_) {
      return VodLibrary.empty;
    }
  }

  static bool _embyKey(String favKey) => isEmbyId(favKey.substring(2));

  /// Im Gastmodus wirkungslos – weder Verlauf noch „Meine Liste“ ändern.
  /// Emby-Einträge gehen in den portalunabhängigen Bereich.
  Future<void> _save(VodLibrary lib) async {
    final s = await ref.read(storageProvider.future);
    final p = await ref.read(activePortalProvider.future);
    if (s.guestMode) return;
    Future<void> write(String scope, bool emby) async {
      await s.setOption(
          'vodfav_$scope',
          jsonEncode([
            for (final f in lib.favorites)
              if (_embyKey(f) == emby) f
          ]));
      await s.setOption(
          'vodhist_$scope',
          jsonEncode([
            for (final h in lib.history)
              if (isEmbyId(h.id) == emby) h.toJson()
          ]));
    }

    if (p != null) await write(p.id, false);
    await write(embyScope, true);
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
    return _save(VodLibrary(lib.favorites, _cap(h)));
  }

  /// Höchstens 40 Einträge je Bereich (Portal bzw. Emby).
  static List<VodHistoryEntry> _cap(List<VodHistoryEntry> h) {
    var portal = 0, emby = 0;
    return [
      for (final e in h)
        if (isEmbyId(e.id) ? ++emby <= 40 : ++portal <= 40) e,
    ];
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
