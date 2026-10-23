import 'dart:async';

import 'package:crypto/crypto.dart' show sha1;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import 'dart:convert' show jsonEncode, utf8;

import '../core/updater.dart';
import '../data/emby/emby_client.dart';
import '../data/emby/emby_mapper.dart';
import '../data/emby/emby_playback.dart';
import '../data/list_cache.dart';
import '../data/storage.dart';
import '../models/models.dart';
import 'list_refresh.dart' show StartReload;
import 'profile_mode.dart';
import 'providers.dart';

/// Emby-/Jellyfin-Server als zusätzliche Quelle für Filme und Serien –
/// einmal eingerichtet, unabhängig vom aktiven IPTV-Portal (ein
/// Portalwechsel ändert hier nichts).

// ---------------------------------------------------------------- Zugang

/// Nur für Tests: eigener HTTP-Client (null = Standard).
final embyHttpClientProvider = Provider<http.Client?>((_) => null);

/// So meldet sich die App beim Server (Gerätename, feste Kennung, Version).
final embyDeviceProvider = FutureProvider<EmbyDevice>((ref) async {
  // Nur lesen: ein Neuladen des Speichers (nach jeder Wiedergabe) soll
  // keinen neuen Client und damit kein Neuladen der Listen auslösen.
  final st = await ref.read(storageProvider.future);
  final id = await st.embyDeviceId();
  // Gerätename/Version sind Beiwerk – nie lange darauf warten.
  const wait = Duration(seconds: 2);
  final model = await Updater.deviceModel().timeout(wait, onTimeout: () => '');
  final version =
      await Updater.currentVersion().timeout(wait, onTimeout: () => '');
  return EmbyDevice(
      name: model.isEmpty ? 'Android' : model, id: id, version: version);
});

class EmbyAccountNotifier extends Notifier<EmbyAccount?> {
  @override
  EmbyAccount? build() => ref.watch(storageProvider).value?.embyAccount();

  /// Gleicher Inhalt (z. B. Speicher neu geladen) → nichts neu aufbauen.
  @override
  bool updateShouldNotify(EmbyAccount? previous, EmbyAccount? next) =>
      jsonEncode(previous?.toJson()) != jsonEncode(next?.toJson());

  Future<EmbyClient> _client(String server, {EmbyAccount? acc}) async {
    final norm = EmbyClient.normalizeServer(server);
    if (norm == null) throw const EmbyException(EmbyErrorKind.badAddress);
    final dev = await ref.read(embyDeviceProvider.future);
    return EmbyClient(norm,
        device: dev,
        token: acc?.token,
        userId: acc?.userId,
        client: ref.read(embyHttpClientProvider));
  }

  /// „Verbindung testen“: Server erreichbar? Mit Benutzer/Passwort wird
  /// auch die Anmeldung geprüft (ohne zu speichern).
  Future<EmbyAccount> test(String server,
      {String? user, String? password}) async {
    final c = await _client(server);
    if (user != null && user.trim().isNotEmpty) {
      final acc = await c.authenticate(user.trim(), password ?? '');
      // Prüf-Token gleich wieder abmelden.
      unawaited(EmbyClient.forAccount(acc,
              device: c.device, client: ref.read(embyHttpClientProvider))
          .logout());
      return acc;
    }
    final info = await c.publicInfo();
    return EmbyAccount(
      server: c.base,
      userName: '',
      serverName: info['ServerName'] as String?,
      serverVersion: info['Version'] as String?,
      serverId: info['Id'] as String?,
      jellyfin: '${info['ProductName'] ?? ''}'.toLowerCase().contains('jellyfin'),
    );
  }

  /// Anmelden und verschlüsselt speichern.
  Future<EmbyAccount> signIn(String server, String user, String password) async {
    final c = await _client(server);
    final acc = await c.authenticate(user.trim(), password);
    final st = await ref.read(storageProvider.future);
    await st.setEmbyAccount(acc);
    state = acc;
    return acc;
  }

