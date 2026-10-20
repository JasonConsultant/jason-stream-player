import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/security.dart';
import '../../core/theme.dart';
import '../../l10n/strings.dart';
import '../../models/models.dart';
import '../../state/providers.dart';

/// Fertige, kleine EPG-Dateien pro Land (frei verfügbar, täglich aktuell).
/// Viel kleiner als das Gesamt-EPG vieler Anbieter → lädt in Sekunden.
class EpgPreset {
  final String id;
  final String label;
  final String flag;
  final List<String> urls;
  final String size;
  const EpgPreset(this.id, this.label, this.flag, this.urls, this.size);

  static const _base = 'https://epgshare01.online/epgshare01/epg_ripper_';
  static const all = [
    EpgPreset('de', 'Deutschland', '🇩🇪', ['${_base}DE1.xml.gz'], '4 MB'),
    EpgPreset('at', 'Österreich', '🇦🇹', ['${_base}AT1.xml.gz'], '4 MB'),
    EpgPreset('ch', 'Schweiz', '🇨🇭', ['${_base}CH1.xml.gz'], '6 MB'),
    EpgPreset('tr', 'Türkei', '🇹🇷',
        ['${_base}TR1.xml.gz', '${_base}TR3.xml.gz'], '2 MB'),
    EpgPreset('uk', 'Großbritannien', '🇬🇧', ['${_base}UK1.xml.gz'], '3 MB'),
    EpgPreset('al', 'Albanien', '🇦🇱', ['${_base}AL1.xml.gz'], '0,3 MB'),
  ];
}

/// Kurzbeschreibung der gewählten Quellen für die Einstellungen.
String epgSourcesSummary(Portal p) {
  final src = p.epgSources;
  final parts = <String>[];
  for (final pr in EpgPreset.all) {
    if (pr.urls.every(src.contains)) parts.add(tr(pr.label));
  }
  final known = {for (final pr in EpgPreset.all) ...pr.urls, 'portal'};
  final custom = src.where((s) => !known.contains(s)).length;
  if (custom > 0) parts.add(trf('{0} eigene', [custom]));
  if (src.contains('portal')) parts.add(tr('Anbieter'));
  return parts.isEmpty ? tr('Keine') : parts.join(' + ');
}

class EpgSourcesScreen extends ConsumerStatefulWidget {
  final Portal portal;
  const EpgSourcesScreen({super.key, required this.portal});

  @override
  ConsumerState<EpgSourcesScreen> createState() => _EpgSourcesScreenState();
}

