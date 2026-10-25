import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import 'package:flutter/services.dart';

import '../../core/theme.dart';
import '../tv/tv_safe.dart' show TvLook;

/// Ein Eintrag, der auf Touch *und* D-Pad (Android TV) funktioniert:
/// Fokus-Rahmen, OK/Enter löst [onTap] aus, Menü-Taste oder langes Drücken
/// löst [onLongPress] aus. [onFocus] meldet, wenn der Eintrag Fokus bekommt
/// (z. B. für die Live-Vorschau).
class FocusableTile extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onFocus;
  final bool autofocus;
  final bool selected;
  final BorderRadius radius;
  final bool scaleOnFocus;
  final FocusNode? focusNode;

  /// Vorlesetext für TalkBack. Gesetzt ersetzt er die Texte im Inhalt
  /// (z. B. „Das Erste, jetzt: Tagesschau“ statt einzelner Bruchstücke);
  /// sonst werden die Texte des Inhalts zu einem Eintrag zusammengefasst.
  final String? semanticLabel;

  /// „Ausgewählt“ für TalkBack, ohne die Hervorhebung von [selected]
  /// (z. B. gewählter Staffel-Reiter mit eigener Farbe).
  final bool? semanticSelected;

  const FocusableTile({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.onFocus,
    this.autofocus = false,
    this.selected = false,
    this.radius = const BorderRadius.all(Radius.circular(12)),
    this.scaleOnFocus = false,
    this.focusNode,
    this.semanticLabel,
    this.semanticSelected,
  });

  @override
  State<FocusableTile> createState() => _FocusableTileState();
}

class _FocusableTileState extends State<FocusableTile> {
  // Fokus/Hover als Notifier: Bei ▲/▼ baut nur die Dekoration (Rahmen,
  // Skalierung) neu, nicht Semantik, Aktionen und Gesten der Kachel.
  final _focused = ValueNotifier(false);
  final _hover = ValueNotifier(false);

  @override
  void dispose() {
    _focused.dispose();
    _hover.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final label = widget.semanticLabel;
    // Ein Eintrag = ein TalkBack-Element (Schaltfläche, ggf. „ausgewählt“).
    return MergeSemantics(
        child: Semantics(
            button: widget.onTap != null,
            // Nur „ausgewählt“ melden – nicht bei jeder Kachel „nicht
            // ausgewählt“.
            selected: (widget.semanticSelected ?? widget.selected) ? true : null,
            child: FocusableActionDetector(
              focusNode: widget.focusNode,
              autofocus: widget.autofocus,
              onShowHoverHighlight: (h) => _hover.value = h,
              onFocusChange: (f) {
                _focused.value = f;
                if (f) {
                  widget.onFocus?.call();
                  Scrollable.ensureVisible(context,
                      alignment: 0.5,
                      duration: const Duration(milliseconds: 160));
                }
              },
              shortcuts: _shortcuts,
              actions: {
                ActivateIntent: CallbackAction<ActivateIntent>(
                  onInvoke: (_) => widget.onTap?.call(),
                ),
                _MenuIntent: CallbackAction<_MenuIntent>(
                  onInvoke: (_) => widget.onLongPress?.call(),
                ),
              },
              mouseCursor: SystemMouseCursors.click,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: widget.onTap,
                // Touch-Langdruck: kurzes Vibrieren wie in nativen Apps
                // (Fernbedienung nutzt den Intent oben, ohne Haptik).
                onLongPress: widget.onLongPress == null
                    ? null
                    : () {
                        Feedback.forLongPress(context);
                        widget.onLongPress!();
                      },
                child: _TileDecor(
                  focused: _focused,
                  hover: _hover,
                  selected: widget.selected,
                  scaleOnFocus: widget.scaleOnFocus,
                  radius: widget.radius,
                  child: label == null
                      ? widget.child
                      : Semantics(
                          label: label,
                          excludeSemantics: true,
                          child: widget.child),
                ),
              ),
            )));
  }

  static const _shortcuts = <ShortcutActivator, Intent>{
    SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
    SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
    SingleActivator(LogicalKeyboardKey.gameButtonA): ActivateIntent(),
    SingleActivator(LogicalKeyboardKey.contextMenu): _MenuIntent(),
  };
}

/// Rahmen, Hintergrund und Skalierung einer [FocusableTile] – baut bei
/// Fokus/Hover allein neu ([child] bleibt unangetastet).
class _TileDecor extends StatelessWidget {
  final ValueListenable<bool> focused, hover;
  final bool selected, scaleOnFocus;
  final BorderRadius radius;
  final Widget child;
  const _TileDecor({
    required this.focused,
    required this.hover,
    required this.selected,
    required this.scaleOnFocus,
    required this.radius,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    // Fernseher: Fokus-Hof ohne Weichzeichnung (ein Rechteck statt eines
    // teuren Blur-Schattens), etwas weniger Vergrößerung.
    final tv = TvLook.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([focused, hover]),
      child: child,
      builder: (context, child) {
        final f = focused.value;
        final h = hover.value;
        final active = f || h;
        return AnimatedScale(
          scale: scaleOnFocus && f ? (tv ? 1.05 : 1.06) : 1,
          duration: const Duration(milliseconds: 140),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            decoration: BoxDecoration(
              color: f
                  ? AppColors.surface3
                  : selected
                      ? AppColors.surface2
                      : h
                          ? AppColors.surface
                          : Colors.transparent,
              borderRadius: radius,
              border: Border.all(
                color: f ? AppColors.accent : Colors.transparent,
                width: 2,
              ),
              // Fernseher: Hof aus zwei scharfen Ringen (zwei gefüllte
              // Rechtecke) statt eines 24-px-Weichzeichners.
              boxShadow: f && scaleOnFocus
                  ? tv
                      ? [
                          BoxShadow(
                            color: AppColors.accent.withValues(alpha: 0.07),
                            spreadRadius: 5,
                          ),
                          BoxShadow(
                            color: AppColors.accent.withValues(alpha: 0.12),
                            spreadRadius: 2,
                          ),
                        ]
                      : [
                          BoxShadow(
                            color: AppColors.accent.withValues(alpha: 0.25),
                            blurRadius: 24,
                          )
                        ]
                  : null,
            ),
            foregroundDecoration: active || !selected
                ? null
                : BoxDecoration(
                    borderRadius: radius,
                    border: Border(
                        left: BorderSide(color: AppColors.accent, width: 3)),
                  ),
            child: child,
          ),
        );
      },
    );
  }
}

class _MenuIntent extends Intent {
  const _MenuIntent();
}

/// Kleine Kennzeichnung (LIVE, HD, CATCH-UP …).
class Tag extends StatelessWidget {
  final String text;
  final Color color;
  final bool filled;
  final IconData? icon;
  const Tag(this.text,
      {super.key,
      this.color = AppColors.textDim,
      this.filled = false,
      this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: filled ? color : color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[
          Icon(icon, size: 11, color: filled ? Colors.white : color),
          const SizedBox(width: 3),
        ],
        Text(
          text,
          style: TextStyle(
            fontFamily: 'Inter',
            fontSize: 10,
            height: 1.3,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.4,
            color: filled ? Colors.white : color,
          ),
        ),
      ]),
    );
  }
}

/// Live-Punkt mit „LIVE“.
class LiveBadge extends StatelessWidget {
  const LiveBadge({super.key});
  @override
  Widget build(BuildContext context) =>
      Tag(tr('LIVE'), color: AppColors.live, filled: true);
}
