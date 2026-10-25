import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;
import 'package:http/http.dart' as http;
import 'package:jsp_exoplayer/jsp_cast.dart' show JspNetState;

import '../data/content_filters.dart' show AdultDetector;
import '../data/downloads/download_files_stub.dart'
    if (dart.library.io) '../data/downloads/download_files_io.dart';
import '../data/downloads/download_models.dart';
import '../data/downloads/download_native.dart';
import '../data/downloads/download_queue.dart';
import '../data/downloads/download_rules.dart';
import '../data/downloads/download_transfer.dart';
import '../data/downloads/local_playback.dart';
import '../data/downloads/url_vault.dart';
import '../data/emby/emby_client.dart';
import '../data/emby/emby_mapper.dart' show embyRaw;
import '../data/host_failover.dart';
import '../data/recordings/recordings.dart';
import '../data/smb/smb.dart';
import '../data/storage.dart';
import '../l10n/strings.dart';
import '../models/models.dart';
import '../player/data_saver.dart';
import '../ui/player/stream_open_headers.dart' show playerHeadersFor;
import 'content_filter.dart' show adultLockActiveProvider;
import 'emby.dart';
import 'profile_mode.dart';
import 'providers.dart';

export '../data/downloads/download_models.dart';

/// Einstellungen der Downloads.
abstract final class DownloadSettings {
  /// „Downloads auch über Mobilfunk“ (Standard aus = nur WLAN).
  static const mobileKey = 'dlmobile';

  /// Gleichzeitige Downloads: '1' oder '2'.
  static const parallelKey = 'dlparallel';

  /// „Eine Verbindung für Live frei halten“ (Aufnahmen und Downloads).
  static const keepFreeKey = 'reckeepfree';
}

/// Belegte Anbieter-Verbindungen durch laufende Aufnahmen (aktives Portal).
int runningRecordings(List<Recording> recs, DateTime now) => recs
    .where((r) =>
        r.status == 'läuft' ||
        (r.status == 'geplant' && !now.isBefore(r.start) && now.isBefore(r.end)))
    .length;

/// Vom Anbieter gemeldete Verbindungen (nur Xtream meldet sie), null =
/// unbekannt.
int? reportedMaxConnections(Portal? portal, AccountInfo? account) {
  if (portal == null || account == null) return null;
  if (portal.type != PortalType.xtream && portal.type != PortalType.demo) {
    return null;
  }
  return account.maxConnections > 0 ? account.maxConnections : null;
}

/// Verbindungs-Limit des aktiven Portals.
final maxConnectionsProvider = Provider<int?>((ref) {
  final portal = ref.watch(activePortalProvider).value;
  final repo = ref.watch(repositoryProvider).value;
  return reportedMaxConnections(portal, repo?.account);
});

/// Die echte Umgebung der Warteschlange (Tests ersetzen sie).
final downloadHostProvider =
    Provider<DownloadHost>((ref) => AppDownloadHost(ref));

/// Alle Downloads (ungefiltert). Läuft im Hintergrund weiter, solange die
/// App-Engine lebt (Android-Vordergrunddienst hält sie wach).
class DownloadsNotifier extends Notifier<List<DownloadItem>> {
  late DownloadQueue _q;

  DownloadQueue get queue => _q;

  @override
  List<DownloadItem> build() {
    final host = ref.watch(downloadHostProvider);
    _q = DownloadQueue(host);
    void listener(List<DownloadItem> l) => state = l;
    _q.addListener(listener);
    StreamSubscription<String>? actions;
    if (DownloadNative.available) {
      actions = DownloadNative.actions.listen(_onAction);
    }
    // Netz, Datensparmodus, Einstellungen, Aufnahmen → Regeln neu prüfen.
    ref.listen(networkStateProvider, (_, __) => _envChanged());
    ref.listen(dataSaverActiveProvider, (_, __) => _envChanged());
    ref.listen(recordingsProvider, (_, __) => _envChanged());
    ref.listen(maxConnectionsProvider, (_, __) => _envChanged());
    ref.onDispose(() {
      actions?.cancel();
      _q.removeListener(listener);
      _q.dispose();
    });
    Future.microtask(_q.init);
    return const [];
  }

  void _envChanged() => unawaited(_q.envChanged());

  /// Einstellung geändert (Mobilfunk/Gleichzeitig/Verbindung frei).
  Future<void> settingsChanged() => _q.envChanged();

