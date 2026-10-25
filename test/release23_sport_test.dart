import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:jason_stream_player/core/secret_store.dart';
import 'package:jason_stream_player/data/reminders/reminders.dart';
import 'package:jason_stream_player/data/storage.dart';
import 'package:jason_stream_player/l10n/strings.dart';
import 'package:jason_stream_player/models/models.dart';
import 'package:jason_stream_player/state/providers.dart';
import 'package:jason_stream_player/state/sport_hub.dart';
import 'package:jason_stream_player/ui/home/home_screen.dart';
import 'package:jason_stream_player/ui/sport/sport_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/app_fonts.dart';
import 'helpers/tv_harness.dart';

/// 2.3 Sport-Hub: Erkennung Sportart/Liga (de/en/tr), Ereignisse aus dem
/// EPG (laufend/kommend), Gruppen, Filter, Seite Handy + TV (D-Pad).
///
/// `TV_SHOTS=ordner`: phone_sport.png, tv_sport.png.

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    L10n.lang = 'de';
    await initializeDateFormatting('de');
    await loadAppFonts();
  });

  group('Erkennung', () {
    SportClass? c(String t, {String? genre, bool group = false}) =>
        SportClassifier.classify(t, genre: genre, sportGroup: group);

    test('Ligen und Wettbewerbe (de/en/tr)', () {
      const cases = <String, (SportKind, String)>{
        'Fußball: Bundesliga – FC Bayern München – Borussia Dortmund':
            (SportKind.football, 'Bundesliga'),
        '2. Bundesliga: Hamburger SV - FC Schalke 04':
            (SportKind.football, '2. Bundesliga'),
        'DFB-Pokal: Achtelfinale': (SportKind.football, 'DFB-Pokal'),
        'Trendyol Süper Lig: Galatasaray - Fenerbahçe':
            (SportKind.football, 'Süper Lig'),
        'Süper Lig Özetleri': (SportKind.football, 'Süper Lig'),
        'UEFA Şampiyonlar Ligi: Real Madrid - Beşiktaş':
            (SportKind.football, 'Champions League'),
        'UEFA Champions League: Inter v Arsenal':
            (SportKind.football, 'Champions League'),
        'Europa League Highlights': (SportKind.football, 'Europa League'),
        'UEFA Avrupa Ligi': (SportKind.football, 'Europa League'),
        'Premier League: Liverpool vs Chelsea':
            (SportKind.football, 'Premier League'),
        'LaLiga: Barcelona - Sevilla': (SportKind.football, 'La Liga'),
        'Serie A: Juventus - Milan': (SportKind.football, 'Serie A'),
        'Formel 1: Großer Preis von Monaco – Rennen':
            (SportKind.motorsport, 'Formel 1'),
        'Formula 1 Grand Prix: Qualifying': (SportKind.motorsport, 'Formel 1'),
        'F1 Live: Abu Dhabi': (SportKind.motorsport, 'Formel 1'),
        'Formula 1 Türkiye Grand Prix': (SportKind.motorsport, 'Formel 1'),
        'MotoGP: Sprint Race': (SportKind.motorsport, 'MotoGP'),
        'NBA: Lakers @ Celtics': (SportKind.basketball, 'NBA'),
        'Basketbol: THY EuroLeague – Anadolu Efes':
            (SportKind.basketball, 'EuroLeague'),
        'Tennis: Wimbledon – Herren-Finale': (SportKind.tennis, 'Wimbledon'),
        'ATP Masters Paris': (SportKind.tennis, 'ATP'),
        'UFC 310: Main Card': (SportKind.combat, 'UFC'),
        'NFL: Kansas City Chiefs at Buffalo Bills':
            (SportKind.americanFootball, 'NFL'),
        'NHL: Oilers - Kings': (SportKind.iceHockey, 'NHL'),
        'Tour de France: 12. Etappe': (SportKind.cycling, 'Tour de France'),
      };
      for (final e in cases.entries) {
        final r = c(e.key);
        expect(r, isNotNull, reason: e.key);
        expect((r!.kind, r.league), e.value, reason: e.key);
      }
    });

    test('Sportarten ohne Liga und über die EPG-Kategorie', () {
      expect(c('Boxen: WM-Kampf im Schwergewicht')?.kind, SportKind.combat);
      expect(c('Canlı Boks Gecesi')?.kind, SportKind.combat);
      expect(c('Handball-EM: Deutschland - Dänemark')?.kind,
          SportKind.handball);
      expect(c('Voleybol: VakıfBank - Eczacıbaşı')?.kind,
          SportKind.volleyball);
      expect(c('Biathlon-Weltcup: Verfolgung Damen')?.kind, SportKind.winter);
      expect(c('Darts: PDC WM')?.kind, SportKind.darts);
      expect(c('Live', genre: 'Fußball')?.kind, SportKind.football);
      expect(c('Galatasaray - Trabzonspor', genre: 'Futbol')?.kind,
          SportKind.football);
      expect(c('Live: Tennis')?.kind, SportKind.tennis);
      expect(c('Sportschau')?.kind, SportKind.football);
      expect(c('Motorsport: DTM Hockenheim')?.league, 'DTM');
      expect(c('Snooker: UK Championship')?.kind, SportKind.other);
    });

    test('Kein Sport', () {
      for (final t in [
        'Tagesschau',
        'Tatort: Der Pate',
        'Wetter',
        'Kurtlar Vadisi',
        'Transporter – The Mission',
        'Das Golfstrom-Rätsel: Doku',
        'Del Monte Werbung',
        'Grand Designs',
        'Polizeiruf 110',
        'Haber Bülteni',
      ]) {
        expect(c(t), isNull, reason: t);
      }
    });

    test('Paarung „A – B“ nur auf Sport-Sendern', () {
      expect(c('Galatasaray - Fenerbahçe'), isNull);
      expect(c('Galatasaray - Fenerbahçe', group: true)?.kind,
          SportKind.football);
      expect(c('Live: Hertha vs Union', group: true)?.kind,
          SportKind.football);
      expect(c('Studio Talk', group: true), isNull);
    });
  });

  group('Ereignisse', () {
    final now = DateTime(2026, 10, 25, 20, 0);
    EpgEntry e(int fromMin, int durMin, String title, {String? genre}) =>
        EpgEntry(
            channelEpgId: '',
            start: now.add(Duration(minutes: fromMin)),
            end: now.add(Duration(minutes: fromMin + durMin)),
            title: title,
            genre: genre);
    const cats = [
      Category(id: 'sp', name: 'DE | Sport'),
      Category(id: 'gen', name: 'DE | Allgemein'),
      Category(id: 'tr', name: 'TR | Ulusal'),
    ];
    const chs = [
      Channel(id: 'a', name: 'Sky Sport Bundesliga', categoryId: 'sp', streamUrl: 'x', epgId: 'a'),
      Channel(id: 'b', name: 'Das Erste', categoryId: 'gen', streamUrl: 'x', epgId: 'b'),
      Channel(id: 'c', name: 'beIN Sports 1', categoryId: 'tr', streamUrl: 'x', epgId: 'c'),
      Channel(id: 'd', name: 'Versteckt', categoryId: 'gen', streamUrl: 'x', epgId: 'd'),
    ];
    late Map<String, List<EpgEntry>> epg;
    setUp(() {
      epg = {
        'a': [
          e(-120, 60, 'Bundesliga: Vorbericht'),
          e(-30, 120, 'Bundesliga: FC Bayern – BVB'),
          e(90, 60, 'Mainz - Freiburg'),
          e(26 * 60, 60, 'Bundesliga: zu spät (morgen Abend)'),
        ],
        'b': [
          e(-15, 30, 'Tagesschau'),
          e(15, 105, 'Tatort'),
          e(120, 120, 'Formel 1: Qualifying'),
        ],
        'c': [e(-10, 110, 'Trendyol Süper Lig: Galatasaray - Fenerbahçe')],
        'd': [e(0, 60, 'Champions League Magazin')],
      };
    });

    List<SportEvent> events() => sportEvents(
        categories: cats,
        channels: chs,
        epg: epg,
        now: now,
        hidden: (c) => c.id == 'd');

    test('laufend zuerst, dann nach Beginn; 24 h; versteckte Sender nicht',
        () {
      final ev = events();
      expect([for (final x in ev) x.entry.title], [
        'Bundesliga: FC Bayern – BVB',
        'Trendyol Süper Lig: Galatasaray - Fenerbahçe',
        'Mainz - Freiburg',
        'Formel 1: Qualifying',
      ]);
      expect(ev.first.liveAt(now), isTrue);
      expect(ev.first.progressAt(now), closeTo(0.25, 0.001));
      expect(ev[2].liveAt(now), isFalse);
    });

    test('Gruppen nach Sportart/Liga, Filter Sportart und Favoriten', () {
      final hub = SportHub(events(), now);
      expect(hub.live.length, 2);
      expect(hub.upcoming.length, 2);
      expect(hub.kinds, [SportKind.football, SportKind.motorsport]);
      final g = hub.groups();
      expect([for (final x in g) (x.kind, x.league)], [
        (SportKind.football, 'Bundesliga'),
        (SportKind.football, 'Süper Lig'),
        (SportKind.football, null),
        (SportKind.motorsport, 'Formel 1'),
      ]);
      expect(hub.groups(kind: SportKind.motorsport).single.events.single
          .channel.id, 'b');
      expect(
          hub
              .groups(onlyChannels: {'c'})
              .expand((x) => x.events)
              .map((x) => x.channel.id),
          ['c']);
    });

    test('Leistung: 20 000 Sender × 30 Sendungen unter 1,5 s', () {
      final many = <Channel>[];
      final big = <String, List<EpgEntry>>{};
      for (var i = 0; i < 20000; i++) {
        many.add(Channel(
            id: 'x$i',
            name: 'Sender $i',
            categoryId: i % 10 == 0 ? 'sp' : 'gen',
            streamUrl: 'x',
            epgId: 'x$i'));
        big['x$i'] = [
          for (var k = 0; k < 30; k++)
            e(-60 + k * 60, 60,
                k % 7 == 0 ? 'Fußball: Spiel $k' : 'Sendung $i/$k'),
        ];
      }
      final sw = Stopwatch()..start();
      final r = sportEvents(
          categories: cats, channels: many, epg: big, now: now);
      sw.stop();
      expect(r, isNotEmpty);
      expect(r.length, lessThanOrEqualTo(400));
      expect(sw.elapsedMilliseconds, lessThan(1500));
    });
  });

  group('Seite', () {
    final now = DateTime.now();
    EpgEntry e(int fromMin, int durMin, String title) => EpgEntry(
        channelEpgId: '',
        start: now.add(Duration(minutes: fromMin)),
        end: now.add(Duration(minutes: fromMin + durMin)),
        title: title);
    const portal = Portal(
        id: 'sp', name: 'P', type: PortalType.m3u, url: 'http://h/l.m3u');
    const cats = [Category(id: 'sp', name: 'Sport')];
    const chs = [
      Channel(id: 'a', name: 'Sky Sport 1', categoryId: 'sp', streamUrl: 'x', epgId: 'a', number: 1),
      Channel(id: 'b', name: 'beIN Sports', categoryId: 'sp', streamUrl: 'x', epgId: 'b', number: 2),
      Channel(id: 'c', name: 'Sport1', categoryId: 'sp', streamUrl: 'x', epgId: 'c', number: 3),
    ];
    TvData data() => TvData(
          live: const LiveData(cats, chs),
          portal: portal,
          movies: const VodData([], []),
          series: const VodData([], []),
          flags: const ChannelFlags({'b'}, {}, {}),
          epg: {
            'a': [
              e(-40, 105, 'Bundesliga: RB Leipzig – VfB Stuttgart'),
              e(70, 120, 'Formel 1: Großer Preis von Brasilien'),
            ],
            'b': [
              e(-5, 110, 'Süper Lig: Beşiktaş - Trabzonspor'),
              e(180, 120, 'NBA: Warriors vs Nuggets'),
            ],
            'c': [e(30, 90, 'Darts: PDC World Series')],
          },
        );

    Future<Storage> storage() async {
      SharedPreferences.setMockInitialValues({'set_applang': 'de'});
      return Storage.open(store: PreviewSecretStore());
    }

    testWidgets('Handy: Gruppen, ehrlicher Hinweis, Filter, Erinnerung',
        (tester) async {
      await pumpTv(tester, const SportScreen(), data(), storage(),
          tv: false, size: const Size(1080, 2340), dpr: 3);
      expect(find.byKey(const ValueKey('sport-honest')), findsOneWidget);
      expect(find.text('Fußball · Bundesliga'), findsOneWidget);
      expect(find.text('Fußball · Süper Lig'), findsOneWidget);
      expect(find.text('Motorsport · Formel 1'), findsOneWidget);
      expect(find.text('LIVE'), findsNWidgets(2));
      await writeShot(tester, tvShotKey, 'phone_sport');
      // Filter Motorsport.
      await tester.ensureVisible(find.byKey(const ValueKey('sport-kind-motorsport')));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.byKey(const ValueKey('sport-kind-motorsport')));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('Fußball · Bundesliga'), findsNothing);
      expect(find.text('Motorsport · Formel 1'), findsOneWidget);
      // Alle + nur Favoriten (Sender b).
      await tester.ensureVisible(find.byKey(const ValueKey('sport-kind-all')));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.byKey(const ValueKey('sport-kind-all')));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.ensureVisible(find.byKey(const ValueKey('sport-fav')));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.byKey(const ValueKey('sport-fav')));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('Fußball · Bundesliga'), findsNothing);
      expect(find.text('Fußball · Süper Lig'), findsOneWidget);
      expect(find.text('Basketball · NBA'), findsOneWidget);
      // Kommende Sendung → Erinnern.
      await tester.tap(find.text('NBA: Warriors vs Nuggets'));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 150));
      }
      await tester.tap(find.byKey(const ValueKey('sport-remind')));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      final c = ProviderScope.containerOf(
          tester.element(find.byType(SportScreen)));
      expect(c.read(remindersProvider).single.title,
          'NBA: Warriors vs Nuggets');
      expect(find.byIcon(Icons.notifications_active_rounded), findsOneWidget);
      // Zurücksetzen (Filter ist global).
      c.read(sportFilterProvider.notifier).set(const SportFilter());
      await tvDone(tester);
    });

    testWidgets('TV: D-Pad von den Filtern in die Liste, OK auf kommender '
        'Sendung öffnet das Blatt', (tester) async {
      await pumpTv(tester, const SportScreen(), data(), storage());
      await writeShot(tester, tvShotKey, 'tv_sport');
      // Fokus startet auf „Alle“; ▶ = nächster Filter.
      final first = FocusManager.instance.primaryFocus;
      expect(first, isNotNull);
      await tvKey(tester, LogicalKeyboardKey.arrowRight);
      await tvKey(tester, LogicalKeyboardKey.select);
      final c = ProviderScope.containerOf(
          tester.element(find.byType(SportScreen)));
      expect(c.read(sportFilterProvider).kind, SportKind.football);
      await tvKey(tester, LogicalKeyboardKey.arrowLeft);
      await tvKey(tester, LogicalKeyboardKey.select);
      expect(c.read(sportFilterProvider).kind, isNull);
      // ▼ in die Liste bis zur kommenden Formel-1-Sendung.
      final target =
          'sport-row-a-${data().epg['a']![1].start.millisecondsSinceEpoch}';
      String? focused() {
        final ctx = FocusManager.instance.primaryFocus?.context;
        String? found;
        if (ctx == null) return null;
        bool check(Element e) {
          final k = e.widget.key;
          if (k is ValueKey<String> && k.value.startsWith('sport-')) {
            found = k.value;
            return false;
          }
          return true;
        }

        if (check(ctx as Element)) ctx.visitAncestorElements(check);
        return found ?? '-';
      }
      var reached = false;
      for (var i = 0; i < 8 && !reached; i++) {
        await tvKey(tester, LogicalKeyboardKey.arrowDown);
        reached = focused()!.contains(target);
      }
      expect(reached, isTrue, reason: focused());
      await tvKey(tester, LogicalKeyboardKey.select);
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 150));
      }
      expect(find.byKey(const ValueKey('sport-remind')), findsOneWidget);
      // Fokus im Blatt auf „Erinnern“ → OK.
      await tvKey(tester, LogicalKeyboardKey.select);
      expect(c.read(remindersProvider).single.title,
          'Formel 1: Großer Preis von Brasilien');
      c.read(sportFilterProvider.notifier).set(const SportFilter());
      await tvDone(tester);
    });

    testWidgets('TV-Startseite: Kachel „Sport“ per D-Pad öffnet den Hub',
        (tester) async {
      await pumpTv(tester, HomeScreen(onOpenTab: (_) {}), data(), storage());
      for (var i = 0; i < 4; i++) {
        await tvKey(tester, LogicalKeyboardKey.arrowRight);
      }
      await tvKey(tester, LogicalKeyboardKey.select);
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 150));
      }
      expect(find.byType(SportScreen), findsOneWidget);
      await tvDone(tester);
    });
  });
}
