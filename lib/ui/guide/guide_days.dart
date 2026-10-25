import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../data/epg_window.dart';
import '../../l10n/strings.dart';
import '../../models/models.dart';

/// Tage für die Tagesauswahl im TV-Guide (relativ zu heute): höchstens
/// 7 zurück und 7 voraus, nur soweit das EPG Sendungen hat. Heute ist immer
/// dabei. Geprüft werden nur erste/letzte Sendung je Sender (schnell).
List<int> guideDayOffsets(Map<String, List<EpgEntry>> epg, DateTime now) {
  DateTime? lo, hi;
  for (final l in epg.values) {
    if (l.isEmpty) continue;
    if (lo == null || l.first.start.isBefore(lo)) lo = l.first.start;
    if (hi == null || l.last.end.isAfter(hi)) hi = l.last.end;
  }
  return guideDayOffsetsRange(lo, hi, now);
}

/// Wie [guideDayOffsets] mit bekannter erster/letzter Sendung (ab 2.0 aus
/// der Datenbank – der Speicher hält nur gestern … übermorgen).
List<int> guideDayOffsetsRange(DateTime? lo, DateTime? hi, DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  int dayOf(DateTime t) =>
      (DateTime(t.year, t.month, t.day).difference(today).inHours / 24).round();
  final back = EpgWindow.back.inDays, fwd = EpgWindow.forward.inDays;
  final first = lo == null ? 0 : dayOf(lo).clamp(-back, 0);
  // Endet die letzte Sendung genau um Mitternacht, zählt der Tag nicht.
  final last = hi == null
      ? 0
      : dayOf(hi.subtract(const Duration(seconds: 1))).clamp(0, fwd);
  return [for (var d = first; d <= last; d++) d];
}

/// „Gestern“, „Heute“, „Morgen“, sonst „Mi 23.10.“.
String guideDayLabel(int offset, DateTime now) {
  switch (offset) {
    case -1:
      return tr('Gestern');
    case 0:
      return tr('Heute');
    case 1:
      return tr('Morgen');
  }
  final d = DateTime(now.year, now.month, now.day + offset);
  return DateFormat('EEE dd.MM.', L10n.lang).format(d);
}

/// Tagesauswahl als Chips (Fernbedienung: Start auf dem gewählten Tag,
/// ◀▶▲▼ wechseln, OK wählt, Zurück schließt).
Future<int?> pickGuideDay(BuildContext context, int current, List<int> days) {
  final now = DateTime.now();
  return showDialog<int>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(tr('Tag wählen')),
      content: SingleChildScrollView(
        child: Wrap(spacing: 8, runSpacing: 8, children: [
          for (final d in days)
            ChoiceChip(
              key: ValueKey('guide_day_$d'),
              autofocus: d == current,
              label: Text(guideDayLabel(d, now)),
              selected: d == current,
              showCheckmark: false,
              onSelected: (_) => Navigator.pop(ctx, d),
            ),
        ]),
      ),
    ),
  );
}
