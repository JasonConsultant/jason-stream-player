import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/storage.dart';
import 'my_groups.dart';
import 'providers.dart';

/// Kinder- und Gastmodus (pro Gerät, in den Einstellungen gespeichert).
///
/// - **Kindermodus**: nur freigegebene Gruppen (Live; optional Film-/Serien-
///   Kategorien) sind überall sichtbar; Einstellungen, Portalwechsel und
///   Bearbeiten sind gesperrt. Beenden nur mit PIN.
/// - **Gastmodus**: nichts wird in Verlauf/Weiterschauen geschrieben,
///   Favoriten/Verlauf/Meine Liste sind ausgeblendet und unveränderbar.
class ProfileMode {
  final bool kids;
  final bool guest;

  /// Freigegebene Live-Gruppen des aktiven Portals (Kategorie-IDs, auch
  /// eigene Gruppen `my_…`).
  final Set<String> kidsGroups;

  /// Freigegebene Film-/Serien-Kategorien: `m:<id>` bzw. `s:<id>`.
  final Set<String> kidsVod;

  const ProfileMode({
    this.kids = false,
    this.guest = false,
    this.kidsGroups = const {},
    this.kidsVod = const {},
  });

  static const off = ProfileMode();

  static String vodKey(bool series, String categoryId) =>
      '${series ? 's' : 'm'}:$categoryId';

  ProfileMode copyWith(
          {bool? kids,
          bool? guest,
          Set<String>? kidsGroups,
          Set<String>? kidsVod}) =>
      ProfileMode(
        kids: kids ?? this.kids,
        guest: guest ?? this.guest,
        kidsGroups: kidsGroups ?? this.kidsGroups,
        kidsVod: kidsVod ?? this.kidsVod,
      );

  @override
  bool operator ==(Object other) =>
      other is ProfileMode &&
      other.kids == kids &&
      other.guest == guest &&
      _same(other.kidsGroups, kidsGroups) &&
      _same(other.kidsVod, kidsVod);

  static bool _same(Set<String> a, Set<String> b) =>
      a.length == b.length && a.containsAll(b);

  @override
  int get hashCode => Object.hash(kids, guest, kidsGroups.length, kidsVod.length);
}

class ProfileModeNotifier extends Notifier<ProfileMode> {
  @override
  ProfileMode build() {
    final st = ref.watch(storageProvider).value;
    final portal = ref.watch(activePortalProvider).value;
    if (st == null) return ProfileMode.off;
    return ProfileMode(
      kids: st.kidsMode,
      guest: st.guestMode,
      kidsGroups: portal == null ? const {} : st.kidsGroups(portal.id),
      kidsVod: portal == null ? const {} : st.kidsVod(portal.id),
    );
  }

  Future<Storage> get _st => ref.read(storageProvider.future);

  /// Gastmodus an/aus (ohne PIN).
  Future<void> setGuest(bool on) async {
    await (await _st).setFlag(Storage.guestFlag, on);
    state = state.copyWith(guest: on);
  }

  /// Kindermodus an/aus. Die PIN-Abfrage macht die Oberfläche
  /// (ensurePin beim Einschalten, askPin beim Ausschalten).
  Future<void> setKids(bool on) async {
    await (await _st).setFlag(Storage.kidsFlag, on);
    state = state.copyWith(kids: on);
  }

  Future<void> setKidsGroups(Set<String> ids) async {
    final p = ref.read(activePortalProvider).value;
    if (p == null) return;
    await (await _st).setKidsGroups(p.id, ids);
    state = state.copyWith(kidsGroups: {...ids});
  }

  Future<void> setKidsVod(Set<String> keys) async {
    final p = ref.read(activePortalProvider).value;
    if (p == null) return;
    await (await _st).setKidsVod(p.id, keys);
    state = state.copyWith(kidsVod: {...keys});
  }
}

final profileModeProvider =
    NotifierProvider<ProfileModeNotifier, ProfileMode>(ProfileModeNotifier.new);

/// Nur die Kindermodus-Freigaben (für Filter, die sich nicht um den
/// Gastmodus kümmern).
final _kidsProvider = Provider<ProfileMode?>((ref) {
  final m = ref.watch(profileModeProvider);
  return m.kids ? m : null;
});

