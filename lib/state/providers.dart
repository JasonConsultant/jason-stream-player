import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/platform_info.dart';
import '../core/security.dart';
import '../data/epg_cache/epg_cache.dart';
import '../data/list_cache.dart';
import '../data/epg_matcher.dart';
export '../data/epg_matcher.dart' show epgKeyOf, epgOf;
import '../data/repository.dart';
import '../data/storage.dart';
import '../l10n/strings.dart';
import '../models/models.dart';
import '../player/data_saver.dart' show dataSaverActiveProvider;
import 'discover.dart' show peopleCacheProvider;
import 'emby.dart' show embyMovieDetailsProvider, embySeriesDetailsProvider;
import 'list_refresh.dart';
import 'profile_mode.dart';

// ---------- Plattform ----------
final _isTvFutureProvider = FutureProvider<bool>((_) => PlatformInfo.isTv());
final isTvProvider =
    Provider<bool>((ref) => ref.watch(_isTvFutureProvider).value ?? false);

// ---------- Storage ----------
final storageProvider = FutureProvider<Storage>((_) => Storage.open().timeout(
    const Duration(seconds: 20),
    onTimeout: () =>
        throw StartupException(tr('Der Gerätespeicher antwortet nicht.'))));

class StartupException implements Exception {
  final String message;
  StartupException(this.message);
  @override
  String toString() => message;
}

// ---------- Portale ----------
class PortalsNotifier extends AsyncNotifier<List<Portal>> {
  @override
  Future<List<Portal>> build() async {
    final s = await ref.watch(storageProvider.future);
    return s.portals();
  }

  Future<void> add(Portal p) async {
    final s = await ref.read(storageProvider.future);
    await s.addPortal(p);
    state = AsyncData(s.portals());
  }

  Future<void> rename(Portal p, String name) async {
    final s = await ref.read(storageProvider.future);
    final np = p.copyWith(name: name);
    await s.updatePortal(np);
    state = AsyncData(s.portals());
    final active = ref.read(activePortalProvider).value;
    if (active?.id == p.id) {
      ref.read(activePortalProvider.notifier).replaceSilently(np);
    }
  }

  /// Portal mit neuen Daten speichern (gleiche ID, gleiche Position).
  /// Ist es das aktive Portal, wird neu verbunden und alles neu geladen.
  Future<void> replace(Portal np) async {
    final s = await ref.read(storageProvider.future);
    await s.updatePortal(np);
    state = AsyncData(s.portals());
    if (ref.read(activePortalProvider).value?.id == np.id) {
      await ref.read(activePortalProvider.notifier).select(np);
      ref.invalidate(liveDataProvider);
      ref.invalidate(moviesProvider);
      ref.invalidate(seriesProvider);
    }
  }

  /// EPG-Quellen eines Portals ändern (zeilenweise, „portal“ = Anbieter).
  Future<void> setEpgSources(Portal p, List<String> sources) async {
    final s = await ref.read(storageProvider.future);
    final value = sources.length == 1 && sources.first == 'portal'
        ? null
        : sources.join('\n');
    // copyWith: erweiterte Einstellungen (User-Agent, Versatz …) bleiben.
    final np = p.copyWith(epgUrl: value, clearEpgUrl: value == null);
    await s.updatePortal(np);
    state = AsyncData(s.portals());
    if (ref.read(activePortalProvider).value?.id == p.id) {
      // Neue Quelle → Repository neu, EPG neu laden.
      await ref.read(activePortalProvider.notifier).select(np);
    }
  }

  Future<void> moveToTop(String id) async {
    final s = await ref.read(storageProvider.future);
    final ids = [
      id,
      for (final p in s.portals())
        if (p.id != id) p.id
    ];
    await s.reorderPortals(ids);
    state = AsyncData(s.portals());
  }

  Future<void> remove(String id) async {
    final s = await ref.read(storageProvider.future);
    await s.removePortal(id);
    state = AsyncData(s.portals());
    ref.invalidate(activePortalProvider);
  }
}

final portalsProvider =
    AsyncNotifierProvider<PortalsNotifier, List<Portal>>(PortalsNotifier.new);