class _EpgSourcesScreenState extends ConsumerState<EpgSourcesScreen> {
  late final Set<String> _presets;
  late bool _provider;
  late final List<String> _custom;
  final _ctrl = TextEditingController();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final src = widget.portal.epgSources;
    _presets = {
      for (final p in EpgPreset.all)
        if (p.urls.every(src.contains)) p.id
    };
    _provider = src.contains('portal');
    final known = {for (final p in EpgPreset.all) ...p.urls, 'portal'};
    _custom = src.where((s) => !known.contains(s)).toList();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _addCustom() {
    final v = _ctrl.text.trim();
    if (v.isEmpty) return;
    if (!UrlPolicy.isWeb(v)) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(tr('Bitte eine gültige http(s)-Adresse eingeben'))));
      return;
    }
    setState(() {
      if (!_custom.contains(v)) _custom.add(v);
      _ctrl.clear();
    });
  }

  Future<void> _save() async {
    // Reihenfolge: Länder-EPG, eigene, dann Anbieter (füllt Lücken).
    final list = <String>[
      for (final p in EpgPreset.all)
        if (_presets.contains(p.id)) ...p.urls,
      ..._custom,
      if (_provider) 'portal',
    ];
    if (list.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(tr('Mindestens eine Quelle auswählen'))));
      return;
    }
    setState(() => _saving = true);
    await ref
        .read(portalsProvider.notifier)
        .setEpgSources(widget.portal, list);
    // Mit den neuen Quellen sofort neu laden.
    Future.delayed(const Duration(milliseconds: 300),
        () => ref.read(epgProvider.notifier).refresh(force: true));
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final isStalker = widget.portal.type == PortalType.stalker;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('EPG-Quellen')),
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
          Text(
            tr('Das EPG des Anbieters enthält oft alle Länder und ist sehr groß. '
                'Ein Länder-EPG ist viel kleiner und lädt in Sekunden. '
                'Sender werden automatisch über den Namen zugeordnet.'),
            style: t.bodySmall?.copyWith(height: 1.5),
          ),
          const SizedBox(height: 18),
          Text(tr('LÄNDER-EPG'), style: t.labelSmall),
          const SizedBox(height: 6),
          for (final p in EpgPreset.all)
            CheckboxListTile(
              value: _presets.contains(p.id),
              onChanged: (v) => setState(() =>
                  v == true ? _presets.add(p.id) : _presets.remove(p.id)),
              secondary: Text(p.flag, style: const TextStyle(fontSize: 24)),
              title: Text(tr(p.label)),
              subtitle: Text(trf('ca. {0} · täglich aktuell', [p.size])),
            ),
          const SizedBox(height: 14),
          Text(tr('ANBIETER'), style: t.labelSmall),
          const SizedBox(height: 6),
          CheckboxListTile(
            value: _provider,
            onChanged: (v) => setState(() => _provider = v ?? false),
            secondary: const Icon(Icons.dns_outlined),
            title: Text(tr('EPG vom Portal')),
            subtitle: Text(isStalker
                ? tr('Programm direkt vom MAC-Portal')
                : tr('Vollständig, aber oft groß und langsam. Zusammen mit '
                    'einem Länder-EPG füllt es nur Lücken.')),
          ),
          const SizedBox(height: 14),
          Text(tr('EIGENE ADRESSEN (XMLTV)'), style: t.labelSmall),
          const SizedBox(height: 6),
          for (final u in _custom)
            ListTile(
              leading: const Icon(Icons.link_rounded),
              title: Text(Redactor.redact(u),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: IconButton(
                tooltip: tr('Entfernen'),
                icon: const Icon(Icons.close_rounded),
                onPressed: () => setState(() => _custom.remove(u)),
              ),
            ),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _ctrl,
                keyboardType: TextInputType.url,
                decoration: InputDecoration(
                    hintText: 'https://…/epg.xml.gz',
                    prefixIcon: const Icon(Icons.add_link_rounded)),
                onSubmitted: (_) => _addCustom(),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filledTonal(
              tooltip: tr('Hinzufügen'),
              onPressed: _addCustom,
              icon: const Icon(Icons.add_rounded),
            ),
          ]),
          const SizedBox(height: 20),
          Row(children: [
            const Icon(Icons.info_outline_rounded,
                size: 16, color: AppColors.textFaint),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                tr('Länder-EPG von epgshare01.online (frei verfügbar).'),
                style: t.bodySmall?.copyWith(color: AppColors.textFaint),
              ),
            ),
          ]),
        ],
      ),
    );
  }
}

/// Passendes Länder-EPG aus den Sendernamen raten („DE • ZDF“ → Deutschland).
EpgPreset suggestPreset(List<Channel> channels) {
  final re = RegExp(r'^\W*([A-Za-z]{2})\b');
  const map = {
    'DE': 'de', 'GER': 'de', 'AT': 'at', 'CH': 'ch', 'TR': 'tr',
    'UK': 'uk', 'GB': 'uk', 'AL': 'al',
  };
  final count = <String, int>{};
  for (final c in channels.take(5000)) {
    final m = re.firstMatch(c.name);
    final id = m == null ? null : map[m.group(1)!.toUpperCase()];
    if (id != null) count[id] = (count[id] ?? 0) + 1;
  }
  String id = L10n.lang == 'tr' ? 'tr' : 'de';
  if (count.isNotEmpty) {
    id = (count.entries.toList()..sort((a, b) => b.value.compareTo(a.value)))
        .first
        .key;
  }
  return EpgPreset.all.firstWhere((p) => p.id == id);
}

/// Mit einem Tippen: Länder-EPG zuerst, Anbieter-EPG füllt Lücken.
Future<void> useCountryEpg(WidgetRef ref, Portal p, EpgPreset preset) async {
  await ref
      .read(portalsProvider.notifier)
      .setEpgSources(p, [...preset.urls, 'portal']);
  await Future<void>.delayed(const Duration(milliseconds: 300));
  await ref.read(epgProvider.notifier).refresh(force: true);
}
