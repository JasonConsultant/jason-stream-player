import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_messages.dart';
import '../../core/remote/content_ref.dart';
import '../../core/remote/keys.dart';
import '../../core/remote/peers.dart';
import '../../core/remote/protocol.dart';
import '../../core/remote/transport.dart';
import '../../core/theme.dart';
import '../../l10n/strings.dart';
import '../../models/models.dart';
import '../../state/emby.dart';
import '../../state/playback_session.dart';
import '../../state/profile_mode.dart';
import '../../state/profiles.dart' show profilePickPendingProvider;
import '../../state/providers.dart';
import '../../state/remote.dart';
import '../../state/shell_tab.dart';
import '../live/parental.dart';
import '../nav.dart';
import '../shell/app_guard.dart' show AppLock, appNavigatorKeyContext;
import '../shell/reminder_host.dart' show appNavigatorKey;

/// Dienst „Handy als Fernbedienung“ am Fernseher.
///
/// Läuft nur, solange die App im Vordergrund ist und die Einstellung an ist
/// (kein Hintergrunddienst): WebSocket-Server im privaten LAN, Ankündigung
/// per NSD, Code-Anzeige beim Koppeln. Befehle eines gekoppelten Handys
/// wirken wie die Fernbedienung:
/// - Tasten als echte Tastenereignisse ([KeyInjector]) – Fokus, PIN-Dialoge,
///   Kinder-/Gastprofil und Sperren verhalten sich identisch.
/// - Sender/Inhalte nur aus den sichtbaren Listen des Fernsehers; gesperrte
///   Sender verlangen die PIN am Fernseher ([askPin]).
/// - Bei App-Sperre oder offener Profilauswahl nichts öffnen.
class TvRemoteService extends ConsumerStatefulWidget {
  final Widget child;

  /// Nur am Fernseher.
  final bool enabled;
  const TvRemoteService({super.key, required this.child, required this.enabled});

  @override
  ConsumerState<TvRemoteService> createState() => TvRemoteServiceState();
}

