import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/profile_mode.dart' show guestModeProvider;
import '../../state/profiles.dart' show activeProfileIdProvider;
import '../../state/providers.dart';

/// „Letzte Suchen“ je Portal (höchstens [max], neueste zuerst). Im
/// Gastmodus wird nichts gespeichert und nichts angezeigt.
class RecentSearchesNotifier extends Notifier<List<String>> {
  static const max = 8;

  String? _pid;

  static String keyFor(String portalId) => 'recentsearch_$portalId';

  @override
  List<String> build() {
    final st = ref.watch(storageProvider).value;
    final portal = ref.watch(activePortalProvider).value;
    final guest = ref.watch(guestModeProvider);
    ref.watch(activeProfileIdProvider); // Suchverlauf je Profil
    _pid = portal?.id;
    if (st == null || portal == null || guest) return const [];
    return decode(st.option(keyFor(portal.id), ''));
  }

  static List<String> decode(String raw) {
    if (raw.isEmpty) return const [];
    try {
      final l = jsonDecode(raw);
      if (l is! List) return const [];
      return [
        for (final x in l.whereType<String>())
          if (x.trim().isNotEmpty) x,
      ].take(max).toList();
    } catch (_) {
      return const [];
    }
  }

  bool get _blocked =>
      _pid == null ||
      ref.read(guestModeProvider) ||
      ref.read(storageProvider).value == null;

  Future<void> _save(List<String> l) async {
    final st = ref.read(storageProvider).value;
    final pid = _pid;
    if (st == null || pid == null) return;
    state = List.unmodifiable(l);
    await st.setOption(keyFor(pid), jsonEncode(l));
  }

  /// Suchbegriff merken (vorne; Groß/Klein-Dubletten ersetzt).
  Future<void> add(String query) async {
    final q = query.trim();
    if (q.length < 2 || _blocked) return;
    final low = q.toLowerCase();
    final l = [q, ...state.where((x) => x.toLowerCase() != low)];
    await _save(l.length > max ? l.sublist(0, max) : l);
  }

  Future<void> remove(String query) async {
    if (_blocked) return;
    await _save([...state.where((x) => x != query)]);
  }
}

final recentSearchesProvider =
    NotifierProvider<RecentSearchesNotifier, List<String>>(
        RecentSearchesNotifier.new);