class ActivePortalNotifier extends AsyncNotifier<Portal?> {
  @override
  Future<Portal?> build() async {
    if (PlatformInfo.launchParams['demo'] == '1') return Portal.demo;
    final s = await ref.watch(storageProvider.future);
    final id = s.activePortalId();
    if (id == null) return null;
    if (id == Portal.demo.id) return Portal.demo;
    final list = await ref.watch(portalsProvider.future);
    for (final p in list) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// Nur Anzeige-Daten ändern (Name), ohne Neuladen der Sender.
  void replaceSilently(Portal p) => state = AsyncData(p);

  Future<void> select(Portal? p) async {
    final s = await ref.read(storageProvider.future);
    await s.setActivePortal(p?.id);
    state = AsyncData(p);
  }
}

final activePortalProvider =
    AsyncNotifierProvider<ActivePortalNotifier, Portal?>(
        ActivePortalNotifier.new);

/// Quelle des aktiven Portals.
final repositoryProvider = FutureProvider<IptvRepository?>((ref) async {
  final portal = await ref.watch(activePortalProvider.future);
  if (portal == null) return null;
  final repo = IptvRepository.forPortal(portal);
  await repo.connect();
  return repo;
});

// ---------- Live ----------
class LiveData {
  final List<Category> categories;
  final List<Channel> channels;
  const LiveData(this.categories, this.channels);
}

/// Senderliste: sofort aus dem Zwischenspeicher, danach im Hintergrund vom
/// Server aktualisiert (ohne auf den Login zu warten).
class LiveNotifier extends AsyncNotifier<LiveData> {
  /// Senderliste ohne Überschreibungen (Original vom Server/Cache).
  LiveData _raw = const LiveData([], []);

  /// Prüfsumme der angezeigten Liste: Liefert der Server beim Nachladen
  /// denselben Inhalt, bleibt der Zustand unangetastet (keine Neuberechnung
  /// der abgeleiteten Indizes, kein Neuzeichnen, kein Schreiben).
  String? _hash;

  @override
  Future<LiveData> build() async {
    final portal = await ref.watch(activePortalProvider.future);
    if (portal == null) return const LiveData([], []);
    if (portal.type == PortalType.demo) {
      return _withOverrides(await _fetch(null) ?? const LiveData([], []));
    }
    // Automatische Listen-Aktualisierung (Portal → Erweitert).
    ref.listen(listAutoRefreshProvider, (_, __) {});
    final cached = await ListCache.loadLive(portal);
    if (cached != null && cached.items.isNotEmpty) {
      _hash = cached.hash;
      // „Nach dem Start aktuell“: still nachladen – aber erst, wenn der
      // Start durch ist (nicht während ein Stream startet).
      final t = StartReload.schedule(
          StartReload.liveDelay, () => reload(silent: true));
      ref.onDispose(t.cancel);
      return _withOverrides(LiveData(cached.categories, cached.items));
    }
    _hash = null;
    return _withOverrides(await _fetch(portal) ?? const LiveData([], []));
  }

  /// Vom Server holen. null = unverändert gegenüber der angezeigten Liste.
  Future<LiveData?> _fetch(Portal? saveFor) async {
    final repo = await ref.read(repositoryProvider.future);
    if (repo == null) return const LiveData([], []);
    final spec = saveFor == null
        ? null
        : await ListCache.spec('live', saveFor, prevHash: _hash);
    // Kategorien und Sender gleichzeitig abrufen; Umwandeln/Speichern im
    // Hintergrund-Isolate.
    final out = await repo.liveBundle(spec);
    if (saveFor != null) ListCache.lastSaved[saveFor.id] = DateTime.now();
    if (out.unchanged) return null;
    if (out.hash.isNotEmpty) _hash = out.hash;
    return LiveData(out.categories, out.items);
  }

  /// Manuelle Anpassungen (Name, Logo, EPG-Kennung) auf die Liste anwenden.
  /// Merkt sich [raw], damit [setOverride] ohne Neuladen neu anwenden kann.
  Future<LiveData> _withOverrides(LiveData raw) async {
    _raw = raw;
    final portal = ref.read(activePortalProvider).value;
    final st = ref.read(storageProvider).value;
    if (portal == null || st == null) return raw;
    return applyOverrides(raw, st.overrides(portal.id));
  }

  /// [overrides] (Sender-ID → Anpassung) auf [data] anwenden.
  static LiveData applyOverrides(
      LiveData data, Map<String, ChannelOverride> overrides) {
    if (overrides.isEmpty) return data;
    return LiveData(data.categories, [
      for (final c in data.channels) c.withOverride(overrides[c.id]),
    ]);
  }

  /// Original (ohne Überschreibung) eines Senders, z. B. zum Zurücksetzen.
  Channel? original(String channelId) {
    for (final c in _raw.channels) {
      if (c.id == channelId) return c;
    }
    return null;
  }

  /// Anpassung speichern (null/leer = entfernen) und Liste sofort neu
  /// aufbauen – Live-Liste, Guide und EPG-Filter sehen die Änderung direkt.
  Future<void> setOverride(String channelId, ChannelOverride? o) async {
    final st = await ref.read(storageProvider.future);
    final portal = ref.read(activePortalProvider).value;
    if (portal == null) return;
    await st.setOverride(portal.id, channelId, o);
    state = AsyncData(applyOverrides(_raw, st.overrides(portal.id)));
  }

