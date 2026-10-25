import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../l10n/strings.dart';
import '../../state/playback_session.dart';
import '../../state/providers.dart';
import '../nav.dart' show openPlayerAttached;
import '../shell/reminder_host.dart' show appNavigatorKey;
import '../widgets/artwork.dart';
import 'cast_ui.dart';

/// Legt den Mini-Player über die ganze App (alle Tabs, Detailseiten).
/// Sichtbar, wenn ein Stream läuft und die Player-Seite nicht offen ist –
/// nur Handy/Tablet.
class MiniPlayerHost extends ConsumerWidget {
  final Widget child;
  const MiniPlayerHost({super.key, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tv = ref.watch(isTvProvider);
    final show = !tv && ref.watch(playbackProvider.select((s) => s.showMini));
    return Stack(children: [
      child,
      if (show) const MiniPlayer(),
    ]);
  }
}

/// Ecke, in der der Mini-Player liegt (an Ecken einrasten).
enum MiniCorner { topLeft, topRight, bottomLeft, bottomRight }

/// Kleine Videofläche mit Titel, Play/Pause, Nur-Ton und Schließen.
/// Ziehen verschiebt (rastet an Ecken ein), Antippen öffnet das Vollbild
/// mit derselben Player-Instanz, Wischen nach unten stoppt.
class MiniPlayer extends ConsumerStatefulWidget {
  const MiniPlayer({super.key});

  /// Breite der Videofläche.
  static const width = 224.0;
  static const videoHeight = width * 9 / 16;
  static const barHeight = 48.0;
  static const margin = 12.0;

  /// Abstand unten über der Navigationsleiste der Shell.
  static const bottomInset = 84.0;

  /// Gemerkte Ecke (bleibt über Ein-/Ausblenden erhalten).
  static MiniCorner corner = MiniCorner.bottomRight;

