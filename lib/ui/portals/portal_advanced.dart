import 'package:flutter/material.dart';

import '../../core/security.dart';
import '../../core/theme.dart';
import '../../data/stream_headers.dart';
import '../../l10n/strings.dart';
import '../../models/models.dart';
import '../../state/list_refresh.dart';
import '../widgets/dpad_text_field.dart';

/// Werte des Abschnitts „Erweitert“ beim Hinzufügen/Bearbeiten eines Portals.
class PortalAdvancedController extends ChangeNotifier {
  String uaPreset;
  final customUa = TextEditingController();
  final referer = TextEditingController();
  final altUrls = <String>[];

  /// Eingetippte, noch nicht mit „+“ übernommene Ersatz-Adresse – wird beim
  /// Speichern mitgenommen (sonst ginge sie stillschweigend verloren).
  final pendingAlt = TextEditingController();
  int autoRefreshHours;

  PortalAdvancedController.from(Portal? p)
      : uaPreset = UserAgentPreset.idOf(p?.userAgent),
        autoRefreshHours = p?.autoRefreshHours ?? 0 {
    if (uaPreset == 'custom') customUa.text = p?.userAgent ?? '';
    referer.text = p?.referer ?? '';
    altUrls.addAll(p?.altUrls ?? const []);
  }

  /// Etwas vom Standard abweichend (dann Abschnitt gleich aufgeklappt).
  bool get isCustomized =>
      uaPreset != 'app' ||
      referer.text.trim().isNotEmpty ||
      altUrls.isNotEmpty ||
      autoRefreshHours > 0;

  String? get userAgent {
    if (uaPreset == 'custom') {
      final v = customUa.text.trim();
      return v.isEmpty ? null : v;
    }
    for (final p in UserAgentPreset.all) {
      if (p.id == uaPreset) return p.value;
    }
    return null;
  }

  /// Einstellungen auf [p] übertragen.
  Portal applyTo(Portal p) => p.copyWith(
        userAgent: userAgent ?? '',
        referer: referer.text.trim(),
        altUrls: {
          for (final u in [
            ...altUrls,
            if (UrlPolicy.isWeb(pendingAlt.text.trim())) pendingAlt.text
          ])
            if (u.trim().isNotEmpty && u.trim() != p.url.trim()) u.trim()
        }.toList(),
        autoRefreshHours: autoRefreshHours,
      );

  void changed() => notifyListeners();

  @override
  void dispose() {
    for (final c in [customUa, referer, pendingAlt]) {
      c.clear();
      c.dispose();
    }
    altUrls.clear();
    super.dispose();
  }
}

String autoRefreshLabel(int hours) =>
    hours <= 0 ? tr('Aus') : trf('Alle {0} Std.', [hours]);

/// Aufklappbarer Abschnitt „Erweitert“: User-Agent, Referer,
/// Ersatz-Adressen, automatische Aktualisierung.
class PortalAdvancedSection extends StatefulWidget {
  final PortalAdvancedController controller;
  final PortalType type;
  const PortalAdvancedSection(
      {super.key, required this.controller, required this.type});

  @override
  State<PortalAdvancedSection> createState() => _PortalAdvancedSectionState();
}

class _PortalAdvancedSectionState extends State<PortalAdvancedSection> {
  String? _altError;

  PortalAdvancedController get _c => widget.controller;
  TextEditingController get _alt => _c.pendingAlt;

  void _addAlt() {
    final v = _alt.text.trim();
    if (v.isEmpty) return;
    if (!UrlPolicy.isWeb(v)) {
      setState(() =>
          _altError = tr('Bitte eine vollständige http(s)-Adresse eingeben'));
      return;
    }
    setState(() {
      _altError = null;
      if (!_c.altUrls.contains(v)) _c.altUrls.add(v);
      _alt.clear();
    });
    _c.changed();
  }

