import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:jason_stream_player/core/secret_store.dart';
import 'package:jason_stream_player/data/storage.dart';
import 'package:jason_stream_player/ui/search/recent_searches.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:jason_stream_player/models/models.dart';
import 'package:jason_stream_player/state/discover.dart';
import 'package:jason_stream_player/state/list_refresh.dart';
import 'package:jason_stream_player/state/providers.dart';
import 'package:jason_stream_player/ui/player/mpv_tuning.dart';

import 'helpers/stress_data.dart';

/// 1.5 Abschlussprüfung: „Jetzt live im Sport“ nur noch über Kandidaten
/// im Minutentakt; „Video-Ausgabe: Hardware direkt“ ohne Software-Notlösung.

String _ids(List<LiveShow> l) =>
    [for (final s in l) '${s.channel.id}:${s.entry.title}'].join(',');

void main() {
  group('Jetzt live im Sport (Memo)', () {
    final t0 = DateTime(2026, 10, 22, 19, 0, 20);
    const titles = [
      'Tagesschau',
      'Bundesliga: Topspiel',
      'Tatort',
      'Transport-Giganten',
      'Sportschau',
      'Kochen',
      'Formel 1 – Rennen',
      'Nachrichten',
    ];
    const cats = [
      Category(id: 'de', name: 'DE | Vollprogramm'),
      Category(id: 'sp', name: 'DE | Sport'),
      Category(id: 'nw', name: 'News'),
    ];
    final rnd = Random(7);
    final channels = [
      for (var i = 0; i < 600; i++)
        Channel(
            id: 'c$i',
            name: 'Sender $i',
            categoryId: cats[rnd.nextInt(cats.length)].id,
            streamUrl: 'u',
            epgId: 'c$i'),
    ];
    // Programme 20–70 min lang, von 2 h vorher bis 5 h nachher; manche
    // Sender ohne EPG, manche mit Lücken.
    final epg = <String, List<EpgEntry>>{};
    for (final c in channels) {
      if (rnd.nextInt(10) == 0) continue;
      var t = t0.subtract(Duration(minutes: 120 + rnd.nextInt(60)));
      final l = <EpgEntry>[];
      while (t.isBefore(t0.add(const Duration(hours: 5)))) {
        final len = 20 + rnd.nextInt(50);
        final gap = rnd.nextInt(8) == 0 ? 15 : 0;
        l.add(EpgEntry(
            channelEpgId: c.id,
            title: titles[rnd.nextInt(titles.length)],
            genre: rnd.nextInt(20) == 0 ? 'Sports' : null,
            start: t,
            end: t.add(Duration(minutes: len))));
        t = t.add(Duration(minutes: len + gap));
      }
      epg[c.id] = l;
    }
    final live = LiveData(cats, channels);
    const hiddenGroups = <String>{'nw'};
    final flags = ChannelFlags.empty;
    bool hidden(Channel c) =>
        flags.isHidden(c.id) || hiddenGroups.contains(c.categoryId);

    test('liefert minütlich dasselbe wie die volle Berechnung', () {
      final memo = LiveSportMemo();
      for (var m = 0; m < 180; m++) {
        final now = t0.add(Duration(minutes: m));
        final a = memo.compute(
            live: live,
            epg: epg,
            flags: flags,
            hiddenGroups: hiddenGroups,
            now: now);
        final b = liveSport(
            categories: cats,
            channels: channels,
            epg: epg,
            now: now,
            hidden: hidden);
        expect(_ids(a), _ids(b), reason: 'Minute $m');
      }
      // Volle Durchläufe nur beim Ablauf des Fensters (15 min).
      expect(memo.fullScans, lessThanOrEqualTo(180 ~/ 15 + 1));
      expect(memo.candidateScans, greaterThan(150));
    });

    test('gleiche Minute: nichts gerechnet, dieselbe Liste; neue Daten: voll',
        () {
      final memo = LiveSportMemo();
      List<LiveShow> at(Duration d, [Map<String, List<EpgEntry>>? e]) =>
          memo.compute(
              live: live,
              epg: e ?? epg,
              flags: flags,
              hiddenGroups: hiddenGroups,
              now: t0.add(d));
      final a = at(Duration.zero);
      expect(memo.fullScans, 1);
      final b = at(const Duration(seconds: 30)); // zweiter 30-s-Takt
      expect(identical(a, b), isTrue);
      expect(memo.fullScans + memo.candidateScans, 1);
      at(const Duration(minutes: 1));
      expect(memo.candidateScans, 1);
      // EPG geändert (neue Map) → voll neu, Ergebnis stimmt.
      final epg2 = {...epg};
      epg2['c1'] = [
        EpgEntry(
            channelEpgId: 'c1',
            title: 'UEFA Champions League',
            start: t0.subtract(const Duration(minutes: 5)),
            end: t0.add(const Duration(hours: 2))),
      ];
      final r = at(const Duration(minutes: 1), epg2);
      expect(memo.fullScans, 2);
      final want = liveSport(
          categories: cats,
          channels: channels,
          epg: epg2,
          now: t0.add(const Duration(minutes: 1)),
          hidden: hidden);
      expect(_ids(r), _ids(want));
    });

    test('50 000 Sender: Minutentakt über Kandidaten deutlich billiger', () {
      final big = stressLive();
      final now = DateTime.now();
      final e = <String, List<EpgEntry>>{
        for (var i = 0; i < big.channels.length; i++)
          epgKeyOf(big.channels[i]): [
            EpgEntry(
                channelEpgId: 'x',
                title: i % 997 == 0 ? 'Bundesliga: Topspiel' : 'Tatort $i',
                start: now.subtract(const Duration(minutes: 10)),
                end: now.add(const Duration(minutes: 50))),
          ],
      };
      final memo = LiveSportMemo();
      List<LiveShow> run(Duration d) => memo.compute(
          live: big,
          epg: e,
          flags: ChannelFlags.empty,
          hiddenGroups: const {},
          now: now.add(d));
      run(Duration.zero); // Erkennung gemerkt (wie nach dem ersten Mal)
      final full = Stopwatch()..start();
      liveSport(
          categories: big.categories, channels: big.channels, epg: e, now: now);
      full.stop();
      final sw = Stopwatch()..start();
      for (var m = 1; m <= 10; m++) {
        run(Duration(minutes: m));
      }
      sw.stop();
      final per = sw.elapsedMicroseconds / 10 / 1000;
      // ignore: avoid_print
      print('[review15] Sport 50k: voll ${full.elapsedMilliseconds} ms, '
          'Minutentakt ${per.toStringAsFixed(2)} ms '
          '(${memo.candidateScans} Kandidaten-Läufe)');
      expect(memo.candidateScans, 10);
      expect(per, lessThan(full.elapsedMicroseconds / 1000 + 1));
    });
  });

  test('Video-Ausgabe „Hardware direkt“: keine Software-Notlösung', () {
    expect(VideoOutput.direct.allowsSoftwareFallback, isFalse);
    expect(VideoOutput.standard.allowsSoftwareFallback, isTrue);
    expect(VideoOutput.compat.allowsSoftwareFallback, isTrue);
  });

  test('Stilles Nachladen: Fälligkeit ab App-Start, mindestens 1/8', () {
    final t0 = DateTime(2026, 10, 22, 20);
    StartReload.resetAppStart(t0);
    addTearDown(StartReload.resetAppStart);
    const live = Duration(seconds: 8), movies = Duration(seconds: 45);
    // Beim Start wie geplant gestaffelt.
    expect(StartReload.effective(live, now: t0), live);
    expect(StartReload.effective(movies, now: t0.add(const Duration(seconds: 1))),
        const Duration(seconds: 44));
    // „Filme“ erst nach 10 min geöffnet → bald nachladen, nicht 45 s später.
    expect(
        StartReload.effective(movies, now: t0.add(const Duration(minutes: 10))),
        movies ~/ 8);
  });

  test('Kurz-EPG: erste Veröffentlichung sofort, dann ¼, ½, voller Abstand',
      () {
    expect(EpgNotifier.shortGap(0), Duration.zero);
    expect(EpgNotifier.shortGap(1), const Duration(seconds: 1));
    expect(EpgNotifier.shortGap(2), const Duration(seconds: 2));
    expect(EpgNotifier.shortGap(3), const Duration(seconds: 4));
    expect(EpgNotifier.shortGap(9), const Duration(seconds: 4));
  });

  test('Portal entfernen löscht seine „Letzten Suchen“', () async {
    SharedPreferences.setMockInitialValues({});
    final st = await Storage.open(store: PreviewSecretStore());
    const p = Portal(
        id: 'px', name: 'X', type: PortalType.m3u, url: 'http://x/l.m3u');
    await st.addPortal(p);
    await st.setOption(RecentSearchesNotifier.keyFor('px'), '["Tatort"]');
    await st.setOption(RecentSearchesNotifier.keyFor('andere'), '["Krimi"]');
    await st.removePortal('px');
    expect(st.option(RecentSearchesNotifier.keyFor('px'), ''), isEmpty);
    expect(st.option(RecentSearchesNotifier.keyFor('andere'), ''), '["Krimi"]');
  });
}