  void _onAction(String a) {
    switch (a) {
      case 'pause':
        unawaited(_q.pauseAll());
      case 'resume':
        unawaited(_q.resumeAll());
      case 'cancel':
        for (final id in [..._q.running]) {
          unawaited(_q.remove(id));
        }
    }
  }

  Future<int> add(List<DownloadItem> items) => _q.add(items);
  Future<void> pause(String id) => _q.pause(id);
  Future<void> resume(String id) => _q.resume(id);
  Future<void> remove(String id) => _q.remove(id);
  Future<void> pauseAll() => _q.pauseAll();
  Future<void> resumeAll() => _q.resumeAll();
}

final downloadsProvider =
    NotifierProvider<DownloadsNotifier, List<DownloadItem>>(
        DownloadsNotifier.new);

/// Downloads, die der aktuelle Modus zeigen darf (Kindermodus: nur
/// freigegebene Kategorien; Erwachsenen-Sperre: keine Erwachsenen-Titel).
final visibleDownloadsProvider = Provider<List<DownloadItem>>((ref) {
  final all = ref.watch(downloadsProvider);
  final mode = ref.watch(profileModeProvider);
  final adult = ref.watch(adultLockActiveProvider);
  final portal = ref.watch(activePortalProvider).value;
  return [
    for (final d in all)
      if (downloadVisible(d,
          adultLocked: adult,
          kids: mode.kids,
          portalId: portal?.id,
          kidsVod: mode.kidsVod,
          kidsEmby: mode.kidsEmby))
        d,
  ];
});

/// Download eines Films/einer Folge (oder null).
final downloadOfProvider = Provider.family<DownloadItem?, String>((ref, id) {
  for (final d in ref.watch(downloadsProvider)) {
    if (d.id == id) return d;
  }
  return null;
});

/// Lesen aus Ref, WidgetRef oder ProviderContainer (`ref.read`).
typedef Reader = T Function<T>(ProviderListenable<T> provider);

/// Bereich (Portal-ID bzw. Medienserver) eines Titels.
String downloadScopeOf(Reader read, VodItem item) => item.isEmby
    ? embyScope
    : (read(activePortalProvider).value?.id ?? '');

// ------------------------------------------------------------ Erstellen

/// Warum ein Titel nicht geladen werden kann.
class DownloadRefused implements Exception {
  final String message;
  const DownloadRefused(this.message);
  @override
  String toString() => message;
}

/// Erwachsenen-Kategorie? (Name der Kategorie des Titels.)
Future<bool> isAdultVod(Reader read, VodItem item) async {
  final p = item.isEmby
      ? (item.isSeries ? embySeriesProvider : embyMoviesProvider)
      : (item.isSeries ? seriesProvider : moviesProvider);
  VodData? data = read(p).value;
  if (data == null) {
    try {
      data = await read(p.future).timeout(const Duration(seconds: 5));
    } catch (_) {
      data = null;
    }
  }
  for (final c in data?.categories ?? const <Category>[]) {
    if (c.id == item.categoryId) return AdultDetector.isAdult(c.name);
  }
  return false;
}

/// Kann diese Quelle überhaupt laden? (Portal: direkte Datei, kein HLS.)
bool canDownloadUrl(String url) => isDownloadableUrl(url);

/// Download-Eintrag für einen Film.
Future<DownloadItem> movieDownload(Reader read, VodItem m) async {
  final scope = downloadScopeOf(read, m);
  final adult = await isAdultVod(read, m);
  if (m.isEmby) {
    return _embyItem(read,
        appId: m.id,
        title: m.name,
        poster: m.posterUrl,
        categoryId: m.categoryId,
        adult: adult,
        duration: m.duration);
  }
  final portal = read(activePortalProvider).value;
  if (portal == null || !canDownloadUrl(m.streamUrl)) {
    throw DownloadRefused(tr('Dieser Titel kann nicht heruntergeladen werden.'));
  }
  return DownloadItem(
    id: DownloadItem.idOf(scope, m.id),
    scope: scope,
    source: VodSource.portal,
    itemId: m.id,
    title: m.name,
    posterUrl: m.posterUrl ?? m.backdropUrl,
    categoryId: m.categoryId,
    adult: adult,
    maskedUrl: UrlVault.mask(m.streamUrl, portalSecrets(portal)),
    ext: extOfUrl(m.streamUrl) ?? 'mkv',
    added: DateTime.now(),
    duration: m.duration,
  );
}

