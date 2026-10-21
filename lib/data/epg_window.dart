import '../models/models.dart';

/// Zeitfenster und Speichergrenzen des EPG.
///
/// Behalten werden 7 Tage zurück (Catch-up) und 7 Tage voraus – soweit die
/// Quelle das liefert. Damit schwache Boxen (1–2 GB RAM) nicht in
/// Speichernot geraten, gibt es Obergrenzen pro Sender und insgesamt; wird
/// es zu viel, wird zuerst die ferne Zukunft gekürzt, dann die ferne
/// Vergangenheit (mindestens 2 Tage voraus und 1 Tag zurück bleiben).
class EpgWindow {
  EpgWindow._();

  static const back = Duration(days: 7);
  static const forward = Duration(days: 7);

  /// Höchstens so viele Sendungen pro Sender (~15 Tage à 60 Sendungen).
  static const maxPerChannel = 900;

  /// Höchstens so viele Sendungen insgesamt. Gemessen (stress_13_test):
  /// ~300 Byte je Sendung mit Beschreibung → 1,2 Mio. ≈ 350 MB. Auf Geräten
  /// mit wenig RAM senkt [tuneForDevice] die Grenze.
  static int maxTotal = defaultMaxTotal;
  static const defaultMaxTotal = 1200000;

  /// Grenze nach Arbeitsspeicher: ≤ 2,5 GB (z. B. Mi Box, 2 GB) 500 000
  /// Sendungen (≈ 150 MB), „Low-RAM“-Geräte 250 000.
  static void tuneForDevice({required int totalBytes, required bool lowRam}) {
    if (lowRam) {
      maxTotal = 250000;
    } else if (totalBytes <= 2560 << 20) {
      maxTotal = 500000;
    } else {
      maxTotal = defaultMaxTotal;
    }
  }

  static DateTime from(DateTime now) => now.subtract(back);
  static DateTime to(DateTime now) => now.add(forward);

  /// Grenzen anwenden. Listen müssen nach Start sortiert sein; das
  /// Ergebnis ist es ebenfalls. [window]: Zeitfenster auch dann prüfen,
  /// wenn die Mengen-Grenzen eingehalten sind.
  static Map<String, List<EpgEntry>> cap(Map<String, List<EpgEntry>> epg,
      {DateTime? now,
      int? total,
      int perChannel = maxPerChannel,
      bool window = false}) {
    final n = now ?? DateTime.now();
    final limit = total ?? maxTotal;
    var fwd = forward;
    var bwd = back;
    Map<String, List<EpgEntry>> apply() {
      final lo = n.subtract(bwd);
      final hi = n.add(fwd);
      final out = <String, List<EpgEntry>>{};
      for (final e in epg.entries) {
        var list = [
          for (final p in e.value)
            if (p.end.isAfter(lo) && p.start.isBefore(hi)) p
        ];
        if (list.length > perChannel) list = _nearest(list, n, perChannel);
        if (list.isNotEmpty) out[e.key] = list;
      }
      return out;
    }

    int count(Map<String, List<EpgEntry>> m) =>
        m.values.fold(0, (a, l) => a + l.length);
    // Schnellweg: unter den Grenzen → unverändert (spart bei 1 Mio.
    // Sendungen das Umkopieren). Das Zeitfenster hat der Scanner bzw. der
    // Zwischenspeicher beim Lesen schon angewendet.
    if (!window &&
        count(epg) <= limit &&
        epg.values.every((l) => l.length <= perChannel)) {
      return epg;
    }
    var out = apply();
    while (count(out) > limit) {
      if (fwd > const Duration(days: 2)) {
        fwd -= const Duration(days: 1);
      } else if (bwd > const Duration(days: 1)) {
        bwd -= const Duration(days: 1);
      } else {
        break;
      }
      out = apply();
    }
    return out;
  }

  /// [keep] Sendungen um [now] herum: Zukunft und Vergangenheit je zur
  /// Hälfte, Rest auffüllen.
  static List<EpgEntry> _nearest(List<EpgEntry> list, DateTime now, int keep) {
    var i = list.indexWhere((p) => p.end.isAfter(now));
    if (i < 0) i = list.length;
    var start = i - keep ~/ 2;
    if (start < 0) start = 0;
    var end = start + keep;
    if (end > list.length) {
      end = list.length;
      start = (end - keep).clamp(0, end);
    }
    return list.sublist(start, end);
  }

  /// Alle Sendungen um [offset] verschieben (EPG-Zeitversatz).
  static Map<String, List<EpgEntry>> shift(
      Map<String, List<EpgEntry>> epg, Duration offset) {
    if (offset == Duration.zero) return epg;
    return {
      for (final e in epg.entries)
        e.key: [for (final p in e.value) shiftEntry(p, offset)],
    };
  }

  static EpgEntry shiftEntry(EpgEntry p, Duration offset) => EpgEntry(
        channelEpgId: p.channelEpgId,
        title: p.title,
        description: p.description,
        genre: p.genre,
        start: p.start.add(offset),
        end: p.end.add(offset),
        hasArchive: p.hasArchive,
      );

  /// Erlaubte Versätze in Minuten: −3 h … +3 h in 30-Minuten-Schritten.
  static const offsetSteps = [
    -180,
    -150,
    -120,
    -90,
    -60,
    -30,
    0,
    30,
    60,
    90,
    120,
    150,
    180,
  ];

  static int clampOffset(int minutes) {
    final m = (minutes / 30).round() * 30;
    return m.clamp(-180, 180);
  }

  /// „+1:30 h“ / „−2 h“ / „0“.
  static String offsetLabel(int minutes) {
    if (minutes == 0) return '±0';
    final sign = minutes > 0 ? '+' : '−';
    final a = minutes.abs();
    final h = a ~/ 60, m = a % 60;
    return m == 0 ? '$sign$h h' : '$sign$h:${m.toString().padLeft(2, '0')} h';
  }
}
