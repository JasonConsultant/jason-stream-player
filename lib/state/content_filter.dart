import 'package:flutter/foundation.dart' show compute;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/content_filters.dart';
import '../data/storage.dart';
import '../models/models.dart';
import 'providers.dart';

/// Inhaltsfilter, die vor dem Kindermodus angewendet werden:
/// - **Erwachsenen-Sperre**: erkannte Erwachsenen-Gruppen (Live, Filme,
///   Serien) sind überall ausgeblendet – Live TV, Guide, Suche, Startseite,
///   „Neu hinzugefügt“ –, bis sie mit der PIN entsperrt werden (gilt bis
///   zum nächsten App-Start).
/// - **Länderfilter**: nur gewählte Länder (pro Portal).

// ---------------------------------------------------------------- Erwachsene

/// „Erwachseneninhalte automatisch sperren“ (Gerät, Standard an).
class AdultLockEnabledNotifier extends Notifier<bool> {
  @override
  bool build() => ref.watch(storageProvider).value?.adultLock ?? true;

  Future<void> set(bool on) async {
    final st = await ref.read(storageProvider.future);
    await st.setFlag(Storage.adultLockFlag, on);
    state = on;
  }
}

final adultLockEnabledProvider =
    NotifierProvider<AdultLockEnabledNotifier, bool>(
        AdultLockEnabledNotifier.new);

/// Mit PIN entsperrt (nur im Speicher – nach Neustart wieder gesperrt).
class AdultUnlockedNotifier extends Notifier<bool> {
  @override
  bool build() {
    // Anderes Portal → wieder sperren.
    ref.watch(activePortalProvider.select((p) => p.value?.id));
    return false;
  }

  void set(bool v) => state = v;
}

final adultUnlockedProvider =
    NotifierProvider<AdultUnlockedNotifier, bool>(AdultUnlockedNotifier.new);

/// Automatische 18+-Sperre ist (auf Wunsch) vorerst abgeschaltet: nichts wird
/// automatisch gesperrt oder versteckt, die Einstellung ist ausgeblendet.
/// Zum Aktivieren auf `true` setzen.
const kAdultAutoLockFeature = false;

/// Sperre wirkt gerade (an und nicht entsperrt).
final adultLockActiveProvider = Provider<bool>((ref) =>
    kAdultAutoLockFeature &&
    ref.watch(adultLockEnabledProvider) &&
    !ref.watch(adultUnlockedProvider));

/// Anzahl erkannter Erwachsenen-Gruppen im aktiven Portal (ungefiltert).
final adultGroupCountProvider = Provider<int>((ref) {
  final live = ref.watch(liveDataProvider).value;
  final movies = ref.watch(moviesProvider).value;
  final series = ref.watch(seriesProvider).value;
  var n = 0;
  for (final cats in [
    live?.categories,
    movies?.categories,
    series?.categories
  ]) {
    for (final c in cats ?? const <Category>[]) {
      if (AdultDetector.isAdult(c.name)) n++;
    }
  }
  return n;
});

/// Einmaliger Hinweis fällig: Erwachsenen-Gruppen gesperrt, aber noch keine
/// PIN – ohne PIN bleiben sie ausgeblendet.
final adultInfoDueProvider = Provider<bool>((ref) {
  final st = ref.watch(storageProvider).value;
  if (st == null || st.adultInfoShown || st.hasPin()) return false;
  if (!ref.watch(adultLockActiveProvider)) return false;
  return ref.watch(adultGroupCountProvider) > 0;
});

class AdultFilter {
  AdultFilter._();

  static LiveData live(LiveData d) {
    final adult = {
      for (final c in d.categories)
        if (AdultDetector.isAdult(c.name)) c.id
    };
    if (adult.isEmpty) return d;
    return LiveData(
      [
        for (final c in d.categories)
          if (!adult.contains(c.id)) c
      ],
      [
        for (final c in d.channels)
          if (!adult.contains(c.categoryId)) c
      ],
    );
  }

  static VodData vod(VodData d) {
    final adult = {
      for (final c in d.categories)
        if (AdultDetector.isAdult(c.name)) c.id
    };
    if (adult.isEmpty) return d;
    return VodData(
      [
        for (final c in d.categories)
          if (!adult.contains(c.id)) c
      ],
      [
        for (final m in d.items)
          if (!adult.contains(m.categoryId)) m
      ],
    );
  }
}

// ------------------------------------------------------------------ Länder

/// Gewählte Länder des aktiven Portals (leer = alle).
class CountryFilterNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() {
    final st = ref.watch(storageProvider).value;
    final p = ref.watch(activePortalProvider).value;
    if (st == null || p == null) return const {};
    return st.countries(p.id);
  }

  Future<void> set(Set<String> codes) async {
    final st = await ref.read(storageProvider.future);
    final p = ref.read(activePortalProvider).value;
    if (p == null) return;
    await st.setCountries(p.id, codes);
    state = {...codes};
  }
}