/// Kindermodus-Filter für Live-Daten.
class KidsFilter {
  KidsFilter._();

  /// Sender in freigegebenen Gruppen (Anbieter-Gruppen oder eigene Gruppen).
  static LiveData live(
      LiveData d, Set<String> groups, List<MyGroup> myGroups) {
    final viaMy = <String>{
      for (final g in myGroups)
        if (groups.contains(g.id)) ...g.channels,
    };
    return LiveData(
      [for (final c in d.categories) if (groups.contains(c.id)) c],
      [
        for (final c in d.channels)
          if (groups.contains(c.categoryId) || viaMy.contains(c.id)) c,
      ],
    );
  }

  static VodData vod(VodData d, bool series, Set<String> keys) => VodData(
        [
          for (final c in d.categories)
            if (keys.contains(ProfileMode.vodKey(series, c.id))) c,
        ],
        [
          for (final m in d.items)
            if (keys.contains(ProfileMode.vodKey(series, m.categoryId))) m,
        ],
      );
}

/// Senderliste, wie sie überall angezeigt wird: im Kindermodus nur die
/// freigegebenen Gruppen. Startseite, Live TV, TV-Guide, Suche und damit
/// auch die Senderliste/das Zappen im Player nutzen diese Liste.
final visibleLiveDataProvider = Provider<AsyncValue<LiveData>>((ref) {
  final live = ref.watch(liveDataProvider);
  final kids = ref.watch(_kidsProvider);
  if (kids == null) return live;
  final my = ref.watch(myGroupsProvider).value ?? const <MyGroup>[];
  return live.whenData((d) => KidsFilter.live(d, kids.kidsGroups, my));
});

/// Wie [visibleLiveDataProvider], zum Abwarten (z. B. Start aus einer
/// Benachrichtigung).
/// Liest den Modus direkt aus dem Speicher (nicht aus [profileModeProvider],
/// der beim Kaltstart noch „aus“ melden kann) und wartet auf die eigenen
/// Gruppen – sonst könnte ein Start über den TV-Startbildschirm oder eine
/// Erinnerung kurz die ungefilterte Liste sehen.
Future<LiveData> readVisibleLive(WidgetRef ref) async {
  final st = await ref.read(storageProvider.future);
  final d = await ref.read(liveDataProvider.future);
  if (!st.kidsMode) return d;
  final portal = await ref.read(activePortalProvider.future);
  if (portal == null) return const LiveData([], []);
  List<MyGroup> my;
  try {
    my = await ref.read(myGroupsProvider.future);
  } catch (_) {
    my = const [];
  }
  return KidsFilter.live(d, st.kidsGroups(portal.id), my);
}

/// Eigene Gruppen – im Kindermodus nur freigegebene.
final visibleMyGroupsProvider = Provider<List<MyGroup>>((ref) {
  final all = ref.watch(myGroupsProvider).value ?? const <MyGroup>[];
  final kids = ref.watch(_kidsProvider);
  if (kids == null) return all;
  return [for (final g in all) if (kids.kidsGroups.contains(g.id)) g];
});

AsyncValue<VodData> _vod(Ref ref, bool series) {
  final v = ref.watch(series ? seriesProvider : moviesProvider);
  final kids = ref.watch(_kidsProvider);
  if (kids == null) return v;
  return v.whenData((d) => KidsFilter.vod(d, series, kids.kidsVod));
}

/// Filme bzw. Serien – im Kindermodus nur freigegebene Kategorien.
final visibleMoviesProvider =
    Provider<AsyncValue<VodData>>((ref) => _vod(ref, false));
final visibleSeriesProvider =
    Provider<AsyncValue<VodData>>((ref) => _vod(ref, true));

/// Gastmodus aktiv? (Verlauf/Favoriten ausblenden, nichts speichern)
final guestModeProvider =
    Provider<bool>((ref) => ref.watch(profileModeProvider).guest);

/// Kindermodus aktiv?
final kidsModeProvider =
    Provider<bool>((ref) => ref.watch(profileModeProvider).kids);
