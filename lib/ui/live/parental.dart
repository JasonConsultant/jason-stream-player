import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/profile_mode.dart';
import '../../state/providers.dart';
import '../widgets/dpad_text_field.dart';

/// Fragt die PIN ab. Liefert true, wenn korrekt (oder keine PIN gesetzt).
/// Falsche Eingaben werden gezählt; nach 5 Fehlversuchen ist kurz gesperrt.
Future<bool> askPin(BuildContext context, WidgetRef ref) async {
  final storage = await ref.read(storageProvider.future);
  if (!storage.hasPin()) return true;
  String? hint;
  while (true) {
    if (!context.mounted) return false;
    final entered = await pinDialog(context, tr('PIN eingeben'), hint: hint);
    if (entered == null) return false;
    final r = await storage.verifyPin(entered);
    if (r.ok) return true;
    if (r.lockedFor != null) {
      if (context.mounted) {
        final s = r.lockedFor!.inSeconds;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(trf('Zu viele Fehlversuche. Bitte in {0} erneut versuchen.', [
              s >= 60
                  ? trf('{0} Min.', [(s / 60).ceil()])
                  : trf('{0} Sek.', [s])
            ]))));
      }
      return false;
    }
    hint = r.attemptsLeft == 1
        ? tr('Falsche PIN – noch 1 Versuch')
        : trf('Falsche PIN – noch {0} Versuche', [r.attemptsLeft]);
  }
}

/// Kindermodus: Bearbeiten, Einstellungen und Portalwechsel nur mit PIN.
/// Liefert true, wenn erlaubt (kein Kindermodus oder PIN korrekt).
Future<bool> kidsGuard(BuildContext context, WidgetRef ref) async {
  if (!ref.read(profileModeProvider).kids) return true;
  return askPin(context, ref);
}

/// Stellt sicher, dass eine PIN existiert (legt sonst eine an) und
/// verlangt sie anschließend. Liefert true bei Erfolg.
Future<bool> ensurePin(BuildContext context, WidgetRef ref) async {
  final storage = await ref.read(storageProvider.future);
  if (!storage.hasPin()) {
    if (!context.mounted) return false;
    final p = await pinDialog(context, tr('Neue PIN festlegen'));
    if (p == null || p.length < 4) return false;
    await storage.setPin(p);
    return true;
  }
  if (!context.mounted) return false;
  return askPin(context, ref);
}

Future<void> showParentalSettings(BuildContext context, WidgetRef ref) async {
  final storage = await ref.read(storageProvider.future);
  if (!context.mounted) return;
  final hasPin = storage.hasPin();
  await showDialog<void>(
    context: context,
    builder: (_) => AlertDialog(
      title: Text(tr('Kindersicherung')),
      content: Text(hasPin
          ? tr('Eine PIN ist gesetzt. Gesperrte Sender verlangen sie vor dem Abspielen.')
          : tr('Noch keine PIN. Beim ersten Sperren eines Senders wird sie angelegt.')),
      actions: [
        if (hasPin)
          TextButton(
            onPressed: () async {
              if (await askPin(context, ref)) {
                await storage.setPin(null);
                if (context.mounted) Navigator.pop(context);
              }
            },
            child: Text(tr('PIN entfernen')),
          ),
        TextButton(
          onPressed: () async {
            if (!hasPin || await askPin(context, ref)) {
              if (!context.mounted) return;
              final p = await pinDialog(context, tr('Neue PIN'));
              if (p != null && p.length >= 4) await storage.setPin(p);
              if (context.mounted) Navigator.pop(context);
            }
          },
          child: Text(hasPin ? tr('PIN ändern') : tr('PIN anlegen')),
        ),
        FilledButton(
            autofocus: true,
            onPressed: () => Navigator.pop(context),
            child: Text(tr('Schließen'))),
      ],
    ),
  );
}

Future<String?> pinDialog(BuildContext context, String title,
    {String? hint}) {
  final ctrl = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (_) => AlertDialog(
      title: Text(title),
      content: DpadTextField(
        controller: ctrl,
        builder: (_, dp) => TextField(
          controller: ctrl,
          autofocus: true,
          obscureText: true,
          keyboardType: TextInputType.number,
          maxLength: 8,
          decoration: InputDecoration(
            hintText: tr('mind. 4 Ziffern'),
            errorText: hint,
          ),
          onSubmitted: (v) => Navigator.pop(context, v),
          readOnly: dp.readOnly,
          showCursor: dp.showCursor,
          onTap: dp.onTap,
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(tr('Abbrechen'))),
        FilledButton(
            onPressed: () => Navigator.pop(context, ctrl.text),
            child: Text(tr('OK'))),
      ],
    ),
  );
}