/// Download-Einträge für Folgen einer Serie.
Future<List<DownloadItem>> episodeDownloads(
    Reader read, VodItem series, List<Episode> episodes) async {
  final scope = downloadScopeOf(read, series);
  final adult = await isAdultVod(read, series);
  final out = <DownloadItem>[];
  final portal = read(activePortalProvider).value;
  for (final e in episodes) {
    if (series.isEmby) {
      try {
        out.add(await _embyItem(read,
            appId: e.id,
            title: e.title,
            poster: e.stillUrl ?? series.posterUrl,
            categoryId: series.categoryId,
            adult: adult,
            duration: e.duration,
            series: series,
            episode: e));
      } on DownloadRefused {
        if (episodes.length == 1) rethrow;
      }
      continue;
    }
    if (portal == null || !canDownloadUrl(e.streamUrl)) continue;
    out.add(DownloadItem(
      id: DownloadItem.idOf(scope, e.id),
      scope: scope,
      source: VodSource.portal,
      itemId: e.id,
      isEpisode: true,
      seriesId: series.id,
      seriesName: series.name,
      season: e.season,
      episode: e.number,
      title: e.title,
      posterUrl: e.stillUrl ?? series.posterUrl,
      categoryId: series.categoryId,
      adult: adult,
      maskedUrl: UrlVault.mask(e.streamUrl, portalSecrets(portal)),
      ext: extOfUrl(e.streamUrl) ?? 'mkv',
      added: DateTime.now(),
      duration: e.duration,
    ));
  }
  return out;
}

/// Zugangsdaten eines Portals als Platzhalter-Werte.
Map<String, String> portalSecrets(Portal p) =>
    UrlVault.secretsOf(username: p.username, password: p.password);

Future<DownloadItem> _embyItem(
  Reader read, {
  required String appId,
  required String title,
  required String? poster,
  required String categoryId,
  required bool adult,
  Duration? duration,
  VodItem? series,
  Episode? episode,
}) async {
  final c = await read(embyClientProvider.future);
  final token = c?.token;
  if (c == null || token == null || token.isEmpty) {
    throw DownloadRefused(tr('Nicht beim Medienserver angemeldet.'));
  }
  final raw = embyRaw(appId);
  final info = await c.downloadInfo(raw);
  // Nur, wenn der Server dem Benutzer das Herunterladen erlaubt.
  if (info['CanDownload'] == false) {
    throw DownloadRefused(
        tr('Der Medienserver erlaubt das Herunterladen dieses Titels nicht.'));
  }
  final sources = info['MediaSources'];
  final src = sources is List && sources.isNotEmpty && sources.first is Map
      ? (sources.first as Map).cast<String, dynamic>()
      : const <String, dynamic>{};
  final container = (src['Container'] as String?)?.split(',').first.toLowerCase();
  final path = (src['Path'] ?? info['Path']) as String?;
  final ext = container ??
      (path == null ? null : extOfUrl(path)) ??
      'mkv';
  final size = src['Size'];
  final msid = (src['Id'] as String?) ?? raw;
  final secrets = UrlVault.secretsOf(token: token);
  final streams = (src['MediaStreams'] ?? info['MediaStreams']);
  final subs = <DownloadSub>[
    if (streams is List)
      for (final s in streams)
        if (s is Map &&
            s['Type'] == 'Subtitle' &&
            s['IsExternal'] == true &&
            s['Index'] is int)
          DownloadSub(
            maskedUrl: UrlVault.mask(
                c.subtitleUrl(raw, msid, s['Index'] as int), secrets),
            language: s['Language'] as String?,
            title: (s['DisplayTitle'] ?? s['Title']) as String?,
          ),
  ];
  return DownloadItem(
    id: DownloadItem.idOf(embyScope, appId),
    scope: embyScope,
    source: VodSource.emby,
    itemId: appId,
    isEpisode: episode != null,
    seriesId: series?.id,
    seriesName: series?.name,
    season: episode?.season ?? 0,
    episode: episode?.number ?? 0,
    title: title,
    posterUrl: poster,
    categoryId: categoryId,
    adult: adult,
    maskedUrl: UrlVault.mask(c.downloadUrl(raw), secrets),
    ext: downloadableExts.contains(ext) ? ext : 'mkv',
    total: size is num && size > 0 ? size.toInt() : -1,
    added: DateTime.now(),
    duration: duration,
    subs: subs,
  );
}

