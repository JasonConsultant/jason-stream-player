import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../l10n/strings.dart';
import '../widgets/focusable_tile.dart';

/// Anzeigename einer Akzentfarbe.
String accentLabel(String key) => switch (key) {
      'blau' => tr('Blau'),
      'gruen' => tr('Grün'),
      'lila' => tr('Lila'),
      'rot' => tr('Rot'),
      'tuerkis' => tr('Türkis'),
      _ => tr('Orange'),
    };

/// „Akzentfarbe“: sechs Farbfelder nebeneinander – Touch und D-Pad
/// (◀/▶ wählen, OK übernimmt). Wirkt sofort in der ganzen App.
class AccentPicker extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;
  const AccentPicker({super.key, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.palette_rounded, color: AppColors.textDim, size: 22),
          const SizedBox(width: 16),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr('Akzentfarbe'),
                  style: t.titleSmall?.copyWith(fontSize: 15)),
              const SizedBox(height: 2),
              Text(
                  trf('Fokus, Schalter und Hervorhebungen · {0}',
                      [accentLabel(value)]),
                  style: t.bodySmall),
            ]),
          ),
        ]),
        const SizedBox(height: 10),
        Padding(
          padding: const EdgeInsets.only(left: 30),
          child: Wrap(spacing: 6, runSpacing: 6, children: [
            for (final e in AppColors.accentPresets.entries)
              _Swatch(
                key: ValueKey('accent_${e.key}'),
                color: e.value,
                label: accentLabel(e.key),
                selected: e.key == value,
                onTap: () => onChanged(e.key),
              ),
          ]),
        ),
      ]),
    );
  }
}

class _Swatch extends StatelessWidget {
  final Color color;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _Swatch({
    super.key,
    required this.color,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => Tooltip(
        message: label,
        excludeFromSemantics: true,
        child: FocusableTile(
          semanticLabel: selected ? trf('{0}, ausgewählt', [label]) : label,
          radius: BorderRadius.circular(28),
          scaleOnFocus: true,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(
                    color: selected ? AppColors.text : Colors.transparent,
                    width: 3),
              ),
              child: selected
                  ? const Icon(Icons.check_rounded,
                      color: Color(0xFF1A0B04), size: 22)
                  : null,
            ),
          ),
        ),
      );
}
