import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jason_stream_player/core/secret_store.dart';
import 'package:jason_stream_player/data/epg_cache/epg_cache.dart';
import 'package:jason_stream_player/data/image_caches.dart';
import 'package:jason_stream_player/data/list_cache.dart';
import 'package:jason_stream_player/data/net.dart';
import 'package:jason_stream_player/data/repository.dart';
import 'package:jason_stream_player/data/storage.dart';
import 'package:jason_stream_player/data/xmltv_parser.dart';
import 'package:jason_stream_player/data/xtream_repository.dart';
import 'package:jason_stream_player/models/models.dart';
import 'package:jason_stream_player/state/list_refresh.dart';
import 'package:jason_stream_player/state/providers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:jason_stream_player/data/db/catalog.dart';
import 'package:jason_stream_player/data/db/catalog_io.dart' show withCatalog;
import 'package:jason_stream_player/data/db/db_io.dart' show writeEpg;

import 'helpers/xtream_stress.dart';

const portal = Portal(
  id: 'x15',
  name: 'X',
  type: PortalType.xtream,
  url: 'http://srv.example:8080',
  username: 'jason77',
  password: 'Geh eim!',
);

class _Active extends ActivePortalNotifier {
  @override
  Future<Portal?> build() async => portal;
}

/// Mock-Server: liefert Live/Filme aus veränderbaren Antworten.
class _Server {
  Uint8List cats = xtreamCategories(5);
  Uint8List live = xtreamLiveStreams(30, groups: 5);
  Uint8List movies = xtreamMovies(40, groups: 5);
  int requests = 0;
  http.Client client() => MockClient(handle);
  Future<http.Response> handle(http.Request req) async {
    requests++;
    final a = req.url.queryParameters['action'];
    final body = switch (a) {
      'get_live_categories' || 'get_vod_categories' => cats,
      'get_live_streams' => live,
      'get_vod_streams' => movies,
      _ => utf8.encode('[]'),
    };
    return http.Response.bytes(body, 200);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('data15_');
    ListCache.debugDirectory = dir.path;
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() {
    ListCache.debugDirectory = null;
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('Xtream – fehlerhafte Einträge', () {
    test('Liste mit Nicht-Objekten und fehlender ID kippt nicht', () {
      final data = [
        1,
        'kaputt',
        null,
        [1, 2],
        {'name': 'ohne ID'},
        {
          'stream_id': {'x': 1},
          'name': 'ID ist Objekt'
        },
        {'stream_id': 7, 'name': 'Gut', 'category_id': 3, 'num': 'x'},
      ];
      final live = XtreamRepository.mapLive(data, 'http://h', 'u', 'p');
      expect(live.map((c) => c.id), ['7']);
      expect(live.single.number, 0);
      expect(live.single.streamUrl, 'http://h/live/u/p/7.ts');
      expect(XtreamRepository.mapMovies(data, 'http://h', 'u', 'p').length, 1);
      expect(
          XtreamRepository.mapSeries([
            'x',
            {'series_id': 3, 'name': null, 'backdrop_path': 'kein Array'}
          ]).single.name,
          '');
      expect(
          XtreamRepository.mapCategories([
            {'category_id': 1, 'category_name': 'A'},
            'x',
            {'category_name': 'ohne ID'}
          ]).map((c) => c.id),
          ['1']);
      // Keine Liste → leer statt Fehler.
      expect(
          XtreamRepository.mapLive({'user_info': {}}, 'h', 'u', 'p'), isEmpty);
    });
  });

  group('Listen-Zwischenspeicher', () {
    test('Speichern/Laden im Isolate, ohne Zugangsdaten in der Datei',
        () async {
      final repo = XtreamRepository(portal);
      final s = _Server();
      Net.client = s.client();
      final spec = await ListCache.spec('live', portal);
      final out = await repo.liveBundle(spec);
      expect(out.unchanged, isFalse);
      expect(out.items.length, 30);
      // Ab 2.0 in der Datenbank (samt WAL) – ohne Zugangsdaten.
      final raw = _dbBytes(dir);
      expect(raw, isNot(contains('jason77')));
      expect(raw, isNot(contains('Geh')));
      expect(raw, contains('100000.ts'));
      final back = await ListCache.loadLive(portal);
      expect(back!.items.length, 30);
      expect(back.hash, out.hash);
      expect(back.items.first.streamUrl,
          'http://srv.example:8080/live/jason77/Geh%20eim!/100000.ts');
    });

    test('Unveränderter Inhalt → nichts schreiben, nichts übertragen',
        () async {
      final repo = XtreamRepository(portal);
      final s = _Server();
      Net.client = s.client();
      final first = await repo.liveBundle(await ListCache.spec('live', portal));
      final before = _savedAt(dir, 'live');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final again = await repo.liveBundle(
          await ListCache.spec('live', portal, prevHash: first.hash));
      expect(again.unchanged, isTrue);
      expect(again.items, isEmpty);
      expect(_savedAt(dir, 'live'), before); // gleicher Zeitstempel
      s.live = xtreamLiveStreams(30, groups: 5, tag: ' neu');
      final changed = await repo.liveBundle(
          await ListCache.spec('live', portal, prevHash: first.hash));
      expect(changed.unchanged, isFalse);
      expect(changed.hash, isNot(first.hash));
    });

    test('Ersatz-Adresse und Fehler beim Laden im Hintergrund', () async {
      const p = Portal(
          id: 'fo',
          name: 'F',
          type: PortalType.xtream,
          url: 'http://main.example',
          username: 'u',
          password: 'p',
          altUrls: ['http://backup.example']);
      final s = _Server();
      Net.client = MockClient((req) async {
        if (req.url.host == 'main.example') {
          throw const SocketException('weg');
        }
        return s.handle(req);
      });
      final out = await XtreamRepository(p).liveBundle(null);
      expect(out.items.length, 30);
      expect(out.items.first.streamUrl, startsWith('http://backup.example/'));
      Net.client = MockClient((req) async => http.Response('nein', 401));
      await expectLater(XtreamRepository(portal).liveBundle(null),
          throwsA(isA<RepositoryException>()));
    });

    test('Beschädigte Datei → wie nicht vorhanden, wird gelöscht', () async {
      final file = File('${dir.path}/live_x15.json')
        ..writeAsStringSync('{"v":1,"fp":"${ListCache.fingerprintFor(portal)}",'
            '"saved":1,"ch":[[kaputt');
      expect(await ListCache.loadLive(portal), isNull);
      expect(file.existsSync(), isFalse);
      // Falscher Typ der Struktur
      final f2 = File('${dir.path}/movies_x15.json')
        ..writeAsStringSync('{"v":1,"fp":"${ListCache.fingerprintFor(portal)}",'
            '"saved":"gestern","items":{}}');
      expect(await ListCache.loadVod('movies', portal), isNull);
      expect(f2.existsSync(), isFalse);
    });

    test('Einzelne kaputte Zeilen im Speicher werden übersprungen', () {
      final raw = jsonEncode({
        'saved': 1,
        'cats': [
          ['1', 'A'],
          'x',
          [2, 'B']
        ],
        'ch': [
          ['a', 'Sender', null, '1', 'http://s/1', null, 0, 1, null, null],
          ['b', 5, null, '1', 'http://s/2', null, 0, 1, null, null],
          'kaputt',
          ['c', 'Kurz'],
          [
            'd',
            'Mit Kopf',
            null,
            '1',
            'http://s/4',
            'd.de',
            '3',
            2.0,
            null,
            null,
            {'User-Agent': 'X', 'n': 1},
            'x'
          ],
        ],
      });
      final d = ListCache.debugDecodeLive(raw)!;
      expect(d.categories.map((c) => c.id), ['1']);
      expect(d.items.map((c) => c.id), ['a', 'd']);
      expect(d.items.last.number, 2);
      expect(d.items.last.catchupDays, 0);
      expect(d.items.last.headers, {'User-Agent': 'X'});
      expect(d.items.last.epgShift, 0);
    });
  });

  group('Start-Nachladen', () {
    Future<ProviderContainer> container(_Server s) async {
      final st = await Storage.open(store: PreviewSecretStore());
      Net.client = s.client();
      return ProviderContainer(overrides: [
        storageProvider.overrideWith((_) async => st),
        activePortalProvider.overrideWith(_Active.new),
        repositoryProvider.overrideWith((_) async => XtreamRepository(portal)),
      ]);
    }

    test('Unverändert → 0 neue Zustände, 0 Neuberechnungen; geändert → 1',
        () async {
      StartReload.liveDelay = const Duration(milliseconds: 20);
      StartReload.moviesDelay = const Duration(milliseconds: 40);
      addTearDown(() {
        StartReload.liveDelay = const Duration(seconds: 8);
        StartReload.moviesDelay = const Duration(seconds: 45);
      });
      final s = _Server();
      // 1. Erster Start: kein Speicher → vom Server, Datei wird geschrieben.
      var c = await container(s);
      expect((await c.read(liveDataProvider.future)).channels.length, 30);
      expect((await c.read(moviesProvider.future)).items.length, 40);
      c.dispose();

      // 2. Zweiter Start: aus dem Speicher; stilles Nachladen bringt
      //    denselben Inhalt → kein neuer Zustand.
      c = await container(s);
      var derived = 0;
      final derivedProvider = Provider<int>((ref) {
        ref.watch(liveDataProvider);
        ref.watch(moviesProvider);
        return ++derived;
      });
      final emits = <String>[];
      c.listen(liveDataProvider, (_, __) => emits.add('live'));
      c.listen(moviesProvider, (_, __) => emits.add('movies'));
      c.listen(derivedProvider, (_, __) {});
      await c.read(liveDataProvider.future);
      await c.read(moviesProvider.future);
      await Future<void>.delayed(Duration.zero);
      final settledEmits = emits.length;
      final settledDerived = derived;
      final req = s.requests;
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(s.requests, greaterThan(req), reason: 'Nachladen lief');
      expect(emits.length - settledEmits, 0);
      expect(derived - settledDerived, 0);

      // 3. Inhalt geändert → genau eine neue Senderliste.
      s.live = xtreamLiveStreams(31, groups: 5);
      final liveBefore = emits.where((e) => e == 'live').length;
      await c.read(liveDataProvider.notifier).reload(silent: true);
      expect(emits.where((e) => e == 'live').length - liveBefore, 1);
      expect(c.read(liveDataProvider).value!.channels.length, 31);
      c.dispose();
    });

    test('Wartet, solange ein Stream startet', () async {
      PlaybackGate.starting();
      addTearDown(PlaybackGate.reset);
      StartReload.retryDelay = const Duration(milliseconds: 20);
      addTearDown(() => StartReload.retryDelay = const Duration(seconds: 5));
      var ran = 0;
      final h =
          StartReload.schedule(const Duration(milliseconds: 10), () => ran++);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(ran, 0);
      expect(h.pending, isTrue);
      PlaybackGate.reset();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(ran, 1);
      expect(h.pending, isFalse);
    });
  });

  group('EPG', () {
    final now = DateTime.now();
    final base = DateTime.fromMillisecondsSinceEpoch(
        now.millisecondsSinceEpoch ~/ 60000 * 60000);
    String xml(int channels) {
      String t(DateTime d) {
        final u = d.toUtc();
        String two(int v) => v.toString().padLeft(2, '0');
        return '${u.year}${two(u.month)}${two(u.day)}${two(u.hour)}'
            '${two(u.minute)}00 +0000';
      }

      final b = StringBuffer('<?xml version="1.0"?><tv>');
      for (var c = 0; c < channels; c++) {
        b.write('<channel id="k$c.de"><display-name>Kanal $c</display-name>'
            '</channel>');
      }
      for (var c = 0; c < channels; c++) {
        for (var i = 0; i < 10; i++) {
          final s = base.add(Duration(minutes: 30 * i));
          b.write(
              '<programme start="${t(s)}" stop="${t(s.add(const Duration(minutes: 30)))}" '
              'channel="k$c.de"><title>Sendung $i</title><desc>Text $c/$i</desc>'
              '</programme>');
        }
      }
      b.write('</tv>');
      return b.toString();
    }

    test('Streaming-Parse im Isolate liefert fertige Cache-Bytes', () async {
      final body = xml(20);
      Net.client = MockClient((req) async => http.Response.bytes(
          req.url.path.endsWith('.gz')
              ? gzip.encode(utf8.encode(body))
              : utf8.encode(body),
          200));
      final progress = <bool>[];
      final epg = await XmltvParser.loadSources([
        ('http://epg.example/a.xml.gz', 0),
        ('http://epg.example/b.xml', 60)
      ], channelIds: {
        'k1.de',
        'k2.de'
      }, onParsing: (_) => progress.add(true));
      expect(epg.keys.toSet(), {'k1.de', 'k2.de'});
      expect(epg['k1.de']!.length, 10);
      // Erste Quelle hat Vorrang (kein Versatz).
      expect(epg['k1.de']!.first.start, base);
      expect(progress.length, 2);
      final hash = EpgCache.hashOf(epg);
      expect(hash, isNotNull);
      expect(hash, EpgCache.hashBytes(EpgCache.debugEncode(epg)));
    });

    test('Fehler einer Quelle stört nicht, alle Fehler → Ausnahme', () async {
      Net.client = MockClient((req) async => req.url.path.contains('bad')
          ? http.Response('nein', 500)
          : http.Response(xml(2), 200));
      final epg = await XmltvParser.loadSources([
        ('http://epg.example/bad.xml', 0),
        ('http://epg.example/ok.xml', 0)
      ]);
      expect(epg.keys.toSet(), {'k0.de', 'k1.de'});
      await expectLater(
          XmltvParser.loadSources([('http://epg.example/bad.xml', 0)]),
          throwsA(isA<RepositoryException>()));
    });

    test('tvg-shift wird im Isolate angewendet', () async {
      Net.client = MockClient((req) async => http.Response(xml(2), 200));
      final epg = await XmltvParser.loadSources(
          [('http://epg.example/a.xml', 0)],
          shifts: {'k0.de': 60});
      expect(epg['k0.de']!.first.start, base.add(const Duration(hours: 1)));
      expect(epg['k1.de']!.first.start, base);
      expect(
          EpgCache.hashOf(epg), EpgCache.hashBytes(EpgCache.debugEncode(epg)));
    });

    test('Beschädigter EPG-Speicher → null und gelöscht', () async {
      final f = File('${dir.path}/epg_x15.bin')
        ..writeAsBytesSync([
          0x4A,
          0x45,
          0x50,
          0x47,
          0,
          0,
          0,
          2,
          0xFF,
          0xFF,
          0xFF,
          0xFF,
          0,
          0,
          0,
          9
        ]);
      expect(await EpgCache.loadWindow('x15', near: true), isNull);
      expect(f.existsSync(), isFalse);
      File('${dir.path}/epg_x15.bin').writeAsStringSync('Unsinn');
      expect(await EpgCache.loadWindow('x15'), isNull);
    });

    test('Speichern nutzt die fertigen Bytes, Laden liefert die Prüfsumme',
        () async {
      Net.client = MockClient((req) async => http.Response(xml(3), 200));
      final epg =
          await XmltvParser.loadSources([('http://epg.example/a.xml', 0)]);
      await EpgCache.save('x15', epg);
      final full = await EpgCache.loadWindow('x15');
      expect(full!.keys.toSet(), epg.keys.toSet());
      expect(EpgCache.hashOf(full), EpgCache.hashOf(epg));
      final near = await EpgCache.loadWindow('x15', near: true);
      expect(near!['k0.de']!.first.title, 'Sendung 0');
    });
  });

  group('Kurz-EPG gesammelt', () {
    test('40 Sender → höchstens wenige Veröffentlichungen statt 10', () async {
      EpgNotifier.shortPublishEvery = const Duration(milliseconds: 250);
      addTearDown(
          () => EpgNotifier.shortPublishEvery = const Duration(seconds: 4));
      final st = await Storage.open(store: PreviewSecretStore());
      final repo = _ShortRepo();
      final c = ProviderContainer(overrides: [
        storageProvider.overrideWith((_) async => st),
        activePortalProvider.overrideWith(_Active.new),
        repositoryProvider.overrideWith((_) async => repo),
        liveDataProvider.overrideWith(_Live.new),
        sortOrderProvider.overrideWith(_Sort.new),
      ]);
      addTearDown(c.dispose);
      var emits = 0;
      c.listen(epgProvider, (_, __) => emits++);
      await c.read(epgProvider.future);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final settled = emits;
      final n = c.read(epgProvider.notifier);
      for (var i = 0; i < 40; i++) {
        n.want(Channel(
            id: '$i', name: 'S$i', categoryId: 'g', streamUrl: 'http://s/$i'));
      }
      await Future<void>.delayed(const Duration(milliseconds: 900));
      final epg = c.read(epgProvider).value!;
      expect(epg.length, 40);
      // Vorher: 10 Veröffentlichungen (je 4 Sender).
      expect(emits - settled, lessThanOrEqualTo(3));
      expect(repo.calls, 40);
      // Gleiche Daten nochmal → kein neuer Zustand.
      final before = emits;
      n.want(Channel(
          id: '0', name: 'S0', categoryId: 'g', streamUrl: 'http://s/0'));
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(emits, before);
    });
  });

  group('Haupt-Isolate bleibt frei (großzügige Grenzen für CI)', () {
    test('100 000 Filme nachladen: kurzer Stillstand, unverändert ohne Zustand',
        () async {
      final s = _Server()..movies = xtreamMovies(100000);
      Net.client = MockClient.streaming((req, _) async {
        final body = (await s.handle(req as http.Request)).bodyBytes;
        Stream<List<int>> chunks() async* {
          for (var i = 0; i < body.length; i += 65536) {
            await Future<void>.delayed(Duration.zero);
            yield Uint8List.fromList(body.sublist(
                i, i + 65536 > body.length ? body.length : i + 65536));
          }
        }

        return http.StreamedResponse(chunks(), 200);
      });
      final repo = XtreamRepository(portal);
      final (out, stall) = await measureMainStall(() async =>
          repo.vodBundle(false, await ListCache.spec('movies', portal)));
      expect(out.items.length, 100000);
      final (same, stall2) = await measureMainStall(() async => repo.vodBundle(
          false, await ListCache.spec('movies', portal, prevHash: out.hash)));
      expect(same.unchanged, isTrue);
      // Vorher (1.4) ≈ 600–1100 ms auf dem Desktop.
      expect(stall, lessThan(400));
      expect(stall2, lessThan(400));
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('EPG speichern nach dem Parse-Isolate kopiert das EPG nicht', () async {
      final now = DateTime.now();
      final epg = {
        for (var c = 0; c < 800; c++)
          'c$c': [
            for (var i = 0; i < 250; i++)
              EpgEntry(
                  channelEpgId: 'c$c',
                  title: 'T$i',
                  description: 'Beschreibung $c $i',
                  start: now.add(Duration(minutes: 30 * i)),
                  end: now.add(Duration(minutes: 30 * i + 30)))
          ]
      };
      // Ab 2.0 schreibt das Parse-Isolate gleich in die Datenbank
      // (vorbereitete Generation); [EpgCache.save] schaltet nur noch um.
      final path = (await Catalog.path())!;
      final hash = EpgCache.hashEpg(epg);
      final gen = await Isolate.run(() => withCatalog(path,
          (db) => writeEpg(db, 'big', epg, saved: now, hash: hash, activate: false)!.gen));
      EpgCache.attach(epg, null, hash, staged: gen);
      final (_, stall) =
          await measureMainStall(() => EpgCache.save('big', epg));
      final info = await Catalog.epgInfo('big');
      expect(info!.gen, gen);
      expect(info.count, 200000);
      expect(info.hash, hash);
      // Vorher (Kopie von 200 000 Sendungen ins Isolate) ≈ 0,8–1,2 s.
      expect(stall, lessThan(200));
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  group('Sonstiges', () {
    test('Bild-Cache nach RAM', () {
      expect(ImageCaches.memoryLimits(2 << 30).bytes, 48 << 20);
      expect(ImageCaches.memoryLimits(null).bytes, 48 << 20);
      expect(ImageCaches.memoryLimits(4 << 30).bytes, 96 << 20);
      ImageCaches.configureMemory(4 << 30);
      expect(PaintingBindingProbe.maxBytes, 96 << 20);
      ImageCaches.configureMemory(2 << 30);
      expect(PaintingBindingProbe.maxBytes, 48 << 20);
    });

    test('Geheimnisse: ein Sammelaufruf statt einer pro Eintrag', () async {
      final store = _CountingStore();
      var s = await Storage.open(store: store);
      await s.addPortal(portal);
      await s.addPortal(const Portal(
          id: 'p2',
          name: 'Y',
          type: PortalType.m3u,
          url: 'http://l.example/x'));
      await s.setPin('1234');
      store.single = 0;
      store.batch = 0;
      s = await Storage.open(store: store);
      expect(store.batch, 1);
      expect(store.single, 0);
      expect(s.portals().length, 2);
      expect(s.unreadableSecrets, 0);
      // Unlesbarer Eintrag → wird verworfen, Rest bleibt.
      final prefs = await SharedPreferences.getInstance();
      final k =
          prefs.getKeys().firstWhere((k) => k.startsWith('sec_portal_p2'));
      await prefs.setString(k, 'p1:%%%');
      s = await Storage.open(store: store);
      expect(s.unreadableSecrets, 1);
      expect(s.portals().map((p) => p.id), ['x15']);
    });
  });
}

class PaintingBindingProbe {
  static int get maxBytes =>
      TestWidgetsFlutterBinding.instance.imageCache.maximumSizeBytes;
}

class _CountingStore extends PreviewSecretStore {
  int single = 0, batch = 0;
  @override
  Future<String> decrypt(String cipher) {
    single++;
    return super.decrypt(cipher);
  }

  @override
  Future<List<String?>> decryptAll(List<String> ciphers) {
    batch++;
    return super.decryptAll(ciphers);
  }
}

class _ShortRepo extends XtreamRepository {
  _ShortRepo() : super(portal);
  int calls = 0;
  @override
  Future<Map<String, List<EpgEntry>>> loadEpg(
          {Set<String>? channelIds,
          List<Channel>? channels,
          EpgProgress? progress,
          EpgStoreSpec? store}) async =>
      {};
  @override
  Future<List<EpgEntry>> shortEpg(Channel c) async {
    calls++;
    await Future<void>.delayed(const Duration(milliseconds: 15));
    final s = DateTime.now();
    return [
      EpgEntry(
          channelEpgId: '@${c.id}',
          title: 'Jetzt',
          start: s,
          end: s.add(const Duration(minutes: 30)))
    ];
  }
}

class _Live extends LiveNotifier {
  @override
  Future<LiveData> build() async => const LiveData([], []);
}

class _Sort extends SortOrderNotifier {
  @override
  Future<SortOrder> build() async => SortOrder.empty;
}

/// Inhalt der Katalog-Datenbank samt WAL (als Text, für „enthält nicht“).
String _dbBytes(Directory dir) {
  final b = StringBuffer();
  for (final f in Directory('${dir.path}/databases').listSync().whereType<File>()) {
    b.write(latin1.decode(f.readAsBytesSync(), allowInvalid: true));
  }
  return b.toString();
}

/// Speicherzeitpunkt einer Liste in der Datenbank.
int _savedAt(Directory dir, String kind) {
  final db = sqlite3.open('${dir.path}/databases/catalog.db');
  try {
    return db.select('SELECT saved FROM lists WHERE kind = ?', [kind]).first.columnAt(0) as int;
  } finally {
    db.close();
  }
}