  /// Abmelden: Token beim Server ungültig machen; Adresse und Benutzer
  /// bleiben zum erneuten Anmelden stehen.
  Future<void> signOut() async {
    final acc = state;
    if (acc == null) return;
    if (acc.signedIn) {
      try {
        await (await _client(acc.server, acc: acc)).logout();
      } catch (_) {}
    }
    final st = await ref.read(storageProvider.future);
    final out = acc.signedOut();
    await st.setEmbyAccount(out);
    state = out;
  }

  /// Emby ganz entfernen.
  Future<void> forget() async {
    await signOut();
    final st = await ref.read(storageProvider.future);
    await st.setEmbyAccount(null);
    state = null;
  }
}

final embyAccountProvider =
    NotifierProvider<EmbyAccountNotifier, EmbyAccount?>(EmbyAccountNotifier.new);

/// Angemeldet? (Filme/Serien zeigen dann den Quellen-Umschalter.)
final embySignedInProvider =
    Provider<bool>((ref) => ref.watch(embyAccountProvider)?.signedIn ?? false);

final embyClientProvider = FutureProvider<EmbyClient?>((ref) async {
  final acc = ref.watch(embyAccountProvider);
  if (acc == null || !acc.signedIn) return null;
  final dev = await ref.watch(embyDeviceProvider.future);
  return EmbyClient.forAccount(acc,
      device: dev, client: ref.watch(embyHttpClientProvider));
});

/// Pseudo-Portal für den Listen-Zwischenspeicher: eigene Datei je Server
/// und Benutzer; die Listen enthalten keine Zugangsdaten (Bilder ohne
/// Token, Abspieladressen entstehen erst beim Abspielen).
Portal embyCachePortal(EmbyAccount a) {
  final h = sha1
      .convert(utf8.encode('${a.server}|${a.userId ?? a.userName}'))
      .toString()
      .substring(0, 12);
  return Portal(
      id: 'emby_$h', name: 'Emby', type: PortalType.m3u, url: a.server);
}

// ---------------------------------------------------------------- Listen

/// Emby-Filme bzw. -Serien: alle Mediatheken des Typs (movies/tvshows,
/// gemischte nur, wenn sie solche Titel enthalten), je Mediathek eine
/// Kategorie. Wie die Portal-Listen: Zwischenspeicher zuerst, dann still
/// nachladen.
class EmbyVodNotifier extends AsyncNotifier<VodData> {
  final bool series;
  EmbyVodNotifier(this.series);

  String get _kind => series ? 'embyseries' : 'embymovies';
  String? _hash;
  VodData? _last;

  @override
  Future<VodData> build() async {
    final acc = ref.watch(embyAccountProvider);
    final client = await ref.watch(embyClientProvider.future);
    if (client == null || acc == null) return const VodData([], []);
    final portal = embyCachePortal(acc);
    final cached = await ListCache.loadVod(_kind, portal);
    if (cached != null && cached.items.isNotEmpty) {
      _hash = cached.hash;
      final t = StartReload.schedule(
          series ? StartReload.seriesDelay : StartReload.moviesDelay,
          () => reload(silent: true));
      ref.onDispose(t.cancel);
      return _last = VodData(cached.categories, cached.items);
    }
    _hash = null;
    return _last = await _fetch(client, portal) ?? const VodData([], []);
  }

  /// null = unverändert.
  Future<VodData?> _fetch(EmbyClient c, Portal cachePortal) async {
    final data = await fetchEmbyVod(c, series: series);
    CacheSpec? spec;
    try {
      spec = await ListCache.spec(_kind, cachePortal, prevHash: _hash);
    } catch (_) {
      spec = null;
    }
    final out = await ListCache.storeVod(spec, data.categories, data.items);
    if (out.unchanged) return null;
    if (out.hash.isNotEmpty) _hash = out.hash;
    return VodData(out.categories, out.items);
  }

