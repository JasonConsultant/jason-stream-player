import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/models.dart';
import 'providers.dart';

/// Feingranulare EPG-Sicht für einzelne Zeilen/Kacheln.
///
/// Bildschirme beobachten nicht mehr die ganze EPG-Map (jede Änderung –
/// etwa ein nachgeladenes Kurz-EPG für 4 Sender – baute sonst alle Zeilen
/// aller offenen Reiter neu), sondern je Sender nur dessen Programmliste.
/// Solange der EPG-Notifier unveränderte Listen beim Ersetzen der Map
/// übernimmt (Identität), meldet sich hier nichts.

/// Programm eines Senders (nach EPG-Schlüssel), leer wenn unbekannt.
final channelEntriesProvider =
    Provider.autoDispose.family<List<EpgEntry>, String>((ref, key) {
  return ref.watch(epgProvider.select((a) => a.value?[key])) ??
      const <EpgEntry>[];
});

/// Laufende und nächste Sendung eines Senders (Minutentakt). Meldet sich nur,
/// wenn sich die *Sendung* ändert (Programmwechsel, neues EPG) – nicht bei
/// jedem Takt; Fortschrittsbalken ticken selbst (siehe `MinuteBuilder`).
final nowNextProvider =
    Provider.autoDispose.family<NowNext, Channel>((ref, c) {
  final list = ref.watch(channelEntriesProvider(epgKeyOf(c)));
  ref.watch(minuteTickProvider);
  return NowNext.of(list, DateTime.now());
});

/// Ergebnis von [nowNextProvider]; gleich, wenn Liste und Sendungen
/// identisch sind.
class NowNext {
  /// Vollständiges Programm des Senders (sortiert nach Beginn).
  final List<EpgEntry> entries;
  final EpgEntry? now;
  final EpgEntry? next;

  /// Index von [now] in [entries] (−1 ohne laufende Sendung).
  final int index;
  const NowNext(this.entries, this.now, this.next, this.index);

  static const empty = NowNext(<EpgEntry>[], null, null, -1);

  bool get isEmpty => entries.isEmpty;

  /// Bis zu [n] Sendungen nach der laufenden.
  List<EpgEntry> upcoming(int n) => index < 0
      ? const <EpgEntry>[]
      : entries.skip(index + 1).take(n).toList();

  static NowNext of(List<EpgEntry> list, DateTime t) {
    if (list.isEmpty) return NowNext(list, null, null, -1);
    // Binäre Suche wie nowPlaying(): letzte Sendung mit Beginn ≤ t.
    var lo = 0, hi = list.length - 1, found = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (!list[mid].start.isAfter(t)) {
        found = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    if (found < 0 || !list[found].isNowAt(t)) {
      return NowNext(list, null, null, -1);
    }
    final next = found + 1 < list.length ? list[found + 1] : null;
    return NowNext(list, list[found], next, found);
  }

  @override
  bool operator ==(Object other) =>
      other is NowNext &&
      identical(other.entries, entries) &&
      identical(other.now, now) &&
      identical(other.next, next);

  @override
  int get hashCode => Object.hash(
      identityHashCode(entries), identityHashCode(now), identityHashCode(next));
}
