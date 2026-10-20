import 'package:flutter_test/flutter_test.dart';
import 'package:jason_stream_player/core/tv_home.dart';
import 'package:jason_stream_player/models/models.dart';
import 'package:jason_stream_player/state/providers.dart';

Channel ch(int i, {String? epgId, String? logo}) => Channel(
      id: 'c$i',
      name: 'Sender $i',
      categoryId: 'cat',
      streamUrl: 'http://s/$i',
      epgId: epgId,
      logoUrl: logo,
    );

void main() {
  final now = DateTime(2026, 10, 20, 20, 15);

  test('Favoriten in Senderlisten-Reihenfolge, versteckte ausgelassen', () {
    final channels = [for (var i = 0; i < 6; i++) ch(i)];
    const flags = ChannelFlags({'c4', 'c1', 'c3'}, {'c3'}, {});
    final items = buildTvHomeItems(channels: channels, flags: flags, epg: {});
    expect(items.map((e) => e.channelId), ['c1', 'c4']);
    expect(items.first.name, 'Sender 1');
  });

  test('höchstens 30 Einträge', () {
    final channels = [for (var i = 0; i < 50; i++) ch(i)];
    final flags = ChannelFlags({for (var i = 0; i < 50; i++) 'c$i'}, {}, {});
    final items = buildTvHomeItems(channels: channels, flags: flags, epg: {});
    expect(items.length, tvHomeMaxItems);
    expect(items.length, 30);
    expect(items.last.channelId, 'c29');
  });

  test('Titel der laufenden Sendung, sonst leer', () {
    final a = ch(1, epgId: 'tv.a', logo: 'http://l/a.png');
    final b = ch(2, epgId: 'tv.b');
    final c = ch(3, logo: '');
    final epg = {
      'tv.a': [
        EpgEntry(
            channelEpgId: 'tv.a',
            title: 'Alt',
            start: now.subtract(const Duration(hours: 2)),
            end: now.subtract(const Duration(hours: 1))),
        EpgEntry(
            channelEpgId: 'tv.a',
            title: ' Tagesschau ',
            start: now.subtract(const Duration(minutes: 15)),
            end: now.add(const Duration(minutes: 15))),
      ],
      'tv.b': [
        EpgEntry(
            channelEpgId: 'tv.b',
            title: 'Später',
            start: now.add(const Duration(hours: 1)),
            end: now.add(const Duration(hours: 2))),
      ],
    };
    const flags = ChannelFlags({'c1', 'c2', 'c3'}, {}, {});
    final items = buildTvHomeItems(
        channels: [a, b, c], flags: flags, epg: epg, now: now, portal: 'p1');
    expect(items[0].title, 'Tagesschau');
    expect(items[0].logoUrl, 'http://l/a.png');
    expect(items[1].title, ''); // nichts läuft gerade
    expect(items[2].title, ''); // kein EPG
    expect(items[2].logoUrl, isNull); // leeres Logo → null
    final m = items[0].toMap();
    expect(m['channelId'], 'c1');
    expect(m['portal'], 'p1');
    expect(m['title'], 'Tagesschau');
  });
}