// ------------------------------------------------------------ Abspielen

/// Fertiger Download für einen Film/eine Folge mit vorhandener Datei.
Future<DownloadItem?> offlineCopy(Reader read, String scope, String id) async {
  final d = _find(read(downloadsProvider), DownloadItem.idOf(scope, id));
  if (d == null || d.state != DownloadState.done || d.path == null) return null;
  return await downloadFileExists(d) ? d : null;
}

DownloadItem? _find(List<DownloadItem> l, String id) {
  for (final d in l) {
    if (d.id == id) return d;
  }
  return null;
}

/// Nur für Tests: Prüfung „Datei vorhanden?“ ersetzen.
@visibleForTesting
Future<bool> Function(DownloadItem d)? debugDownloadExists;

Future<bool> downloadFileExists(DownloadItem d) async {
  final test = debugDownloadExists;
  if (test != null) return test(d);
  final p = d.path;
  if (p == null) return false;
  if (p.startsWith('content://')) return await DownloadNative.safSize(p) >= 0;
  if (p.startsWith('smb://')) {
    // Netzlaufwerk: nur, wenn erreichbar (sonst Stream statt Datei).
    final c = Smb.current;
    final rel = c?.relOf(p);
    if (c == null || rel == null) return false;
    try {
      return await Smb.size(c, rel) >= 0;
    } on SmbException {
      return false;
    }
  }
  return localFileExists(p);
}

/// Abspiel-Anfrage für einen heruntergeladenen Titel (gleicher
/// „Weiterschauen“-Schlüssel wie online).
PlayRequest offlineRequest(DownloadItem d, {Future<NextUp?> Function()? nextUp}) =>
    PlayRequest(
      title: d.isEpisode ? (d.seriesName ?? d.title) : d.title,
      subtitle: d.isEpisode
          ? trf('S{0} · F{1} – {2}', [d.season, d.episode, d.title])
          : tr('Offline'),
      url: LocalPlayback.uriOf(d.path ?? ''),
      resumeKey: d.resumeKey,
      artworkSeed: d.seriesName ?? d.title,
      artworkUrl: d.posterUrl,
      remote: LocalPlayback(d),
      nextUp: nextUp,
    );

// ------------------------------------------------------------ Umgebung

/// Echte Umgebung: Speicher, Zugangsdaten, Android-Dienst.
class AppDownloadHost extends DownloadHost {
  final Ref ref;
  AppDownloadHost(this.ref);

  final _client = http.Client();

  @override
  http.Client get httpClient => _client;

  @override
  Future<List<DownloadItem>> load() async {
    final raw = await readDownloadList();
    if (raw == null) return const [];
    final j = jsonDecode(raw);
    if (j is! Map || j['items'] is! List) return const [];
    return [
      for (final e in j['items'] as List)
        if (DownloadItem.fromJson(e) != null) DownloadItem.fromJson(e)!,
    ];
  }

  @override
  Future<void> save(List<DownloadItem> items) => writeDownloadList(jsonEncode({
        'v': 1,
        'items': [for (final d in items) d.toJson()],
      }));

  Future<Storage> get _st => ref.read(storageProvider.future);

  @override
  Future<ResolvedUrl?> resolve(DownloadItem d, String maskedUrl) async {
    final st = await _st;
    if (d.isEmby) {
      final acc = st.embyAccount();
      final u = UrlVault.unmask(maskedUrl, UrlVault.secretsOf(token: acc?.token));
      if (u == null) return null;
      return (url: u, headers: playerHeadersFor(null, null));
    }
    Portal? portal;
    for (final p in st.portals()) {
      if (p.id == d.scope) portal = p;
    }
    if (portal == null) return null;
    final u = UrlVault.unmask(maskedUrl, portalSecrets(portal));
    if (u == null) return null;
    return (
      url: HostFailover.rewrite(portal, u),
      headers: playerHeadersFor(portal, null)
    );
  }

  Future<String> _tree() async => (await _st).option(RecTree.optionKey, '');

  /// Netzlaufwerk als Speicherort gewählt → Zugang (sonst null).
  Future<SmbConfig?> _smb() async {
    final st = await _st;
    if (!RecTree.isSmb(st.option(RecTree.optionKey, ''))) return null;
    return st.smbConfig();
  }

