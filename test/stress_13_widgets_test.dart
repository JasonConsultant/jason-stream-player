import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:jason_stream_player/core/secret_store.dart';
import 'package:jason_stream_player/data/storage.dart';
import 'package:jason_stream_player/l10n/strings.dart';
import 'package:jason_stream_player/models/models.dart';
import 'package:jason_stream_player/state/providers.dart';
import 'package:jason_stream_player/ui/guide/guide_screen.dart';
import 'package:jason_stream_player/ui/live/live_screen.dart';
import 'package:jason_stream_player/ui/search/search_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/stress_data.dart';
import 'helpers/tv_harness.dart';

/// Oberfläche mit 50 000 Sendern (TV): Aufbau und Blättern per D-Pad.
/// Ausgegeben werden Wanduhr-Zeiten je Bild (`[stress-ui] …`) – im Test
/// ohne GPU, also nur Aufbau/Layout/Zeichnen-Aufzeichnung.

Map<String, List<EpgEntry>> _epg(int channels, DateTime now) {
  final base = DateTime(now.year, now.month, now.day)
      .subtract(const Duration(days: 1));
  return {
    for (var c = 0; c < channels; c++)
      'e$c': [
        for (var p = 0; p < 48; p++)
          EpgEntry(
            channelEpgId: 'e$c',
            title: 'Sendung $p auf $c',
            start: base.add(Duration(hours: p)),
            end: base.add(Duration(hours: p + 1)),
          ),
      ],
  };
}

Future<List<int>> _frames(WidgetTester tester, LogicalKeyboardKey k, int n) async {
  final out = <int>[];
  for (var i = 0; i < n; i++) {
    final sw = Stopwatch()..start();
    await tester.sendKeyEvent(k);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    out.add(sw.elapsedMilliseconds);
  }
  return out;
}

String _stats(List<int> f) {
  final s = [...f]..sort();
  final avg = f.reduce((a, b) => a + b) / f.length;
  return 'Ø ${avg.toStringAsFixed(1)} ms, p95 ${s[(s.length * 0.95).floor().clamp(0, s.length - 1)]} ms, max ${s.last} ms';
}

void main() {
  late Storage storage;
  late TvData data;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    L10n.lang = 'de';
    await initializeDateFormatting('de');
    final live = stressLive();
    data = TvData(
      live: live,
      epg: _epg(5000, DateTime.now()),
      recent: [for (var i = 0; i < 30; i++) 'c${i * 7}'],
      flags: ChannelFlags({for (var i = 0; i < 50; i++) 'c${i * 13}'}, const {}, const {}),
      movies: stressVod(items: 100000),
      series: stressVod(items: 20000, series: true, cats: 120, seed: 3),
    );
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    storage = await Storage.open(store: PreviewSecretStore());
  });

  Future<int> open(WidgetTester tester, Widget w) async {
    final sw = Stopwatch()..start();
    await pumpTv(tester, w, data, Future.value(storage));
    // Varianten-Gruppierung läuft bei großen Listen im Isolate.
    await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 3)));
    final before = sw.elapsedMilliseconds;
    final first = Stopwatch()..start();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    return before + first.elapsedMilliseconds;
  }

  testWidgets('Live TV: 50 000 Sender (19 000 nach Zusammenfassen), D-Pad',
      (tester) async {
    final ms = await open(tester, const Scaffold(body: LiveScreen()));
    expect(find.byType(LiveScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
    // Liste ist faul aufgebaut: nur sichtbare Zeilen existieren.
    final rows = find.textContaining(RegExp(r'^(DE|TR|UK|AT|CH|FR)?:? ?\w')).evaluate().length;
    await tvKey(tester, LogicalKeyboardKey.arrowDown);
    final down = await _frames(tester, LogicalKeyboardKey.arrowDown, 60);
    final pageDown = await _frames(tester, LogicalKeyboardKey.pageDown, 10);
    // ignore: avoid_print
    print('[stress-ui] Live TV öffnen: $ms ms (inkl. Laden), Textelemente $rows; '
        '▼ ${_stats(down)}; Bild ab ${_stats(pageDown)}');
    expect(_stats(down), isNotEmpty);
    expect(down.reduce((a, b) => a > b ? a : b), lessThan(250));
    await tvDone(tester);
  });

  testWidgets('TV-Guide: 50 000 Sender, EPG 5000 × 48', (tester) async {
    final ms = await open(tester, const Scaffold(body: GuideScreen()));
    expect(find.byType(GuideScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tvKey(tester, LogicalKeyboardKey.arrowDown);
    final down = await _frames(tester, LogicalKeyboardKey.arrowDown, 40);
    final right = await _frames(tester, LogicalKeyboardKey.arrowRight, 20);
    // ignore: avoid_print
    print('[stress-ui] TV-Guide öffnen: $ms ms; ▼ ${_stats(down)}; ▶ ${_stats(right)}');
    expect(down.reduce((a, b) => a > b ? a : b), lessThan(250));
    await tvDone(tester);
  });

  testWidgets('Suche: Bildaufbau je Eingabe', (tester) async {
    await open(tester, const Scaffold(body: SearchScreen()));
    final field = find.byType(EditableText);
    expect(field, findsOneWidget);
    final times = <int>[];
    for (final q in ['ni', 'nig', 'nigh', 'night']) {
      await tester.enterText(field, q);
      final sw = Stopwatch()..start();
      await tester.pump(const Duration(milliseconds: 250)); // Entprellung
      await tester.pump();
      times.add(sw.elapsedMilliseconds);
    }
    // ignore: avoid_print
    print('[stress-ui] Suche je Eingabe (inkl. Aufbau): $times ms');
    expect(times.skip(1).reduce((a, b) => a > b ? a : b), lessThan(250));
    await tvDone(tester);
  });
}
