import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:jason_stream_player/data/epg_cache/epg_cache.dart';
import 'package:jason_stream_player/data/epg_window.dart';
import 'package:jason_stream_player/data/xmltv_parser.dart';
import 'package:jason_stream_player/l10n/strings.dart';
import 'package:jason_stream_player/models/models.dart';
import 'package:jason_stream_player/state/list_refresh.dart';
import 'package:jason_stream_player/ui/guide/guide_days.dart';

/// EPG: 7 Tage zurück / 7 Tage voraus, Obergrenzen, Zeitversatz pro Quelle,
/// Tagesauswahl im Guide; dazu die Fälligkeit der Listen-Aktualisierung.
String _t(DateTime d) {
  final u = d.toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${u.year}${two(u.month)}${two(u.day)}${two(u.hour)}${two(u.minute)}00 +0000';
}

String _xml(List<(DateTime, DateTime, String)> progs) => '''
<?xml version="1.0" encoding="UTF-8"?>
<tv>
<channel id="a.de"><display-name>A</display-name></channel>
${progs.map((p) => '<programme start="${_t(p.$1)}" stop="${_t(p.$2)}" channel="a.de"><title>${p.$3}</title></programme>').join('\n')}
</tv>''';

void main() {
  setUpAll(() async {
    L10n.lang = 'de';
    await initializeDateFormatting('de');
  });

  final now = DateTime.now();
  final hour = DateTime(now.year, now.month, now.day, now.hour);

  group('Zeitfenster −7 … +7 Tage', () {
    test('Scanner behält +6 Tage und −6 Tage, verwirft +8 und −8', () async {
      final epg = await XmltvParser.parse(_xml([
        (hour.subtract(const Duration(days: 8)),
            hour.subtract(const Duration(days: 8)).add(const Duration(hours: 1)), 'alt'),
        (hour.subtract(const Duration(days: 6)),
            hour.subtract(const Duration(days: 6)).add(const Duration(hours: 1)), 'vorgestern+'),
        (hour, hour.add(const Duration(hours: 1)), 'jetzt'),
        (hour.add(const Duration(days: 6)),
            hour.add(const Duration(days: 6, hours: 1)), 'nächste Woche'),
        (hour.add(const Duration(days: 8)),
            hour.add(const Duration(days: 8, hours: 1)), 'zu weit'),
      ]));
      expect([for (final e in epg['a.de']!) e.title],
          ['vorgestern+', 'jetzt', 'nächste Woche']);
    });

    test('Zwischenspeicher liefert ebenfalls +6 Tage zurück', () {
      final e = EpgEntry(
          channelEpgId: 'a.de',
          title: 'später',
          start: hour.add(const Duration(days: 6)),
          end: hour.add(const Duration(days: 6, hours: 1)));
      final back = EpgCache.debugDecode(EpgCache.debugEncode({
        'a.de': [e]
      }));
      expect(back['a.de']!.single.title, 'später');
    });

    test('Obergrenze: zuerst ferne Zukunft kürzen, Mindestfenster bleibt', () {
      // 4 Sender × 15 Tage × 24 Sendungen = 1440 Sendungen
      final epg = <String, List<EpgEntry>>{
        for (var c = 0; c < 4; c++)
          'c$c': [
            for (var h = -7 * 24; h < 7 * 24; h++)
              EpgEntry(
                  channelEpgId: 'c$c',
                  title: '$h',
                  start: hour.add(Duration(hours: h)),
                  end: hour.add(Duration(hours: h + 1))),
          ]
      };
      final capped = EpgWindow.cap(epg, now: hour, total: 1000);
      final n = capped.values.fold<int>(0, (a, l) => a + l.length);
      expect(n, lessThanOrEqualTo(1000));
      final last = capped['c0']!.last.start;
      final first = capped['c0']!.first.start;
      // Vergangenheit (Catch-up) bleibt vollständig, Zukunft ist gekürzt.
      expect(first.isBefore(hour.subtract(const Duration(days: 6))), isTrue);
      expect(last.isBefore(hour.add(const Duration(days: 7))), isTrue);
      expect(last.isAfter(hour.add(const Duration(days: 2))), isTrue);
      // Pro Sender: höchstens perChannel, rund um „jetzt“.
      final per = EpgWindow.cap(epg, now: hour, perChannel: 48);
      expect(per['c1']!.length, 48);
      expect(per['c1']!.any((e) => e.isNowAt(hour)), isTrue);
    });
  });

  group('Zeitversatz pro Quelle', () {
    test('+90 Minuten und −2 Stunden beim Lesen', () async {
      final xml = _xml([(hour, hour.add(const Duration(hours: 1)), 'X')]);
      final plus = await XmltvParser.parse(xml, offsetMinutes: 90);
      expect(plus['a.de']!.single.start, hour.add(const Duration(minutes: 90)));
      expect(plus['a.de']!.single.end, hour.add(const Duration(minutes: 150)));
      final minus = await XmltvParser.parse(xml, offsetMinutes: -120);
      expect(minus['a.de']!.single.start, hour.subtract(const Duration(hours: 2)));
    });

    test('Versatz verschiebt auch über die Fenstergrenze', () async {
      // Liegt knapp außerhalb (+7 Tage + 1 h), mit −3 h wieder drin.
      final s = hour.add(const Duration(days: 7, hours: 1));
      final xml = _xml([(s, s.add(const Duration(hours: 1)), 'Rand')]);
      expect((await XmltvParser.parse(xml))['a.de'], isNull);
      expect((await XmltvParser.parse(xml, offsetMinutes: -180))['a.de'],
          isNotNull);
    });

    test('Schritte, Begrenzung, Beschriftung', () {
      expect(EpgWindow.offsetSteps.first, -180);
      expect(EpgWindow.offsetSteps.last, 180);
      expect(EpgWindow.offsetSteps.length, 13);
      expect(EpgWindow.clampOffset(500), 180);
      expect(EpgWindow.clampOffset(-47), -60);
      expect(EpgWindow.clampOffset(44), 30);
      expect(EpgWindow.offsetLabel(0), '±0');
      expect(EpgWindow.offsetLabel(90), '+1:30 h');
      expect(EpgWindow.offsetLabel(-120), '−2 h');
    });
  });

  group('Tagesauswahl im Guide', () {
    test('Tage nach EPG-Abdeckung, höchstens −7 … +7', () {
      final noon = DateTime(now.year, now.month, now.day, 12);
      EpgEntry e(int dayFrom, int dayTo) => EpgEntry(
          channelEpgId: 'x',
          title: '',
          start: noon.add(Duration(days: dayFrom)),
          end: noon.add(Duration(days: dayTo)));
      expect(guideDayOffsets(const {}, now), [0]);
      final days = guideDayOffsets({
        'a': [e(-2, -2 + 0), e(3, 3)],
        'b': [e(-1, 0)],
      }, noon);
      expect(days.first, -2);
      expect(days.last, 3);
      final wide = guideDayOffsets({
        'a': [e(-20, -19), e(30, 31)]
      }, noon);
      expect(wide, [for (var d = -7; d <= 7; d++) d]);
    });

    test('Beschriftung', () {
      expect(guideDayLabel(-1, now), 'Gestern');
      expect(guideDayLabel(0, now), 'Heute');
      expect(guideDayLabel(1, now), 'Morgen');
      final label = guideDayLabel(3, now);
      expect(label, matches(RegExp(r'^\S+ \d\d\.\d\d\.$')));
    });
  });

  group('Automatische Listen-Aktualisierung', () {
    final t0 = DateTime(2026, 10, 21, 12);
    test('aus → nie fällig', () {
      expect(AutoRefresh.isDue(0, null, t0), isFalse);
      expect(AutoRefresh.isDue(0, t0.subtract(const Duration(days: 9)), t0),
          isFalse);
    });
    test('nie aktualisiert → fällig', () {
      expect(AutoRefresh.isDue(6, null, t0), isTrue);
    });
    test('Intervall 6/12/24 h', () {
      for (final h in [6, 12, 24]) {
        expect(AutoRefresh.isDue(h, t0.subtract(Duration(hours: h - 1)), t0),
            isFalse, reason: '$h');
        expect(AutoRefresh.isDue(h, t0.subtract(Duration(hours: h)), t0),
            isTrue, reason: '$h');
      }
    });
    test('Zeitpunkt in der Zukunft (Uhr verstellt) → fällig', () {
      expect(AutoRefresh.isDue(24, t0.add(const Duration(days: 2)), t0), isTrue);
    });
  });
}