  /// Zugang für einen NAS-Download – fehlt er, nicht still ausweichen.
  Future<(SmbConfig, String)> _smbOf(String uri) async {
    final c = (await _st).smbConfig();
    final rel = c?.relOf(uri);
    if (c == null || rel == null) throw const SmbException('path');
    return (c, rel);
  }

  @override
  Future<DownloadItem> prepare(DownloadItem d) async {
    final name = downloadFileName(d);
    final smb = await _smb();
    if (smb != null) {
      // Direkt aufs NAS (Unterordner „Downloads“); unerreichbar → Fehler
      // „nas:…“ beim Öffnen, kein Rückfall auf den App-Ordner.
      return d.copyWith(path: smb.uriFor('Downloads/$name'));
    }
    final tree = DownloadNative.available ? await _tree() : '';
    if (tree.isNotEmpty && !RecTree.isSmb(tree)) {
      // Gewählter Speicherort (USB/Netzlaufwerk): Unterordner „Downloads“.
      final doc = await DownloadNative.safCreate(tree, 'Downloads', name,
          mime: _mime(d.ext));
      if (doc != null) return d.copyWith(path: doc, tree: tree);
    }
    return d.copyWith(path: '${await downloadsDir()}/$name');
  }

  static String _mime(String ext) => switch (ext) {
        'mp4' || 'm4v' => 'video/mp4',
        'ts' || 'm2ts' => 'video/mp2t',
        'avi' => 'video/x-msvideo',
        'webm' => 'video/webm',
        _ => 'video/x-matroska',
      };

  @override
  Future<DownloadSink> sinkFor(DownloadItem d) async {
    final p = d.path!;
    if (p.startsWith('smb://')) {
      final (c, rel) = await _smbOf(p);
      return SmbSink(c, rel);
    }
    return p.startsWith('content://') ? SafSink(p) : FileSink(p);
  }

  @override
  Future<(String, DownloadSink)?> subtitleSink(
      DownloadItem d, DownloadSub s, int index) async {
    final base = downloadFileName(d).replaceAll(RegExp(r'\.[^.]+$'), '');
    final lang = (s.language ?? 'und').replaceAll(RegExp(r'[^A-Za-z-]'), '');
    final name = '$base.$index.$lang.srt';
    if (d.path?.startsWith('smb://') ?? false) {
      final c = (await _st).smbConfig();
      if (c == null) return null;
      return (c.uriFor('Downloads/$name'), SmbSink(c, 'Downloads/$name'));
    }
    if (d.tree != null) {
      final doc = await DownloadNative.safCreate(d.tree!, 'Downloads', name,
          mime: 'application/x-subrip');
      return doc == null ? null : (doc, SafSink(doc));
    }
    final path = '${await downloadsDir()}/$name';
    return (path, FileSink(path));
  }

  @override
  Future<int> freeSpace(DownloadItem d) async {
    final p = d.path;
    if ((p != null && p.startsWith('smb://')) ||
        (p == null && await _smb() != null)) {
      final c = (await _st).smbConfig();
      if (c == null) return -1;
      // Nicht erreichbar → unbekannt; der Start meldet dann „nas:…“.
      try {
        return await Smb.free(c);
      } on SmbException {
        return -1;
      }
    }
    if (d.tree != null ||
        (d.path == null &&
            (await _tree()).isNotEmpty &&
            !RecTree.isSmb(await _tree()))) {
      final tree = d.tree ?? await _tree();
      return (await RecTree.info(tree)).free;
    }
    return DownloadNative.freeSpace(await downloadsDir());
  }

  @override
  Future<void> deleteFiles(DownloadItem d) async {
    for (final p in [d.path, for (final s in d.subs) s.path]) {
      if (p == null) continue;
      if (p.startsWith('smb://')) {
        try {
          final (c, rel) = await _smbOf(p);
          await Smb.delete(c, rel);
        } on SmbException {
          // NAS weg: Eintrag trotzdem entfernen (Datei bleibt dort liegen).
        }
      } else if (p.startsWith('content://')) {
        await DownloadNative.safDelete(p);
      } else {
        await deleteLocalFile(p);
      }
    }
    // Noch nicht angelegte Untertitel im App-Ordner gibt es nicht.
  }

