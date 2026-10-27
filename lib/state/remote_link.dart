import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/remote/content_ref.dart';
import '../core/remote/nsd.dart';
import '../core/remote/peers.dart';
import '../core/remote/protocol.dart';
import '../core/remote/transport.dart';
import '../l10n/strings.dart';
import '../models/models.dart';
import 'emby.dart';
import 'providers.dart';
import 'remote.dart';

/// Handy-Seite der Fernbedienung: Verbindung zum gewählten Fernseher,
/// automatisches Neuverbinden (solange die Fernbedienung offen ist), Status
/// und Textfeld des Fernsehers, Befehle.

enum LinkPhase {
  /// Kein Fernseher gekoppelt.
  none,

  /// Gekoppelt, nicht verbunden.
  idle,
  connecting,
  connected,

  /// Nicht gefunden (anderes WLAN, App am TV zu, Dienst aus).
  unreachable,

  /// Der Fernseher kennt dieses Handy nicht mehr (dort entfernt).
  removed,
}

@immutable
class RemoteLinkState {
  final LinkPhase phase;
  final RemotePeer? tv;
  final RemoteStatus status;
  final RemoteTextState text;

  /// Lautstärke am Fernseher über die App regelbar.
  final bool volume;

  const RemoteLinkState({
    this.phase = LinkPhase.none,
    this.tv,
    this.status = RemoteStatus.none,
    this.text = RemoteTextState.none,
    this.volume = false,
  });

  bool get connected => phase == LinkPhase.connected;

  RemoteLinkState copyWith({
    LinkPhase? phase,
    RemotePeer? tv,
    RemoteStatus? status,
    RemoteTextState? text,
    bool? volume,
  }) =>
      RemoteLinkState(
        phase: phase ?? this.phase,
        tv: tv ?? this.tv,
        status: status ?? this.status,
        text: text ?? this.text,
        volume: volume ?? this.volume,
      );
}

/// Gewählter Fernseher (bei mehreren gekoppelten).
const remoteTvOption = 'remote_tv';

class RemoteLink extends Notifier<RemoteLinkState> {
  RemoteConnection? _conn;
  Future<bool>? _connecting;
  Timer? _retry;
  int _attempt = 0;
  int _leases = 0;
  bool _foreground = true;
  AppLifecycleListener? _life;
  bool _disposed = false;

  /// Suche nach dem Fernseher per NSD (wenn die letzte Adresse nicht mehr
  /// stimmt) – so lange höchstens.
  static const searchFor = Duration(seconds: 6);

  @override
  RemoteLinkState build() {
    _disposed = false;
    ref.onDispose(() {
      _disposed = true;
      _retry?.cancel();
      _life?.dispose();
      final c = _conn;
      _conn = null;
      if (c != null) unawaited(c.close());
    });
    _life = AppLifecycleListener(
      onPause: () {
        _foreground = false;
        _disconnect();
      },
      onResume: () {
        _foreground = true;
        if (_leases > 0) unawaited(connect());
      },
    );
    // Gekoppelte Fernseher beobachten, ohne die Verbindung bei jeder
    // Kleinigkeit (zuletzt gesehen) neu aufzubauen.
    ref.listen(remoteTvsProvider, (_, list) => _pick(list));
    ref.listen(storageProvider, (_, __) => _pick(ref.read(remoteTvsProvider)));
    return _initial(ref.read(remoteTvsProvider));
  }

  RemoteLinkState _initial(List<RemotePeer> tvs) {
    final tv = _choose(tvs);
    return tv == null
        ? const RemoteLinkState()
        : RemoteLinkState(phase: LinkPhase.idle, tv: tv);
  }

  RemotePeer? _choose(List<RemotePeer> tvs) {
    if (tvs.isEmpty) return null;
    final want = ref.read(storageProvider).value?.option(remoteTvOption, '');
    for (final t in tvs) {
      if (t.id == want) return t;
    }
    return tvs.first;
  }