@visibleForTesting
class TvRemoteServiceState extends ConsumerState<TvRemoteService>
    with WidgetsBindingObserver
    implements RemoteTvHost {
  RemoteServerHandle? _server;
  Future<void> _busy = Future.value();
  bool _resumed = true;
  String _tvId = '';
  String _tvName = 'Android TV';
  bool _volume = false;
  late final KeyInjector keys = KeyInjector();
  Timer? _statusTimer;
  RemoteStatus? _sentStatus;
  RemoteTextState? _sentText;
  EditableTextState? _field;
  TextEditingController? _fieldCtl;
  Timer? _textTimer;

  /// Laufender Server (Tests).
  RemoteServerHandle? get server => _server;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    FocusManager.instance.addListener(_onFocus);
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
  }

  @override
  void didUpdateWidget(TvRemoteService oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled != widget.enabled) _sync();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    FocusManager.instance.removeListener(_onFocus);
    _fieldCtl?.removeListener(_scheduleText);
    _textTimer?.cancel();
    _statusTimer?.cancel();
    keys.releaseAll();
    final s = _server;
    _server = null;
    if (s != null) {
      unawaited(s.close());
      unawaited(_discovery.unregister());
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Nur im Vordergrund (inactive = kurz verdeckt, z. B. Systemdialog).
    _resumed = state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive;
    _sync();
  }

  late final _discovery = ref.read(remoteDiscoveryProvider);

  bool get _want =>
      mounted &&
      widget.enabled &&
      _resumed &&
      !kIsWeb &&
      ref.read(remoteEnabledProvider);

  void _sync() {
    _busy = _busy.then((_) => _want ? _start() : _stop()).catchError((_) {});
  }

  /// Auf Start/Stopp warten (Tests).
  Future<void> get settled => _busy;

  Future<void> _start() async {
    if (_server != null) return;
    final st = await ref.read(storageProvider.future);
    _tvId = await st.remoteSelfId();
    try {
      final model = await ref
          .read(remoteDeviceNameProvider.future)
          .timeout(const Duration(seconds: 3));
      _tvName = model == 'Android' ? 'Android TV' : model;
    } catch (_) {}
    _volume = await _discovery.volumeControllable();
    if (!_want) return;
    RemoteServerHandle s;
    try {
      s = await ref.read(remoteServerStarterProvider)(this);
    } catch (_) {
      if (mounted) {
        ref
            .read(remoteServerInfoProvider.notifier)
            .set(const RemoteServerInfo(error: 'network'));
      }
      return;
    }
    if (!_want) {
      await s.close();
      return;
    }
    _server = s;
    ref.read(remoteServerInfoProvider.notifier).set(RemoteServerInfo(
        running: true, address: s.address, clients: s.clients));
    await _discovery.register(
        name: _tvName,
        port: s.port,
        attrs: {'id': _tvId, 'v': '$remoteProtocolVersion'});
  }

  Future<void> _stop() async {
    final s = _server;
    _server = null;
    keys.releaseAll();
    _statusTimer?.cancel();
    _statusTimer = null;
    if (mounted) {
      ref.read(remotePairPromptProvider.notifier).hide();
      ref.read(remoteServerInfoProvider.notifier).set(const RemoteServerInfo());
    }
    if (s == null) return;
    await _discovery.unregister();
    await s.close();
  }

  // ------------------------------------------------------------ RemoteTvHost

  @override
  String get tvId => _tvId;

  @override
  String get tvName => _tvName;

  @override
  Map<String, Object?> get caps => {'volume': _volume};

  @override
  RemotePeer? phone(String deviceId) {
    for (final p in ref.read(remotePhonesProvider)) {
      if (p.id == deviceId) return p;
    }
    return null;
  }

  @override
  Future<void> addPhone(RemotePeer p) =>
      ref.read(remotePhonesProvider.notifier).add(p);

  @override
  void showPairingCode(String code, String phoneName) {
    if (!mounted) return;
    ref.read(remotePairPromptProvider.notifier).show(PairPrompt(code, phoneName));
  }

  @override
  void hidePairingCode({bool paired = false, String? phoneName}) {
    if (!mounted) return;
    ref.read(remotePairPromptProvider.notifier).hide();
    if (paired) {
      AppMessages.show(trf('„{0}“ ist jetzt als Fernbedienung gekoppelt.',
          [phoneName ?? 'Android']));
    }
  }

  @override
  void connected(String deviceId) {
    if (!mounted) return;
    unawaited(ref.read(remotePhonesProvider.notifier).touch(deviceId));
    _updateInfo();
    _sentStatus = null;
    _sentText = null;
    _pushStatus();
    _pushText();
    _statusTimer ??=
        Timer.periodic(const Duration(seconds: 1), (_) => _pushStatus());
  }

  @override
  void disconnected(String deviceId) {
    if (!mounted) return;
    _updateInfo();
    if ((_server?.clients ?? 0) == 0) {
      keys.releaseAll();
      _statusTimer?.cancel();
      _statusTimer = null;
    }
  }

  void _updateInfo() {
    final s = _server;
    if (s == null || !mounted) return;
    ref.read(remoteServerInfoProvider.notifier).set(RemoteServerInfo(
        running: true, address: s.address, clients: s.clients));
  }

  @override
  Future<Map<String, Object?>?> handle(
      String deviceId, Map<String, Object?> msg) async {
    if (!mounted) return null;
    switch (msg['t']) {
      case 'key':
        final k = RemoteKey.fromWire(msg['k']);
        final a = KeyAction.fromWire(msg['a']) ?? KeyAction.tap;
        if (k == null) return null;
        if (k.isVolume) {
          if (a != KeyAction.up && _volume) {
            await _discovery.volume(k == RemoteKey.volumeUp
                ? 1
                : k == RemoteKey.volumeDown
                    ? -1
                    : 0);
          }
          return null;
        }
        if (k == RemoteKey.home) {
          if (a != KeyAction.up) _home();
          return null;
        }
        switch (a) {
          case KeyAction.tap:
            keys.tap(k);
          case KeyAction.down:
            keys.down(k);
          case KeyAction.up:
            keys.up(k);
        }
        return null;
      case 'text':
        if (!AppLock.locked.value) {
          setText(Wire.str(msg, 'v', max: 4000) ?? '');
        }
        return null;
      case 'textDone':
        if (!AppLock.locked.value) _textDone();
        return null;
      case 'req':
        return _request(msg);
    }
    return null;
  }

  Future<Map<String, Object?>> _request(Map<String, Object?> msg) async {
    final m = msg['m'];
    if (m == 'status') return _status().toJson()..remove('t');
    if (AppLock.locked.value) return {'err': RemoteError.locked};
    if (ref.read(profilePickPendingProvider) ||
        ref.read(activePortalProvider).value == null) {
      return {'err': RemoteError.busy};
    }
    try {
      switch (m) {
        case 'groups':
          return await _groups();
        case 'channels':
          return await _channelsPage(
              Wire.str(msg, 'g', max: 200) ?? '',
              Wire.integer(msg, 'o', max: 1 << 20) ?? 0,
              (Wire.integer(msg, 'n', max: 200) ?? remotePageSize)
                  .clamp(1, 100));
        case 'tune':
          final id = Wire.str(msg, 'ch');
          if (id == null) return {'err': RemoteError.bad};
          return await _tune(id);
        case 'play':
          return await _play(ContentRef.fromJson(Wire.map(msg, 'ref')));
      }
    } on TimeoutException {
      return {'err': RemoteError.busy};
    }
    return {'err': RemoteError.bad};
  }

  // ------------------------------------------------------------ Sender

  Future<(List<Channel>, LiveData, ChannelFlags)> _visible() async {
    final live =
        await readVisibleLive(ref).timeout(const Duration(seconds: 15));
    final flags = ref.read(channelFlagsProvider).value ?? ChannelFlags.empty;
    return (
      [for (final c in live.channels) if (!flags.isHidden(c.id)) c],
      live,
      flags
    );
  }

  Future<Map<String, Object?>> _groups() async {
    final (list, live, flags) = await _visible();
    final counts = <String, int>{};
    var favs = 0;
    for (final c in list) {
      counts[c.categoryId] = (counts[c.categoryId] ?? 0) + 1;
      if (flags.favorites.contains(c.id)) favs++;
    }
    return {
      'total': list.length,
      'groups': [
        if (favs > 0) RemoteGroup('fav', tr('Favoriten'), favs).toJson(),
        for (final g in live.categories)
          if ((counts[g.id] ?? 0) > 0)
            RemoteGroup(g.id, g.name, counts[g.id]!).toJson(),
      ],
    };
  }

  Future<Map<String, Object?>> _channelsPage(String g, int o, int n) async {
    final (all, _, flags) = await _visible();
    final list = g.isEmpty
        ? all
        : g == 'fav'
            ? [for (final c in all) if (flags.favorites.contains(c.id)) c]
            : [for (final c in all) if (c.categoryId == g) c];
    final epg = ref.read(epgProvider).value ?? const {};
    final portal = ref.read(activePortalProvider).value;
    final now = DateTime.now();
    RemoteProgramme? prog(EpgEntry? e) =>
        e == null ? null : RemoteProgramme(e.title, e.start, e.end);
    return {
      'total': list.length,
      'items': [
        for (final c in list.skip(o).take(n))
          () {
            final cur = nowPlaying(epg, c, now);
            final logo = c.logoUrl;
            return RemoteChannel(
              id: c.id,
              name: c.name,
              number: c.number,
              logo: logo != null &&
                      isSafeLogoUrl(logo,
                          secrets: [portal?.username, portal?.password])
                  ? logo
                  : null,
              now: prog(cur),
              next: prog(nextAfter(epg, c, cur)),
              locked: flags.locked.contains(c.id),
            ).toJson();
          }(),
      ],
    };
  }

  BuildContext? get _navContext => appNavigatorKeyContext();

  /// Laufende Player-Seite schließen (Fernseher: beendet den Stream), damit
  /// nie zwei Player-Seiten übereinander liegen.
  Future<void> _closePlayer() async {
    if (!ref.read(playbackProvider).active) return;
    appNavigatorKey.currentState?.popUntil((r) => r.isFirst);
    await WidgetsBinding.instance.endOfFrame;
  }

  Future<Map<String, Object?>> _tune(String id) async {
    final (list, live, flags) = await _visible();
    Channel? c;
    for (final x in list) {
      if (x.id == id) c = x;
    }
    if (c == null) return {'err': RemoteError.notAvailable};
    return _openChannel(c, live.channels, flags);
  }

  Future<Map<String, Object?>> _openChannel(
      Channel c, List<Channel> all, ChannelFlags flags) async {
    final ctl = ref.read(playbackProvider.notifier);
    final s = ctl.session;
    final tune = ctl.tuneHandler;
    if (s != null &&
        s.live &&
        tune != null &&
        ref.read(playbackProvider).surface == PlayerSurface.fullscreen) {
      // Player läuft: umschalten wie mit der Nummern-Direktwahl (PIN dort).
      await tune(c);
      return {'ok': true};
    }
    final ctx = _navContext;
    if (ctx == null) return {'err': RemoteError.busy};
    if (flags.locked.contains(c.id) && !await askPin(ctx, ref)) {
      return {'err': RemoteError.refused};
    }
    await _closePlayer();
    final ctx2 = _navContext;
    if (ctx2 == null || !ctx2.mounted) return {'err': RemoteError.busy};
    unawaited(openPlayer(
      ctx2,
      PlayRequest(
        title: c.name,
        url: c.streamUrl,
        isLive: true,
        channels: all,
        channel: c,
        artworkSeed: c.name,
      ),
    ));
    return {'ok': true};
  }

  // ------------------------------------------------------------ Inhalte

  Future<Map<String, Object?>> _play(ContentRef? r) async {
    if (r == null) return {'err': RemoteError.bad};
    if (r.isEmby) return _playEmby(r);
    final portals = await ref.read(portalsProvider.future);
    final active = await ref.read(activePortalProvider.future);
    switch (matchPortal(r, portals, active)) {
      case PortalMatch.none:
        return {'err': RemoteError.notAvailable};
      case PortalMatch.inactive:
        return {'err': RemoteError.portalInactive};
      case PortalMatch.active:
        break;
    }
    switch (r.kind) {
      case ContentKind.live:
        return _tune(r.id);
      case ContentKind.movie:
        await ref.read(moviesProvider.future).timeout(const Duration(seconds: 20));
        return _openMovie(r, ref.read(visibleMoviesProvider).value);
      case ContentKind.episode:
        await ref.read(seriesProvider.future).timeout(const Duration(seconds: 20));
        return _openEpisode(r, ref.read(visibleSeriesProvider).value);
    }
  }

  Future<Map<String, Object?>> _playEmby(ContentRef r) async {
    final acc = ref.read(embyAccountProvider);
    final sid = acc?.serverId;
    if (acc == null ||
        !acc.signedIn ||
        sid == null ||
        !r.scope.contains(embyFingerprint(sid))) {
      return {'err': RemoteError.notAvailable};
    }
    switch (r.kind) {
      case ContentKind.movie:
        await ref
            .read(embyMoviesProvider.future)
            .timeout(const Duration(seconds: 20));
        return _openMovie(r, ref.read(visibleEmbyMoviesProvider).value);
      case ContentKind.episode:
        await ref
            .read(embySeriesProvider.future)
            .timeout(const Duration(seconds: 20));
        return _openEpisode(r, ref.read(visibleEmbySeriesProvider).value);
      case ContentKind.live:
        return {'err': RemoteError.notAvailable};
    }
  }

  static VodItem? _find(VodData? d, String? id) {
    if (d == null || id == null) return null;
    for (final m in d.items) {
      if (m.id == id) return m;
    }
    return null;
  }

  /// Stelle vom Handy übernehmen (als „Weiterschauen“ – der Player springt
  /// beim Öffnen dorthin, wie sonst auch).
  Future<void> _takePosition(String key, int pos, Duration? total) async {
    if (pos <= 15) return;
    final st = await ref.read(storageProvider.future);
    final t = total?.inSeconds ?? 0;
    await st.setResume(key, pos, t > pos ? t : 0);
  }

  Future<Map<String, Object?>> _openMovie(ContentRef r, VodData? d) async {
    final m = _find(d, r.id);
    if (m == null || m.isSeries) return {'err': RemoteError.notAvailable};
    await _takePosition('movie_${m.id}', r.position, m.duration);
    await _closePlayer();
    final ctx = _navContext;
    if (ctx == null || !ctx.mounted) return {'err': RemoteError.busy};
    unawaited(playMovie(ctx, ref, m));
    return {'ok': true};
  }

  Future<Map<String, Object?>> _openEpisode(ContentRef r, VodData? d) async {
    final s = _find(d, r.seriesId);
    if (s == null) return {'err': RemoteError.notAvailable};
    final details = await ref
        .read(seriesDetailsProvider(s).future)
        .timeout(const Duration(seconds: 20));
    Episode? ep;
    for (final l in details.seasons.values) {
      for (final e in l) {
        if (e.id == r.id) ep = e;
      }
    }
    if (ep == null) return {'err': RemoteError.notAvailable};
    await _takePosition('ep_${ep.id}', r.position, ep.duration);
    await _closePlayer();
    final ctx = _navContext;
    if (ctx == null || !ctx.mounted) return {'err': RemoteError.busy};
    unawaited(playEpisode(ctx, ref, s, ep));
    return {'ok': true};
  }

  /// „Home“: zur Startseite der App (Player/Seiten schließen).
  void _home() {
    if (AppLock.locked.value) return;
    appNavigatorKey.currentState?.popUntil((r) => r.isFirst);
    ref.read(shellTabRequestProvider.notifier).open(0);
  }

  // ------------------------------------------------------------ Status

  RemoteStatus _status() {
    final snap = ref.read(playbackProvider);
    final s = ref.read(playbackProvider.notifier).session;
    if (!snap.active || s == null || AppLock.locked.value) {
      return RemoteStatus.none;
    }
    if (s.live) {
      final c = s.channel;
      final epg = ref.read(epgProvider).value ?? const {};
      return RemoteStatus(
        kind: 'live',
        title: c?.name ?? snap.title,
        channelId: c?.id,
        channelNumber: c == null || c.number <= 0 ? null : c.number,
        programme: c == null ? null : nowPlaying(epg, c)?.title,
        playing: snap.playing,
        buffering: snap.buffering,
      );
    }
    final st = s.engine.state;
    return RemoteStatus(
      kind: 'vod',
      title: snap.title,
      subtitle: snap.subtitle,
      playing: snap.playing,
      buffering: snap.buffering,
      position: st.position.inSeconds,
      duration: st.duration.inSeconds,
    );
  }

  void _pushStatus() {
    final srv = _server;
    if (srv == null || srv.clients == 0 || !mounted) return;
    final s = _status();
    if (s == _sentStatus) return;
    _sentStatus = s;
    unawaited(srv.broadcast(s.toJson()));
  }

  // ------------------------------------------------------------ Text

  void _onFocus() {
    final node = FocusManager.instance.primaryFocus;
    final ctx = node?.context;
    final st = ctx?.findAncestorStateOfType<EditableTextState>();
    if (!identical(st, _field)) {
      _fieldCtl?.removeListener(_scheduleText);
      _field = st;
      _fieldCtl = st?.widget.controller;
      _fieldCtl?.addListener(_scheduleText);
    }
    _scheduleText();
  }

  void _scheduleText() {
    if (_server == null) return;
    _textTimer?.cancel();
    _textTimer = Timer(const Duration(milliseconds: 120), _pushText);
  }

  /// Fokussiertes Textfeld am Fernseher (oder [RemoteTextState.none]).
  RemoteTextState textState() {
    final st = _field;
    if (st == null ||
        !st.mounted ||
        !st.widget.focusNode.hasFocus ||
        AppLock.locked.value) {
      return RemoteTextState.none;
    }
    final w = st.widget;
    final tf = st.context.findAncestorWidgetOfExactType<TextField>();
    final hint = tf?.decoration?.hintText ?? tf?.decoration?.labelText;
    return RemoteTextState(
      focus: true,
      text: w.controller.text,
      hint: hint == null || hint.length > 200 ? null : hint,
      obscure: w.obscureText,
      multiline: w.maxLines != 1,
      numeric: w.keyboardType.index == TextInputType.number.index,
    );
  }

  void _pushText() {
    final srv = _server;
    if (srv == null || srv.clients == 0 || !mounted) return;
    final t = textState();
    if (t == _sentText) return;
    _sentText = t;
    unawaited(srv.broadcast(t.toJson()));
  }

  /// Text vom Handy ins fokussierte Feld (wie Tippen: Formatierer und
  /// onChanged – die Suche reagiert live).
  @visibleForTesting
  void setText(String v) {
    final st = _field;
    if (st == null || !st.mounted || !st.widget.focusNode.hasFocus) return;
    st.userUpdateTextEditingValue(
        TextEditingValue(
            text: v, selection: TextSelection.collapsed(offset: v.length)),
        SelectionChangedCause.keyboard);
    // Kein Echo zurück ans Handy (dort wird schon weitergetippt).
    _sentText = textState();
  }

  void _textDone() {
    final st = _field;
    if (st == null || !st.mounted) return;
    st.performAction(st.widget.textInputAction ?? TextInputAction.done);
  }

  // ------------------------------------------------------------ UI

  @override
  Widget build(BuildContext context) {
    ref.listen(remoteEnabledProvider, (_, __) => _sync());
    ref.listen(playbackProvider, (_, __) => _pushStatus());
    // Gerät entfernt → sofort trennen.
    ref.listen(remotePhonesProvider, (prev, next) {
      final ids = {for (final p in next) p.id};
      for (final p in prev ?? const <RemotePeer>[]) {
        if (!ids.contains(p.id)) _server?.disconnect(p.id);
      }
    });
    final prompt = widget.enabled ? ref.watch(remotePairPromptProvider) : null;
    return Stack(children: [
      widget.child,
      if (prompt != null)
        Positioned.fill(child: IgnorePointer(child: PairCodeOverlay(prompt))),
    ]);
  }
}