  @override
  DownloadEnv env() {
    final st = ref.read(storageProvider).value;
    final net = ref.read(networkStateProvider).value ?? JspNetState.unknown;
    final portal = ref.read(activePortalProvider).value;
    final max = ref.read(maxConnectionsProvider);
    final recs = ref.read(recordingsProvider);
    return DownloadEnv(
      connected: net.connected,
      cellular: net.cellular,
      metered: net.metered,
      mobileAllowed: st?.flag(DownloadSettings.mobileKey) ?? false,
      dataSaverActive: ref.read(dataSaverActiveProvider),
      concurrency:
          int.tryParse(st?.option(DownloadSettings.parallelKey, '1') ?? '1') ??
              1,
      keepLiveFree: st?.flag(DownloadSettings.keepFreeKey) ?? false,
      maxConnections: (scope) => scope == portal?.id ? max : null,
      busyConnections: (scope) =>
          scope == portal?.id ? runningRecordings(recs, DateTime.now()) : 0,
    );
  }

  DownloadNotice? _last;
  DateTime _lastSent = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void changed(List<DownloadItem> items) {
    if (!DownloadNative.available) return;
    final n = downloadNotice(items);
    if (n == _last) return;
    // Nur Fortschritt: höchstens etwa 1× pro Sekunde zum Dienst; Start,
    // Ende und Titelwechsel sofort.
    final now = DateTime.now();
    final onlyProgress = n != null &&
        _last != null &&
        n.title == _last!.title &&
        n.paused == _last!.paused;
    if (onlyProgress && now.difference(_lastSent).inMilliseconds < 900) return;
    _last = n;
    _lastSent = now;
    unawaited(DownloadNative.service(n));
  }
}

/// Text der Benachrichtigung; null = kein Dienst nötig.
@visibleForTesting
DownloadNotice? downloadNotice(List<DownloadItem> items) {
  final running = items.where((d) => d.state == DownloadState.running).toList();
  final waitingRetry = items.where((d) =>
      d.state == DownloadState.queued ||
      (d.state == DownloadState.waiting && d.wait == DownloadWait.retry));
  if (running.isEmpty && waitingRetry.isEmpty) {
    // Alles angehalten: Hinweis mit „Fortsetzen“ (ohne Vordergrunddienst).
    final paused = items.where((d) => d.state == DownloadState.paused).length;
    if (paused == 0) return null;
    return DownloadNotice(
        title: tr('Downloads angehalten'),
        text: trf('{0} angehalten', [paused]),
        paused: true);
  }
  final more = running.length + waitingRetry.length - 1;
  if (running.isEmpty) {
    return DownloadNotice(
        title: tr('Downloads'),
        text: trf('{0} in der Warteschlange', [waitingRetry.length]));
  }
  final d = running.first;
  final p = d.progress;
  final name = d.isEpisode
      ? '${d.seriesName ?? ''} S${d.season} F${d.episode}'
      : d.title;
  final parts = [
    if (p != null) '${(p * 100).floor()} %',
    formatBytes(d.bytes) + (d.total > 0 ? ' / ${formatBytes(d.total)}' : ''),
    if (more > 0) trf('{0} weitere', [more]),
  ];
  return DownloadNotice(
    title: trf('Lädt herunter: {0}', [name]),
    text: parts.join(' · '),
    progress: p == null ? -1 : (p * 1000).round(),
  );
}

/// „1,4 GB“, „350 MB“.
String formatBytes(int b) {
  if (b <= 0) return '0 MB';
  const gb = 1024 * 1024 * 1024;
  const mb = 1024 * 1024;
  if (b >= gb) {
    final v = b / gb;
    return '${v.toStringAsFixed(v >= 10 ? 0 : 1).replaceAll('.', L10n.lang == 'en' ? '.' : ',')} GB';
  }
  return '${(b / mb).toStringAsFixed(0)} MB';
}

/// Nächste heruntergeladene Folge derselben Serie (fertig), sonst null.
DownloadItem? nextDownloadedEpisode(List<DownloadItem> all, DownloadItem d) {
  if (!d.isEpisode || d.seriesId == null) return null;
  DownloadItem? best;
  int key(DownloadItem x) => x.season * 10000 + x.episode;
  for (final x in all) {
    if (!x.isEpisode ||
        x.scope != d.scope ||
        x.seriesId != d.seriesId ||
        x.state != DownloadState.done ||
        key(x) <= key(d)) {
      continue;
    }
    if (best == null || key(x) < key(best)) best = x;
  }
  return best;
}
