import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../l10n/strings.dart';
import '../../models/models.dart';
import '../../player/data_saver.dart';
import '../../state/providers.dart';
import '../widgets/focusable_tile.dart';

/// Einstellung „Nächste Folge automatisch“ (Standard: an).
const autoNextFlag = 'autonext';

/// Ab dieser Restlaufzeit erscheint die Karte (Abspann).
const nextUpLead = Duration(seconds: 30);

/// Countdown auf der Karte.
const nextUpCountdown = 10;

/// Kürzere Videos (Trailer, Clips) bekommen keine Karte vor dem Ende.
const _minLength = Duration(minutes: 3);

/// „Nächste Folge in 10 s“: beobachtet Position/Länge der laufenden Folge,
/// zeigt im Abspann (letzte 30 s) bzw. am Ende eine Karte und spielt nach
/// Ablauf die nächste Folge – auch über das Staffelende hinweg.
/// OK = jetzt abspielen, Zurück = abbrechen (die Folge läuft zu Ende, danach
/// schließt der Player wie gewohnt).
class NextEpisodeHost extends ConsumerStatefulWidget {
  final PlayRequest request;
  final Stream<Duration> position;
  final Stream<Duration> duration;

  /// Nächste Folge starten (Player tauscht die Anfrage aus).
  final void Function(PlayRequest next) onPlay;

  /// Ende ohne nächste Folge (Player schließen).
  final VoidCallback onExit;

  /// Fokus nach dem Schließen der Karte (der Player selbst).
  final FocusNode? returnFocus;

  const NextEpisodeHost({
    super.key,
    required this.request,
    required this.position,
    required this.duration,
    required this.onPlay,
    required this.onExit,
    this.returnFocus,
  });

  @override
  ConsumerState<NextEpisodeHost> createState() => NextEpisodeHostState();
}

enum _Phase { idle, resolving, showing, dismissed, done }

class NextEpisodeHostState extends ConsumerState<NextEpisodeHost> {
  final _subs = <StreamSubscription>[];
  final _playNode = FocusNode(debugLabel: 'next-up play');
  final _cancelNode = FocusNode(debugLabel: 'next-up cancel');
  _Phase _phase = _Phase.idle;
  Duration _len = Duration.zero;
  NextUp? _next;
  int _left = nextUpCountdown;
  Timer? _tick;
  bool _ended = false;

  /// Karte sichtbar? (für Tests und den Player)
  bool get showing => _phase == _Phase.showing;

  bool get _enabled =>
      widget.request.nextUp != null &&
      (ref.read(storageProvider).value?.flag(autoNextFlag, fallback: true) ??
          true);

  @override
  void initState() {
    super.initState();
    _subs.add(widget.duration.listen((d) => _len = d));
    _subs.add(widget.position.listen(_onPosition));
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _tick?.cancel();
    _playNode.dispose();
    _cancelNode.dispose();
    super.dispose();
  }

  void _onPosition(Duration p) {
    if (_phase != _Phase.idle || _len < _minLength || p <= Duration.zero) {
      return;
    }
    // Datensparmodus: nächste Folge nicht schon im Abspann vorbereiten
    // (erst am Ende).
    if (ref.read(dataSaverActiveProvider)) return;
    if (_len - p <= nextUpLead && _enabled) _resolve();
  }

  /// Wiedergabe zu Ende. true = Karte übernimmt (Player bleibt offen).
  bool onCompleted() {
    _ended = true;
    switch (_phase) {
      case _Phase.showing:
        _commit();
        return true;
      case _Phase.resolving:
        return true;
      case _Phase.idle:
        if (!_enabled) return false;
        _resolve();
        return true;
      case _Phase.dismissed:
      case _Phase.done:
        return false;
    }
  }

  Future<void> _resolve() async {
    _phase = _Phase.resolving;
    NextUp? n;
    try {
      n = await widget.request.nextUp!();
    } catch (_) {
      n = null;
    }
    if (!mounted || _phase != _Phase.resolving) return;
    if (n == null) {
      _phase = _Phase.done;
      if (_ended) widget.onExit();
      return;
    }
    setState(() {
      _next = n;
      _phase = _Phase.showing;
      _left = nextUpCountdown;
    });
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (_left <= 1) {
        _commit();
      } else {
        setState(() => _left--);
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && showing) _playNode.requestFocus();
    });
  }

  /// Jetzt abspielen.
  void _commit() {
    final n = _next;
    if (n == null || _phase != _Phase.showing) return;
    _tick?.cancel();
    setState(() => _phase = _Phase.done);
    // Laufende Folge gilt als gesehen (auch wenn der Abspann fehlt).
    final key = widget.request.resumeKey;
    if (key != null) ref.read(storageProvider).value?.setWatched(key);
    n.onStart?.call();
    widget.onPlay(n.request);
  }

  /// Abbrechen: Folge läuft weiter; am Ende schließt der Player.
  void _cancel() {
    if (_phase != _Phase.showing) return;
    _tick?.cancel();
    setState(() => _phase = _Phase.dismissed);
    widget.returnFocus?.requestFocus();
    if (_ended) widget.onExit();
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) {
      // Loslassen von Zurück ebenfalls schlucken (sonst schließt das
      // System den Player).
      final k = e.logicalKey;
      return k == LogicalKeyboardKey.escape || k == LogicalKeyboardKey.goBack
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.escape || k == LogicalKeyboardKey.goBack) {
      _cancel();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowLeft || k == LogicalKeyboardKey.arrowRight) {
      (_playNode.hasFocus ? _cancelNode : _playNode).requestFocus();
      return KeyEventResult.handled;
    }
    // ▲▼ bleiben in der Karte (sonst landet der Fokus in den Bedienelementen).
    if (k == LogicalKeyboardKey.arrowUp || k == LogicalKeyboardKey.arrowDown) {
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    if (!showing || _next == null) return const SizedBox.shrink();
    final tv = ref.watch(isTvProvider);
    return Positioned(
      right: tv ? 48 : 20,
      bottom: tv ? 56 : 28,
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _cancel();
        },
        child: Focus(
          onKeyEvent: _onKey,
          skipTraversal: true,
          canRequestFocus: false,
          child: NextEpisodeCard(
            key: const ValueKey('next-episode-card'),
            label: _next!.label,
            secondsLeft: _left,
            playNode: _playNode,
            cancelNode: _cancelNode,
            onPlay: _commit,
            onCancel: _cancel,
          ),
        ),
      ),
    );
  }
}