  void _pick(List<RemotePeer> tvs) {
    if (_disposed) return;
    final tv = _choose(tvs);
    if (tv == null) {
      _disconnect();
      state = const RemoteLinkState();
      return;
    }
    if (tv.id != state.tv?.id) {
      _disconnect();
      state = RemoteLinkState(phase: LinkPhase.idle, tv: tv);
      if (_leases > 0) unawaited(connect());
    } else {
      // Gleicher Fernseher (z. B. neue Adresse gemerkt) → nur übernehmen.
      state = state.copyWith(tv: tv);
    }
  }

  /// Fernbedienung offen: verbunden halten (und neu verbinden).
  void hold() {
    _leases++;
    unawaited(connect());
  }

  void release() {
    if (_leases > 0) _leases--;
    if (_leases == 0) _retry?.cancel();
  }

  void _disconnect() {
    _retry?.cancel();
    final c = _conn;
    _conn = null;
    if (c != null) unawaited(c.close());
    if (state.phase == LinkPhase.connected ||
        state.phase == LinkPhase.connecting) {
      state = state.copyWith(
          phase: LinkPhase.idle,
          status: RemoteStatus.none,
          text: RemoteTextState.none);
    }
  }

  /// Verbinden (falls nötig). true = verbunden.
  Future<bool> connect() {
    if (_conn?.isOpen ?? false) return Future.value(true);
    if (state.tv == null || !_foreground || _disposed) {
      return Future.value(false);
    }
    return _connecting ??= _connect().whenComplete(() => _connecting = null);
  }

  Future<bool> _connect() async {
    final tv = state.tv;
    if (tv == null || !_foreground || _disposed) return false;
    _retry?.cancel();
    state = state.copyWith(phase: LinkPhase.connecting);
    final connector = ref.read(remoteConnectorProvider);
    final st = await ref.read(storageProvider.future);
    final me = await st.remoteSelfId();

    Future<RemoteConnection?> tryAt(String host, int port) async {
      try {
        final c = await connector(host, port);
        if (c.hello.tvId == tv.id) return c;
        await c.close();
      } catch (_) {}
      return null;
    }

    var host = tv.host, port = tv.port;
    RemoteConnection? c;
    if (host != null && port != null) c = await tryAt(host, port);
    if (c == null) {
      final found = await _search(tv.id);
      if (found != null) {
        host = found.host;
        port = found.port;
        c = await tryAt(found.host, found.port);
      }
    }
    if (_disposed) {
      await c?.close();
      return false;
    }
    if (state.tv?.id != tv.id) {
      // Inzwischen anderer Fernseher gewählt → für den neuen neu starten.
      await c?.close();
      if (_leases > 0) Timer.run(() => unawaited(connect()));
      return false;
    }
    if (c == null) {
      _failed(LinkPhase.unreachable);
      return false;
    }
    try {
      await c.authenticate(me, tv.key);
    } on RemoteRejected catch (e) {
      _failed(e.reason == 'unknown' ? LinkPhase.removed : LinkPhase.unreachable);
      return false;
    }
    final conn = c;
    _conn = conn;
    _attempt = 0;
    state = state.copyWith(
        phase: LinkPhase.connected,
        volume: (c.ready['caps'] as Map?)?['volume'] == true);
    final name = c.ready['name'];
    unawaited(ref.read(remoteTvsProvider.notifier).touch(tv.id,
        host: host, port: port, name: name is String ? name : null));
    c.events.listen((m) {
      if (_disposed || !identical(_conn, c)) return;
      switch (m['t']) {
        case 'status':
          state = state.copyWith(status: RemoteStatus.fromJson(m));
        case 'text':
          state = state.copyWith(text: RemoteTextState.fromJson(m));
      }
    });
    unawaited(conn.done.then((_) => _closed(conn)));
    return true;
  }

