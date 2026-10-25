import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jason_stream_player/data/db/db_io.dart';
import 'package:jason_stream_player/data/db/db_types.dart';
import 'package:jason_stream_player/data/search_norm.dart';
import 'package:jason_stream_player/models/models.dart';
import 'package:sqlite3/sqlite3.dart';

/// 2.0: Katalog-Datenbank (Schema, Migration, Listen, Fenster, Suche, EPG).
void main() {
  late Database db;
  setUp(() => db = openCatalogInMemory());
  tearDown(() => db.close());

  final cats = [
    const Category(id: '1', name: 'TR | Ulusal'),
    const Category(id: '2', name: 'DE | Sport'),
  ];
  List<Channel> chans() => [
        const Channel(
            id: 'a',
            name: 'Şahin TV HD',
            categoryId: '1',
            streamUrl: 'http://h/live/USER/PASS/1.ts',
            epgId: 'sahin.tr',
            catchupDays: 3,
            number: 1,
            headers: {'User-Agent': 'X', 'Cookie': 'tok=PASS'}),
        const Channel(
            id: 'b',
            name: 'ZDF HD',
            categoryId: '2',
            streamUrl: 'http://h/live/USER/PASS/2.ts',
            epgId: 'zdf.de',
            number: 2),
        const Channel(
            id: 'c',
            name: 'Çocuk Kanalı',
            categoryId: '1',
            streamUrl: 'http://h/live/USER/PASS/3.ts',
            number: 3),
        const Channel(
            id: 'd',
            name: 'İstanbul Haber',
            categoryId: '1',
            streamUrl: 'http://h/live/USER/PASS/4.ts',
            number: 4),
      ];
  String mask(String s) => s
      .replaceAll('USER', '\u0000S0\u0000')
      .replaceAll('PASS', '\u0000S1\u0000');
  String restore(String s) => s
      .replaceAll('\u0000S0\u0000', 'USER')
      .replaceAll('\u0000S1\u0000', 'PASS');

  group('Schema', () {
    test('Version gesetzt, Tabellen da, erneutes Migrieren ändert nichts', () {
      expect(db.userVersion, catalogSchemaVersion);
      final names = {
        for (final r
            in db.select("SELECT name FROM sqlite_master WHERE type='table'"))
          r.columnAt(0) as String
      };
      expect(
          names,
          containsAll([
            'src',
            'lists',
            'categories',
            'channels',
            'vod',
            'channels_fts',
            'vod_fts',
            'epg',
            'epg_chan',
            'epg_text',
            'epg_meta',
            'epg_fts'
          ]));
      migrateCatalog(db);
      expect(db.userVersion, catalogSchemaVersion);
    });

    test('neuere Datei (Rückkehr zu älterer App) → neu angelegt', () {
      writeLive(db, 'p',
          fp: 'f',
          hash: 'h',
          saved: DateTime(2026),
          cats: cats,
          items: chans());
      db.userVersion = catalogSchemaVersion + 5;
      migrateCatalog(db);
      expect(db.userVersion, catalogSchemaVersion);
      expect(hasList(db, 'p', 'live'), isFalse);
    });

    test('beschädigte Datei wird ersetzt', () {
      final dir = Directory.systemTemp.createTempSync('db20_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/databases/catalog.db';
      File(path)
        ..createSync(recursive: true)
        ..writeAsStringSync('kein sqlite ' * 200);
      final d = openCatalog(path);
      expect(d.userVersion, catalogSchemaVersion);
      writeLive(d, 'p',
          fp: 'f',
          hash: 'h',
          saved: DateTime(2026),
          cats: cats,
          items: chans());
      d.close();
      final d2 = openCatalog(path);
      expect(readLive(d2, 'p', fp: 'f')!.items, hasLength(4));
      d2.close();
    });
  });

  group('Listen', () {
    test('Sender: Reihenfolge, Felder, maskierte Zugangsdaten', () {
      writeLive(db, 'p1',
          fp: 'fp',
          hash: 'h1',
          saved: DateTime(2026, 1, 2),
          cats: cats,
          items: chans(),
          mask: mask);
      // In der Datenbank stehen keine Zugangsdaten.
      final raw = db.select('SELECT url, headers FROM channels');
      for (final r in raw) {
        expect('${r['url']}${r['headers']}', isNot(contains('PASS')));
        expect('${r['url']}', isNot(contains('USER')));
      }
      final l = readLive(db, 'p1', fp: 'fp', restore: restore)!;
      expect(l.categories.map((c) => c.id), ['1', '2']);
      expect(l.items.map((c) => c.id), ['a', 'b', 'c', 'd']);
      expect(l.items.first.streamUrl, 'http://h/live/USER/PASS/1.ts');
      expect(l.items.first.headers, {'User-Agent': 'X', 'Cookie': 'tok=PASS'});
      expect(l.items.first.catchupDays, 3);
      expect(l.hash, 'h1');
      expect(l.saved, DateTime(2026, 1, 2));
    });

    test('andere Zugangsdaten → nichts, Liste gelöscht', () {
      writeLive(db, 'p1',
          fp: 'fp',
          hash: 'h',
          saved: DateTime(2026),
          cats: cats,
          items: chans());
      expect(readLive(db, 'p1', fp: 'anders'), isNull);
      expect(hasList(db, 'p1', 'live'), isFalse);
      expect(db.select('SELECT count(*) FROM channels').first.columnAt(0), 0);
    });

    test('Ersetzen in einer Transaktion: Fehler → alter Stand bleibt', () {
      writeLive(db, 'p1',
          fp: 'fp',
          hash: 'h',
          saved: DateTime(2026),
          cats: cats,
          items: chans());
      // Doppelte Position erzwingt einen Fehler mitten im Schreiben.
      db.execute('CREATE TRIGGER boom BEFORE INSERT ON channels '
          "WHEN NEW.id = 'c' BEGIN SELECT RAISE(ABORT, 'x'); END");
      expect(
          () => writeLive(db, 'p1',
              fp: 'fp',
              hash: 'h2',
              saved: DateTime(2027),
              cats: cats,
              items: chans().reversed.toList()),
          throwsA(isA<SqliteException>()));
      db.execute('DROP TRIGGER boom');
      final l = readLive(db, 'p1', fp: 'fp')!;
      expect(l.items.map((c) => c.id), ['a', 'b', 'c', 'd']);
      expect(l.hash, 'h');
    });

    test('Filme: alle Felder inkl. Emby-Stand', () {
      final items = [
        VodItem(
            id: 'm1',
            name: 'Gönül Dağı',
            categoryId: '1',
            streamUrl: 'http://h/movie/USER/PASS/1.mkv',
            rating: 7.5,
            year: 2020,
            plot: 'Handlung',
            genre: 'Dram',
            added: DateTime(2024, 3, 1),
            duration: const Duration(minutes: 95),
            cast: 'Ayşe Öztürk, Emre Kaya',
            director: 'Zeynep Demir',
            trailer: 'yt1',
            posterUrl: 'p',
            backdropUrl: 'b'),
        const VodItem(
            id: 'emby_9',
            name: 'Emby Film',
            categoryId: '2',
            streamUrl: 'emby://9',
            source: VodSource.emby,
            serverPosition: Duration(seconds: 61),
            serverPlayed: true),
      ];
      writeVod(db, 'p1', 'movies',
          fp: 'fp',
          hash: 'hv',
          saved: DateTime(2026),
          cats: cats,
          items: items,
          mask: mask);
      final l = readVod(db, 'p1', 'movies', fp: 'fp', restore: restore)!;
      final a = l.items.first, b = l.items.last;
      expect(a.streamUrl, 'http://h/movie/USER/PASS/1.mkv');
      expect([
        a.rating,
        a.year,
        a.plot,
        a.genre,
        a.added,
        a.duration,
        a.cast,
        a.director,
        a.trailer,
        a.posterUrl,
        a.backdropUrl
      ], [
        7.5,
        2020,
        'Handlung',
        'Dram',
        DateTime(2024, 3, 1),
        const Duration(minutes: 95),
        'Ayşe Öztürk, Emre Kaya',
        'Zeynep Demir',
        'yt1',
        'p',
        'b'
      ]);
      expect(b.isEmby, isTrue);
      expect(b.serverPosition, const Duration(seconds: 61));
      expect(b.serverPlayed, isTrue);
      // Serien-Liste desselben Portals ist getrennt.
      expect(readVod(db, 'p1', 'series', fp: 'fp'), isNull);
    });
  });

  group('Fenster', () {
    test('seitenweise in Listenreihenfolge, Zählung', () {
      final many = [
        for (var i = 0; i < 1000; i++)
          Channel(
              id: 'c$i',
              name: 'Sender $i',
              categoryId: i.isEven ? 'g' : 'u',
              streamUrl: 'u$i')
      ];
      writeLive(db, 'p',
          fp: 'f', hash: null, saved: DateTime(2026), cats: cats, items: many);
      expect(countChannels(db, 'p'), 1000);
      expect(countChannels(db, 'p', category: 'g'), 500);
      final w = channelWindow(db, 'p', offset: 200, limit: 200);
      expect(w.first.id, 'c200');
      expect(w.last.id, 'c399');
      final g = channelWindow(db, 'p', category: 'u', offset: 0, limit: 3);
      expect(g.map((c) => c.id), ['c1', 'c3', 'c5']);
      expect(channelWindow(db, 'p', offset: 990, limit: 200), hasLength(10));
      expect(countChannels(db, 'unbekannt'), 0);
    });

    test('Filme seitenweise + einzeln', () {
      final items = [
        for (var i = 0; i < 450; i++)
          VodItem(
              id: 'm$i',
              name: 'Film $i',
              categoryId: 'k${i % 3}',
              streamUrl: 'u')
      ];
      writeVod(db, 'p', 'movies',
          fp: 'f', hash: null, saved: DateTime(2026), cats: cats, items: items);
      expect(countVod(db, 'p', 'movies'), 450);
      expect(countVod(db, 'p', 'movies', category: 'k1'), 150);
      expect(
          vodWindow(db, 'p', 'movies', category: 'k1', offset: 149, limit: 5)
              .map((m) => m.id),
          ['m448']);
      expect(vodById(db, 'p', 'movies', 'm7')!.name, 'Film 7');
    });
  });

  group('Suche', () {
    setUp(() {
      writeLive(db, 'p',
          fp: 'f',
          hash: null,
          saved: DateTime(2026),
          cats: cats,
          items: chans());
    });

    test('Faltung: Türkisch und Akzente', () {
      expect(foldSearch('Şahin'), 'sahin');
      expect(foldSearch('İSTANBUL'), 'istanbul');
      expect(foldSearch('ISPARTA'), 'isparta');
      expect(foldSearch('ılık'), 'ilik');
      expect(foldSearch('Çocuk Kanalı'), 'cocuk kanali');
      expect(foldSearch('Gönül Dağı'), 'gonul dagi');
      expect(foldSearch('Straße Ü'), 'strasse u');
      expect(foldSearch('Café'), 'cafe');
      expect(foldSearch('ZDF HD'), 'zdf hd');
    });

    test('Sender: mit und ohne Sonderzeichen, Teilwort, 2 Zeichen', () {
      expect(searchChannelIds(db, 'p', foldSearch('sahin')), ['a']);
      expect(searchChannelIds(db, 'p', foldSearch('Şahin')), ['a']);
      expect(searchChannelIds(db, 'p', foldSearch('çocuk')), ['c']);
      expect(searchChannelIds(db, 'p', foldSearch('cocuk')), ['c']);
      expect(searchChannelIds(db, 'p', foldSearch('istanbul')), ['d']);
      expect(searchChannelIds(db, 'p', foldSearch('İstanbul')), ['d']);
      expect(searchChannelIds(db, 'p', foldSearch('kanali')), ['c']);
      expect(searchChannelIds(db, 'p', foldSearch('hd')), ['a', 'b']);
      expect(searchChannelIds(db, 'p', foldSearch('zdf hd')), ['b']);
      expect(searchChannelIds(db, 'p', 'xyz'), isEmpty);
      // Sonderzeichen im Suchbegriff stören die Abfrage nicht.
      expect(searchChannelIds(db, 'p', '"a'), isEmpty);
      expect(searchChannelIds(db, 'p', '%_'), isEmpty);
      expect(searchChannelIds(db, 'p', 'a"b OR c'), isEmpty);
    });

    test('Filme und Personen', () {
      writeVod(db, 'p', 'movies',
          fp: 'f',
          hash: null,
          saved: DateTime(2026),
          cats: cats,
          items: const [
            VodItem(
                id: 'm1',
                name: 'Gönül Dağı',
                categoryId: '1',
                streamUrl: 'u',
                cast: 'Ayşe Öztürk, Emre Kaya'),
            VodItem(
                id: 'm2',
                name: 'Night Storm',
                categoryId: '1',
                streamUrl: 'u',
                director: 'Ayse Ozturk'),
          ]);
      expect(searchVodIds(db, 'p', 'movies', foldSearch('gonul')), ['m1']);
      expect(searchVodIds(db, 'p', 'movies', foldSearch('DAĞI')), ['m1']);
      expect(searchVodPeopleIds(db, 'p', 'movies', foldSearch('ayşe öztürk')),
          ['m1', 'm2']);
      expect(searchVodIds(db, 'p', 'series', 'night'), isEmpty);
    });
  });

  group('EPG', () {
    final now = DateTime(2026, 10, 25, 12);
    int sec(DateTime t) => t.millisecondsSinceEpoch ~/ 1000;
    Map<String, List<EpgEntry>> epg({String tag = ''}) => {
          for (final ch in ['sahin.tr', 'zdf.de'])
            ch: [
              for (var h = -48; h < 48; h++)
                EpgEntry(
                    channelEpgId: ch,
                    title: h.isEven ? 'Haber$tag' : 'Tatort Münster$tag',
                    description: 'Folge $h',
                    genre: 'Krimi',
                    start: now.add(Duration(hours: h)),
                    end: now.add(Duration(hours: h + 1)),
                    hasArchive: h < 0),
            ],
        };

    test('schreiben, Fenster, einzelne Sender, Stand', () {
      final info = writeEpg(db, 'p', epg(), saved: now, hash: 'eh')!;
      expect(info.count, 192);
      expect(info.gen, 1);
      final m = epgInfo(db, 'p')!;
      expect(m.hash, 'eh');
      expect(m.first, now.subtract(const Duration(hours: 48)));
      expect(m.last, now.add(const Duration(hours: 48)));
      // Fenster: überschneidende Sendungen inkl. der gerade laufenden.
      final w = readEpgWindow(
          db,
          'p',
          sec(now.add(const Duration(minutes: 30))),
          sec(now.add(const Duration(hours: 3))));
      expect(w.keys, ['sahin.tr', 'zdf.de']);
      expect(w['zdf.de']!.map((e) => e.start.hour), [12, 13, 14]);
      final e = w['zdf.de']!.first;
      expect([e.title, e.description, e.genre, e.channelEpgId, e.hasArchive],
          ['Haber', 'Folge 0', 'Krimi', 'zdf.de', false]);
      final one = readEpgChannels(db, 'p', ['zdf.de', 'fehlt']);
      expect(one.keys, ['zdf.de']);
      expect(one['zdf.de'], hasLength(96));
      expect(one['zdf.de']!.first.hasArchive, isTrue);
    });

    test('Ersetzen: neue Generation, alte weg; Texte nur einmal', () {
      writeEpg(db, 'p', epg(), saved: now);
      final n1 =
          db.select('SELECT count(*) FROM epg_text').first.columnAt(0) as int;
      expect(n1, lessThan(110)); // 2 Titel + 96 Beschreibungen + Genre
      final info = writeEpg(db, 'p', epg(tag: ' neu'), saved: now)!;
      expect(info.gen, 2);
      expect(
          db
              .select('SELECT DISTINCT gen FROM epg_chan')
              .map((r) => r.columnAt(0)),
          [2]);
      expect(db.select('SELECT count(*) FROM epg').first.columnAt(0), 192);
      final w = readEpgChannels(db, 'p', ['zdf.de']);
      expect(w['zdf.de']!.first.title, endsWith(' neu'));
      expect(db.select('SELECT count(*) FROM epg_text').first.columnAt(0), n1);
    });

    test('Abbruch mitten im Schreiben → alter Stand bleibt, Reste später weg',
        () {
      writeEpg(db, 'p', epg(), saved: now, hash: 'alt');
      var calls = 0;
      final r = writeEpg(db, 'p', epg(tag: ' neu'),
          saved: now, hash: 'neu', chunk: 50, cancelled: () => ++calls >= 1);
      expect(r, isNull);
      expect(epgInfo(db, 'p')!.hash, 'alt');
      final w = readEpgChannels(db, 'p', ['zdf.de']);
      expect(w['zdf.de']!.first.title, isNot(endsWith(' neu')));
      // Reste der abgebrochenen Generation existieren …
      expect(
          db
              .select('SELECT count(DISTINCT gen) FROM epg_chan')
              .first
              .columnAt(0),
          2);
      // … und verschwinden beim nächsten Schreiben.
      writeEpg(db, 'p', epg(tag: ' x'), saved: now, hash: 'x');
      expect(
          db
              .select('SELECT count(DISTINCT gen) FROM epg_chan')
              .first
              .columnAt(0),
          1);
      expect(db.select('SELECT count(*) FROM epg').first.columnAt(0), 192);
    });

    test('Suche: läuft → demnächst → vergangen nur mit Catch-up', () {
      writeEpg(db, 'p', epg(), saved: now);
      setSearchChannels(db, {'sahin.tr': true, 'zdf.de': false});
      final hits = searchEpg(db, 'p', foldSearch('münster'),
          now: sec(now.add(const Duration(minutes: 70))),
          from: sec(now.subtract(const Duration(days: 7))),
          to: sec(now.add(const Duration(days: 2))),
          limit: 200);
      // 13:00 läuft (beide Sender), dann demnächst, dann Vergangenes nur sahin.
      expect(hits.take(2).map((h) => (h.key, h.entry.start.hour)),
          [('sahin.tr', 13), ('zdf.de', 13)]);
      final past = hits.where(
          (h) => !h.entry.end.isAfter(now.add(const Duration(minutes: 70))));
      expect(past.map((h) => h.key).toSet(), {'sahin.tr'});
      // vergangen: neueste zuerst
      expect(past.first.entry.start.isAfter(past.last.entry.start), isTrue);
      expect(
          searchEpg(db, 'p', foldSearch('Tatort'),
              now: sec(now), from: sec(now), to: sec(now), limit: 5),
          hasLength(lessThanOrEqualTo(5)));
      // Nur sichtbare Sender.
      setSearchChannels(db, {'zdf.de': true});
      expect(
          searchEpg(db, 'p', 'haber', now: sec(now), from: 0, to: sec(now) * 2)
              .map((h) => h.key)
              .toSet(),
          {'zdf.de'});
      // 2 Zeichen
      expect(searchEpg(db, 'p', 'ha', now: sec(now), from: 0, to: sec(now) * 2),
          isNotEmpty);
    });
  });

  test('Portal löschen entfernt alles (Listen, EPG, Suchindex)', () {
    writeLive(db, 'p',
        fp: 'f', hash: null, saved: DateTime(2026), cats: cats, items: chans());
    writeVod(db, 'p', 'movies',
        fp: 'f',
        hash: null,
        saved: DateTime(2026),
        cats: cats,
        items: const [
          VodItem(id: 'm', name: 'M', categoryId: '1', streamUrl: 'u')
        ]);
    writeEpg(
        db,
        'p',
        {
          'x': [
            EpgEntry(
                channelEpgId: 'x',
                title: 'T',
                start: DateTime(2026),
                end: DateTime(2026, 1, 2))
          ]
        },
        saved: DateTime(2026));
    writeLive(db, 'q',
        fp: 'f', hash: null, saved: DateTime(2026), cats: cats, items: chans());
    deletePortalData(db, 'p');
    expect(portalsWithData(db), ['q']);
    for (final t in [
      'epg',
      'epg_chan',
      'epg_text',
      'epg_meta',
      'vod',
      'vod_fts'
    ]) {
      expect(db.select('SELECT count(*) FROM $t').first.columnAt(0), 0,
          reason: t);
    }
    expect(db.select('SELECT count(*) FROM channels').first.columnAt(0), 4);
    expect(searchChannelIds(db, 'q', 'zdf'), ['b']);
    expect(searchChannelIds(db, 'p', 'zdf'), isEmpty);
  });
}
