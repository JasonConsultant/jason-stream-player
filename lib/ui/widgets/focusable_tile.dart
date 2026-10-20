import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import 'package:flutter/services.dart';

import '../../core/theme.dart';

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
  });

  @override
  State<FocusableTile> createState() => _FocusableTileState();
}

class _FocusableTileState extends State<FocusableTile> {
  bool _focused = false;
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final active = _focused || _hover;
    return FocusableActionDetector(
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      onShowHoverHighlight: (h) => setState(() => _hover = h),
      onFocusChange: (f) {
        setState(() => _focused = f);
        if (f) {
          widget.onFocus?.call();
          Scrollable.ensureVisible(context,
              alignment: 0.5, duration: const Duration(milliseconds: 160));
        }
      },
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.gameButtonA): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.contextMenu): _MenuIntent(),
      },
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
        onLongPress: widget.onLongPress,
        child: AnimatedScale(
          scale: widget.scaleOnFocus && _focused ? 1.06 : 1,
          duration: const Duration(milliseconds: 140),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            decoration: BoxDecoration(
              color: _focused
                  ? AppColors.surface3
                  : widget.selected
                      ? AppColors.surface2
                      : _hover
                          ? AppColors.surface
                          : Colors.transparent,
              borderRadius: widget.radius,
              border: Border.all(
                color: _focused ? AppColors.accent : Colors.transparent,
                width: 2,
              ),
              boxShadow: _focused && widget.scaleOnFocus
                  ? [
                      BoxShadow(
                        color: AppColors.accent.withValues(alpha: 0.25),
                        blurRadius: 24,
                      )
                    ]
                  : null,
            ),
            foregroundDecoration: active || !widget.selected
                ? null
                : BoxDecoration(
                    borderRadius: widget.radius,
                    border: const Border(
                        left: BorderSide(color: AppColors.accent, width: 3)),
                  ),
            child: widget.child,
          ),
        ),
      ),
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
      {super.key, this.color = AppColors.textDim, this.filled = false, this.icon});

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