  Future<FoundTv?> _search(String tvId) async {
    final d = ref.read(remoteDiscoveryProvider);
    final hit = Completer<FoundTv?>();
    final sub = d.discover().listen((t) {
      if (t.id == tvId && !hit.isCompleted) hit.complete(t);
    });
    try {
      return await hit.future.timeout(searchFor, onTimeout: () => null);
    } finally {
      await sub.cancel();
      await d.stopDiscover();
    }
  }

  void _failed(LinkPhase p) {
    if (_disposed) return;
    state = state.copyWith(
        phase: p, status: RemoteStatus.none, text: RemoteTextState.none);
    if (p != LinkPhase.removed) _scheduleRetry();
  }

  void _closed(RemoteConnection c) {
    if (!identical(_conn, c) || _disposed) return;
    _conn = null;
    state = state.copyWith(
        phase: LinkPhase.connecting,
        status: RemoteStatus.none,
        text: RemoteTextState.none);
    _scheduleRetry();
  }

  /// Neu verbinden mit wachsender Pause (1, 2, 4, 8, höchstens 10 s) –
  /// nur, solange die Fernbedienung offen und die App im Vordergrund ist.
  void _scheduleRetry() {
    _retry?.cancel();
    if (_leases == 0 || !_foreground || _disposed) {
      if (state.phase == LinkPhase.connecting) {
        state = state.copyWith(phase: LinkPhase.idle);
      }
      return;
    }
    final s = 1 << _attempt.clamp(0, 3);
    _attempt++;
    _retry = Timer(Duration(seconds: s > 10 ? 10 : s), () {
      if (_leases > 0) unawaited(connect());
    });
  }

  /// Sofort erneut versuchen (Knopf „Erneut verbinden“).
  Future<bool> retry() {
    _attempt = 0;
    return connect();
  }

  // ------------------------------------------------------------ Befehle

  void key(RemoteKey k, [KeyAction a = KeyAction.tap]) {
    final c = _conn;
    if (c == null) return;
    unawaited(c.send({'t': 'key', 'k': k.wire, 'a': a.wire}));
  }

  void text(String v) {
    unawaited(_conn?.send({'t': 'text', 'v': v}));
    state = state.copyWith(
        text: RemoteTextState(
            focus: state.text.focus,
            text: state.text.obscure ? '' : v,
            hint: state.text.hint,
            obscure: state.text.obscure,
            multiline: state.text.multiline,
            numeric: state.text.numeric));
  }

  void textDone() => unawaited(_conn?.send({'t': 'textDone'}));

  /// Anfrage an den Fernseher (verbindet bei Bedarf). Wirft
  /// [RemoteRejected]/[TimeoutException], wenn er nicht erreichbar ist.
  Future<Map<String, Object?>> request(String method,
      [Map<String, Object?> args = const {},
      Duration timeout = const Duration(seconds: 10)]) async {
    if (!await connect()) throw const RemoteRejected('unreachable');
    return _conn!.request(method, args, timeout);
  }

  /// Inhalt auf dem Fernseher öffnen. null = läuft, sonst Fehlercode
  /// ([RemoteError] bzw. `unreachable`).
  Future<String?> playOnTv(ContentRef r) async {
    try {
      final res = await request('play', {'ref': r.toJson()},
          const Duration(seconds: 60));
      if (res['ok'] == true) return null;
      return res['err'] as String? ?? RemoteError.bad;
    } on RemoteRejected {
      return 'unreachable';
    } on TimeoutException {
      return 'unreachable';
    }
  }

  /// Sender am Fernseher einschalten. null = ok, sonst Fehlercode.
  Future<String?> tune(String channelId) async {
    try {
      final res = await request(
          'tune', {'ch': channelId}, const Duration(seconds: 60));
      if (res['ok'] == true) return null;
      return res['err'] as String? ?? RemoteError.bad;
    } on RemoteRejected {
      return 'unreachable';
    } on TimeoutException {
      return 'unreachable';
    }
  }