  /// Vom Server neu laden. [silent]: Fehler ignorieren, Liste bleibt.
  Future<void> reload({bool silent = false}) async {
    final portal = ref.read(activePortalProvider).value;
    if (portal == null) return;
    try {
      final d = await _fetch(portal.type == PortalType.demo ? null : portal);
      if (d == null) {
        // Unverändert: nichts melden (0 Neuberechnungen) – außer ein
        // vorheriger Fehler soll wieder der Liste weichen.
        if (state.hasError) state = AsyncData(await _withOverrides(_raw));
        return;
      }
      state = AsyncData(await _withOverrides(d));
    } catch (e, st) {
      if (!silent) state = AsyncError(e, st);
    }
  }
}

final liveDataProvider =
    AsyncNotifierProvider<LiveNotifier, LiveData>(LiveNotifier.new);

// ---------- EPG ----------
/// Stand der EPG-Aktualisierung (für Einstellungen und TV-Guide).
class EpgStatus {
  final bool updating;
  final DateTime? lastUpdate;
  final String? lastError;

  /// Fortschritt während [updating]: Quelle i von n, Bytes, Gesamtgröße,
  /// true = Download fertig, wird verarbeitet.
  final (
    int source,
    int sources,
    int bytes,
    int? total,
    bool parsing
  )? progress;
  const EpgStatus(
      {this.updating = false, this.lastUpdate, this.lastError, this.progress});

  /// „Quelle 1/2 · Herunterladen 84 / 210 MB“ bzw. „Wird verarbeitet …“
  String? get progressText {
    final p = progress;
    if (p == null) return null;
    final (src, n, bytes, total, parsing) = p;
    final pre = n > 1 ? '${trf('Quelle {0}/{1}', [src, n])} · ' : '';
    if (parsing) return '$pre${tr('Wird verarbeitet …')}';
    String mb(int b) => (b / 1048576).toStringAsFixed(b < 10485760 ? 1 : 0);
    return total != null && total > 0
        ? '$pre${trf('Herunterladen {0} / {1} MB ({2} %)', [
                mb(bytes),
                mb(total),
                (bytes * 100 ~/ total)
              ])}'
        : '$pre${trf('Herunterladen {0} MB …', [mb(bytes)])}';
  }
}

class EpgStatusNotifier extends Notifier<EpgStatus> {
  @override
  EpgStatus build() => const EpgStatus();
  void set(EpgStatus s) => state = s;
}

final epgStatusProvider =
    NotifierProvider<EpgStatusNotifier, EpgStatus>(EpgStatusNotifier.new);

/// Senderliste der geladenen EPG-Quellen: XMLTV-Kennung → Anzeigename
/// (für die manuelle EPG-Zuordnung). Wird nach jedem EPG-Download gefüllt
/// und beim Start aus dem Zwischenspeicher geholt.
class EpgChannelNamesNotifier extends Notifier<Map<String, String>> {
  @override
  Map<String, String> build() => const {};
  void set(Map<String, String> names) => state = names;
}

final epgChannelNamesProvider =
    NotifierProvider<EpgChannelNamesNotifier, Map<String, String>>(
        EpgChannelNamesNotifier.new);

/// EPG mit Zwischenspeicher und automatischer Aktualisierung:
/// - Start: sofort aus dem Speicher, Nachladen im Hintergrund wenn fällig.
/// - Während die App läuft: alle 15 Min. und beim Zurückkehren in die App
///   wird geprüft, ob die geplante Aktualisierung (z. B. täglich 5 Uhr) fällig ist.
class EpgNotifier extends AsyncNotifier<Map<String, List<EpgEntry>>> {
  Timer? _timer;
  DateTime? _busySince;
  int _gen = 0;
  bool get _busy =>
      _busySince != null &&
      DateTime.now().difference(_busySince!) < const Duration(minutes: 7);

  // Ersatz-Programm pro Sender (get_short_epg), gesammelt nachgeladen.
  final _shortWanted = <String, Channel>{};
  final _shortDone = <String, DateTime>{};
  final _shortResults = <String, List<EpgEntry>>{};
  bool _shortRunning = false;

  String? _portalId;

  /// Prüfsumme des angezeigten EPG (aus dem Zwischenspeicher bzw. dem
  /// letzten Download). Gleicher Inhalt → kein neuer Zustand.
  String? _hash;

  /// Kurz-Programm höchstens so oft veröffentlichen (statt nach jedem
  /// 4er-Block): jede Veröffentlichung baut Listen/Guide neu auf.
  static Duration shortPublishEvery = const Duration(seconds: 4);
  final _shortPending = <String>{};
  DateTime _shortPublished = DateTime(0);

  /// Veröffentlichungen in der laufenden Folge (siehe [shortGap]).
  int _shortSeq = 0;

  /// Abstand vor der [seq]-ten Veröffentlichung einer Folge: die erste
  /// sofort, dann ¼, ½ und ab da der volle [shortPublishEvery] – die ersten
  /// sichtbaren Zeilen bekommen ihr Programm schnell, langes Scrollen löst
  /// trotzdem keinen Neuaufbau-Sturm aus.
  @visibleForTesting
  static Duration shortGap(int seq) => switch (seq) {
        0 => Duration.zero,
        1 => shortPublishEvery ~/ 4,
        2 => shortPublishEvery ~/ 2,
        _ => shortPublishEvery,
      };
  Timer? _shortTimer;

