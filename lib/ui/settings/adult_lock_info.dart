import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/strings.dart';
import '../../state/content_filter.dart';
import '../../state/providers.dart';

bool _showing = false;

/// Einmaliger Hinweis: Erwachsenen-Gruppen wurden erkannt und ausgeblendet,
/// es gibt aber noch keine PIN zum Entsperren. Im build einer immer
/// sichtbaren Seite (Startseite) aufrufen.
void listenAdultLockInfo(BuildContext context, WidgetRef ref) {
  final due = ref.watch(adultInfoDueProvider);
  if (!due || _showing) return;
  _showing = true;
  WidgetsBinding.instance.addPostFrameCallback((_) async {
    try {
      final st = await ref.read(storageProvider.future);
      if (st.adultInfoShown || !context.mounted) return;
      await st.setAdultInfoShown();
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const Icon(Icons.no_adult_content_rounded),
          title: Text(tr('Erwachseneninhalte gesperrt')),
          content: Text(tr(
              'In diesem Portal wurden Gruppen für Erwachsene erkannt und ausgeblendet. Zum Entsperren unter Einstellungen → Kindersicherung eine PIN anlegen und „Erwachseneninhalte anzeigen“ wählen.')),
          actions: [
            FilledButton(
              autofocus: true,
              onPressed: () => Navigator.pop(ctx),
              child: Text(tr('OK')),
            ),
          ],
        ),
      );
    } finally {
      _showing = false;
    }
  });
}
