import 'package:flutter/material.dart';

import '../../core/subtitle_style.dart';
import '../../core/theme.dart';
import '../../l10n/strings.dart';

/// Untertitel-Aussehen wählen: Größe, Farbe, Hintergrund, Rand – mit
/// Live-Vorschau (angenäherte Flutter-Darstellung des mpv-Stils).
/// Liefert den neuen Stil oder null (abgebrochen).
Future<SubtitleStyle?> showSubtitleStyleDialog(
    BuildContext context, SubtitleStyle current) {
  return showDialog<SubtitleStyle>(
    context: context,
    builder: (ctx) => _SubtitleStyleDialog(initial: current),
  );
}

class _SubtitleStyleDialog extends StatefulWidget {
  final SubtitleStyle initial;
  const _SubtitleStyleDialog({required this.initial});

  @override
  State<_SubtitleStyleDialog> createState() => _SubtitleStyleDialogState();
}

class _SubtitleStyleDialogState extends State<_SubtitleStyleDialog> {
  late SubtitleStyle _style = widget.initial;

  static String sizeLabel(String s) => switch (s) {
        'klein' => tr('Klein'),
        'gross' => tr('Groß'),
        'sehrgross' => tr('Sehr groß'),
        _ => tr('Normal'),
      };

  static String colorLabel(String c) => switch (c) {
        'gelb' => tr('Gelb'),
        'cyan' => tr('Cyan'),
        _ => tr('Weiß'),
      };

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    // mpv-Größe bezieht sich auf 720p; Vorschau skaliert auf ~1/3.
    final previewSize = _style.fontSize / 3 + 4;
    return AlertDialog(
      title: Text(tr('Untertitel-Aussehen')),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Vorschau auf „Video“-Hintergrund
              Container(
                height: 110,
                alignment: Alignment.bottomCenter,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  gradient: const LinearGradient(
                    colors: [Color(0xFF2B3A55), Color(0xFF151B2A)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: _style.box ? const Color(0x80000000) : Colors.transparent,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    tr('Beispiel-Untertitel'),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: previewSize,
                      fontWeight: FontWeight.w600,
                      color: Color(_style.colorArgb),
                      shadows: _style.outline
                          ? const [
                              Shadow(offset: Offset(-1.2, -1.2), color: Colors.black),
                              Shadow(offset: Offset(1.2, -1.2), color: Colors.black),
                              Shadow(offset: Offset(-1.2, 1.2), color: Colors.black),
                              Shadow(offset: Offset(1.2, 1.2), color: Colors.black),
                            ]
                          : const [],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(tr('Größe'), style: t.labelSmall),
              const SizedBox(height: 6),
              _Chips(
                // Fernbedienung: Start auf der gewählten Größe.
                autofocus: true,
                values: SubtitleStyle.sizes,
                selected: _style.size,
                label: sizeLabel,
                onPick: (v) => setState(() => _style = _style.copy(size: v)),
              ),
              const SizedBox(height: 12),
              Text(tr('Farbe'), style: t.labelSmall),
              const SizedBox(height: 6),
              _Chips(
                values: SubtitleStyle.colors,
                selected: _style.color,
                label: colorLabel,
                onPick: (v) => setState(() => _style = _style.copy(color: v)),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(tr('Hintergrund-Kasten')),
                subtitle: Text(tr('Halbtransparent hinter dem Text')),
                value: _style.box,
                activeThumbColor: AppColors.accent,
                onChanged: (v) => setState(() => _style = _style.copy(box: v)),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(tr('Rand um die Schrift')),
                value: _style.outline,
                activeThumbColor: AppColors.accent,
                onChanged: (v) =>
                    setState(() => _style = _style.copy(outline: v)),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(tr('Abbrechen'))),
        FilledButton(
            onPressed: () => Navigator.pop(context, _style),
            child: Text(tr('Übernehmen'))),
      ],
    );
  }
}

class _Chips extends StatelessWidget {
  final List<String> values;
  final String selected;
  final String Function(String) label;
  final ValueChanged<String> onPick;
  final bool autofocus;
  const _Chips(
      {required this.values,
      required this.selected,
      required this.label,
      required this.onPick,
      this.autofocus = false});

  @override
  Widget build(BuildContext context) => Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final v in values)
            ChoiceChip(
              autofocus: autofocus && v == selected,
              label: Text(label(v)),
              selected: v == selected,
              selectedColor: AppColors.accentSoft,
              onSelected: (_) => onPick(v),
            ),
        ],
      );
}