  @override
  ConsumerState<MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends ConsumerState<MiniPlayer> {
  Offset? _drag;

  Rect _bounds(Size size, EdgeInsets pad) => Rect.fromLTRB(
        MiniPlayer.margin,
        pad.top + MiniPlayer.margin,
        size.width - MiniPlayer.margin,
        size.height - pad.bottom - MiniPlayer.bottomInset,
      );

  Offset _cornerOffset(MiniCorner c, Rect b) {
    const w = MiniPlayer.width;
    const h = MiniPlayer.videoHeight + MiniPlayer.barHeight;
    return switch (c) {
      MiniCorner.topLeft => Offset(b.left, b.top),
      MiniCorner.topRight => Offset(b.right - w, b.top),
      MiniCorner.bottomLeft => Offset(b.left, b.bottom - h),
      MiniCorner.bottomRight => Offset(b.right - w, b.bottom - h),
    };
  }

  MiniCorner _nearest(Offset o, Rect b) {
    const w = MiniPlayer.width;
    const h = MiniPlayer.videoHeight + MiniPlayer.barHeight;
    final cx = o.dx + w / 2, cy = o.dy + h / 2;
    final left = cx < b.center.dx;
    final top = cy < b.center.dy;
    return top
        ? (left ? MiniCorner.topLeft : MiniCorner.topRight)
        : (left ? MiniCorner.bottomLeft : MiniCorner.bottomRight);
  }

  /// Kontext unter dem Navigator (für Blätter/Dialoge).
  BuildContext _navContext() =>
      appNavigatorKey.currentState?.overlay?.context ?? context;

  void _open() {
    final ctl = ref.read(playbackProvider.notifier);
    final s = ctl.session;
    if (s == null) return;
    // Läuft auf dem Fernseher: Steuerung/Trennen statt Vollbild.
    if (ctl.casting) {
      showCastSheet(_navContext(), ref);
      return;
    }
    ctl.toFullscreen();
    openPlayerAttached(s.request);
  }

  @override
  Widget build(BuildContext context) {
    final snap = ref.watch(playbackProvider);
    final ctl = ref.read(playbackProvider.notifier);
    final engine = ctl.session?.engine;
    final size = MediaQuery.sizeOf(context);
    final pad = MediaQuery.paddingOf(context);
    final b = _bounds(size, pad);
    final pos = _drag ?? _cornerOffset(MiniPlayer.corner, b);
    final video = snap.audioOnly || snap.casting
        ? null
        : engine?.buildVideo(fit: BoxFit.contain, aspectRatio: 16 / 9);
    final t = Theme.of(context).textTheme;

    return AnimatedPositioned(
      key: const ValueKey('mini-player'),
      duration: _drag == null
          ? const Duration(milliseconds: 220)
          : Duration.zero,
      curve: Curves.easeOutCubic,
      left: pos.dx,
      top: pos.dy,
      width: MiniPlayer.width,
      child: Semantics(
        label: tr('Mini-Player'),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _open,
          onPanStart: (d) => setState(() => _drag = pos),
          onPanUpdate: (d) => setState(() => _drag = _drag! + d.delta),
          onPanEnd: (d) {
            final v = d.velocity.pixelsPerSecond;
            final o = _drag ?? pos;
            setState(() => _drag = null);
            // Wischen nach unten (schnell, kaum seitlich) → Stopp.
            if (v.dy > 900 && v.dy.abs() > v.dx.abs() * 2) {
              ctl.stop();
              return;
            }
            MiniPlayer.corner = _nearest(o, b);
          },
          child: Material(
            elevation: 10,
            color: AppColors.surface,
            clipBehavior: Clip.antiAlias,
            borderRadius: BorderRadius.circular(14),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              SizedBox(
                height: MiniPlayer.videoHeight,
                child: Stack(fit: StackFit.expand, children: [
                  if (video != null && snap.hasVideo)
                    video
                  else
                    _Art(snap: snap),
                  if (snap.casting)
                    Center(
                      child: Column(
                        key: const ValueKey('mini-casting'),
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.cast_connected_rounded,
                              color: Colors.white, size: 30),
                          const SizedBox(height: 4),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            child: Text(
                              trf('Läuft auf {0}', [snap.castDevice!]),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600),
                            ),
                          ),
                        ],
                      ),
                    )
                  else if (snap.audioOnly)
                    Center(
                      child: Icon(Icons.headphones_rounded,
                          key: const ValueKey('mini-audio-only'),
                          color: Colors.white, size: 34),
                    ),
                  if (snap.buffering && !snap.audioOnly && !snap.casting)
                    const Center(
                      child: SizedBox(
                        width: 26,
                        height: 26,
                        child: CircularProgressIndicator(strokeWidth: 2.5),
                      ),
                    ),
                  if (snap.live)
                    Positioned(
                      left: 8,
                      top: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: AppColors.live,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Text('LIVE',
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.w800)),
                      ),
                    ),
                ]),
              ),
              SizedBox(
                height: MiniPlayer.barHeight,
                child: Row(children: [
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(snap.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: t.bodyMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                                color: AppColors.text)),
                        if (snap.subtitle != null && snap.subtitle!.isNotEmpty)
                          Text(snap.subtitle!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: t.bodySmall
                                  ?.copyWith(color: AppColors.textDim)),
                      ],
                    ),
                  ),
                  CastButton(
                      style: CastButtonStyle.mini, dialogContext: _navContext),
                  if (!snap.casting)
                  _Btn(
                    key: const ValueKey('mini-audio-toggle'),
                    icon: snap.audioOnly
                        ? Icons.videocam_rounded
                        : Icons.headphones_rounded,
                    tooltip: snap.audioOnly ? tr('Video wieder an') : tr('Nur Ton'),
                    onTap: () => ctl.setAudioOnly(!snap.audioOnly),
                  ),
                  _Btn(
                    key: const ValueKey('mini-play-pause'),
                    icon: snap.playing
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                    tooltip: snap.playing ? tr('Pause') : tr('Abspielen'),
                    onTap: ctl.playPause,
                  ),
                  _Btn(
                    key: const ValueKey('mini-close'),
                    icon: snap.casting ? Icons.stop_rounded : Icons.close_rounded,
                    tooltip: snap.casting ? tr('Stopp') : tr('Schließen'),
                    onTap: ctl.stop,
                  ),
                  const SizedBox(width: 2),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _Art extends StatelessWidget {
  final PlaybackSnapshot snap;
  const _Art({required this.snap});

  @override
  Widget build(BuildContext context) => Stack(fit: StackFit.expand, children: [
        NetworkArt(url: snap.live ? null : snap.artUrl, seed: snap.title),
        Container(color: Colors.black.withValues(alpha: 0.35)),
        if (snap.live && !snap.audioOnly && !snap.casting)
          Center(child: ChannelLogo(name: snap.title, url: snap.artUrl, size: 40)),
      ]);
}

class _Btn extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  const _Btn(
      {super.key,
      required this.icon,
      required this.tooltip,
      required this.onTap});

  // Kein Tooltip: der Mini-Player liegt über dem Navigator (kein Overlay);
  // TalkBack bekommt den Text als Semantik.
  @override
  Widget build(BuildContext context) => Semantics(
        label: tooltip,
        button: true,
        child: IconButton(
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
          onPressed: onTap,
          icon: Icon(icon, size: 22, color: AppColors.text),
        ),
      );
}