/// Die Karte selbst (auch für Bildschirmfotos/Tests einzeln nutzbar).
class NextEpisodeCard extends StatelessWidget {
  final String label;
  final int secondsLeft;
  final FocusNode? playNode;
  final FocusNode? cancelNode;
  final VoidCallback onPlay;
  final VoidCallback onCancel;
  const NextEpisodeCard({
    super.key,
    required this.label,
    required this.secondsLeft,
    required this.onPlay,
    required this.onCancel,
    this.playNode,
    this.cancelNode,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Material(
      color: Colors.transparent,
      child: Container(
        width: 360,
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
        decoration: BoxDecoration(
          color: AppColors.surface.withValues(alpha: 0.96),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.line),
          boxShadow: const [
            BoxShadow(color: Color(0x88000000), blurRadius: 30),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  value: secondsLeft / nextUpCountdown,
                  strokeWidth: 2.5,
                  color: AppColors.accent,
                  backgroundColor: AppColors.line,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                    trf('Nächste Folge in {0} s', [secondsLeft]),
                    style: t.labelLarge?.copyWith(
                        color: AppColors.textDim,
                        fontWeight: FontWeight.w600)),
              ),
            ]),
            const SizedBox(height: 10),
            Text(label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: t.titleMedium?.copyWith(color: AppColors.text)),
            const SizedBox(height: 14),
            Row(children: [
              Expanded(
                child: _CardButton(
                  node: playNode,
                  primary: true,
                  icon: Icons.play_arrow_rounded,
                  label: tr('Jetzt abspielen'),
                  onTap: onPlay,
                ),
              ),
              const SizedBox(width: 10),
              _CardButton(
                node: cancelNode,
                icon: Icons.close_rounded,
                label: tr('Abbrechen'),
                onTap: onCancel,
              ),
            ]),
          ],
        ),
      ),
    );
  }
}

class _CardButton extends StatelessWidget {
  final FocusNode? node;
  final bool primary;
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _CardButton({
    required this.node,
    required this.icon,
    required this.label,
    required this.onTap,
    this.primary = false,
  });

  @override
  Widget build(BuildContext context) {
    final fg = primary ? const Color(0xFF1A0B04) : AppColors.text;
    return FocusableTile(
      focusNode: node,
      onTap: onTap,
      radius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        decoration: BoxDecoration(
          color: primary ? AppColors.accent : AppColors.surface2,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 20, color: fg),
            const SizedBox(width: 6),
            Flexible(
              child: Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: fg, fontWeight: FontWeight.w700, fontSize: 14)),
            ),
          ],
        ),
      ),
    );
  }
}

/// Einstellungs-Eintrag „Nächste Folge automatisch“ (wie die übrigen
/// Schalter der Einstellungen: ganze Zeile schaltet, D-Pad-fähig).
class NextEpisodeTile extends ConsumerWidget {
  const NextEpisodeTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(storageProvider).value;
    if (st == null) return const SizedBox.shrink();
    final t = Theme.of(context).textTheme;
    return StatefulBuilder(builder: (context, setState) {
      final on = st.flag(autoNextFlag, fallback: true);
      return FocusableTile(
        key: const ValueKey('next-episode-tile'),
        onTap: () async {
          await st.setFlag(autoNextFlag, !on);
          setState(() {});
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Row(children: [
            const Icon(Icons.skip_next_rounded,
                color: AppColors.textDim, size: 22),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(tr('Nächste Folge automatisch'),
                        style: t.titleSmall?.copyWith(fontSize: 15)),
                    const SizedBox(height: 2),
                    Text(
                        tr('Im Abspann „Nächste Folge in 10 s“ zeigen und '
                            'weiterspielen'),
                        style: t.bodySmall),
                  ]),
            ),
            IgnorePointer(
              child: ExcludeFocus(
                child: Switch(
                  value: on,
                  onChanged: (_) {},
                  activeThumbColor: AppColors.accent,
                ),
              ),
            ),
          ]),
        ),
      );
    });
  }
}