  @override
  Future<Map<String, List<EpgEntry>>> build() async {
    final portal = await ref.watch(activePortalProvider.future);
    if (portal == null) return {};
    final st = await ref.watch(storageProvider.future);

    // Anderes Portal: Ein noch laufender Download gehört zum alten Portal –
    // sein Ergebnis darf nicht als Programm des neuen erscheinen.
    if (_portalId != portal.id) {
      _portalId = portal.id;
      _gen++;
      _busySince = null;
    }

    _timer?.cancel();
    _timer = Timer.periodic(const Duration(minutes: 15), (_) => checkDue());
    final lifecycle = AppLifecycleListener(onResume: checkDue);
    ref.onDispose(() {
      _timer?.cancel();
      _shortTimer?.cancel();
      lifecycle.dispose();
    });

    // Demo: Programm wird ohnehin lokal erzeugt.
    if (portal.type == PortalType.demo) {
      ref
          .read(epgStatusProvider.notifier)
          .set(EpgStatus(lastUpdate: DateTime.now()));
      final repo = await ref.read(repositoryProvider.future);
      return repo == null ? {} : _fetchSafe(repo);
    }

    final last = st.epgUpdated(portal.id);
    _shortDone.clear();
    _shortResults.clear();
    _shortPending.clear();
    _shortSeq = 0;
    _hash = null;
    // Läuft gerade ein Download, Anzeige „wird aktualisiert“ nicht überschreiben.
    if (!_busy) {
      ref.read(epgStatusProvider.notifier).set(EpgStatus(lastUpdate: last));
    }
    // Zwischenspeicher sofort – ohne auf Login/Server zu warten.
    // Stufe 1: nur „jetzt und demnächst“ (schnell), Stufe 2: ganzes Archiv.
    // Lesen und Dekodieren im Hintergrund; die Rohdaten bleiben dort.
    final near = await EpgCache.loadWindow(portal.id, near: true);
    if (near != null && near.isNotEmpty) {
      Future.microtask(() async {
        // Senderliste der Quellen (für die manuelle Zuordnung) aus dem Cache.
        if (ref.read(epgChannelNamesProvider).isEmpty) {
          final names = await EpgCache.loadNames(portal.id);
          if (names.isNotEmpty && _portalId == portal.id) {
            ref.read(epgChannelNamesProvider.notifier).set(names);
          }
        }
        final full = await EpgCache.loadWindow(portal.id);
        // Nur übernehmen, wenn nicht inzwischen frisch geladen wurde.
        if (full != null && identical(state.value, near)) {
          _hash = EpgCache.hashOf(full);
          state = AsyncData(full);
        }
        if (st.epgSchedule().isDue(last: last, now: DateTime.now()) &&
            !ref.read(dataSaverActiveProvider)) {
          await refresh();
        }
      });
      return near;
    }
    final repo = await ref.read(repositoryProvider.future);
    if (repo == null) return {};
    return await _download(repo, st) ?? {};
  }

  /// Prüft, ob laut Plan aktualisiert werden muss.
  Future<void> checkDue() async {
    final repo = ref.read(repositoryProvider).value;
    final st = ref.read(storageProvider).value;
    if (repo == null || st == null || repo.portal.type == PortalType.demo) {
      return;
    }
    // Datensparmodus: kein automatisches EPG-Update über Mobilfunk (von
    // Hand geht weiter).
    if (ref.read(dataSaverActiveProvider)) return;
    final last = st.epgUpdated(repo.portal.id);
    if (st.epgSchedule().isDue(last: last, now: DateTime.now())) {
      await refresh();
    }
  }

  /// Jetzt neu laden. Das bisherige Programm bleibt sichtbar, bis das neue da ist.
  /// [force]: laufenden Download verwerfen (z. B. neue EPG-Quellen gewählt).
  Future<void> refresh({bool force = false}) async {
    if (force) {
      _gen++;
      _busySince = null;
    }
    final repo = await ref.read(repositoryProvider.future);
    final st = await ref.read(storageProvider.future);
    if (repo == null) return;
    final fresh = await _download(repo, st);
    if (fresh != null) state = AsyncData(fresh);
  }

  /// Für Sender ohne Programm im großen EPG: Kurz-Programm direkt vom
  /// Portal holen (nur Xtream). Wird beim Anzeigen einer Zeile aufgerufen.
  void want(Channel c) {
    final key = epgKeyOf(c);
    final done = _shortDone[key];
    if (done != null && DateTime.now().difference(done).inMinutes < 30) return;
    if (_shortWanted.containsKey(key)) return;
    _shortWanted[key] = c;
    if (!_shortRunning) Future.microtask(_runShort);
  }

