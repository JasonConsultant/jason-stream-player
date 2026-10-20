import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/security.dart';
import '../../core/updater.dart';
import '../../l10n/strings.dart';
import '../../state/providers.dart';

/// Automatisch höchstens 1× pro Tag nach Updates schauen.
Future<void> autoCheckForUpdate(BuildContext context, WidgetRef ref) async {
  if (!Updater.enabled) return;
  final st = await ref.read(storageProvider.future);
  final last = int.tryParse(st.option('updcheck', '0')) ?? 0;
  final now = DateTime.now().millisecondsSinceEpoch;
  if (now - last < const Duration(hours: 20).inMilliseconds) return;
  await st.setOption('updcheck', '$now');
  try {
    final u = await Updater.check();
    if (u == null || !context.mounted) return;
    // „Später“ für genau diese Version gewählt → nicht erneut fragen.
    if (st.option('updskip', '') == u.version) return;
    await showUpdateDialog(context, ref, u);
  } catch (_) {
    // Kein Netz o. Ä. – still ignorieren, nächster Versuch morgen.
  }
}

/// „Nach Updates suchen“ in den Einstellungen.
Future<void> manualCheckForUpdate(BuildContext context, WidgetRef ref) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final u = await Updater.check();
    if (!context.mounted) return;
    if (u == null) {
      messenger.showSnackBar(
          SnackBar(content: Text(tr('Du hast die neueste Version'))));
    } else {
      await showUpdateDialog(context, ref, u);
    }
  } catch (e) {
    messenger.showSnackBar(SnackBar(
        content: Text(trf('Update-Prüfung fehlgeschlagen: {0}',
            [Redactor.friendly(e)]))));
  }
}

Future<void> showUpdateDialog(
    BuildContext context, WidgetRef ref, UpdateInfo u) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _UpdateDialog(update: u),
  );
}

class _UpdateDialog extends ConsumerStatefulWidget {
  final UpdateInfo update;
  const _UpdateDialog({required this.update});

  @override
  ConsumerState<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends ConsumerState<_UpdateDialog> {
  bool _busy = false;
  double? _progress;
  String? _error;

  Future<void> _install() async {
    setState(() {
      _busy = true;
      _error = null;
      _progress = null;
    });
    try {
      final ok = await Updater.downloadAndInstall(widget.update,
          onProgress: (r, t) {
        if (mounted && t != null && t > 0) setState(() => _progress = r / t);
      });
      if (!mounted) return;
      if (ok) {
        Navigator.pop(context);
      } else {
        setState(() {
          _busy = false;
          _error = tr('Bitte „Apps aus dieser Quelle zulassen“ einschalten, '
              'zurückkehren und erneut „Installieren“ tippen.');
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = Redactor.friendly(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final u = widget.update;
    final t = Theme.of(context).textTheme;
    final mb = u.size > 0 ? ' · ${(u.size / 1048576).toStringAsFixed(0)} MB' : '';
    return AlertDialog(
      icon: const Icon(Icons.system_update_rounded),
      title: Text(trf('Version {0} verfügbar', [u.version])),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460, maxHeight: 320),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('${tr('Wird über deine App installiert – Portale und '
                  'Einstellungen bleiben erhalten.')}$mb', style: t.bodySmall),
              if (u.notes.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(u.notes, style: t.bodyMedium),
              ],
              if (_busy) ...[
                const SizedBox(height: 16),
                LinearProgressIndicator(value: _progress),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: t.bodySmall?.copyWith(color: Colors.orange)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy
              ? null
              : () async {
                  final st = await ref.read(storageProvider.future);
                  await st.setOption('updskip', u.version);
                  if (context.mounted) Navigator.pop(context);
                },
          child: Text(tr('Später')),
        ),
        FilledButton.icon(
          autofocus: true,
          onPressed: _busy ? null : _install,
          icon: const Icon(Icons.download_rounded),
          label: Text(tr('Installieren')),
        ),
      ],
    );
  }
}