  // ------------------------------------------------------------ Geräte

  Future<void> select(String tvId) async {
    final st = await ref.read(storageProvider.future);
    await st.setOption(remoteTvOption, tvId);
    _pick(ref.read(remoteTvsProvider));
  }

  /// Fernseher hier vergessen (Schlüssel löschen).
  Future<void> forget(String tvId) async {
    if (state.tv?.id == tvId) _disconnect();
    await ref.read(remoteTvsProvider.notifier).remove(tvId);
  }

  /// Nach dem Koppeln: speichern, auswählen, verbinden.
  Future<void> paired(RemotePeer tv) async {
    await ref.read(remoteTvsProvider.notifier).add(tv);
    await select(tv.id);
    _attempt = 0;
    unawaited(connect());
  }
}

final remoteLinkProvider =
    NotifierProvider<RemoteLink, RemoteLinkState>(RemoteLink.new);

/// Meldung zu einem Fehlercode (Handy).
String remoteErrorText(String code) => switch (code) {
      RemoteError.notAvailable =>
        tr('Dieser Inhalt ist auf dem TV nicht verfügbar.'),
      RemoteError.portalInactive => tr('Auf dem TV ist gerade ein anderes '
          'Portal aktiv. Bitte dort zuerst das passende Portal wählen.'),
      RemoteError.refused => tr('Am Fernseher abgebrochen.'),
      RemoteError.locked =>
        tr('Die App am Fernseher ist gesperrt – bitte dort entsperren.'),
      RemoteError.busy => tr('Der Fernseher ist noch nicht bereit (Profil '
          'wählen oder Listen laden).'),
      'unreachable' => tr('Fernseher nicht erreichbar.'),
      _ => tr('Das hat nicht geklappt.'),
    };

// ------------------------------------------------------------ Inhalte

/// Kennung für „Auf dem TV abspielen“ – nur IDs, nie eine Adresse.
/// null, wenn der Inhalt keine Quelle hat, die der Fernseher kennen kann.
ContentRef? contentRefFor(WidgetRef ref,
    {Channel? channel, VodItem? movie, VodItem? series, Episode? episode}) {
  final st = ref.read(storageProvider).value;
  int pos(String key) => st?.resume(key)?.pos ?? 0;
  final item = movie ?? series;
  if (item != null && item.isEmby) {
    final sid = ref.read(embyAccountProvider)?.serverId;
    if (sid == null) return null;
    final scope = [embyFingerprint(sid)];
    if (movie != null) {
      return ContentRef(
          source: 'emby',
          scope: scope,
          kind: ContentKind.movie,
          id: movie.id,
          position: pos('movie_${movie.id}'),
          title: movie.name);
    }
    if (episode == null) return null;
    return ContentRef(
        source: 'emby',
        scope: scope,
        kind: ContentKind.episode,
        id: episode.id,
        seriesId: series!.id,
        position: pos('ep_${episode.id}'),
        title: episode.title);
  }
  final portal = ref.read(activePortalProvider).value;
  if (portal == null || portal.type == PortalType.demo) return null;
  final scope = portalFingerprints(portal);
  if (channel != null) {
    return ContentRef(
        source: 'portal',
        scope: scope,
        kind: ContentKind.live,
        id: channel.id,
        title: channel.name);
  }
  if (movie != null) {
    return ContentRef(
        source: 'portal',
        scope: scope,
        kind: ContentKind.movie,
        id: movie.id,
        position: pos('movie_${movie.id}'),
        title: movie.name);
  }
  if (series != null && episode != null) {
    return ContentRef(
        source: 'portal',
        scope: scope,
        kind: ContentKind.episode,
        id: episode.id,
        seriesId: series.id,
        position: pos('ep_${episode.id}'),
        title: episode.title);
  }
  return null;
}