  Future<void> _runShort() async {
    if (_shortRunning) return;
    _shortRunning = true;
    try {
      final repo = await ref.read(repositoryProvider.future);
      if (repo == null || repo.portal.type != PortalType.xtream) {
        _shortWanted.clear();
        return;
      }
      while (_shortWanted.isNotEmpty) {
        final batch = _shortWanted.entries.take(4).toList();
        for (final e in batch) {
          _shortWanted.remove(e.key);
          _shortDone[e.key] = DateTime.now();
        }
        final lists = await Future.wait(batch.map((e) =>
            repo.shortEpg(e.value).catchError((_) => const <EpgEntry>[])));
        for (var i = 0; i < batch.length; i++) {
          if (lists[i].isEmpty) continue;
          _shortResults[batch[i].key] = lists[i];
          _shortPending.add(batch[i].key);
        }
        _publishShort();
      }
    } catch (_) {
      // Ersatz-Programm ist optional.
    } finally {
      _shortRunning = false;
      _publishShort();
    }
  }

  /// Gesammelte Kurz-Programme veröffentlichen – höchstens alle
  /// [shortPublishEvery]; sonst später per Timer. Nur Sender, die im
  /// angezeigten EPG noch nichts haben (gleiche Daten → kein neuer Zustand).
  void _publishShort() {
    if (_shortPending.isEmpty) return;
    final since = DateTime.now().difference(_shortPublished);
    // Länger Ruhe → neue Folge (wieder sofort veröffentlichen).
    if (since > shortPublishEvery * 2) _shortSeq = 0;
    final wait = shortGap(_shortSeq) - since;
    if (wait > Duration.zero) {
      _shortTimer ??= Timer(wait, () {
        _shortTimer = null;
        _publishShort();
      });
      return;
    }
    final cur = state.value;
    if (cur == null) return;
    final add = <String, List<EpgEntry>>{
      for (final k in _shortPending)
        if ((cur[k] ?? const []).isEmpty && _shortResults[k] != null)
          k: _shortResults[k]!,
    };
    _shortPending.clear();
    if (add.isEmpty) return;
    _shortPublished = DateTime.now();
    _shortSeq++;
    state = AsyncData({...cur, ...add});
  }

  Map<String, List<EpgEntry>> _withoutExisting(
          Map<String, List<EpgEntry>> cur) =>
      {
        for (final e in _shortResults.entries)
          if ((cur[e.key] ?? const []).isEmpty) e.key: e.value,
      };

  Future<Map<String, List<EpgEntry>>?> _download(
      IptvRepository repo, Storage st) async {
    if (_busy) return null;
    _busySince = DateTime.now();
    final gen = _gen;
    // Versuch merken: Wird die App vor dem Ende geschlossen, sieht der
    // nächste Start, dass das Laden abgebrochen wurde (→ Tipp Länder-EPG).
    final attemptKey = 'epgattempt_${repo.portal.id}';
    await st.setOption(
        attemptKey, '${(int.tryParse(st.option(attemptKey, '0')) ?? 0) + 1}');
    final status = ref.read(epgStatusProvider.notifier);
    final before = ref.read(epgStatusProvider);
    status.set(EpgStatus(updating: true, lastUpdate: before.lastUpdate));
    try {
      final live = await ref.read(liveDataProvider.future);
      // Ausgeblendete Gruppen brauchen kein Programm – spart bei großen
      // Playlisten (viele Länder) sehr viel Ladezeit.
      final hiddenGroups =
          (await ref.read(sortOrderProvider.future)).hiddenGroups;
      final visible = hiddenGroups.isEmpty
          ? live.channels
          : live.channels
              .where((c) => !hiddenGroups.contains(c.categoryId))
              .toList();
      final ids = {
        for (final c in visible)
          if (c.epgId != null && c.epgId!.isNotEmpty) c.epgId!,
      };
      var lastTick = DateTime(0);
      EpgChannelNames.reset();
      final epg = await repo.loadEpg(
          channelIds: ids.isEmpty ? null : ids,
          channels: visible,
          progress: (p) {
            if (gen != _gen) return; // veralteter Download
            // Höchstens 3× pro Sekunde neu zeichnen.
            final t = DateTime.now();
            if (!p.$5 && t.difference(lastTick).inMilliseconds < 300) return;
            lastTick = t;
            status.set(EpgStatus(
                updating: true, lastUpdate: before.lastUpdate, progress: p));
          });
      final now = DateTime.now();
      // Inzwischen neu gestartet (andere Quellen) → dieses Ergebnis verwerfen.
      if (gen != _gen) return null;
      final names = EpgChannelNames.snapshot();
      if (names.isNotEmpty) {
        ref.read(epgChannelNamesProvider.notifier).set(names);
      }
      // Gleicher Inhalt wie angezeigt (Prüfsumme der fertigen Cache-Bytes,
      // im EPG-Isolate berechnet) → nicht neu schreiben, nicht neu melden.
      final hash = EpgCache.hashOf(epg);
      final unchanged = hash != null && hash == _hash && state.hasValue;
      if (repo.portal.type != PortalType.demo) {
        await EpgCache.saveNames(repo.portal.id, names);
        if (!unchanged) await EpgCache.save(repo.portal.id, epg);
        await st.setEpgUpdated(repo.portal.id, now);
        await st.setOption(attemptKey, '0');
      }
      status.set(EpgStatus(
          lastUpdate: now,
          lastError: epg.isEmpty && repo.portal.type != PortalType.demo
              ? tr('EPG geladen, aber keinem Sender zugeordnet')
              : null));
      if (unchanged) return null;
      if (hash != null) _hash = hash;
      return {...epg, ..._withoutExisting(epg)};
    } catch (e) {
      if (gen != _gen) return null;
      status.set(EpgStatus(
          lastUpdate: before.lastUpdate, lastError: Redactor.friendly(e)));
      return null; // EPG ist optional – altes Programm bleibt
    } finally {
      if (gen == _gen) _busySince = null;
    }
  }

