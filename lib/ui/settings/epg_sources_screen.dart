import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/security.dart';
import '../../core/theme.dart';
import '../../data/epg_window.dart';
import '../../l10n/strings.dart';
import '../../models/models.dart';
import '../../state/providers.dart';
import '../widgets/dpad_text_field.dart';

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
  /// Zeitversatz je Quelle in Minuten (Schlüssel: Adresse bzw. „portal“).
  late final Map<String, int> _offsets;
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
    _offsets = {...widget.portal.epgOffsets};
  }

  /// Gewählte Quellen als (Schlüssel, Anzeigename) – für den Zeitversatz.
  /// Länder-EPG mit mehreren Dateien: Schlüssel = erste Datei.
  List<(String, String)> get _activeSources => [
        for (final p in EpgPreset.all)
          if (_presets.contains(p.id)) (p.urls.first, tr(p.label)),
        for (final u in _custom) (u, Redactor.redact(u)),
        if (_provider) ('portal', tr('EPG vom Portal')),
      ];

  Future<void> _pickOffset(String key, String label) async {
    final cur = _offsets[key] ?? 0;
    final v = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(trf('Zeitversatz: {0}', [label])),
        children: [
          for (final m in EpgWindow.offsetSteps)
            ListTile(
              key: ValueKey('offset_$m'),
              autofocus: m == cur, // Fernbedienung: Start beim aktuellen Wert
              dense: true,
              leading: Icon(
                  m == cur
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                  size: 18),
              title: Text(EpgWindow.offsetLabel(m)),
              onTap: () => Navigator.pop(ctx, m),
            ),
        ],
      ),
    );
    if (v == null || !mounted) return;
    setState(() => v == 0 ? _offsets.remove(key) : _offsets[key] = v);
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
    // Versatz eines Länder-EPG gilt für alle seine Dateien.
    final offsets = <String, int>{};
    for (final p in EpgPreset.all) {
      final m = _offsets[p.urls.first] ?? 0;
      if (_presets.contains(p.id) && m != 0) {
        for (final u in p.urls) {
          offsets[u] = m;
        }
      }
    }
    for (final k in [..._custom, if (_provider) 'portal']) {
      final m = _offsets[k] ?? 0;
      if (m != 0) offsets[k] = EpgWindow.clampOffset(m);
    }
    if (list.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(tr('Mindestens eine Quelle auswählen'))));
      return;
    }
    setState(() => _saving = true);
    // Notifier vor dem Schließen holen: nach dem Pop ist „ref“ dieser Seite
    // nicht mehr nutzbar und der Neuladen-Aufruf ginge verloren.
    final epg = ref.read(epgProvider.notifier);
    await ref
        .read(portalsProvider.notifier)
        .setEpgSources(widget.portal.copyWith(epgOffsets: offsets), list);
    // Mit den neuen Quellen sofort neu laden.
    Future.delayed(const Duration(milliseconds: 300),
        () => epg.refresh(force: true));
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
          for (final (i, p) in EpgPreset.all.indexed)
            CheckboxListTile(
              autofocus: i == 0, // Fernbedienung: Start in der Liste
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
              child: DpadTextField(
                controller: _ctrl,
                builder: (_, dp) => TextField(
                  controller: _ctrl,
                  keyboardType: TextInputType.url,
                  decoration: InputDecoration(
                      hintText: 'https://…/epg.xml.gz',
                      prefixIcon: const Icon(Icons.add_link_rounded)),
                  onSubmitted: (_) => _addCustom(),
                  readOnly: dp.readOnly,
                  showCursor: dp.showCursor,
                  onTap: dp.onTap,
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filledTonal(
              tooltip: tr('Hinzufügen'),
              onPressed: _addCustom,
              icon: const Icon(Icons.add_rounded),
            ),
          ]),
          if (_activeSources.isNotEmpty) ...[
            const SizedBox(height: 18),
            Text(tr('ZEITVERSATZ'), style: t.labelSmall),
            const SizedBox(height: 4),
            Text(
                tr('Falls Sendungen zu früh oder zu spät angezeigt werden: Versatz pro Quelle (−3 bis +3 Std.).'),
                style: t.bodySmall),
            const SizedBox(height: 4),
            for (final (key, label) in _activeSources)
              ListTile(
                key: ValueKey('offset-tile-$label'),
                leading: const Icon(Icons.schedule_rounded),
                title: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: Text(EpgWindow.offsetLabel(_offsets[key] ?? 0),
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, color: AppColors.accent)),
                onTap: () => _pickOffset(key, label),
              ),
          ],
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
  final epg = ref.read(epgProvider.notifier);
  await ref
      .read(portalsProvider.notifier)
      .setEpgSources(p, [...preset.urls, 'portal']);
  await Future<void>.delayed(const Duration(milliseconds: 300));
  await epg.refresh(force: true);
}
