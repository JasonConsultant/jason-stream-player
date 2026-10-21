import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/content_filters.dart';
import '../../l10n/strings.dart';
import '../../state/content_filter.dart';

/// Anzeigename eines Landes bzw. Sammelbeckens.
String countryLabel(String code) => switch (code) {
      'DE' => tr('Deutschland'),
      'AT' => tr('Österreich'),
      'CH' => tr('Schweiz'),
      'TR' => tr('Türkei'),
      'UK' => tr('Großbritannien'),
      'AL' => tr('Albanien'),
      'FR' => tr('Frankreich'),
      'IT' => tr('Italien'),
      'ES' => tr('Spanien'),
      'PT' => tr('Portugal'),
      'NL' => tr('Niederlande'),
      'BE' => tr('Belgien'),
      'PL' => tr('Polen'),
      'RO' => tr('Rumänien'),
      'EXYU' => tr('Ex-Jugoslawien (RS, HR, BA …)'),
      'GR' => tr('Griechenland'),
      'BG' => tr('Bulgarien'),
      'HU' => tr('Ungarn'),
      'CZ' => tr('Tschechien/Slowakei'),
      'RU' => tr('Russland'),
      'UA' => tr('Ukraine'),
      'SE' => tr('Schweden'),
      'NO' => tr('Norwegen'),
      'DK' => tr('Dänemark'),
      'FI' => tr('Finnland'),
      'KU' => tr('Kurdisch'),
      'AR' => tr('Arabisch'),
      'IR' => tr('Iran/Persisch'),
      'IN' => tr('Indien'),
      'PK' => tr('Pakistan'),
      'AF' => tr('Afghanistan'),
      'US' => tr('USA'),
      'CA' => tr('Kanada'),
      'LATAM' => tr('Lateinamerika'),
      CountryDetector.none => tr('Ohne Länderkennung'),
      _ => code,
    };

String countryFlag(String code) => switch (code) {
      'DE' => '🇩🇪',
      'AT' => '🇦🇹',
      'CH' => '🇨🇭',
      'TR' => '🇹🇷',
      'UK' => '🇬🇧',
      'AL' => '🇦🇱',
      'FR' => '🇫🇷',
      'IT' => '🇮🇹',
      'ES' => '🇪🇸',
      'PT' => '🇵🇹',
      'NL' => '🇳🇱',
      'BE' => '🇧🇪',
      'PL' => '🇵🇱',
      'RO' => '🇷🇴',
      'EXYU' => '🇷🇸',
      'GR' => '🇬🇷',
      'BG' => '🇧🇬',
      'HU' => '🇭🇺',
      'CZ' => '🇨🇿',
      'RU' => '🇷🇺',
      'UA' => '🇺🇦',
      'SE' => '🇸🇪',
      'NO' => '🇳🇴',
      'DK' => '🇩🇰',
      'FI' => '🇫🇮',
      'IR' => '🇮🇷',
      'IN' => '🇮🇳',
      'PK' => '🇵🇰',
      'AF' => '🇦🇫',
      'US' => '🇺🇸',
      'CA' => '🇨🇦',
      'AR' || 'KU' || 'LATAM' => '🌍',
      _ => '🏳️',
    };

/// Kurzbeschreibung für die Einstellungen („Alle“ oder „DE, TR“).
String countryFilterSummary(Set<String> selected) {
  if (selected.isEmpty) return tr('Alle');
  final list = [
    for (final c in [...CountryDetector.codes, CountryDetector.none])
      if (selected.contains(c)) c == CountryDetector.none ? tr('Ohne') : c
  ];
  return list.join(', ');
}

/// „Länder anzeigen“: erkannte Länder aus Gruppen- und Sendernamen,
/// Mehrfachauswahl (sofort gespeichert, pro Portal). Keine Auswahl = alle.
class CountryFilterScreen extends ConsumerWidget {
  const CountryFilterScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final selected = ref.watch(countryFilterProvider);
    // Einmal je Liste berechnet (große Anbieter: im Hintergrund).
    final counts = ref.watch(countryCountsProvider).value ?? const {};
    final codes = [
      for (final c in CountryDetector.codes)
        if ((counts[c] ?? 0) > 0 || selected.contains(c)) c,
      if ((counts[CountryDetector.none] ?? 0) > 0 ||
          selected.contains(CountryDetector.none))
        CountryDetector.none,
    ];
    final notifier = ref.read(countryFilterProvider.notifier);

    void toggle(String code, bool on) {
      final next = {...selected};
      on ? next.add(code) : next.remove(code);
      notifier.set(next);
    }

    return Scaffold(
      appBar: AppBar(title: Text(tr('Länder anzeigen'))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 40),
        children: [
          Text(
            tr('Nur Sender, Filme und Serien der gewählten Länder zeigen – in Live TV, TV-Guide, Suche und auf der Startseite. Erkannt am Kürzel im Gruppen- oder Sendernamen (z. B. „DE | Sport“).'),
            style: t.bodySmall?.copyWith(height: 1.5),
          ),
          const SizedBox(height: 12),
          CheckboxListTile(
            key: const ValueKey('country_all'),
            autofocus: true,
            value: selected.isEmpty,
            onChanged: (_) => notifier.set(const {}),
            secondary: const Icon(Icons.public_rounded),
            title: Text(tr('Alle Länder')),
          ),
          const Divider(height: 1, color: AppColors.surface3),
          if (codes.isEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                  tr('Noch keine Länder erkannt – Senderliste wird geladen …'),
                  style: t.bodySmall),
            ),
          for (final c in codes)
            CheckboxListTile(
              key: ValueKey('country_$c'),
              value: selected.contains(c),
              onChanged: (v) => toggle(c, v ?? false),
              secondary:
                  Text(countryFlag(c), style: const TextStyle(fontSize: 22)),
              title: Text(countryLabel(c)),
              subtitle: Text(trf('{0} Einträge', [counts[c] ?? 0])),
            ),
        ],
      ),
    );
  }
}
