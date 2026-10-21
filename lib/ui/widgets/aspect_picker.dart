import 'package:flutter/material.dart';

import '../../l10n/strings.dart';

import '../../core/aspect.dart';
import '../../core/theme.dart';
import 'focusable_tile.dart';

/// Auswahl des Bildformats. Mit [rememberLabel] erscheint ein Schalter
/// „Für diesen Sender merken“. Ergebnis: gewähltes Format + Merken-Wunsch.
Future<(AspectMode, bool)?> showAspectPicker(
  BuildContext context,
  AspectMode current, {
  String? rememberLabel,
  bool rememberInitially = true,
}) {
  var remember = rememberInitially;
  return showModalBottomSheet<(AspectMode, bool)>(
    context: context,
    isScrollControlled: true,
    constraints: const BoxConstraints(maxWidth: 560),
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
              child: Text(tr('Bildformat'),
                  style: Theme.of(ctx).textTheme.titleLarge),
            ),
            for (final m in AspectMode.values)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: FocusableTile(
                  autofocus: m == current,
                  selected: m == current,
                  onTap: () => Navigator.pop(ctx, (m, remember)),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 11),
                    child: Row(children: [
                      Icon(m.icon,
                          color: m == current
                              ? AppColors.accent
                              : AppColors.textDim),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(m.label,
                                style: Theme.of(ctx).textTheme.titleSmall),
                            Text(m.hint,
                                style: Theme.of(ctx).textTheme.bodySmall),
                          ],
                        ),
                      ),
                      if (m == current)
                        Icon(Icons.check_rounded,
                            color: AppColors.accent),
                    ]),
                  ),
                ),
              ),
            if (rememberLabel != null) ...[
              const Divider(height: 20),
              FocusableTile(
                onTap: () => setState(() => remember = !remember),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Row(children: [
                    const Icon(Icons.bookmark_added_rounded,
                        color: AppColors.textDim),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Text(rememberLabel,
                          style: Theme.of(ctx).textTheme.titleSmall),
                    ),
                    IgnorePointer(
                      child: ExcludeFocus(
                        child: Switch(
                          value: remember,
                          onChanged: (_) {},
                          activeThumbColor: AppColors.accent,
                        ),
                      ),
                    ),
                  ]),
                ),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}
