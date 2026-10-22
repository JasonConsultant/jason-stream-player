import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:jason_stream_player/core/secret_store.dart';
import 'package:jason_stream_player/data/storage.dart';
import 'package:jason_stream_player/l10n/strings.dart';
import 'package:jason_stream_player/models/models.dart';
import 'package:jason_stream_player/state/providers.dart' show ChannelFlags;
import 'package:jason_stream_player/state/shell_tab.dart';
import 'package:jason_stream_player/ui/guide/guide_screen.dart';
import 'package:jason_stream_player/ui/home/home_screen.dart';
import 'package:jason_stream_player/ui/live/live_screen.dart';
import 'package:jason_stream_player/ui/shell/home_shell.dart';
import 'package:jason_stream_player/ui/vod/vod_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/stress_data.dart';
import 'helpers/tv_harness.dart';

/// 1.5 „Tempo“: Wie viele Elemente baut ein Tastendruck, eine EPG-Änderung
/// oder der Minutentakt neu? (Zählung über debugOnRebuildDirtyWidget –
/// unabhängig von der Rechnergeschwindigkeit.) Vorher gemessen (50 000
/// Sender): Live ▼ ≈ 1 960, Guide ▶ bis 5 260, VOD ▼ ≈ 490, EPG-Änderung
/// oder Minutentakt mit drei offenen Reitern ≈ 7 300 Elemente. Die Grenzen
/// hier sind großzügig, fangen aber jeden Rückfall in „ganzer Bildschirm
/// baut neu“ ab.

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

int _count = 0;
void _start() {
  _count = 0;
  debugOnRebuildDirtyWidget = (_, __) => _count++;
}

int _stop() {
  debugOnRebuildDirtyWidget = null;
  return _count;
}

/// [n]× Taste [k]; je Druck die neu gebauten Elemente (inkl. Animationen
/// und Scrollen danach).
Future<List<int>> _press(
    WidgetTester tester, LogicalKeyboardKey k, int n) async {
  final out = <int>[];
  for (var i = 0; i < n; i++) {
    _start();
    await tester.sendKeyEvent(k);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 200));
    out.add(_stop());
  }
  return out;
}

double _avg(List<int> l) => l.reduce((a, b) => a + b) / l.length;
int _max(List<int> l) => l.reduce((a, b) => a > b ? a : b);