  Future<void> reload({bool silent = false}) async {
    final acc = ref.read(embyAccountProvider);
    final c = await ref.read(embyClientProvider.future);
    if (c == null || acc == null) return;
    try {
      final d = await _fetch(c, embyCachePortal(acc));
      if (d == null) {
        final last = _last;
        if (state.hasError && last != null) state = AsyncData(last);
        return;
      }
      state = AsyncData(_last = d);
    } catch (e, st) {
      if (!silent) state = AsyncError(e, st);
    }
  }

  /// Einen Titel im angezeigten Stand ersetzen (z. B. nach „gesehen“).
  void patch(VodItem item) {
    final cur = state.value;
    if (cur == null) return;
    var hit = false;
    final items = [
      for (final m in cur.items)
        if (m.id == item.id) (hit = true, item).$2 else m,
    ];
    if (hit) state = AsyncData(_last = VodData(cur.categories, items));
  }
}

/// Mediatheken und Titel vom Server holen (ohne Zwischenspeicher).
Future<VodData> fetchEmbyVod(EmbyClient c, {required bool series}) async {
  final views = await c.views();
  final map = EmbyMapper(c);
  final cats = <Category>[];
  final items = <VodItem>[];
  final seen = <String>{};
  for (final v in views) {
    final fits = series ? v.tvshows : v.movies;
    if (!fits && !v.mixed) continue;
    final raw = await c.allItems(v.id, series ? 'Series' : 'Movie');
    final cat = embyCategoryId(v.id);
    var n = 0;
    for (final j in raw) {
      if (j['Id'] is! String) continue;
      final m = map.item(j, categoryId: cat);
      // Derselbe Titel in zwei Mediatheken → nur einmal.
      if (!seen.add(m.id)) continue;
      items.add(m);
      n++;
    }
    if (n > 0 || fits) cats.add(Category(id: cat, name: v.name));
  }
  return VodData(cats, items);
}

final embyMoviesProvider = AsyncNotifierProvider<EmbyVodNotifier, VodData>(
    () => EmbyVodNotifier(false));
final embySeriesProvider = AsyncNotifierProvider<EmbyVodNotifier, VodData>(
    () => EmbyVodNotifier(true));

AsyncValue<VodData> _visibleEmby(Ref ref, bool series) {
  final raw = ref.watch(series ? embySeriesProvider : embyMoviesProvider);
  final m = ref.watch(profileModeProvider);
  if (!m.kids) return raw;
  return raw.whenData((d) => KidsFilter.vod(d, series, m.kidsEmby));
}

/// Emby-Listen, wie sie angezeigt werden (Kindermodus: nur freigegebene
/// Mediatheken).
final visibleEmbyMoviesProvider =
    Provider<AsyncValue<VodData>>((ref) => _visibleEmby(ref, false));
final visibleEmbySeriesProvider =
    Provider<AsyncValue<VodData>>((ref) => _visibleEmby(ref, true));

// ---------------------------------------------------------------- Quelle

/// Gewählte Quelle in „Filme“ bzw. „Serien“: false = Portal, true = Emby.
class VodSourceNotifier extends Notifier<bool> {
  final bool series;
  VodSourceNotifier(this.series);
  String get _key => series ? 'vodsrc_s' : 'vodsrc_m';

  @override
  bool build() {
    if (!ref.watch(embySignedInProvider)) return false;
    return ref.watch(storageProvider).value?.option(_key, 'portal') == 'emby';
  }

  Future<void> set(bool emby) async {
    state = emby && ref.read(embySignedInProvider);
    final st = await ref.read(storageProvider.future);
    await st.setOption(_key, emby ? 'emby' : 'portal');
  }
}

final movieSourceProvider =
    NotifierProvider<VodSourceNotifier, bool>(() => VodSourceNotifier(false));
final seriesSourceProvider =
    NotifierProvider<VodSourceNotifier, bool>(() => VodSourceNotifier(true));

NotifierProvider<VodSourceNotifier, bool> vodSourceProvider(bool series) =>
    series ? seriesSourceProvider : movieSourceProvider;

// ---------------------------------------------------------------- Details

