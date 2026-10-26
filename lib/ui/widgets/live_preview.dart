import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/security.dart';
import '../../l10n/strings.dart';
import '../../models/models.dart';
import '../../player/data_saver.dart';
import '../../state/playback_session.dart';
import '../../state/providers.dart';
import '../player/stream_url.dart';
import 'artwork.dart';
import 'focusable_tile.dart';

/// Einstellung „Live-Vorschau beim Stöbern“ (Standard: an) – im
/// Datensparmodus aus.
final livePreviewEnabledProvider = FutureProvider<bool>((ref) async {
  final saver = ref.watch(dataSaverActiveProvider);
  final s = await ref.watch(storageProvider.future);
  return s.flag('preview', fallback: true) && !saver;
});

/// Zustand der Vorschau für die Anzeige.
class PreviewStatus {
  final String? channelId;
  final bool loading;
  final bool hasVideo;
  final bool error;
  const PreviewStatus(
      {this.channelId,
      this.loading = false,
      this.hasVideo = false,
      this.error = false});
  static const idle = PreviewStatus();
}

/// Verwaltet die EINE gemeinsame Vorschau-Instanz (Player + VideoController).
/// Mehrere [LivePreview]-Widgets (Live-TV, TV-Guide) teilen sie sich; nur der
/// zuletzt startende „Besitzer“ spielt, [stop] wirkt nur für den Besitzer.
class LivePreviewController {
  LivePreviewController(this._ref);
  final Ref _ref;

  Player? _player;
  VideoController? _video;
  StreamSubscription<int?>? _widthSub;
  Object? _owner;
  int _gen = 0;

  final status = ValueNotifier<PreviewStatus>(PreviewStatus.idle);
  final muted = ValueNotifier<bool>(true);

  /// > 0, solange ein Vollbild-Player o. Ä. läuft – dann keine Vorschau
  /// (viele Portale erlauben nur eine Verbindung gleichzeitig).
  final paused = ValueNotifier<int>(0);

  VideoController? get video => _video;

  void _ensure() {
    if (_player != null) return;
    final storage = _ref.read(storageProvider).value;
    final p = Player(
        configuration: const PlayerConfiguration(bufferSize: 8 * 1024 * 1024));
    _player = p;
    _video = VideoController(
      p,
      configuration: VideoControllerConfiguration(
        enableHardwareAcceleration:
            storage?.flag('hwdec', fallback: true) ?? true,
      ),
    );
    _widthSub = p.stream.width.listen((w) {
      final s = status.value;
      if (w != null && w > 0 && s.channelId != null && !s.hasVideo) {
        status.value = PreviewStatus(channelId: s.channelId, hasVideo: true);
      }
    });
  }

  /// Läuft ein Stream (Vollbild oder Mini-Player)? Dann keine Vorschau –
  /// sonst zwei Player gleichzeitig (doppelter Ton, zweite Verbindung).
  bool get _streamActive {
    try {
      return _ref.read(playbackProvider).active;
    } catch (_) {
      return false;
    }
  }

  Future<void> play(Object owner, Channel c) async {
    if (paused.value > 0 || _streamActive) return;
    if (_owner == owner && status.value.channelId == c.id) return;
    _owner = owner;
    final gen = ++_gen;
    _ensure();
    status.value = PreviewStatus(channelId: c.id, loading: true);
    try {
      final url = await resolveLiveUrl(c,
          portal: _ref.read(activePortalProvider).value,
          current: _ref.read(repositoryProvider),
          repo: () => _ref.read(repositoryProvider.future));
      if (gen != _gen) return;
      if (!UrlPolicy.isStream(url)) throw Exception('invalid url');
      final p = _player!;
      await p.setVolume(muted.value ? 0 : 100);
      if (gen != _gen || _streamActive) return;
      await p.open(Media(url));
      if (gen != _gen || _streamActive) {
        // Inzwischen gestoppt bzw. Vollbild gestartet → nicht weiterspielen.
        if (identical(_player, p) && (_owner == null || _streamActive)) {
          unawaited(p.stop());
        }
        return;
      }
    } catch (_) {
      if (gen == _gen) {
        status.value = PreviewStatus(channelId: c.id, error: true);
      }
    }
  }

