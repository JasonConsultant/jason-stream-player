import 'package:flutter_test/flutter_test.dart';
import 'package:jason_stream_player/data/epg_cache/epg_cache.dart';
import 'package:jason_stream_player/models/models.dart';

void main() {
  test('Binär-Cache: hin und zurück verlustfrei', () {
    final now = DateTime.now();
    final s = DateTime.fromMillisecondsSinceEpoch(
        now.millisecondsSinceEpoch ~/ 1000 * 1000);
    final epg = {
      'a.de': [
        EpgEntry(channelEpgId: 'a.de', title: 'Tom & Jerry – Ü', start: s,
            end: s.add(const Duration(minutes: 30)), description: 'Katze 🐱',
            genre: 'Kinder', hasArchive: true),
        EpgEntry(channelEpgId: 'a.de', title: 'Nachrichten',
            start: s.add(const Duration(minutes: 30)),
            end: s.add(const Duration(minutes: 45))),
      ],
      'b.de': [
        EpgEntry(channelEpgId: 'b.de', title: 'Nachrichten', start: s,
            end: s.add(const Duration(hours: 1)), genre: 'Kinder'),
      ],
    };
    final back = EpgCache.debugDecode(EpgCache.debugEncode(epg));
    expect(back.keys.toSet(), {'a.de', 'b.de'});
    final a = back['a.de']!;
    expect(a.first.title, 'Tom & Jerry – Ü');
    expect(a.first.description, 'Katze 🐱');
    expect(a.first.genre, 'Kinder');
    expect(a.first.hasArchive, isTrue);
    expect(a.first.start, s);
    expect(a.first.end, s.add(const Duration(minutes: 30)));
    expect(a.last.description, isNull);
    expect(back['b.de']!.single.title, 'Nachrichten');
  });
}