void main() {
  late Storage storage;
  late TvData data;
  late StreamController<DateTime> tick;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    L10n.lang = 'de';
    await initializeDateFormatting('de');
    data = TvData(
      live: stressLive(channels: 8000, groups: 120),
      epg: _epg(5000, DateTime.now()),
      recent: [for (var i = 0; i < 30; i++) 'c${i * 7}'],
      flags: ChannelFlags(
          {for (var i = 0; i < 50; i++) 'c${i * 13}'}, const {}, const {}),
      movies: stressVod(items: 6000, cats: 60),
      series: stressVod(items: 2000, series: true, cats: 30, seed: 3),
    );
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    storage = await Storage.open(store: PreviewSecretStore());
    tick = StreamController<DateTime>.broadcast();
  });

  tearDown(() => tick.close());

  Future<void> open(WidgetTester tester, Widget w) async {
    await pumpTv(tester, w, data, Future.value(storage), tick: tick.stream);
    // Varianten-Gruppierung läuft bei großen Listen im Isolate.
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(seconds: 2)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// Elemente, die eine EPG-Änderung bzw. ein Minutentakt neu baut.
  Future<(int, int)> epgAndTick(WidgetTester tester) async {
    _start();
    tvEpgBump('short-test');
    await tester.pump();
    await tester.pump();
    final epg = _stop();
    _start();
    tick.add(DateTime.now());
    await tester.pump();
    await tester.pump();
    final t = _stop();
    return (epg, t);
  }

  testWidgets('Live TV: ▼ baut nur Zeilen + Info neu; EPG/Takt fast nichts',
      (tester) async {
    await open(tester, const Scaffold(body: LiveScreen()));
    await _press(tester, LogicalKeyboardKey.arrowDown, 3); // einschwingen
    final down = await _press(tester, LogicalKeyboardKey.arrowDown, 15);
    expect(_avg(down), lessThan(300), reason: 'Live ▼ $down');
    expect(_max(down), lessThan(600), reason: 'Live ▼ $down');
    final (epg, t) = await epgAndTick(tester);
    expect(epg, lessThan(50), reason: 'EPG-Änderung');
    expect(t, lessThan(250), reason: 'Minutentakt');
    expect(tester.takeException(), isNull);
    await tvDone(tester);
  });

  testWidgets('TV-Guide: ▶/◀ verschiebt nur, statt alle Zeilen neu zu bauen',
      (tester) async {
    await open(tester, const Scaffold(body: GuideScreen()));
    await tvKey(tester, LogicalKeyboardKey.arrowDown);
    final right = await _press(tester, LogicalKeyboardKey.arrowRight, 15);
    final left = await _press(tester, LogicalKeyboardKey.arrowLeft, 8);
    final all = [...right, ...left]..sort();
    final p95 = all[(all.length * 0.95).floor().clamp(0, all.length - 1)];
    expect(p95, lessThan(800), reason: 'Guide ▶/◀ $right $left');
    expect(_avg(all), lessThan(400), reason: 'Guide ▶/◀ $right $left');
    final down = await _press(tester, LogicalKeyboardKey.arrowDown, 10);
    expect(_avg(down), lessThan(450), reason: 'Guide ▼ $down');
    final (epg, t) = await epgAndTick(tester);
    expect(epg, lessThan(50), reason: 'EPG-Änderung');
    expect(t, lessThan(250), reason: 'Minutentakt');
    expect(tester.takeException(), isNull);
    await tvDone(tester);
  });

  testWidgets('Filme: ▼ in eine neue Posterreihe', (tester) async {
    await open(tester, const Scaffold(body: VodScreen(series: false)));
    final down = await _press(tester, LogicalKeyboardKey.arrowDown, 8);
    expect(_avg(down), lessThan(470), reason: 'VOD ▼ $down');
    final right = await _press(tester, LogicalKeyboardKey.arrowRight, 8);
    expect(_avg(right), lessThan(120), reason: 'VOD ▶ $right');
    expect(tester.takeException(), isNull);
    await tvDone(tester);
  });

  testWidgets('Startseite: EPG-Änderung und Minutentakt', (tester) async {
    await open(tester, Scaffold(body: HomeScreen(onOpenTab: (_) {})));
    final (epg, t) = await epgAndTick(tester);
    expect(epg, lessThan(50), reason: 'EPG-Änderung');
    expect(t, lessThan(200), reason: 'Minutentakt');
    expect(tester.takeException(), isNull);
    await tvDone(tester);
  });

  testWidgets(
      'Hauptansicht: Hintergrund-Reiter (Start, Live, Guide besucht) bauen '
      'bei EPG-Änderung und Minutentakt nicht neu', (tester) async {
    await open(tester, const HomeShell());
    final container = ProviderScope.containerOf(
        tester.element(find.byType(HomeShell)),
        listen: false);
    for (final tab in [1, ShellTab.guide, 3]) {
      container.read(shellTabRequestProvider.notifier).open(tab);
      await tester.pump();
      await tester
          .runAsync(() => Future<void>.delayed(const Duration(seconds: 1)));
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(find.byType(HomeScreen, skipOffstage: false), findsOneWidget);
    expect(find.byType(LiveScreen, skipOffstage: false), findsOneWidget);
    expect(find.byType(GuideScreen, skipOffstage: false), findsOneWidget);
    // Sichtbar ist „Filme“ (ohne EPG): Start, Live und Guide im Hintergrund.
    final (epg, t) = await epgAndTick(tester);
    expect(epg, lessThan(30), reason: 'EPG-Änderung, 3 Reiter verdeckt');
    expect(t, lessThan(30), reason: 'Minutentakt, 3 Reiter verdeckt');

    // Zurück auf Live: verpasste Änderungen kommen an, Takt wirkt wieder.
    container.read(shellTabRequestProvider.notifier).open(1);
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
    final (epg2, t2) = await epgAndTick(tester);
    expect(epg2, lessThan(50), reason: 'EPG-Änderung, Live sichtbar');
    expect(t2, greaterThan(0), reason: 'Minutentakt erreicht Live');
    expect(t2, lessThan(250), reason: 'Minutentakt, Live sichtbar');
    expect(tester.takeException(), isNull);
    await tvDone(tester);
  });
}
