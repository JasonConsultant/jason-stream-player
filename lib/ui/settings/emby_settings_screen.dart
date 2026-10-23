import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/security.dart';
import '../../core/theme.dart';
import '../../data/emby/emby_client.dart';
import '../../l10n/strings.dart';
import '../../state/emby.dart';
import '../../state/providers.dart';
import '../widgets/dpad_text_field.dart';
import '../widgets/focusable_tile.dart';

/// Einstellungen → „Emby-Server“: Adresse, Benutzer, Passwort, „Verbindung
/// testen“, Anmelden/Abmelden und die maximale Streaming-Bitrate. Gilt für
/// alle Portale (ein Portalwechsel ändert nichts).
class EmbySettingsScreen extends ConsumerStatefulWidget {
  const EmbySettingsScreen({super.key});

  @override
  ConsumerState<EmbySettingsScreen> createState() => _EmbySettingsState();
}

class _EmbySettingsState extends ConsumerState<EmbySettingsScreen> {
  late final _url = TextEditingController();
  late final _user = TextEditingController();
  final _pass = TextEditingController();
  bool _showPass = false;
  // Nach An-/Abmelden verschwindet der fokussierte Knopf → Fokus gezielt
  // setzen (Fernbedienung).
  final _reloadNode = FocusNode(debugLabel: 'emby reload');
  final _loginNode = FocusNode(debugLabel: 'emby login');
  bool _busy = false;
  String? _error;
  String? _ok;

  @override
  void initState() {
    super.initState();
    // Gespeicherte Adresse/Benutzer vorbelegen (auch wenn der Speicher erst
    // gleich fertig geladen ist) – Eingaben des Nutzers bleiben unberührt.
    ref.listenManual<EmbyAccount?>(embyAccountProvider, (_, acc) {
      if (acc == null) return;
      if (_url.text.isEmpty) _url.text = acc.server;
      if (_user.text.isEmpty) _user.text = acc.userName;
    }, fireImmediately: true);
  }

  @override
  void dispose() {
    _url.dispose();
    _user.dispose();
    _pass.dispose();
    _reloadNode.dispose();
    _loginNode.dispose();
    super.dispose();
  }