  Future<Map<String, List<EpgEntry>>> _fetchSafe(IptvRepository repo) async {
    try {
      return await repo.loadEpg();
    } catch (_) {
      return {};
    }
  }
}

final epgProvider =
    AsyncNotifierProvider<EpgNotifier, Map<String, List<EpgEntry>>>(
        EpgNotifier.new);

/// Aktuelle Sendung eines Kanals (oder null).
EpgEntry? nowPlaying(Map<String, List<EpgEntry>> epg, Channel c,
    [DateTime? at]) {
  final list = epg[epgKeyOf(c)];
  if (list == null || list.isEmpty) return null;
  final t = at ?? DateTime.now();
  // Binäre Suche: Liste ist nach Startzeit sortiert.
  var lo = 0, hi = list.length - 1, found = -1;
  while (lo <= hi) {
    final mid = (lo + hi) >> 1;
    if (!list[mid].start.isAfter(t)) {
      found = mid;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  if (found < 0) return null;
  final e = list[found];
  return e.isNowAt(t) ? e : null;
}

/// Sendung nach [current] (oder null).
EpgEntry? nextAfter(
    Map<String, List<EpgEntry>> epg, Channel c, EpgEntry? current) {
  final list = epg[epgKeyOf(c)];
  if (list == null || current == null) return null;
  final i = list.indexOf(current);
  return (i >= 0 && i + 1 < list.length) ? list[i + 1] : null;
}

// ---------- Filme & Serien ----------
class VodData {
  final List<Category> categories;
  final List<VodItem> items;
  const VodData(this.categories, this.items);
}

/// Filme bzw. Serien – wie die Senderliste: Zwischenspeicher zuerst.
class VodNotifier extends AsyncNotifier<VodData> {
  final bool series;
  VodNotifier(this.series);

  String get _kind => series ? 'series' : 'movies';

  /// Prüfsumme der angezeigten Liste (siehe [LiveNotifier]).
  String? _hash;
  VodData? _last;

  @override
  Future<VodData> build() async {
    final portal = await ref.watch(activePortalProvider.future);
    if (portal == null) return const VodData([], []);
    if (portal.type == PortalType.demo) {
      return await _fetch(null) ?? const VodData([], []);
    }
    if (portal.type == PortalType.m3u) return const VodData([], []);
    final cached = await ListCache.loadVod(_kind, portal);
    if (cached != null && cached.items.isNotEmpty) {
      _hash = cached.hash;
      // Gestaffelt und deutlich nach dem Start (Filme ~45 s, Serien ~60 s).
      final t = StartReload.schedule(
          series ? StartReload.seriesDelay : StartReload.moviesDelay,
          () => reload(silent: true));
      ref.onDispose(t.cancel);
      return _last = VodData(cached.categories, cached.items);
    }
    _hash = null;
    return _last = await _fetch(portal) ?? const VodData([], []);
  }

  /// null = unverändert gegenüber der angezeigten Liste.
  Future<VodData?> _fetch(Portal? saveFor) async {
    final repo = await ref.read(repositoryProvider.future);
    if (repo == null || !repo.supportsVod) return const VodData([], []);
    final spec = saveFor == null
        ? null
        : await ListCache.spec(_kind, saveFor, prevHash: _hash);
    final out = await repo.vodBundle(series, spec);
    if (out.unchanged) return null;
    if (out.hash.isNotEmpty) _hash = out.hash;
    return VodData(out.categories, out.items);
  }

  Future<void> reload({bool silent = false}) async {
    final portal = ref.read(activePortalProvider).value;
    if (portal == null) return;
    try {
      final d = await _fetch(portal.type == PortalType.demo ? null : portal);
      if (d == null) {
        // Fehler vom letzten Versuch → wieder die (unveränderte) Liste.
        final last = _last;
        if (state.hasError && last != null) state = AsyncData(last);
        return;
      }
      state = AsyncData(_last = d);
    } catch (e, st) {
      if (!silent) state = AsyncError(e, st);
    }
  }
}

final moviesProvider =
    AsyncNotifierProvider<VodNotifier, VodData>(() => VodNotifier(false));
final seriesProvider =
    AsyncNotifierProvider<VodNotifier, VodData>(() => VodNotifier(true));

final seriesDetailsProvider =
    FutureProvider.family<SeriesDetails, VodItem>((ref, s) async {
  // Emby-Serien kommen vom Emby-Server, nicht vom Portal.
  if (s.isEmby) return ref.watch(embySeriesDetailsProvider(s).future);
  final repo = await ref.watch(repositoryProvider.future);
  if (repo == null) return SeriesDetails(series: s, seasons: const {});
  final d = await repo.seriesDetails(s);
  // Besetzung für die Personensuche merken (Listen haben sie oft nicht).
  ref.read(peopleCacheProvider.notifier).remember(
      d.series.cast == null && d.cast != null
          ? d.series.copyWith(cast: d.cast)
          : d.series);
  return d;
});

final movieDetailsProvider =
    FutureProvider.family<VodItem, VodItem>((ref, m) async {
  if (m.isEmby) {
    try {
      return await ref.watch(embyMovieDetailsProvider(m).future);
    } catch (_) {
      return m;
    }
  }
  final repo = await ref.watch(repositoryProvider.future);
  if (repo == null) return m;
  try {
    final d = await repo.movieDetails(m);
    ref.read(peopleCacheProvider.notifier).remember(d);
    return d;
  } catch (_) {
    return m;
  }
});

/// EPG eines Senders inkl. Vergangenheit (für Catch-up).
final channelEpgProvider =
    FutureProvider.family<List<EpgEntry>, Channel>((ref, c) async {
  final repo = await ref.watch(repositoryProvider.future);
  final full = await ref.watch(epgProvider.future);
  if (repo == null) return const [];
  return repo.channelEpg(c, full);
});

/// Minütlicher Takt, damit „Jetzt läuft“ und Fortschrittsbalken aktuell bleiben.
final minuteTickProvider = StreamProvider<DateTime>((ref) =>
    Stream.periodic(const Duration(seconds: 30), (_) => DateTime.now()));

// ---------- Favoriten / Verstecken / Sperren ----------
class ChannelFlags {
  final Set<String> favorites, hidden, locked;

  /// Zuletzt „an diesem Standort nicht verfügbar“ (403/451).
  final Set<String> unavailable;

  /// Nicht verfügbare Sender aus den Listen ausblenden.
  final bool hideUnavailable;

  const ChannelFlags(this.favorites, this.hidden, this.locked,
      [this.unavailable = const {}, this.hideUnavailable = false]);
  static const empty = ChannelFlags({}, {}, {});

  /// Sender, die in Listen nicht erscheinen sollen.
  bool isHidden(String id) =>
      hidden.contains(id) || (hideUnavailable && unavailable.contains(id));
}

class ChannelFlagsNotifier extends AsyncNotifier<ChannelFlags> {
  @override
  Future<ChannelFlags> build() async {
    final s = await ref.watch(storageProvider.future);
    final p = await ref.watch(activePortalProvider.future);
    ref.watch(guestModeProvider);
    if (p == null) return ChannelFlags.empty;
    return _read(s, p);
  }

  /// Gastmodus: Favoriten ausgeblendet (gesperrte/versteckte bleiben).
  ChannelFlags _read(Storage s, Portal p) {
    var favs = s.guestMode ? const <String>{} : s.favorites(p.id);
    // Demo: ein paar Favoriten vorbelegen, damit die Liste nicht leer ist.
    if (p.type == PortalType.demo && favs.isEmpty && !s.guestMode) {
      favs = {'demo_0', 'demo_6', 'demo_11', 'demo_16'};
    }
    return ChannelFlags(favs, s.hidden(p.id), s.locked(p.id),
        s.unavailable(p.id), s.flag('hideunavail'));
  }

  Future<void> _apply(
      Future<void> Function(Storage s, String portalId) f) async {
    final s = await ref.read(storageProvider.future);
    final p = await ref.read(activePortalProvider.future);
    if (p == null) return;
    await f(s, p.id);
    state = AsyncData(_read(s, p));
  }

  /// Im Gastmodus wirkungslos (Favoriten unveränderbar).
  Future<void> toggleFavorite(String id) =>
      _apply((s, p) => s.toggleFavorite(p, id));
  Future<void> toggleHidden(String id) =>
      _apply((s, p) => s.toggleHidden(p, id));
  Future<void> toggleLocked(String id) =>
      _apply((s, p) => s.toggleLocked(p, id));
  Future<void> setUnavailable(String id, bool on) =>
      _apply((s, p) => s.markUnavailable(p, id, on: on));
  Future<void> refresh() => _apply((s, p) async {});
}

final channelFlagsProvider =
    AsyncNotifierProvider<ChannelFlagsNotifier, ChannelFlags>(
        ChannelFlagsNotifier.new);

// ---------- Zuletzt gesehen ----------
/// IDs der zuletzt gesehenen Sender des aktiven Portals (neueste zuerst).
class RecentNotifier extends AsyncNotifier<List<String>> {
  @override
  Future<List<String>> build() async {
    final s = await ref.watch(storageProvider.future);
    final p = await ref.watch(activePortalProvider.future);
    // Gastmodus: Verlauf ausblenden.
    if (ref.watch(guestModeProvider)) return const [];
    return p == null ? const [] : s.recent(p.id);
  }

  /// Im Gastmodus wirkungslos (nichts wird gespeichert).
  Future<void> push(String channelId) async {
    final s = await ref.read(storageProvider.future);
    final p = await ref.read(activePortalProvider.future);
    if (p == null || s.guestMode) return;
    if (state.value?.firstOrNull == channelId) return;
    await s.pushRecent(p.id, channelId);
    state = AsyncData(s.recent(p.id));
  }

  Future<void> clear() async {
    final s = await ref.read(storageProvider.future);
    final p = await ref.read(activePortalProvider.future);
    if (p == null || s.guestMode) return;
    await s.clearRecent(p.id);
    state = const AsyncData([]);
  }

  /// Einen Sender aus dem Verlauf entfernen.
  Future<void> remove(String channelId) async {
    final s = await ref.read(storageProvider.future);
    final p = await ref.read(activePortalProvider.future);
    if (p == null || s.guestMode) return;
    await s.removeRecent(p.id, channelId);
    state = AsyncData(s.recent(p.id));
  }
}

final recentProvider =
    AsyncNotifierProvider<RecentNotifier, List<String>>(RecentNotifier.new);

// ---------- Eigene Reihenfolge ----------
/// Gespeicherte Reihenfolge von Gruppen und Sendern (pro Portal).
class SortOrder {
  final List<String> groups;
  final Map<String, List<String>> channels;
  final Set<String> hiddenGroups;
  const SortOrder(this.groups, this.channels, this.hiddenGroups);
  static const empty = SortOrder([], {}, {});

  /// [items] nach [order] sortieren; Unbekannte behalten ihre Reihenfolge
  /// und kommen ans Ende.
  static List<T> apply<T>(
      List<T> items, List<String> order, String Function(T) id) {
    if (order.isEmpty) return items;
    final pos = {for (var i = 0; i < order.length; i++) order[i]: i};
    final indexed = [for (var i = 0; i < items.length; i++) (i, items[i])];
    indexed.sort((a, b) {
      final pa = pos[id(a.$2)], pb = pos[id(b.$2)];
      if (pa != null && pb != null) return pa.compareTo(pb);
      if (pa != null) return -1;
      if (pb != null) return 1;
      return a.$1.compareTo(b.$1);
    });
    return [for (final x in indexed) x.$2];
  }

  List<Category> sortGroups(List<Category> cats) =>
      apply(cats, groups, (c) => c.id);
  List<Channel> sortChannels(String groupId, List<Channel> list) =>
      apply(list, channels[groupId] ?? const [], (c) => c.id);
}

class SortOrderNotifier extends AsyncNotifier<SortOrder> {
  @override
  Future<SortOrder> build() async {
    final st = await ref.watch(storageProvider.future);
    final p = await ref.watch(activePortalProvider.future);
    if (p == null) return SortOrder.empty;
    final live = await ref.watch(liveDataProvider.future);
    return SortOrder(
      st.groupOrder(p.id),
      {
        for (final g in [...live.categories.map((c) => c.id), '__fav', '__all'])
          if (st.channelOrder(p.id, g).isNotEmpty) g: st.channelOrder(p.id, g),
      },
      st.hiddenGroups(p.id),
    );
  }

  Future<void> setGroups(List<String> ids) async {
    final st = await ref.read(storageProvider.future);
    final p = ref.read(activePortalProvider).value;
    if (p == null) return;
    await st.setGroupOrder(p.id, ids);
    ref.invalidateSelf();
  }

  Future<void> setChannels(String groupId, List<String> ids) async {
    final st = await ref.read(storageProvider.future);
    final p = ref.read(activePortalProvider).value;
    if (p == null) return;
    await st.setChannelOrder(p.id, groupId, ids);
    ref.invalidateSelf();
  }

  Future<void> setHiddenGroups(Set<String> ids) async {
    final st = await ref.read(storageProvider.future);
    final p = ref.read(activePortalProvider).value;
    if (p == null) return;
    await st.setHiddenGroups(p.id, ids);
    ref.invalidateSelf();
  }

  Future<void> reset() async {
    final st = await ref.read(storageProvider.future);
    final p = ref.read(activePortalProvider).value;
    if (p == null) return;
    await st.resetOrder(p.id);
    ref.invalidateSelf();
  }
}

final sortOrderProvider =
    AsyncNotifierProvider<SortOrderNotifier, SortOrder>(SortOrderNotifier.new);
