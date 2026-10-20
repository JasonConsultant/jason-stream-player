import '../l10n/strings.dart';

/// Wann das EPG automatisch neu geladen wird.
enum EpgInterval {
  daily('daily', 'Täglich'),
  h12('12h', 'Alle 12 Std.'),
  h6('6h', 'Alle 6 Std.'),
  manual('manual', 'Nur manuell');

  final String id;
  final String _label;
  const EpgInterval(this.id, this._label);

  String get label => tr(_label);

  static EpgInterval fromId(String? id) => EpgInterval.values
      .firstWhere((e) => e.id == id, orElse: () => EpgInterval.daily);
}

class EpgSchedule {
  final EpgInterval interval;

  /// Uhrzeit (0–23) für „Täglich“.
  final int hour;

  const EpgSchedule({this.interval = EpgInterval.daily, this.hour = 5});

  /// Letzter planmäßiger Zeitpunkt „Täglich um [hour]“ vor oder gleich [now].
  DateTime lastDailySlot(DateTime now) {
    final today = DateTime(now.year, now.month, now.day, hour);
    return now.isBefore(today)
        ? today.subtract(const Duration(days: 1))
        : today;
  }

  /// Ist eine Aktualisierung fällig?
  /// Ohne bisherigen Stand ([last] == null) immer – auch bei „Nur manuell“.
  bool isDue({required DateTime? last, required DateTime now}) {
    if (last == null) return true;
    return switch (interval) {
      EpgInterval.manual => false,
      EpgInterval.daily => last.isBefore(lastDailySlot(now)),
      EpgInterval.h12 => now.difference(last) >= const Duration(hours: 12),
      EpgInterval.h6 => now.difference(last) >= const Duration(hours: 6),
    };
  }

  /// Nächste geplante Aktualisierung (für die Anzeige), null bei manuell.
  DateTime? next({required DateTime? last, required DateTime now}) {
    if (last == null) return now;
    return switch (interval) {
      EpgInterval.manual => null,
      EpgInterval.daily => isDue(last: last, now: now)
          ? now
          : lastDailySlot(now).add(const Duration(days: 1)),
      EpgInterval.h12 => last.add(const Duration(hours: 12)),
      EpgInterval.h6 => last.add(const Duration(hours: 6)),
    };
  }
}