final countryFilterProvider =
    NotifierProvider<CountryFilterNotifier, Set<String>>(
        CountryFilterNotifier.new);

class CountryFilter {
  CountryFilter._();

  /// Sender nach Land filtern; Gruppen ohne verbleibende Sender fallen weg.
  static LiveData live(LiveData d, Set<String> allowed) {
    if (allowed.isEmpty) return d;
    final groupCode = {
      for (final c in d.categories) c.id: CountryDetector.fromGroup(c.name)
    };
    final channels = [
      for (final c in d.channels)
        if (CountryDetector.passes(
            CountryDetector.forItem(c.name, groupCode[c.categoryId]), allowed))
          c
    ];
    final used = {for (final c in channels) c.categoryId};
    return LiveData(
      [
        for (final c in d.categories)
          if (used.contains(c.id)) c
      ],
      channels,
    );
  }

  /// Filme/Serien: Land aus dem Titel-Kürzel, sonst aus der Kategorie.
  static VodData vod(VodData d, Set<String> allowed) {
    if (allowed.isEmpty) return d;
    final catCode = {
      for (final c in d.categories) c.id: CountryDetector.fromGroup(c.name)
    };
    final items = [
      for (final m in d.items)
        if (CountryDetector.passes(
            CountryDetector.forItem(m.name, catCode[m.categoryId]), allowed))
          m
    ];
    final used = {for (final m in items) m.categoryId};
    final nonEmpty = {for (final m in d.items) m.categoryId};
    return VodData(
      [
        for (final c in d.categories)
          if (used.contains(c.id) ||
              (!nonEmpty.contains(c.id) &&
                  CountryDetector.passes(catCode[c.id], allowed)))
            c
      ],
      items,
    );
  }

  /// Erkannte Länder mit Anzahl (Sender + Titel) für die Auswahl.
  static Map<String, int> detect(LiveData? live, List<VodData?> vod) {
    final out = <String, int>{};
    void count(String? code) {
      final k = code ?? CountryDetector.none;
      out[k] = (out[k] ?? 0) + 1;
    }

    if (live != null) {
      final g = {
        for (final c in live.categories) c.id: CountryDetector.fromGroup(c.name)
      };
      for (final c in live.channels) {
        count(CountryDetector.forItem(c.name, g[c.categoryId]));
      }
    }
    for (final v in vod) {
      if (v == null) continue;
      final g = {
        for (final c in v.categories) c.id: CountryDetector.fromGroup(c.name)
      };
      for (final m in v.items) {
        count(CountryDetector.forItem(m.name, g[m.categoryId]));
      }
    }
    return out;
  }
}

/// Erkannte Länder mit Anzahl für „Länder anzeigen“ – einmal je Liste
/// berechnet (nicht bei jedem Antippen), große Anbieter im Hintergrund.
final countryCountsProvider = FutureProvider<Map<String, int>>((ref) async {
  final live = ref.watch(liveDataProvider).value;
  final movies = ref.watch(moviesProvider).value;
  final series = ref.watch(seriesProvider).value;
  final n = (live?.channels.length ?? 0) +
      (movies?.items.length ?? 0) +
      (series?.items.length ?? 0);
  if (n < 20000) return CountryFilter.detect(live, [movies, series]);
  // Nur Namen und Gruppen übertragen, nicht die ganzen Objekte.
  final jobs = <_CountryJob>[
    if (live != null)
      (
        {for (final c in live.categories) c.id: c.name},
        [for (final c in live.channels) c.name],
        [for (final c in live.channels) c.categoryId],
      ),
    for (final v in [movies, series])
      if (v != null)
        (
          {for (final c in v.categories) c.id: c.name},
          [for (final m in v.items) m.name],
          [for (final m in v.items) m.categoryId],
        ),
  ];
  return compute(_detectCountries, jobs);
});

typedef _CountryJob = (Map<String, String>, List<String>, List<String>);

Map<String, int> _detectCountries(List<_CountryJob> jobs) {
  final out = <String, int>{};
  for (final (cats, names, catIds) in jobs) {
    final g = {
      for (final e in cats.entries) e.key: CountryDetector.fromGroup(e.value)
    };
    for (var i = 0; i < names.length; i++) {
      final k = CountryDetector.forItem(names[i], g[catIds[i]]) ??
          CountryDetector.none;
      out[k] = (out[k] ?? 0) + 1;
    }
  }
  return out;
}

/// Live-Daten nach Erwachsenen-Sperre und Länderfilter (vor Kindermodus).
LiveData applyContentFilters(LiveData d,
    {required bool adultLocked, required Set<String> countries}) {
  var out = d;
  if (adultLocked) out = AdultFilter.live(out);
  if (countries.isNotEmpty) out = CountryFilter.live(out, countries);
  return out;
}

VodData applyVodContentFilters(VodData d,
    {required bool adultLocked, required Set<String> countries}) {
  var out = d;
  if (adultLocked) out = AdultFilter.vod(out);
  if (countries.isNotEmpty) out = CountryFilter.vod(out, countries);
  return out;
}