  /// Stoppt die Vorschau, wenn [owner] sie gerade besitzt (null = immer).
  void stop([Object? owner]) {
    if (owner != null && owner != _owner) return;
    _gen++;
    _owner = null;
    if (status.value.channelId != null) {
      status.value = PreviewStatus.idle;
      _player?.stop();
    }
  }

  void toggleMute() {
    muted.value = !muted.value;
    _player?.setVolume(muted.value ? 0 : 100);
  }

  /// Vorschau-Player ganz freigeben (Dekoder, Puffer, Verbindung): Der
  /// Vollbild-Player braucht auf schwachen Boxen den Hardware-Dekoder und
  /// den Speicher. Beim nächsten [play] wird er neu angelegt.
  void release() {
    final p = _player;
    if (p == null) return;
    _gen++;
    _owner = null;
    _widthSub?.cancel();
    _widthSub = null;
    _player = null;
    _video = null;
    releases++;
    // Erst die Anzeige leeren (Video-Widget verschwindet mit dem nächsten
    // Bild), dann den Player entsorgen.
    status.value = PreviewStatus.idle;
    SchedulerBinding.instance.addPostFrameCallback((_) => p.dispose());
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  /// Wie oft [release] den Player freigegeben hat (Tests).
  int releases = 0;

  /// Gibt es gerade einen Vorschau-Player?
  bool get alive => _player != null;

  /// Vorschau anhalten, solange [action] läuft (z. B. Vollbild-Player).
  Future<T> whilePaused<T>(Future<T> Function() action) async {
    paused.value++;
    stop();
    release();
    try {
      return await action();
    } finally {
      paused.value--;
    }
  }

  void dispose() {
    _gen++;
    _widthSub?.cancel();
    _player?.dispose();
    _player = null;
    _video = null;
    status.dispose();
    muted.dispose();
    paused.dispose();
  }
}

final livePreviewProvider = Provider<LivePreviewController>((ref) {
  final c = LivePreviewController(ref);
  ref.onDispose(c.dispose);
  return c;
});

/// Kleine, stumme Live-Vorschau (16:9) des fokussierten Senders. Startet erst,
/// wenn der Fokus ~700 ms auf einem Sender ruht, und stoppt, sobald der Tab
/// verlassen, eine Seite darübergelegt oder die App in den Hintergrund
/// geschickt wird. Tippen/OK öffnet den Sender im Vollbild ([onOpen]).
class LivePreview extends ConsumerStatefulWidget {
  final Channel? channel;
  final VoidCallback? onOpen;
  final BorderRadius radius;
  const LivePreview({
    super.key,
    required this.channel,
    this.onOpen,
    this.radius = const BorderRadius.all(Radius.circular(14)),
  });

  @override
  ConsumerState<LivePreview> createState() => _LivePreviewState();
}

class _LivePreviewState extends ConsumerState<LivePreview> {
  static const _debounce = Duration(milliseconds: 700);
  Timer? _timer;
  late final AppLifecycleListener _life;
  bool _foreground = true;
  bool _visible = false; // erster didChangeDependencies-Aufruf startet
  late final LivePreviewController _ctl;
  final _muteFocus = FocusNode(skipTraversal: true, canRequestFocus: false);