/// Server-Stand (Position, gesehen) eines Titels lokal übernehmen – damit
/// Fortschrittsbalken und „Fortsetzen“ zeigen, was auf anderen Geräten
/// geschaut wurde. Der Server gilt (beim Öffnen der Details) als maßgeblich.
/// Im Gastmodus wirkungslos.
Future<void> syncEmbyState(Storage st, String key,
    {Duration? position, required bool played, Duration? total}) async {
  if (st.guestMode) return;
  if (played) {
    if (!st.isWatched(key)) await st.setWatched(key);
    return;
  }
  if (st.isWatched(key)) await st.clearWatched(key);
  final pos = position?.inSeconds ?? 0;
  if (pos < 15) return;
  final cur = st.resume(key);
  if (cur != null && (cur.pos - pos).abs() < 15) return;
  final t = total?.inSeconds ?? cur?.total ?? 0;
  await st.setResume(key, pos, t > pos ? t : pos + 1);
}

String _movieKey(VodItem m) => 'movie_${m.id}';
String _seriesKey(VodItem m) => 'series_${m.id}';
String _epKey(Episode e) => 'ep_${e.id}';

final embyMovieDetailsProvider =
    FutureProvider.family<VodItem, VodItem>((ref, m) async {
  final c = await ref.watch(embyClientProvider.future);
  if (c == null) return m;
  final j = await c.item(embyRaw(m.id));
  final d = EmbyMapper(c).item(j, categoryId: m.categoryId);
  final st = await ref.read(storageProvider.future);
  await syncEmbyState(st, _movieKey(d),
      position: d.serverPosition, played: d.serverPlayed, total: d.duration);
  return d;
});

final embySeriesDetailsProvider =
    FutureProvider.family<SeriesDetails, VodItem>((ref, s) async {
  final c = await ref.watch(embyClientProvider.future);
  if (c == null) return SeriesDetails(series: s, seasons: const {});
  final raw = embyRaw(s.id);
  final map = EmbyMapper(c);
  final seasons = await c.seasons(raw);
  final lists = await Future.wait([
    for (final se in seasons)
      if (se['Id'] is String)
        c.episodes(raw, seasonId: se['Id'] as String).then((eps) => [
              for (final e in eps)
                if (e['Id'] is String)
                  map.episode(e,
                      seasonFallback: se['IndexNumber'] is int
                          ? se['IndexNumber'] as int
                          : null),
            ]),
  ]);
  final out = <int, List<Episode>>{};
  for (final l in lists) {
    for (final e in l) {
      (out[e.season] ??= []).add(e);
    }
  }
  for (final l in out.values) {
    l.sort((a, b) => a.number.compareTo(b.number));
  }
  final sorted = {
    for (final k in (out.keys.toList()..sort())) k: out[k]!,
  };
  // Serie selbst (Besetzung, Bewertung) frisch vom Server.
  VodItem series = s;
  try {
    series = map.item(await c.item(raw), categoryId: s.categoryId);
  } catch (_) {}
  final st = await ref.read(storageProvider.future);
  for (final l in sorted.values) {
    for (final e in l) {
      await syncEmbyState(st, _epKey(e),
          position: e.serverPosition, played: e.serverPlayed, total: e.duration);
    }
  }
  await syncEmbyState(st, _seriesKey(series), played: series.serverPlayed);
  return SeriesDetails(series: series, seasons: sorted, cast: series.cast);
});

// ---------------------------------------------------------------- Startseite

/// Emby-Titel auf die sichtbaren (Kindermodus) beschränken – über die IDs
/// der geladenen Listen.
List<VodItem> _onlyVisible(Ref ref, List<VodItem> items) {
  if (!ref.watch(kidsModeProvider)) return items;
  final movies = ref.watch(visibleEmbyMoviesProvider).value?.items ?? const [];
  final series = ref.watch(visibleEmbySeriesProvider).value?.items ?? const [];
  final ok = {for (final m in movies) m.id, for (final s in series) s.id};
  return [for (final m in items) if (ok.contains(m.id)) m];
}

