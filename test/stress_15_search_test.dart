import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:jason_stream_player/models/models.dart';
import 'package:jason_stream_player/ui/search/search_engine.dart';

import 'helpers/stress_data.dart';

/// 1.5 „Tempo“: Kosten der Suche je Tastendruck mit Großanbieter-Daten
/// (50 000 Sender, EPG 5000 × 48, 100 000 Filme, 20 000 Serien).
/// Vorher lief der Index-Neuaufbau bei jedem EPG-Teil-Update mitten im
/// Tippen im build; jetzt nur, wenn das Feld ruht, und in Häppchen.

Map<String, List<EpgEntry>> _epg(int channels, DateTime now, String tag) {
  final base =
      DateTime(now.year, now.month, now.day).subtract(const Duration(days: 1));
  return {
    for (var c = 0; c < channels; c++)
      'e$c': [
        for (var p = 0; p < 48; p++)
          EpgEntry(
            channelEpgId: 'e$c',
            title: '$tag Sendung $p auf $c',
            start: base.add(Duration(hours: p)),
            end: base.add(Duration(hours: p + 1)),
          ),
      ],
  };
}

int _ms(Stopwatch sw) => sw.elapsedMilliseconds;

void main() {
  test('Suche: Tastendruck ohne Neuaufbau, EPG-Index in Häppchen', () async {
    final now = DateTime.now();
    final live = stressLive();
    final channels = [
      for (var i = 0; i < live.channels.length; i++)
        i < 5000
            ? Channel(
                id: live.channels[i].id,
                name: live.channels[i].name,
                categoryId: live.channels[i].categoryId,
                streamUrl: live.channels[i].streamUrl,
                epgId: 'e$i')
            : live.channels[i],
    ];
    final movies = stressVod(items: 100000).items;
    final series = stressVod(items: 20000, series: true, seed: 3).items;
    final epg1 = _epg(5000, now, 'Krimi');
    final epg2 = _epg(5000, now, 'Doku');
    const typed = ['kr', 'kri', 'krim', 'krimi', 'krimi s'];

    SearchEngine make(Map<String, List<EpgEntry>> epg) => SearchEngine(
        channels: channels,
        epg: epg,
        movies: movies,
        series: series,
        buildPeople: false);

    // Vorher: EPG-Update während des Tippens → neuer Index im build, dann
    // die Suche (synchron, blockiert das Bild).
    final before = <int>[];
    for (final q in typed.take(3)) {
      final sw = Stopwatch()..start();
      make(identical(q, typed[1]) ? epg2 : epg1).search(q, now);
      before.add(_ms(sw));
    }

    // Nachher: Index beim Öffnen in Häppchen; Messung der längsten
    // Blockade über einen Herzschlag-Timer.
    final e = make(epg1);
    var maxGap = 0;
    var beats = 0;
    final gapSw = Stopwatch()..start();
    var running = true;
    void beat() {
      final g = gapSw.elapsedMilliseconds;
      if (g > maxGap) maxGap = g;
      gapSw.reset();
      beats++;
      if (running) Timer.run(beat);
    }

    Timer.run(beat);
    final warm = Stopwatch()..start();
    await e.warmUp();
    final warmMs = _ms(warm);
    running = false;
    await Future<void>.delayed(Duration.zero);
    final keys = <int>[];
    for (final q in typed) {
      final sw = Stopwatch()..start();
      e.search(q, now);
      keys.add(_ms(sw));
    }
    // EPG-Update im Hintergrund (Feld ruht) – ebenfalls in Häppchen.
    running = true;
    gapSw.reset();
    Timer.run(beat);
    final refresh = Stopwatch()..start();
    expect(await e.refreshEpg(epg2), isTrue);
    final refreshMs = _ms(refresh);
    running = false;
    final after = Stopwatch()..start();
    final r = e.search('doku sendung 47', now);
    final afterMs = _ms(after);
    // ignore: avoid_print
    print('[stress15] Suche vorher je Taste bei EPG-Update (Index im build): '
        '$before ms');
    // ignore: avoid_print
    print('[stress15] nachher: Vorab-Index $warmMs ms in Häppchen '
        '(längste Blockade $maxGap ms, $beats Bilder dazwischen), '
        'Tasten $keys ms, EPG-Tausch $refreshMs ms (Häppchen), '
        'erste Suche danach $afterMs ms');
    expect(r.shows, isNotEmpty);
    // Großzügig (2-Kern-CI, parallele Tests). Erster Buchstabe: JIT-
    // Aufwärmen und volle Suche über 410 000 Texte (Worst Case: jede
    // Sendung hat einen eigenen Titel und passt).
    expect(keys.first, lessThan(500));
    expect(keys.skip(1).reduce((a, b) => a > b ? a : b), lessThan(300));
    expect(maxGap, lessThan(250));
  }, timeout: const Timeout(Duration(minutes: 3)));
}