/// Code-Anzeige am Fernseher beim Koppeln.
class PairCodeOverlay extends StatelessWidget {
  final PairPrompt prompt;
  const PairCodeOverlay(this.prompt, {super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return ColoredBox(
      color: Colors.black54,
      child: Center(
        child: Container(
          key: const ValueKey('remote-pair-code'),
          width: 560,
          padding: const EdgeInsets.fromLTRB(36, 32, 36, 28),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: AppColors.accent.withValues(alpha: 0.5)),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.phonelink_ring_rounded,
                size: 44, color: AppColors.accent),
            const SizedBox(height: 14),
            Text(tr('Handy als Fernbedienung koppeln'),
                textAlign: TextAlign.center, style: t.titleLarge),
            const SizedBox(height: 10),
            Text(
                trf('„{0}“ möchte sich verbinden. Gib diesen Code auf dem Handy ein:',
                    [prompt.phoneName]),
                textAlign: TextAlign.center,
                style: t.bodyLarge?.copyWith(color: AppColors.textDim)),
            const SizedBox(height: 22),
            Row(mainAxisSize: MainAxisSize.min, children: [
              for (final d in prompt.code.split(''))
                Container(
                  width: 72,
                  height: 88,
                  margin: const EdgeInsets.symmetric(horizontal: 7),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: AppColors.bg,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Text(d,
                      style: t.displayMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          fontFeatures: const [FontFeature.tabularFigures()])),
                ),
            ]),
            const SizedBox(height: 22),
            Text(
                tr('Nicht angefragt? Einfach ignorieren – ohne Code kann '
                    'niemand den Fernseher bedienen.'),
                textAlign: TextAlign.center,
                style: t.bodySmall),
          ]),
        ),
      ),
    );
  }
}
