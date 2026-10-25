import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/backup.dart';
import '../../core/platform_info.dart';
import '../../core/secret_store.dart';
import '../../core/theme.dart';
import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../../state/vod_library.dart';
import '../../state/my_groups.dart';
import '../widgets/dpad_text_field.dart';

/// Sicherung & Übertragung: alles in eine passwortgeschützte Datei
/// (`.jspbackup`) schreiben bzw. daraus wiederherstellen – für den Umzug
/// auf ein neues Gerät.
class BackupScreen extends ConsumerStatefulWidget {
  const BackupScreen({super.key});

  @override
  ConsumerState<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends ConsumerState<BackupScreen> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: Text(tr('Sicherung & Übertragung'))),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 16),
                child: Text(
                  tr('Sichert Portale mit Zugangsdaten, Favoriten, eigene '
                      'Gruppen, Reihenfolgen, versteckte und gesperrte Sender, '
                      'Film-Merklisten, Positionen und Einstellungen in eine '
                      'Datei. Nicht enthalten: PIN, App-Sperre, Aufnahmen und '
                      'Erinnerungen.'),
                  style: t.bodySmall,
                ),
              ),
              _Card(
                icon: Icons.upload_file_rounded,
                title: tr('Sicherung erstellen'),
                text: tr('Die Datei enthält deine Portal-Passwörter und wird '
                    'deshalb mit einem Passwort verschlüsselt (AES-256). '
                    'Ohne dieses Passwort lässt sie sich nicht öffnen – '
                    'merk es dir gut.'),
                button: tr('Sicherung erstellen'),
                autofocus: true,
                onTap: _busy ? null : _create,
              ),
              const SizedBox(height: 14),
              _Card(
                icon: Icons.settings_backup_restore_rounded,
                title: tr('Sicherung wiederherstellen'),
                text: tr('Wähle eine .jspbackup-Datei und gib ihr Passwort '
                    'ein. Du kannst die Sicherung zu den vorhandenen Daten '
                    'hinzufügen oder alles ersetzen.'),
                button: tr('Datei wählen'),
                onTap: _busy ? null : _restore,
              ),
              if (_busy)
                const Padding(
                  padding: EdgeInsets.only(top: 24),
                  child: Center(child: CircularProgressIndicator()),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _create() async {
    final storage = await ref.read(storageProvider.future);
    if (!mounted) return;
    final pw = await _askPassword(context, confirm: true);
    if (pw == null) return;
    setState(() => _busy = true);
    try {
      final data = storage.exportAll();
      final bytes = await compute(_encrypt, (data, pw));
      final ok = await PlatformInfo.saveFile(
          name: BackupCodec.suggestedName(),
          mime: BackupCodec.mimeType,
          bytes: bytes);
      _snack(ok
          ? tr('Sicherung gespeichert.')
          : tr('Abgebrochen – nichts gespeichert.'));
    } on PlatformException catch (e) {
      _snack(e.code == 'nopicker'
          ? tr('Kein Dateidialog auf diesem Gerät. Bitte einen Dateimanager '
              'installieren.')
          : trf('Speichern fehlgeschlagen: {0}', [e.message ?? e.code]));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore() async {
    ({Uint8List bytes, String? name})? file;
    try {
      file = await PlatformInfo.openFile();
    } on PlatformException catch (e) {
      _snack(e.code == 'nopicker'
          ? tr('Kein Dateidialog auf diesem Gerät. Bitte einen Dateimanager '
              'installieren.')
          : trf('Datei konnte nicht gelesen werden: {0}',
              [e.message ?? e.code]));
      return;
    }
    if (file == null || !mounted) return;
    final pw = await _askPassword(context, confirm: false);
    if (pw == null) return;
    setState(() => _busy = true);
    Map<String, Object?> data;
    try {
      data = await compute(_decrypt, (file.bytes, pw));
    } on BackupException catch (e) {
      if (mounted) setState(() => _busy = false);
      _snack(switch (e.error) {
        BackupError.notABackup => tr('Das ist keine Sicherungsdatei von '
            'Jason Stream Player.'),
        _ => tr('Falsches Passwort oder beschädigte Datei.'),
      });
      return;
    }
    if (mounted) setState(() => _busy = false);
    if (!mounted) return;
    final merge = await _askMode(context, BackupSummary.of(data));
    if (merge == null) return;
    setState(() => _busy = true);
    try {
      final storage = await ref.read(storageProvider.future);
      await storage.importAll(data, merge: merge);
      // Alles neu laden: Storage, Portale, aktives Portal und damit alle
      // davon abhängigen Listen.
      ref.invalidate(storageProvider);
      ref.invalidate(portalsProvider);
      ref.invalidate(activePortalProvider);
      ref.invalidate(channelFlagsProvider);
      ref.invalidate(sortOrderProvider);
      ref.invalidate(recentProvider);
      ref.invalidate(myGroupsProvider);
      ref.invalidate(vodLibraryProvider);
      ref.invalidate(appLangProvider);
      _snack(tr('Sicherung wiederhergestellt. Bei Problemen die App einmal '
          'neu starten.'));
      if (mounted) Navigator.of(context).pop();
    } on FormatException {
      _snack(tr('Das ist keine Sicherungsdatei von Jason Stream Player.'));
    } on SecretStoreException catch (e) {
      // Keystore verweigert das Verschlüsseln der Zugangsdaten – sonst
      // bliebe der Fehler stumm (unbehandelte Future-Ausnahme).
      _snack(e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static Future<Uint8List> _encrypt((Map<String, Object?>, String) a) =>
      BackupCodec.encrypt(a.$1, a.$2);
  static Future<Map<String, Object?>> _decrypt((Uint8List, String) a) =>
      BackupCodec.decrypt(a.$1, a.$2);

  Future<String?> _askPassword(BuildContext context,
      {required bool confirm}) {
    final c1 = TextEditingController();
    final c2 = TextEditingController();
    String? error;
    return showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) {
          void submit() {
            final p = c1.text;
            if (p.length < BackupCodec.minPasswordLength) {
              setState(() => error = trf('Mindestens {0} Zeichen',
                  [BackupCodec.minPasswordLength]));
              return;
            }
            if (confirm && p != c2.text) {
              setState(() => error = tr('Die Passwörter stimmen nicht überein'));
              return;
            }
            Navigator.pop(ctx, p);
          }

          return AlertDialog(
            title: Text(confirm
                ? tr('Passwort für die Sicherung')
                : tr('Passwort der Sicherung')),
            content: Column(mainAxisSize: MainAxisSize.min, children: [
              if (confirm)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    tr('Schützt die Zugangsdaten in der Datei. Wird auf dem '
                        'neuen Gerät wieder abgefragt.'),
                    style: Theme.of(ctx).textTheme.bodySmall,
                  ),
                ),
              DpadTextField(
                controller: c1,
                builder: (_, dp) => TextField(
                  controller: c1,
                  autofocus: true,
                  obscureText: true,
                  textInputAction:
                      confirm ? TextInputAction.next : TextInputAction.done,
                  decoration: InputDecoration(labelText: tr('Passwort')),
                  onSubmitted: confirm ? null : (_) => submit(),
                  readOnly: dp.readOnly,
                  showCursor: dp.showCursor,
                  onTap: dp.onTap,
                ),
              ),
              if (confirm) ...[
                const SizedBox(height: 10),
                DpadTextField(
                  controller: c2,
                  builder: (_, dp) => TextField(
                    controller: c2,
                    obscureText: true,
                    textInputAction: TextInputAction.done,
                    decoration:
                        InputDecoration(labelText: tr('Passwort wiederholen')),
                    onSubmitted: (_) => submit(),
                    readOnly: dp.readOnly,
                    showCursor: dp.showCursor,
                    onTap: dp.onTap,
                  ),
                ),
              ],
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(error!,
                      style: const TextStyle(color: AppColors.live)),
                ),
            ]),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(tr('Abbrechen'))),
              FilledButton(onPressed: submit, child: Text(tr('Weiter'))),
            ],
          );
        },
      ),
    );
  }

  /// Zusammenfassung zeigen; Ergebnis: true = hinzufügen, false = ersetzen,
  /// null = abgebrochen.
  Future<bool?> _askMode(BuildContext context, BackupSummary s) {
    final parts = [
      trf('{0} Portale', [s.portals]),
      trf('{0} Favoriten', [s.favorites]),
      if (s.myGroups > 0) trf('{0} eigene Gruppen', [s.myGroups]),
      if (s.vodFavorites > 0) trf('{0} Film-Merkliste', [s.vodFavorites]),
      if (s.profiles > 1) trf('{0} Profile', [s.profiles]),
    ];
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Sicherung wiederherstellen')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(parts.join(', ')),
            if (s.portalNames.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(s.portalNames.join(' · '),
                  style: Theme.of(ctx).textTheme.bodySmall),
            ],
            const SizedBox(height: 14),
            Text(
              tr('„Hinzufügen“ behält vorhandene Portale und ergänzt die '
                  'Sicherung. „Ersetzen“ entfernt vorher alle Portale und '
                  'Einstellungen auf diesem Gerät (die PIN bleibt).'),
              style: Theme.of(ctx).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(tr('Abbrechen'))),
          TextButton(
              style: TextButton.styleFrom(foregroundColor: AppColors.live),
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr('Ersetzen'))),
          FilledButton(
              autofocus: true,
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr('Hinzufügen'))),
        ],
      ),
    );
  }
}

class _Card extends StatelessWidget {
  final IconData icon;
  final String title;
  final String text;
  final String button;
  final bool autofocus;
  final VoidCallback? onTap;
  const _Card({
    required this.icon,
    required this.title,
    required this.text,
    required this.button,
    required this.onTap,
    this.autofocus = false,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.all(18),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(icon, color: AppColors.accent),
          const SizedBox(width: 12),
          Expanded(child: Text(title, style: t.titleMedium)),
        ]),
        const SizedBox(height: 8),
        Text(text, style: t.bodySmall),
        const SizedBox(height: 14),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.icon(
            autofocus: autofocus,
            onPressed: onTap,
            icon: Icon(icon, size: 18),
            label: Text(button),
          ),
        ),
      ]),
    );
  }
}