/// „Emby: Weiterschauen“ (Server-Liste; Folgen erscheinen als ihre Serie).
/// Gastmodus: leer.
final embyResumeProvider = FutureProvider<List<VodItem>>((ref) async {
  if (ref.watch(guestModeProvider)) return const [];
  final c = await ref.watch(embyClientProvider.future);
  if (c == null) return const [];
  final map = EmbyMapper(c);
  final out = <VodItem>[];
  final seen = <String>{};
  try {
    for (final j in await c.resume(limit: 24)) {
      if (j['Id'] is! String) continue;
      final VodItem m;
      if (j['Type'] == 'Episode' && j['SeriesId'] is String) {
        m = map.seriesOfEpisode(j);
      } else if (j['Type'] == 'Movie') {
        m = map.item(j, categoryId: '');
      } else {
        continue;
      }
      if (seen.add(m.id)) out.add(m);
    }
  } catch (_) {
    return const [];
  }
  return _onlyVisible(ref, out);
});

/// „Emby: Neu hinzugefügt“.
final embyLatestProvider = FutureProvider<List<VodItem>>((ref) async {
  final c = await ref.watch(embyClientProvider.future);
  if (c == null) return const [];
  final map = EmbyMapper(c);
  try {
    final out = [
      for (final j in await c.latest(limit: 24))
        if (j['Id'] is String &&
            (j['Type'] == 'Movie' || j['Type'] == 'Series'))
          map.item(j, categoryId: ''),
    ];
    return _onlyVisible(ref, out);
  } catch (_) {
    return const [];
  }
});

/// Titel aus Startseiten-Reihen gehören zu einer Mediathek – für die
/// Detailseite die Version aus der Liste nehmen, wenn vorhanden.
VodItem embyListVersion(Ref ref, VodItem m) {
  final list = ref
      .read(m.isSeries ? embySeriesProvider : embyMoviesProvider)
      .value
      ?.items;
  if (list == null) return m;
  for (final x in list) {
    if (x.id == m.id) return x;
  }
  return m;
}

// ---------------------------------------------------------------- Aktionen

/// „Als gesehen markieren“ (bzw. ungesehen) – auf dem Server und lokal.
Future<void> setEmbyPlayed(ProviderContainer c, VodItem item, bool played,
    {List<Episode> episodes = const []}) async {
  final client = await c.read(embyClientProvider.future);
  if (client == null) return;
  await client.setPlayed(embyRaw(item.id), played);
  final st = await c.read(storageProvider.future);
  final key = item.isSeries ? _seriesKey(item) : _movieKey(item);
  if (played) {
    await st.setWatched(key);
  } else {
    await st.clearWatched(key);
  }
  for (final e in episodes) {
    if (played) {
      await st.setWatched(_epKey(e));
    } else {
      await st.clearWatched(_epKey(e));
    }
  }
  final patched = item.withServerState(
      position: played ? Duration.zero : item.serverPosition, played: played);
  c.read((item.isSeries ? embySeriesProvider : embyMoviesProvider).notifier)
      .patch(patched);
  c.invalidate(embyResumeProvider);
  if (item.isSeries) {
    c.invalidate(embySeriesDetailsProvider);
  } else {
    c.invalidate(embyMovieDetailsProvider);
  }
}

/// Wiedergabe-Steuerung für einen Emby-Film bzw. eine Folge.
EmbyPlayback embyPlaybackFor(ProviderContainer c, String itemId,
        {Duration? serverPosition}) =>
    EmbyPlayback(
      itemId: itemId,
      client: () => c.read(embyClientProvider.future),
      maxBitrate: () => embyBitrateOf(
          c.read(storageProvider).value?.option('embybitrate', 'auto') ??
              'auto'),
      audioPref: () =>
          c.read(storageProvider).value?.option('alang', 'auto') ?? 'auto',
      reportAllowed: () => !(c.read(storageProvider).value?.guestMode ?? true),
      serverPosition: serverPosition,
      onStopped: () {
        c.invalidate(embyResumeProvider);
      },
    );