  Widget _chips<T>(List<T> values, T selected, String Function(T) label,
          void Function(T) onSelect) =>
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final v in values)
          ChoiceChip(
            label: Text(label(v)),
            selected: v == selected,
            showCheckmark: false,
            onSelected: (_) => onSelect(v),
          ),
      ]);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final hint = t.bodySmall?.copyWith(color: AppColors.textFaint, height: 1.4);
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        key: const ValueKey('portal-advanced'),
        initiallyExpanded: _c.isCustomized,
        // Fernbedienung: Nach dem Auf-/Zuklappen hat sich das Layout
        // geändert – die gemerkte Richtung (▲ dann ▼ = zurück) verwerfen,
        // sonst springt ▼ über den aufgeklappten Inhalt hinweg.
        onExpansionChanged: (_) {
          final scope = FocusScope.of(context);
          final policy = FocusTraversalGroup.maybeOf(context);
          void reset() => policy?.invalidateScopeData(scope);

          reset();
          WidgetsBinding.instance.addPostFrameCallback((_) => reset());
        },
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 8),
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        leading: const Icon(Icons.tune_rounded),
        title: Text(tr('Erweitert')),
        subtitle: Text(
            tr('User-Agent, Referer, Ersatz-Adressen, automatische Aktualisierung'),
            style: hint),
        children: [
          Text(tr('User-Agent'), style: t.labelSmall),
          const SizedBox(height: 6),
          _chips<String>(
            [...UserAgentPreset.all.map((p) => p.id), 'custom'],
            _c.uaPreset,
            (id) => switch (id) {
              'app' => tr('App-Standard'),
              'vlc' => 'VLC',
              'browser' => tr('Browser (Mozilla/5.0 …)'),
              _ => tr('Eigener'),
            },
            (id) {
              setState(() => _c.uaPreset = id);
              _c.changed();
            },
          ),
          if (_c.uaPreset == 'custom') ...[
            const SizedBox(height: 8),
            DpadTextField(
              controller: _c.customUa,
              builder: (_, dp) => TextField(
                key: const ValueKey('custom-ua'),
                controller: _c.customUa,
                autocorrect: false,
                enableSuggestions: false,
                decoration:
                    InputDecoration(labelText: tr('Eigener User-Agent')),
                readOnly: dp.readOnly,
                showCursor: dp.showCursor,
                onTap: dp.onTap,
                onSubmitted: (_) => dp.submitted(),
              ),
            ),
          ],
          const SizedBox(height: 14),
          DpadTextField(
            controller: _c.referer,
            builder: (_, dp) => TextField(
              key: const ValueKey('referer'),
              controller: _c.referer,
              keyboardType: TextInputType.url,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: tr('Referer (optional)'),
                hintText: 'https://…',
              ),
              readOnly: dp.readOnly,
              showCursor: dp.showCursor,
              onTap: dp.onTap,
              onSubmitted: (_) => dp.submitted(),
            ),
          ),
          const SizedBox(height: 6),
          Text(
              tr('Wird bei Anfragen an das Portal, beim EPG und beim Abspielen gesendet. Angaben aus der Playlist pro Sender haben Vorrang.'),
              style: hint),
          const SizedBox(height: 16),
          Text(tr('Ersatz-Adressen'), style: t.labelSmall),
          const SizedBox(height: 4),
          Text(
              widget.type == PortalType.m3u
                  ? tr(
                      'Weitere Playlist-Adressen (Spiegel). Antwortet die Hauptadresse nicht, wird automatisch die nächste genommen und gemerkt.')
                  : tr(
                      'Weitere Server-Adressen deines Anbieters. Antwortet der Hauptserver nicht, wird automatisch der nächste genommen und gemerkt – auch für Streams.'),
              style: hint),
          // Eigene Spalte: Hinzufügen/Entfernen verschiebt die folgenden
          // Einträge nicht im Baum (sonst würden Feld und Knöpfe neu
          // aufgebaut und der Fokus der Fernbedienung ginge verloren).
          Column(children: [
            for (final u in _c.altUrls)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.alt_route_rounded),
                title: Text(Redactor.redact(u),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: IconButton(
                  tooltip: tr('Entfernen'),
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () {
                    setState(() => _c.altUrls.remove(u));
                    _c.changed();
                  },
                ),
              ),
          ]),
          // „+“ im Feld (nicht daneben): mit der Fernbedienung führt ▼ vom
          // Referer sonst auf den Knopf statt ins Feld und von dort an der
          // Aktualisierung vorbei. OK/Fertig auf der Tastatur übernimmt auch.
          DpadTextField(
            controller: _alt,
            builder: (_, dp) => TextField(
              key: const ValueKey('alt-url'),
              controller: _alt,
              keyboardType: TextInputType.url,
              autocorrect: false,
              enableSuggestions: false,
              enableIMEPersonalizedLearning: false,
              decoration: InputDecoration(
                hintText: 'http://backup.server:8080',
                errorText: _altError,
                prefixIcon: const Icon(Icons.add_link_rounded),
                suffixIcon: IconButton(
                  tooltip: tr('Hinzufügen'),
                  onPressed: _addAlt,
                  icon: const Icon(Icons.add_rounded),
                ),
              ),
              onSubmitted: (_) {
                // Erst weiter nach unten (Layout noch unverändert), dann die
                // Adresse übernehmen – die neue Zeile darüber verschiebt alles.
                dp.submitted();
                _addAlt();
              },
              readOnly: dp.readOnly,
              showCursor: dp.showCursor,
              onTap: dp.onTap,
            ),
          ),
          const SizedBox(height: 16),
          Text(tr('Listen automatisch aktualisieren'), style: t.labelSmall),
          const SizedBox(height: 6),
          _chips<int>(
              AutoRefresh.choices, _c.autoRefreshHours, autoRefreshLabel, (h) {
            setState(() => _c.autoRefreshHours = h);
            _c.changed();
          }),
          const SizedBox(height: 6),
          Text(
              tr('Sender, Filme und Serien werden beim Start oder Zurückkehren in die App im Hintergrund neu geladen, wenn fällig.'),
              style: hint),
        ],
      ),
    );
  }
}