  void _focusLater(FocusNode n) =>
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && n.context != null) n.requestFocus();
      });

  /// Knöpfe bleiben während der Anfrage bedienbar (sonst verlöre die
  /// Fernbedienung den Fokus) – ein zweiter Druck wird ignoriert.
  Future<void> _run(Future<void> Function() f) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _ok = null;
    });
    try {
      await f();
    } on EmbyException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = Redactor.friendly(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static String _describe(EmbyAccount a) => [
        a.serverName ?? Uri.tryParse(a.server)?.host ?? a.server,
        if ((a.serverVersion ?? '').isNotEmpty)
          '${a.jellyfin ? 'Jellyfin' : 'Emby'} ${a.serverVersion}'
        else
          a.jellyfin ? 'Jellyfin' : 'Emby',
      ].join(' · ');

  Future<void> _test() => _run(() async {
        final acc = await ref.read(embyAccountProvider.notifier).test(
            _url.text,
            user: _user.text,
            password: _pass.text);
        if (!mounted) return;
        setState(() => _ok = acc.userName.isEmpty
            ? trf('Server erreichbar: {0}', [_describe(acc)])
            : trf('Verbindung OK: {0} · Benutzer {1}',
                [_describe(acc), acc.userName]));
      });

  Future<void> _signIn() => _run(() async {
        if (_user.text.trim().isEmpty) {
          setState(() => _error = tr('Bitte Benutzernamen angeben.'));
          return;
        }
        final acc = await ref
            .read(embyAccountProvider.notifier)
            .signIn(_url.text, _user.text, _pass.text);
        _pass.clear();
        _url.text = acc.server; // vervollständigt (http://…)
        if (!mounted) return;
        setState(() => _ok = tr('Angemeldet. Filme und Serien: oben „Emby“ wählen.'));
        _focusLater(_reloadNode);
      });

  Future<void> _signOut() => _run(() async {
        await ref.read(embyAccountProvider.notifier).signOut();
        if (mounted) setState(() => _ok = tr('Abgemeldet.'));
        _focusLater(_loginNode);
      });

  Future<void> _reload() => _run(() async {
        await Future.wait([
          ref.read(embyMoviesProvider.notifier).reload(),
          ref.read(embySeriesProvider.notifier).reload(),
        ]);
        ref.invalidate(embyResumeProvider);
        ref.invalidate(embyLatestProvider);
        if (mounted) setState(() => _ok = tr('Emby-Listen sind aktuell.'));
      });

  @override
  Widget build(BuildContext context) {
    final acc = ref.watch(embyAccountProvider);
    final st = ref.watch(storageProvider).value;
    final t = Theme.of(context).textTheme;
    final signedIn = acc?.signedIn ?? false;
    final bitrate = st?.option('embybitrate', 'auto') ?? 'auto';

    Widget field(TextEditingController c, String label,
            {Key? key,
            bool autofocus = false,
            bool password = false,
            String? hint,
            TextInputType? type}) =>
        DpadTextField(
          controller: c,
          builder: (_, dp) => TextField(
            key: key,
            controller: c,
            autofocus: autofocus,
            obscureText: password && !_showPass,
            autocorrect: false,
            enableSuggestions: false,
            enableIMEPersonalizedLearning: false,
            keyboardType: type,
            decoration: InputDecoration(
              labelText: label,
              hintText: hint,
              // Fernbedienung: Auge nicht ansteuerbar (▼ soll vom Feld
              // direkt zu den Knöpfen gehen).
              suffixIcon: password
                  ? ExcludeFocus(
                      excluding: dp.tv,
                      child: IconButton(
                      tooltip: _showPass ? tr('Verbergen') : tr('Anzeigen'),
                      icon: Icon(_showPass
                          ? Icons.visibility_off_rounded
                          : Icons.visibility_rounded),
                      onPressed: () => setState(() => _showPass = !_showPass),
                    ))
                  : null,
            ),
            readOnly: dp.readOnly,
            showCursor: dp.showCursor,
            onTap: dp.onTap,
            onSubmitted: (_) => dp.submitted(),
          ),
        );

    final status = <Widget>[
      if (_error != null)
        Padding(
          padding: const EdgeInsets.only(top: 14),
          child: Text(_error!,
              key: const ValueKey('emby-error'),
              style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ),
      if (_ok != null)
        Padding(
          padding: const EdgeInsets.only(top: 14),
          child: Row(children: [
            const Icon(Icons.check_circle_rounded,
                size: 18, color: AppColors.catchup),
            const SizedBox(width: 8),
            Expanded(
                child: Text(_ok!,
                    key: const ValueKey('emby-ok'),
                    style: const TextStyle(color: AppColors.catchup))),
          ]),
        ),
    ];

    final busyIcon = const SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 2));

    return Scaffold(
      appBar: AppBar(title: Text(tr('Emby-Server'))),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Text(
                tr('Filme und Serien vom eigenen Emby- oder Jellyfin-Server – '
                    'unabhängig vom gewählten Portal. Danach in „Filme“ und '
                    '„Serien“ oben „Emby“ wählen.'),
                style: t.bodyMedium?.copyWith(color: AppColors.textDim),
              ),
              const SizedBox(height: 18),
              if (signedIn) ...[
                Container(
                  key: const ValueKey('emby-status'),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Row(children: [
                    const Icon(Icons.home_work_rounded,
                        color: AppColors.catchup, size: 30),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(_describe(acc!),
                              style: t.titleMedium?.copyWith(fontSize: 16)),
                          const SizedBox(height: 2),
                          Text(trf('Angemeldet als {0}', [acc.userName]),
                              style: t.bodySmall),
                          Text(Redactor.redact(acc.server),
                              style: t.bodySmall
                                  ?.copyWith(color: AppColors.textFaint)),
                        ],
                      ),
                    ),
                  ]),
                ),
                const SizedBox(height: 18),
                Text(tr('MAX. STREAMING-BITRATE'), style: t.labelSmall),
                const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final (v, label) in [
                    ('auto', tr('Automatisch')),
                    ('20', '20 Mbit/s'),
                    ('10', '10 Mbit/s'),
                    ('4', '4 Mbit/s'),
                  ])
                    ChoiceChip(
                      key: ValueKey('emby-bitrate-$v'),
                      label: Text(label),
                      selected: bitrate == v,
                      showCheckmark: false,
                      labelStyle: TextStyle(
                          color: bitrate == v
                              ? const Color(0xFF1A0B04)
                              : AppColors.text,
                          fontWeight: FontWeight.w600),
                      onSelected: (_) async {
                        await st?.setOption('embybitrate', v);
                        ref.invalidate(storageProvider);
                      },
                    ),
                ]),
                const SizedBox(height: 6),
                Text(
                    tr('Automatisch spielt die Originaldatei ab; mit Grenze '
                        'wandelt der Server größere Dateien um (für langsames WLAN).'),
                    style: t.bodySmall),
                const SizedBox(height: 18),
                _Action(
                  key: const ValueKey('emby-reload'),
                  focusNode: _reloadNode,
                  icon: Icons.refresh_rounded,
                  label: tr('Emby-Listen neu laden'),
                  autofocus: true,
                  onTap: _reload,
                ),
                _Action(
                  key: const ValueKey('emby-logout'),
                  icon: Icons.logout_rounded,
                  label: tr('Abmelden'),
                  onTap: _signOut,
                ),
                ...status,
              ] else ...[
                field(_url, tr('Server-Adresse'),
                    key: const ValueKey('emby-url'),
                    autofocus: true,
                    hint: 'http://192.168.1.10:8096',
                    type: TextInputType.url),
                const SizedBox(height: 12),
                field(_user, tr('Benutzer'), key: const ValueKey('emby-user')),
                const SizedBox(height: 12),
                field(_pass, tr('Passwort'),
                    key: const ValueKey('emby-pass'), password: true),
                ...status,
                const SizedBox(height: 22),
                // Untereinander: ▼ vom Passwort direkt auf „Anmelden“.
                FilledButton.icon(
                  key: const ValueKey('emby-login'),
                  focusNode: _loginNode,
                  onPressed: _signIn,
                  icon: _busy ? busyIcon : const Icon(Icons.login_rounded),
                  label: Text(tr('Anmelden & speichern')),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  key: const ValueKey('emby-test'),
                  onPressed: _test,
                  icon: const Icon(Icons.network_check_rounded),
                  label: Text(tr('Verbindung testen')),
                ),
              ],
              const SizedBox(height: 24),
              Row(children: [
                const Icon(Icons.verified_user_rounded,
                    size: 16, color: AppColors.catchup),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    tr('Das Passwort wird nicht gespeichert, nur der Zugangsschlüssel '
                        '(verschlüsselt). Sicherungen enthalten nur Adresse und '
                        'Benutzer – nach dem Wiederherstellen einmal neu anmelden.'),
                    style: const TextStyle(
                        fontSize: 12, color: AppColors.textFaint),
                  ),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}

class _Action extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool autofocus;
  final FocusNode? focusNode;
  const _Action(
      {super.key,
      required this.icon,
      required this.label,
      required this.onTap,
      this.autofocus = false,
      this.focusNode});

  @override
  Widget build(BuildContext context) => FocusableTile(
        focusNode: focusNode,
        autofocus: autofocus,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
          child: Row(children: [
            Icon(icon, color: AppColors.textDim, size: 22),
            const SizedBox(width: 16),
            Expanded(
                child: Text(label,
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(fontSize: 15))),
          ]),
        ),
      );
}
