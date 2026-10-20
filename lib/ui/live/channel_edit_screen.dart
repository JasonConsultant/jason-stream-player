import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/security.dart';
import '../../core/theme.dart';
import '../../l10n/strings.dart';
import '../../models/models.dart';
import '../../state/providers.dart';
import '../widgets/artwork.dart';
import '../widgets/common.dart';

/// Sender anpassen (wie TiviMate): Name, Logo-Adresse und EPG-Zuordnung.
/// Gespeichert pro Portal als [ChannelOverride]; das Original bleibt
/// unangetastet und lässt sich jederzeit wiederherstellen.
class ChannelEditScreen extends ConsumerStatefulWidget {
  /// Der Sender, wie er gerade angezeigt wird (ggf. schon überschrieben).
  final Channel channel;
  const ChannelEditScreen({super.key, required this.channel});

  @override
  ConsumerState<ChannelEditScreen> createState() => _ChannelEditScreenState();
}

class _ChannelEditScreenState extends ConsumerState<ChannelEditScreen> {
  late final Channel _orig;
  late final TextEditingController _name;
  late final TextEditingController _logo;

  /// EPG-Zuordnung: null = automatisch, '' = kein EPG, sonst XMLTV-Kennung.
  String? _epg;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _orig = ref.read(liveDataProvider.notifier).original(widget.channel.id) ??
        widget.channel;
    _name = TextEditingController(text: widget.channel.name);
    _logo = TextEditingController(text: widget.channel.logoUrl ?? '');
    final portal = ref.read(activePortalProvider).value;
    final st = ref.read(storageProvider).value;
    _epg = (portal == null || st == null)
        ? null
        : st.overrides(portal.id)[widget.channel.id]?.epgId;
    _name.addListener(_changed);
    _logo.addListener(_changed);
  }

  void _changed() => setState(() {});

  @override
  void dispose() {
    _name.dispose();
    _logo.dispose();
    super.dispose();
  }

  String get _origEpg => _orig.epgId ?? '';

  /// Kennung, die nach dem Speichern wirksam wäre ('' = keine).
  String get _effectiveEpg => _epg ?? _origEpg;

  Future<void> _save() async {
    final logo = _logo.text.trim();
    if (logo.isNotEmpty && !UrlPolicy.isWeb(logo)) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(tr('Bitte eine gültige http(s)-Adresse eingeben'))));
      return;
    }
    setState(() => _saving = true);
    final name = _name.text.trim();
    final o = ChannelOverride(
      name: (name.isEmpty || name == _orig.name) ? null : name,
      logoUrl: (logo.isEmpty || logo == (_orig.logoUrl ?? '')) ? null : logo,
      epgId: _epg == _origEpg ? null : _epg,
    );
    final before = widget.channel.epgId ?? '';
    final after = o.epgId ?? _origEpg;
    final live = ref.read(liveDataProvider.notifier);
    final epgNotifier = ref.read(epgProvider.notifier);
    final loaded = ref.read(epgProvider).value ?? const {};
    final messenger = ScaffoldMessenger.of(context);
    await live.setOverride(widget.channel.id, o);
    // Neue Kennung, deren Programm noch nicht geladen ist → EPG neu laden
    // (der Download behält nur Sender, die es in der Liste gibt).
    if (after != before && after.isNotEmpty && !loaded.containsKey(after)) {
      messenger.showSnackBar(
          SnackBar(content: Text(tr('Programm wird neu geladen'))));
      Future.delayed(const Duration(milliseconds: 300),
          () => epgNotifier.refresh(force: true));
    }
    if (mounted) Navigator.pop(context);
  }

  Future<void> _pickEpg() async {
    final picked = await Navigator.of(context).push<_EpgPick>(
      MaterialPageRoute(
          builder: (_) => _EpgPickerScreen(
              channel: _orig, current: _epg, autoId: _origEpg)),
    );
    if (picked == null || !mounted) return;
    setState(() => _epg = picked.id);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final names = ref.watch(epgChannelNamesProvider);
    final logo = _logo.text.trim();
    final nameChanged = _name.text.trim() != _orig.name;
    final logoChanged = logo != (_orig.logoUrl ?? '');

    String epgLabel() {
      final e = _epg;
      if (e == null) {
        return _origEpg.isEmpty
            ? '${tr('Automatisch')} · ${tr('über den Namen')}'
            : '${tr('Automatisch')} · ${_describe(_origEpg, names)}';
      }
      if (e.isEmpty) return tr('Kein EPG');
      return '${tr('Manuell')} · ${_describe(e, names)}';
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(tr('Sender bearbeiten')),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton(
              onPressed: _saving ? null : _save,
              child: Text(tr('Speichern')),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 40),
        children: [
          Row(children: [
            ChannelLogo(
                name: _name.text.trim().isEmpty ? _orig.name : _name.text.trim(),
                url: logo.isEmpty ? null : logo,
                size: 56),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_orig.name, style: t.titleMedium),
                    Text(trf('Kanal {0}', [_orig.number]), style: t.bodySmall),
                  ]),
            ),
          ]),
          const SizedBox(height: 12),
          Text(
            tr('Name, Logo und EPG-Zuordnung dieses Senders anpassen. '
                'Die Änderungen gelten nur in dieser App und nur für dieses Portal.'),
            style: t.bodySmall?.copyWith(height: 1.5),
          ),
          const SizedBox(height: 18),
          Text(tr('NAME'), style: t.labelSmall),
          const SizedBox(height: 6),
          TextField(
            controller: _name,
            maxLength: 60,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
              hintText: _orig.name,
              counterText: '',
              suffixIcon: nameChanged
                  ? IconButton(
                      tooltip: tr('Zurücksetzen'),
                      icon: const Icon(Icons.restart_alt_rounded),
                      onPressed: () => _name.text = _orig.name,
                    )
                  : null,
            ),
          ),
          const SizedBox(height: 18),
          Text(tr('LOGO-ADRESSE'), style: t.labelSmall),
          const SizedBox(height: 6),
          TextField(
            controller: _logo,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              hintText: 'https://…/logo.png',
              errorText: logo.isNotEmpty && !UrlPolicy.isWeb(logo)
                  ? tr('Bitte eine gültige http(s)-Adresse eingeben')
                  : null,
              suffixIcon: logoChanged
                  ? IconButton(
                      tooltip: tr('Zurücksetzen'),
                      icon: const Icon(Icons.restart_alt_rounded),
                      onPressed: () => _logo.text = _orig.logoUrl ?? '',
                    )
                  : null,
            ),
          ),
          const SizedBox(height: 18),
          Text(tr('EPG-ZUORDNUNG'), style: t.labelSmall),
          const SizedBox(height: 6),
          ListTile(
            leading: Icon(
                _epg == null
                    ? Icons.auto_awesome_rounded
                    : _epg!.isEmpty
                        ? Icons.tv_off_rounded
                        : Icons.link_rounded,
                color: AppColors.accent),
            title: Text(epgLabel(), maxLines: 2, overflow: TextOverflow.ellipsis),
            subtitle: Text(_effectiveEpg.isEmpty
                ? tr('Tippen, um einen EPG-Sender zu wählen')
                : _effectiveEpg),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: _pickEpg,
          ),
          if (_epg != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => setState(() => _epg = null),
                  icon: const Icon(Icons.restart_alt_rounded),
                  label: Text(tr('Automatisch zuordnen')),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// „ZDF HD (ZDF.de)“ bzw. nur die Kennung, wenn kein Name bekannt ist.
String _describe(String id, Map<String, String> names) {
  final n = names[id];
  return (n == null || n.isEmpty || n == id) ? id : '$n ($id)';
}

class _EpgPick {
  /// null = automatisch, '' = kein EPG, sonst Kennung.
  final String? id;
  const _EpgPick(this.id);
}

/// Durchsuchbare Liste aller EPG-Sender der geladenen Quellen.
class _EpgPickerScreen extends ConsumerStatefulWidget {
  final Channel channel;
  final String? current;
  final String autoId;
  const _EpgPickerScreen(
      {required this.channel, required this.current, required this.autoId});

  @override
  ConsumerState<_EpgPickerScreen> createState() => _EpgPickerScreenState();
}

class _EpgPickerScreenState extends ConsumerState<_EpgPickerScreen> {
  final _search = TextEditingController();
  String _q = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final names = ref.watch(epgChannelNamesProvider);
    final loaded = ref.watch(epgProvider).value ?? const {};
    // Alle bekannten Kennungen: Senderliste der Quellen + bereits geladene
    // Programme (ohne „@…“ – das sind Sender ohne Kennung).
    final ids = <String>{
      ...names.keys,
      for (final k in loaded.keys)
        if (!k.startsWith('@')) k,
    }.toList();
    final q = _q.toLowerCase();
    final hits = q.isEmpty
        ? ids
        : ids
            .where((id) =>
                id.toLowerCase().contains(q) ||
                (names[id]?.toLowerCase().contains(q) ?? false))
            .toList();
    hits.sort((a, b) => (names[a] ?? a)
        .toLowerCase()
        .compareTo((names[b] ?? b).toLowerCase()));

    final current = widget.current;
    final selectedId = current ?? widget.autoId;

    return Scaffold(
      appBar: AppBar(title: Text(tr('EPG-Zuordnung'))),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: TextField(
            controller: _search,
            autofocus: true,
            decoration: InputDecoration(
              hintText: tr('Sender oder Kennung suchen …'),
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: _q.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () {
                        _search.clear();
                        setState(() => _q = '');
                      }),
            ),
            onChanged: (v) => setState(() => _q = v.trim()),
          ),
        ),
        Expanded(
          child: ids.isEmpty
              ? EmptyState(
                  icon: Icons.tv_off_rounded,
                  title: tr('Keine EPG-Sender bekannt'),
                  message: tr('Zuerst ein EPG laden (Einstellungen → EPG-Quellen).'))
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 24),
                  itemCount: hits.length + 2,
                  itemBuilder: (_, i) {
                    if (i == 0) {
                      return ListTile(
                        leading: const Icon(Icons.auto_awesome_rounded),
                        title: Text(tr('Automatisch')),
                        subtitle: Text(widget.autoId.isEmpty
                            ? tr('über den Namen')
                            : _describe(widget.autoId, names)),
                        selected: current == null,
                        onTap: () =>
                            Navigator.pop(context, const _EpgPick(null)),
                      );
                    }
                    if (i == 1) {
                      return ListTile(
                        leading: const Icon(Icons.tv_off_rounded),
                        title: Text(tr('Kein EPG')),
                        selected: current == '',
                        onTap: () => Navigator.pop(context, const _EpgPick('')),
                      );
                    }
                    final id = hits[i - 2];
                    final n = names[id];
                    return ListTile(
                      leading: Icon(
                          id == selectedId
                              ? Icons.check_circle_rounded
                              : Icons.circle_outlined,
                          color: id == selectedId ? AppColors.accent : null),
                      title: Text((n == null || n.isEmpty) ? id : n,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: (n == null || n.isEmpty || n == id)
                          ? null
                          : Text(id, maxLines: 1, overflow: TextOverflow.ellipsis),
                      selected: current == id,
                      onTap: () => Navigator.pop(context, _EpgPick(id)),
                    );
                  },
                ),
        ),
      ]),
    );
  }
}
