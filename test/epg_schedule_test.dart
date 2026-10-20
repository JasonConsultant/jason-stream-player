import 'package:flutter_test/flutter_test.dart';
import 'package:jason_stream_player/l10n/strings.dart';
import 'package:jason_stream_player/core/epg_schedule.dart';

void main() {
  setUp(() => L10n.lang = 'de'); // Tests prüfen deutsche Texte
  const daily5 = EpgSchedule(interval: EpgInterval.daily, hour: 5);

  test('Täglich 5 Uhr: gestern 6 Uhr geladen, jetzt 4 Uhr → nicht fällig', () {
    expect(
        daily5.isDue(
            last: DateTime(2026, 10, 18, 6), now: DateTime(2026, 10, 19, 4)),
        isFalse);
  });

  test('Täglich 5 Uhr: gestern 6 Uhr geladen, jetzt 5:10 → fällig', () {
    expect(
        daily5.isDue(
            last: DateTime(2026, 10, 18, 6),
            now: DateTime(2026, 10, 19, 5, 10)),
        isTrue);
  });

  test('App war um 5 Uhr aus → beim Öffnen am Abend nachholen', () {
    expect(
        daily5.isDue(
            last: DateTime(2026, 10, 18, 20), now: DateTime(2026, 10, 19, 21)),
        isTrue);
  });

  test('heute 5:01 geladen → bis morgen 5 Uhr nicht fällig', () {
    final last = DateTime(2026, 10, 19, 5, 1);
    expect(daily5.isDue(last: last, now: DateTime(2026, 10, 19, 23)), isFalse);
    expect(daily5.next(last: last, now: DateTime(2026, 10, 19, 23)),
        DateTime(2026, 10, 20, 5));
  });

  test('Ohne bisherigen Stand immer fällig – auch bei „Nur manuell“', () {
    const manual = EpgSchedule(interval: EpgInterval.manual);
    expect(manual.isDue(last: null, now: DateTime(2026)), isTrue);
    expect(
        manual.isDue(last: DateTime(2020), now: DateTime(2026)), isFalse);
  });

  test('Alle 6 Std.', () {
    const h6 = EpgSchedule(interval: EpgInterval.h6);
    final last = DateTime(2026, 10, 19, 8);
    expect(h6.isDue(last: last, now: DateTime(2026, 10, 19, 13, 59)), isFalse);
    expect(h6.isDue(last: last, now: DateTime(2026, 10, 19, 14)), isTrue);
  });
}
