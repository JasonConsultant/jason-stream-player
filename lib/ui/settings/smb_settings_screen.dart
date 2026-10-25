import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/recordings/recordings.dart' show RecTree;
import '../../data/smb/smb.dart';
import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../widgets/dpad_text_field.dart';

/// Einstellungen → Speicherort → „Netzlaufwerk (SMB)“: Server, Freigabe,
/// Pfad, Benutzer, Passwort (verschlüsselt), „Verbindung testen“ (mit
/// freiem Speicher), „Als Speicherort verwenden“. Nur SMB 2/3.
class SmbSettingsScreen extends ConsumerStatefulWidget {
  const SmbSettingsScreen({super.key});

  @override
  ConsumerState<SmbSettingsScreen> createState() => _SmbSettingsState();
}

class _SmbSettingsState extends ConsumerState<SmbSettingsScreen> {
  final _server = TextEditingController();
  final _share = TextEditingController();
  final _path = TextEditingController();
  final _user = TextEditingController();
  final _pass = TextEditingController();
  final _domain = TextEditingController();
  bool _show = false;
  bool _busy = false;
  String? _ok;
  String? _error;

  @override
  void initState() {
    super.initState();
    final c = ref.read(storageProvider).value?.smbConfig();
    if (c != null) {
      _server.text = c.server;
      _share.text = c.share;
      _path.text = c.path;
      _user.text = c.user;
      _pass.text = c.password;
      _domain.text = c.domain;
    } else {
      _path.text = 'JasonStreamPlayer';
    }
  }

  @override
  void dispose() {
    for (final c in [_server, _share, _path, _user, _pass, _domain]) {
      c.dispose();
    }
    super.dispose();
  }

  SmbConfig get _config => SmbConfig(
        server: _server.text.trim(),
        share: _share.text.trim(),
        path: _path.text.trim(),
        user: _user.text.trim(),
        password: _pass.text,
        domain: _domain.text.trim(),
      );

  Future<bool> _test() async {
    if (_busy) return false;
    final c = _config;
    final p = c.problem;
    if (p != null) {
      setState(() {
        _error = p;
        _ok = null;
      });
      return false;
    }
    setState(() {
      _busy = true;
      _error = null;
      _ok = null;
    });
    try {
      final r = await Smb.test(c);
      if (!mounted) return true;
      setState(() => _ok = r.free >= 0
          ? trf('Verbindung in Ordnung · {0} frei',
              [RecTree.formatFree(r.free)])
          : tr('Verbindung in Ordnung'));
      return true;
    } on SmbException catch (e) {
      if (mounted) setState(() => _error = e.message);
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _use() async {
    if (!await _test()) return;
    final st = await ref.read(storageProvider.future);
    await st.setSmbConfig(_config);
    await st.setOption(RecTree.optionKey, RecTree.smbValue);
    ref.invalidate(storageProvider);
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
        content: Text(trf('Speicherort: Netzlaufwerk {0}', [_config.display]))));
    Navigator.of(context).pop(true);
  }

  Future<void> _remove() async {
    final st = await ref.read(storageProvider.future);
    await st.setSmbConfig(null);
    if (RecTree.isSmb(st.option(RecTree.optionKey, ''))) {
      await st.setOption(RecTree.optionKey, '');
    }
    ref.invalidate(storageProvider);
    if (mounted) Navigator.of(context).pop(false);
  }

  Widget _field(TextEditingController c, String label,
      {String? hint, bool secret = false, Key? key, bool autofocus = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DpadTextField(
        controller: c,
        builder: (_, dp) => TextField(
          key: key,
          controller: c,
          autofocus: autofocus,
          obscureText: secret && !_show,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: label,
            hintText: hint,
            suffixIcon: secret
                ? ExcludeFocus(
                    child: IconButton(
                      onPressed: () => setState(() => _show = !_show),
                      icon: Icon(_show
                          ? Icons.visibility_off_rounded
                          : Icons.visibility_rounded),
                    ),
                  )
                : null,
          ),
          onSubmitted: (_) => dp.submitted(),
          readOnly: dp.readOnly,
          showCursor: dp.showCursor,
          onTap: dp.onTap,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final saved = ref.watch(storageProvider).value?.smbConfig() != null;
    return Scaffold(
      appBar: AppBar(title: Text(tr('Netzlaufwerk (SMB)'))),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
            children: [
              Text(
                  tr('Aufnahmen und Downloads direkt auf einem NAS oder '
                      'Windows-Rechner speichern (SMB 2/3, kein SMB1). '
                      'Downloads werden direkt geschrieben; Aufnahmen werden '
                      'zuerst lokal gepuffert und nach dem Ende verschoben. '
                      'Ist das Netzlaufwerk nicht erreichbar, gibt es einen '
                      'Hinweis – die App weicht nicht still auf den internen '
                      'Speicher aus.'),
                  style: t.bodyMedium),
              const SizedBox(height: 16),
              _field(_server, tr('Server (Name oder IP)'),
                  hint: 'nas.local · 192.168.1.10',
                  key: const ValueKey('smb-server'),
                  autofocus: !saved),
              _field(_share, tr('Freigabe'),
                  hint: 'video', key: const ValueKey('smb-share')),
              _field(_path, tr('Ordner in der Freigabe (optional)'),
                  hint: 'JasonStreamPlayer', key: const ValueKey('smb-path')),
              _field(_user, tr('Benutzer (leer = Gast)'),
                  key: const ValueKey('smb-user')),
              _field(_pass, tr('Passwort'),
                  secret: true, key: const ValueKey('smb-pass')),
              _field(_domain, tr('Domäne/Arbeitsgruppe (optional)'),
                  key: const ValueKey('smb-domain')),
              Wrap(spacing: 10, runSpacing: 10, children: [
                OutlinedButton.icon(
                  key: const ValueKey('smb-test'),
                  onPressed: _test,
                  icon: const Icon(Icons.wifi_tethering_rounded),
                  label: Text(tr('Verbindung testen')),
                ),
                FilledButton.icon(
                  key: const ValueKey('smb-use'),
                  onPressed: _use,
                  icon: const Icon(Icons.check_rounded),
                  label: Text(tr('Als Speicherort verwenden')),
                ),
                if (saved)
                  TextButton.icon(
                    key: const ValueKey('smb-remove'),
                    onPressed: _remove,
                    icon: const Icon(Icons.delete_outline_rounded),
                    label: Text(tr('Netzlaufwerk entfernen')),
                  ),
              ]),
              if (_busy) ...[
                const SizedBox(height: 12),
                const LinearProgressIndicator(),
              ],
              if (_ok != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(_ok!,
                      key: const ValueKey('smb-ok'),
                      style: t.bodyMedium?.copyWith(color: AppColors.accent)),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(_error!,
                      key: const ValueKey('smb-error'),
                      style: t.bodyMedium?.copyWith(color: AppColors.live)),
                ),
              const SizedBox(height: 16),
              Text(
                  tr('Benutzer und Passwort werden verschlüsselt auf diesem '
                      'Gerät gespeichert und nicht in Sicherungen übernommen.'),
                  style: t.bodySmall),
            ],
          ),
        ),
      ),
    );
  }
}
