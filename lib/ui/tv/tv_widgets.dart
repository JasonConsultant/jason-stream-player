import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../widgets/common.dart';
import '../widgets/focusable_tile.dart';

/// Ruhige, dichte Gestaltung für Android TV (Stil wie TiviMate):
/// dunkler Grund, wenige Flächen, kleine Kapitälchen-Überschriften.
/// Nur in den TV-Zweigen der Bildschirme verwendet.
class TvColors {
  static const bg = Color(0xFF090B10);
  static const panel = Color(0xFF0E1117);
  static const surface = Color(0xFF121722);
  static const surface2 = Color(0xFF1B2130);
  static const line = Color(0xFF1A1F29);
  static const text = Color(0xFFE9ECF2);
  static const textDim = Color(0xFF9AA3B2);
  static const textFaint = Color(0xFF6B7383);
  static const onLight = Color(0xFF0B0D12);
}

class TvText {
  /// Kapitälchen-Überschrift („ZULETZT GESEHEN“).
  static const caps = TextStyle(
      fontFamily: 'Inter',
      fontSize: 7.5,
      height: 1.2,
      fontWeight: FontWeight.w600,
      letterSpacing: 1.0,
      color: TvColors.textFaint);

  static const title = TextStyle(
      fontFamily: 'Inter',
      fontSize: 17,
      height: 1.15,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.2,
      color: TvColors.text);

  static const name = TextStyle(
      fontFamily: 'Inter',
      fontSize: 9.5,
      height: 1.2,
      fontWeight: FontWeight.w600,
      color: TvColors.text);

  static const body = TextStyle(
      fontFamily: 'Inter',
      fontSize: 8.5,
      height: 1.25,
      color: TvColors.textDim);

  static const small = TextStyle(
      fontFamily: 'Inter',
      fontSize: 8,
      height: 1.2,
      color: TvColors.textFaint,
      fontFeatures: [FontFeature.tabularFigures()]);
}

/// Äußerer Rand der TV-Bildschirme.
const tvPad = 22.0;

/// Kapitälchen-Überschrift mit optionalem Element rechts.
class TvCaps extends StatelessWidget {
  final String text;
  final Widget? trailing;
  final EdgeInsets padding;
  const TvCaps(this.text,
      {super.key, this.trailing, this.padding = EdgeInsets.zero});

  @override
  Widget build(BuildContext context) => Padding(
        padding: padding,
        child: Row(children: [
          Expanded(
            // TalkBack: Überschrift, normal geschrieben vorlesen (nicht
            // Buchstabe für Buchstabe).
            child: Semantics(
              container: true,
              header: true,
              child: Text(text.toUpperCase(),
                  semanticsLabel: text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TvText.caps),
            ),
          ),
          if (trailing != null) trailing!,
        ]),
      );
}

/// Kleine Pille (15 dp hoch): Filter- oder Aktions-Chip, D-Pad-fähig.
/// [selected] = hell gefüllt, [primary] = Akzentfarbe.
class TvChip extends StatelessWidget {
  final String label;
  final IconData? icon;
  final bool selected;
  final bool primary;
  final Color? color;
  final bool autofocus;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final FocusNode? focusNode;
  const TvChip({
    super.key,
    required this.label,
    this.icon,
    this.selected = false,
    this.primary = false,
    this.color,
    this.autofocus = false,
    this.onTap,
    this.onLongPress,
    this.focusNode,
  });

  @override
  Widget build(BuildContext context) {
    final bg = primary
        ? AppColors.accent
        : selected
            ? TvColors.text
            : TvColors.surface;
    final fg = primary
        ? const Color(0xFF1A0B04)
        : selected
            ? TvColors.onLight
            : (color ?? TvColors.textDim);
    const radius = BorderRadius.all(Radius.circular(10));
    return FocusableTile(
      focusNode: focusNode,
      autofocus: autofocus,
      radius: radius,
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        height: 17,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(color: bg, borderRadius: radius),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[
            Icon(icon, size: 9.5, color: fg),
            const SizedBox(width: 3),
          ],
          Text(label,
              maxLines: 1,
              style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 8,
                  height: 1.1,
                  fontWeight:
                      selected || primary ? FontWeight.w600 : FontWeight.w500,
                  color: fg)),
        ]),
      ),
    );
  }
}

/// Kleines rundes Symbol (z. B. Sortieren, Suche) für TV-Kopfzeilen.
class TvIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool active;
  const TvIconButton(
      {super.key,
      required this.icon,
      required this.tooltip,
      required this.onTap,
      this.active = false});

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: FocusableTile(
          radius: const BorderRadius.all(Radius.circular(8)),
          onTap: onTap,
          child: SizedBox(
            width: 22,
            height: 22,
            child: Icon(icon,
                size: 12.5,
                color: active ? AppColors.accent : TvColors.textDim),
          ),
        ),
      );
}

/// Kompakte TV-Fassung des gemeinsamen [SearchField] (D-Pad-fähig: ▲▼
/// verlassen das Feld, Tastatur erst nach OK) – nur verkleinert dargestellt.
class TvSearchField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final ValueChanged<String> onChanged;
  final double width;
  const TvSearchField({
    super.key,
    required this.controller,
    required this.hint,
    required this.onChanged,
    this.width = 150,
  });

  static const _scale = 0.6;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: width,
        height: 44 * _scale,
        child: FittedBox(
          fit: BoxFit.contain,
          alignment: Alignment.centerLeft,
          child: SearchField(
            controller: controller,
            hint: hint,
            width: width / _scale,
            onChanged: onChanged,
          ),
        ),
      );
}

/// Dünner Fortschrittsbalken in TV-Optik.
class TvProgress extends StatelessWidget {
  final double value;
  final double height;
  final double? width;
  const TvProgress(
      {super.key, required this.value, this.height = 2, this.width});

  @override
  Widget build(BuildContext context) {
    final v = value.isNaN ? 0.0 : value.clamp(0.0, 1.0);
    return SizedBox(
      width: width,
      height: height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xFF232A36),
          borderRadius: BorderRadius.circular(height),
        ),
        child: FractionallySizedBox(
          alignment: Alignment.centerLeft,
          widthFactor: v,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: AppColors.accent,
              borderRadius: BorderRadius.circular(height),
            ),
          ),
        ),
      ),
    );
  }
}
