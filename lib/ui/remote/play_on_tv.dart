import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/remote/content_ref.dart';
import '../../core/theme.dart';
import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../../state/remote.dart';
import '../../state/remote_link.dart';
import '../vod/movie_detail_screen.dart' show GhostButton;

/// Knopf „Auf dem TV abspielen“ (Handy): nur sichtbar, wenn ein Fernseher
/// gekoppelt und erreichbar ist. Übergibt nur die Kennung des Inhalts
/// ([ContentRef]); der Fernseher öffnet ihn aus seinem eigenen Portal.
class PlayOnTvButton extends ConsumerStatefulWidget {
  /// Kennung erst beim Drücken bilden (Stelle „Weiterschauen“ aktuell).
  final ContentRef? Function(WidgetRef ref) content;

  /// Zeile für Menüs (Sender-Blatt) statt Umriss-Knopf.
  final bool tile;
  const PlayOnTvButton({super.key, required this.content, this.tile = false});

  @override
  ConsumerState<PlayOnTvButton> createState() => _PlayOnTvButtonState();
}

class _PlayOnTvButtonState extends ConsumerState<PlayOnTvButton> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // Erreichbarkeit prüfen (verbindet im Hintergrund, ohne zu warten).
    WidgetsBinding.instance.addPostFrameCallback((_) => _probe());
  }

  void _probe() {
    if (!mounted || ref.read(isTvProvider)) return;
    if (ref.read(remoteTvsProvider).isEmpty) return;
    final s = ref.read(remoteLinkProvider);
    if (s.phase == LinkPhase.idle || s.phase == LinkPhase.none) {
      unawaited(ref.read(remoteLinkProvider.notifier).connect());
    }
  }

  Future<void> _go() async {
    if (_busy) return;
    final r = widget.content(ref);
    final messenger = ScaffoldMessenger.maybeOf(context);
    void say(String s) => messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(s)));
    if (r == null) {
      say(remoteErrorText('notAvailable'));
      return;
    }
    HapticFeedback.lightImpact();
    setState(() => _busy = true);
    final err = await ref.read(remoteLinkProvider.notifier).playOnTv(r);
    if (!mounted) return;
    setState(() => _busy = false);
    final tv = ref.read(remoteLinkProvider).tv?.name ?? 'TV';
    say(err == null
        ? trf('Läuft jetzt auf „{0}“.', [tv])
        : remoteErrorText(err));
  }

  @override
  Widget build(BuildContext context) {
    if (ref.watch(isTvProvider)) return const SizedBox.shrink();
    // Fernseher erst nach dem Laden des Speichers bekannt → dann prüfen.
    ref.listen(remoteTvsProvider, (prev, next) {
      if ((prev?.isEmpty ?? true) && next.isNotEmpty) Future.microtask(_probe);
    });
    final s = ref.watch(remoteLinkProvider);
    if (!s.connected) return const SizedBox.shrink();
    if (widget.tile) {
      return ListTile(
        key: const ValueKey('play-on-tv'),
        leading: _busy
            ? const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2))
            : Icon(Icons.connected_tv_rounded, color: AppColors.accent),
        title: Text(tr('Auf dem TV abspielen')),
        subtitle: Text(s.tv?.name ?? ''),
        onTap: _go,
      );
    }
    return GhostButton(
      key: const ValueKey('play-on-tv'),
      icon: Icons.connected_tv_rounded,
      label: tr('Auf dem TV abspielen'),
      onTap: _go,
    );
  }
}
