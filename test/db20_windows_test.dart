import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:jason_stream_player/models/models.dart';
import 'package:jason_stream_player/ui/guide/guide_day_windows.dart';

/// 2.0: Fensterweises Laden (TV-Guide, anderer Tag) – je 200 Zeilen, mit
/// Vorladen, begrenztem Speicher und ohne doppelte Abfragen.
void main() {
  final channels = [
    for (var i = 0; i < 1000; i++)
      Channel(id: 'c$i', name: 'S$i', categoryId: 'g', streamUrl: 'u',
          epgId: i % 7 == 6 ? null : 'e$i'),
  ];
  final calls = <List<String>>[];
  Completer<void>? gate;

  Future<Map<String, List<EpgEntry>>?> loader(
      List<String> keys, int from, int to) async {
    calls.add(keys);
    if (gate != null) await gate!.future;
    return {
      for (final k in keys)
        if (!k.endsWith('5'))
          k: [
            EpgEntry(
                channelEpgId: k,
                title: 'T $k',
                start: DateTime.fromMillisecondsSinceEpoch(from * 1000),
                end: DateTime.fromMillisecondsSinceEpoch(to * 1000)),
          ],
    };
  }

  setUp(() {
    calls.clear();
    gate = null;
  });

  test('erstes Fenster vorher laden, Zeilen danach sofort', () async {
    final w = GuideDayWindows(loader: loader, from: 1000, to: 2000);
    await w.ensureWindow(0, channels);
    expect(calls, hasLength(1));
    expect(calls.single, hasLength(200));
    expect(w.entriesAt(0, channels)!.single.title, 'T e0');
    expect(w.entriesAt(5, channels), isEmpty); // kein Programm
    expect(w.isLoaded(199, channels), isTrue);
    expect(w.isLoaded(200, channels), isFalse);
    expect(calls, hasLength(1)); // nichts nachgeladen
  });

  test('nahe am Fensterende wird das nächste vorgeladen, keine Doppelabfragen', () async {
    final w = GuideDayWindows(loader: loader, from: 0, to: 1);
    var notified = 0;
    w.addListener(() => notified++);
    gate = Completer<void>();
    expect(w.entriesAt(10, channels), isNull); // lädt Fenster 0
    expect(w.entriesAt(11, channels), isNull); // gleiche Abfrage läuft schon
    expect(calls, hasLength(1));
    expect(w.entriesAt(160, channels), isNull); // Vorladen von Fenster 1
    expect(calls, hasLength(2));
    expect(calls[1].first, 'e200');
    gate!.complete();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(notified, 2);
    expect(w.entriesAt(250, channels), isNotNull);
    expect(w.loads, 2);
    w.dispose();
  });

  test('Speicher begrenzt: alte Fenster werden verworfen und neu geladen', () async {
    final w = GuideDayWindows(loader: loader, from: 0, to: 1, maxKeys: 450);
    for (var i = 0; i < 5; i++) {
      await w.ensureWindow(i, channels);
    }
    expect(w.keysInMemory, lessThanOrEqualTo(450));
    expect(w.isLoaded(999, channels), isTrue);
    expect(w.isLoaded(0, channels), isFalse);
    expect(w.entriesAt(0, channels), isNull); // wird neu geholt
    await Future<void>.delayed(Duration.zero);
    expect(calls.last.first, 'e0');
  });

  test('Fehler beim Laden → leer statt endlos neu laden', () async {
    final w = GuideDayWindows(
        loader: (_, __, ___) async => throw StateError('db weg'), from: 0, to: 1);
    await w.ensureWindow(0, channels);
    expect(w.entriesAt(3, channels), isEmpty);
    expect(w.loads, 1);
  });
}
