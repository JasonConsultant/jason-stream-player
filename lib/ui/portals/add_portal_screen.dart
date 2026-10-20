import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/platform_info.dart';
import '../../core/security.dart';
import '../../core/theme.dart';
import '../../data/repository.dart';
import '../../models/models.dart';
import '../../state/providers.dart';
import '../../l10n/strings.dart';

class AddPortalScreen extends ConsumerStatefulWidget {
  /// Nur für die Web-Vorschau: Beispielwerte eintragen.
  final bool previewFill;

  /// Bestehendes Portal bearbeiten (Adresse, Zugangsdaten, Name …).
  final Portal? edit;
  const AddPortalScreen({super.key, this.previewFill = false, this.edit});

  @override
  ConsumerState<AddPortalScreen> createState() => _AddPortalScreenState();
}

class _AddPortalScreenState extends ConsumerState<AddPortalScreen> {
  final _form = GlobalKey<FormState>();
  PortalType _type = PortalType.xtream;
  final _name = TextEditingController();
  final _url = TextEditingController();
  final _user = TextEditingController();
  final _pass = TextEditingController();
  final _epg = TextEditingController();
  final _mac = TextEditingController(text: '00:1A:79:');
  bool _busy = false;
  bool _showPass = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Keine Bildschirmfotos/Aufnahmen und keine Vorschau im App-Wechsler,
    // solange Zugangsdaten auf dem Bildschirm stehen.
    PlatformInfo.setSecureScreen(true);
    _url.addListener(() => setState(() {}));
    final e = widget.edit;
    if (e != null) {
      _type = e.type;
      _name.text = e.name;
      _url.text = e.url;
      if (e.type == PortalType.stalker) {
        _mac.text = e.username ?? '';
      } else {
        _user.text = e.username ?? '';
      }
      _pass.text = e.password ?? '';
      // Mehrere EPG-Quellen werden unter „EPG-Quellen“ verwaltet.
      final epg = e.epgUrl ?? '';
      if (!epg.contains('\n') && epg != 'portal') _epg.text = epg;
    }
    if (widget.previewFill) {
      _name.text = 'Mein Anbieter';
      _url.text = 'http://server.beispiel.de:8080';
      _user.text = 'jason77';
      _pass.text = 'Geheim123';
    }
  }

  @override
  void dispose() {
    PlatformInfo.setSecureScreen(false);
    // Eingaben aus dem Speicher räumen.
    for (final c in [_name, _url, _user, _pass, _epg, _mac]) {
      c.clear();
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });

    final edit = widget.edit;
    final oldEpg = edit?.epgUrl ?? '';
    final keepSources = oldEpg.contains('\n') && _epg.text.trim().isEmpty;
    final portal = Portal(
      id: edit?.id ?? const Uuid().v4(),
      name: _name.text.trim(),
      type: _type,
      url: _url.text.trim(),
      // MAC-Portal: MAC-Adresse steht (verschlüsselt) im Benutzernamen.
      username: switch (_type) {
        PortalType.xtream => _user.text.trim(),
        PortalType.stalker => _mac.text.trim().toUpperCase().replaceAll('-', ':'),
        _ => null,
      },
      password: _type == PortalType.xtream ? _pass.text : null,
      epgUrl: keepSources
          ? oldEpg
          : (_epg.text.trim().isEmpty ? null : _epg.text.trim()),
    );

    try {
      // Zugang testen (Xtream: Login, M3U: Playlist laden).
      await IptvRepository.forPortal(portal).login();
      if (edit != null) {
        await ref.read(portalsProvider.notifier).replace(portal);
      } else {
        await ref.read(portalsProvider.notifier).add(portal);
        await ref.read(activePortalProvider.notifier).select(portal);
      }
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) setState(() => _error = Redactor.friendly(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickFile() async {
    try {
      final r = await PlatformInfo.pickPlaylist();
      if (r == null || !mounted) return;
      setState(() {
        _url.text = r.url;
        if (_name.text.trim().isEmpty && r.name != null) {
          _name.text = r.name!.replaceAll(RegExp(r'\.m3u8?$', caseSensitive: false), '');
        }
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(tr('Datei konnte nicht gelesen werden'))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final isXtream = _type == PortalType.xtream;
    return Scaffold(
      appBar: AppBar(
          title: Text(widget.edit != null
              ? tr('Portal bearbeiten')
              : tr('Portal hinzufügen'))),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Form(
            key: _form,
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Text(tr('Zugangsart'),
                    style: Theme.of(context).textTheme.labelSmall),
                const SizedBox(height: 8),
                SegmentedButton<PortalType>(
                  segments: [
                    ButtonSegment(
                        value: PortalType.xtream,
                        label: Text('Xtream Codes'),
                        icon: Icon(Icons.dns_outlined)),
                    ButtonSegment(
                        value: PortalType.m3u,
                        label: Text('M3U'),
                        icon: Icon(Icons.playlist_play)),
                    ButtonSegment(
                        value: PortalType.stalker,
                        label: Text(tr('MAC-Portal')),
                        icon: Icon(Icons.router_outlined)),
                  ],
                  selected: {_type},
                  onSelectionChanged: (s) => setState(() => _type = s.first),
                ),
                const SizedBox(height: 20),
                TextFormField(
                  controller: _name,
                  autofocus: true,
                  decoration: InputDecoration(labelText: tr('Name')),
                  validator: (v) =>
                      (v == null || v.trim().isEmpty) ? tr('Bitte Name angeben') : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _url,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  enableSuggestions: false,
                  enableIMEPersonalizedLearning: false,
                  decoration: InputDecoration(
                    labelText: switch (_type) {
                      PortalType.xtream => tr('Server-URL (http://host:port)'),
                      PortalType.stalker => tr('Portal-URL (z. B. http://host:port/c/)'),
                      _ => tr('Playlist-URL (.m3u / .m3u8)'),
                    },
                  ),
                  validator: (v) => UrlPolicy.isWeb(v) ||
                          (_type == PortalType.m3u &&
                              (v ?? '').startsWith('file://'))
                      ? null
                      : tr('Bitte eine vollständige http(s)-Adresse eingeben'),
                ),
                if (_type == PortalType.m3u && PlatformInfo.isAndroid) ...[
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      onPressed: _pickFile,
                      icon: const Icon(Icons.folder_open_rounded),
                      label: Text(tr('M3U-Datei vom Gerät wählen')),
                    ),
                  ),
                ],
                if (UrlPolicy.isUnencrypted(_url.text)) ...[
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.gold.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                          color: AppColors.gold.withValues(alpha: 0.35)),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.lock_open_rounded,
                            size: 18, color: AppColors.gold),
                        SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            tr('Unverschlüsselte Verbindung (http). Zugangsdaten können im selben WLAN mitgelesen werden. Wenn dein Anbieter https unterstützt, nutze https://.'),
                            style: TextStyle(
                                fontSize: 12.5,
                                height: 1.4,
                                color: AppColors.textDim),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                if (isXtream) ...[
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _user,
                    autocorrect: false,
                    enableSuggestions: false,
                    enableIMEPersonalizedLearning: false,
                    decoration: InputDecoration(labelText: tr('Benutzername')),
                    validator: (v) =>
                        (v == null || v.isEmpty) ? tr('Pflichtfeld') : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _pass,
                    obscureText: !_showPass,
                    autocorrect: false,
                    enableSuggestions: false,
                    enableIMEPersonalizedLearning: false,
                    keyboardType: TextInputType.visiblePassword,
                    decoration: InputDecoration(
                      labelText: tr('Passwort'),
                      suffixIcon: IconButton(
                        tooltip: _showPass ? tr('Verbergen') : tr('Anzeigen'),
                        icon: Icon(_showPass
                            ? Icons.visibility_off_rounded
                            : Icons.visibility_rounded),
                        onPressed: () =>
                            setState(() => _showPass = !_showPass),
                      ),
                    ),
                    validator: (v) =>
                        (v == null || v.isEmpty) ? tr('Pflichtfeld') : null,
                  ),
                ],
                if (_type == PortalType.stalker) ...[
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _mac,
                    autocorrect: false,
                    enableSuggestions: false,
                    textCapitalization: TextCapitalization.characters,
                    decoration: InputDecoration(
                      labelText: tr('MAC-Adresse'),
                      helperText: tr('Steht im Vertrag/Kundenbereich deines Anbieters'),
                    ),
                    validator: (v) => RegExp(
                                r'^([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}$')
                            .hasMatch(v?.trim() ?? '')
                        ? null
                        : tr('Format: 00:1A:79:XX:XX:XX'),
                  ),
                ],
                const SizedBox(height: 12),
                TextFormField(
                  controller: _epg,
                  keyboardType: TextInputType.url,
                  validator: (v) => (v == null || v.trim().isEmpty ||
                          UrlPolicy.isWeb(v))
                      ? null
                      : tr('Ungültige Adresse'),
                  decoration: InputDecoration(
                    labelText: tr('EPG-URL (XMLTV, optional)'),
                    helperText:
                        tr('Bei Xtream wird sonst das Server-EPG verwendet.'),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  Text(_error!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)),
                ],
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: _busy ? null : _save,
                  icon: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.check),
                  label: Text(_busy ? tr('Verbinde…') : tr('Speichern & verbinden')),
                ),
                const SizedBox(height: 16),
                Row(children: [
                  Icon(Icons.verified_user_rounded,
                      size: 16, color: AppColors.catchup),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      tr('Zugangsdaten werden verschlüsselt im Android-Schlüsselspeicher abgelegt und nur an deinen Server gesendet.'),
                      style: TextStyle(fontSize: 12, color: AppColors.textFaint),
                    ),
                  ),
                ]),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