  @override
  void initState() {
    super.initState();
    _ctl = ref.read(livePreviewProvider);
    _ctl.paused.addListener(_schedule);
    _life = AppLifecycleListener(onStateChange: (s) {
      final fg = s == AppLifecycleState.resumed;
      if (fg == _foreground) return;
      _foreground = fg;
      _schedule();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Unsichtbar im IndexedStack (anderer Tab) oder von einer Seite verdeckt
    // (Navigator schaltet TickerMode der verdeckten Route ab).
    final v = Visibility.of(context) && TickerMode.valuesOf(context).enabled;
    if (v != _visible) {
      _visible = v;
      _schedule();
    }
  }

  @override
  void didUpdateWidget(LivePreview old) {
    super.didUpdateWidget(old);
    if (old.channel?.id != widget.channel?.id) {
      // Beim Weiterscrollen sofort stoppen, neuen Sender erst nach Pause.
      _ctl.stop(this);
      _schedule();
    }
  }

  bool get _locked {
    final c = widget.channel;
    if (c == null) return false;
    final flags = ref.read(channelFlagsProvider).value ?? ChannelFlags.empty;
    return flags.locked.contains(c.id);
  }

  bool get _enabled => ref.read(livePreviewEnabledProvider).value ?? true;

  void _schedule() {
    _timer?.cancel();
    final c = widget.channel;
    if (!mounted ||
        c == null ||
        !_visible ||
        !_foreground ||
        !_enabled ||
        _locked ||
        ref.read(playbackProvider).active ||
        _ctl.paused.value > 0) {
      _ctl.stop(this);
      return;
    }
    if (_ctl.status.value.channelId == c.id) return;
    _timer = Timer(_debounce, () {
      if (mounted && widget.channel?.id == c.id) _ctl.play(this, c);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _life.dispose();
    _ctl.paused.removeListener(_schedule);
    _ctl.stop(this);
    _muteFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Einstellung/Sperren live beobachten.
    ref.listen(livePreviewEnabledProvider, (_, __) => _schedule());
    ref.listen(channelFlagsProvider, (_, __) => _schedule());
    // Mini-Player/Vollbild läuft → Vorschau aus; danach wieder an.
    ref.listen(playbackProvider.select((s) => s.active), (_, __) => _schedule());
    final c = widget.channel;
    final locked = _locked;

    return FocusableTile(
      radius: widget.radius,
      onTap: widget.onOpen == null
          ? null
          : () {
              _ctl.stop(this);
              widget.onOpen!();
            },
      child: ClipRRect(
        borderRadius: widget.radius,
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: ValueListenableBuilder<PreviewStatus>(
            valueListenable: _ctl.status,
            builder: (context, s, _) {
              final mine = c != null && s.channelId == c.id;
              final showVideo = mine && s.hasVideo && _ctl.video != null;
              return Stack(fit: StackFit.expand, children: [
                const ColoredBox(color: Colors.black),
                if (mine && _ctl.video != null)
                  Video(
                    controller: _ctl.video!,
                    controls: NoVideoControls,
                    fill: Colors.black,
                  ),
                if (!showVideo)
                  GeneratedArt(
                    seed: c?.name ?? '',
                    child: Center(
                      child: c == null
                          ? const SizedBox.shrink()
                          : Column(mainAxisSize: MainAxisSize.min, children: [
                              ChannelLogo(
                                  name: c.name, url: c.logoUrl, size: 48),
                              const SizedBox(height: 12),
                              if (locked)
                                const Icon(Icons.lock_rounded,
                                    color: Colors.white70, size: 22)
                              else if (mine && s.loading)
                                const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2, color: Colors.white70),
                                )
                              else if (mine && s.error)
                                Text(tr('Vorschau nicht verfügbar'),
                                    style: const TextStyle(
                                        fontSize: 12, color: Colors.white70))
                              else
                                const Icon(Icons.play_arrow_rounded,
                                    color: Colors.white70, size: 26),
                            ]),
                    ),
                  ),
                const Positioned(left: 10, top: 10, child: LiveBadge()),
                if (showVideo)
                  Positioned(
                    right: 6,
                    bottom: 6,
                    child: ValueListenableBuilder<bool>(
                      valueListenable: _ctl.muted,
                      builder: (_, m, __) => Material(
                        color: Colors.black45,
                        shape: const CircleBorder(),
                        child: IconButton(
                          // Nur Touch/Maus – D-Pad bleibt auf der Vorschau.
                          focusNode: _muteFocus,
                          tooltip: m ? tr('Ton an') : tr('Ton aus'),
                          iconSize: 18,
                          visualDensity: VisualDensity.compact,
                          color: Colors.white,
                          onPressed: _ctl.toggleMute,
                          icon: Icon(m
                              ? Icons.volume_off_rounded
                              : Icons.volume_up_rounded),
                        ),
                      ),
                    ),
                  ),
              ]);
            },
          ),
        ),
      ),
    );
  }
}

/// Bequemer Helfer: Vorschau während [action] (z. B. Vollbild) anhalten.
Future<T> withPreviewPaused<T>(WidgetRef ref, Future<T> Function() action) =>
    ref.read(livePreviewProvider).whilePaused(action);
