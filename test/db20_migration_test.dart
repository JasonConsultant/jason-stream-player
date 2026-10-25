import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jason_stream_player/core/secret_store.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jason_stream_player/data/db/catalog.dart';
import 'package:jason_stream_player/data/epg_cache/epg_cache.dart';
import 'package:jason_stream_player/data/net.dart';
import 'package:jason_stream_player/data/xmltv_parser.dart';
import 'package:jason_stream_player/data/list_cache.dart';
import 'package:jason_stream_player/data/storage.dart';
import 'package:jason_stream_player/models/models.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';

/// 2.0: Update über eine bestehende Installation – die alten
/// Zwischenspeicher (JSON-Dateien bis 1.9) werden einmalig in die Datenbank
/// übernommen; Favoriten, Verlauf, Einstellungen bleiben unberührt.

const portal = Portal(
  id: 'alt-1',
  name: 'Alt',
  type: PortalType.xtream,
  url: 'http://srv.example:8080',
  username: 'jason77',
  password: 'Geh eim!',
);

/// Datei genau so, wie 1.9 sie geschrieben hat (Kopf + maskierter Inhalt).
void writeLegacy(Directory dir, String kind, String body, {Portal p = portal,
    DateTime? saved}) {
  final spec = CacheSpec(null, _secretsOf(p), ListCache.fingerprintFor(p), null);
  final content = ListCache.fileContent(spec, body, ListCache.hashBody(body),
      saved: saved ?? DateTime(2026, 10, 1, 8));
  File('${dir.path}/${kind}_${p.id}.json').writeAsStringSync(content);
}

List<String> _secretsOf(Portal p) {
  // Wie ListCache._secrets: kodiert + roh, längste zuerst.
  final out = <String>[];
  for (final v in [p.username, p.password]) {
    if (v == null || v.length < 2) continue;
    for (final x in [Uri.encodeComponent(v), v]) {
      if (!out.contains(x)) out.add(x);
    }
  }
  out.sort((a, b) => b.length.compareTo(a.length));
  return out;
}

const cats = [Category(id: '1', name: 'DE | Sport'), Category(id: '2', name: 'TR | Ulusal')];
final chans = [
  for (var i = 0; i < 50; i++)
    Channel(
      id: '$i',
      name: i == 3 ? 'Şahin HD' : 'Sender $i',
      categoryId: i.isEven ? '1' : '2',
      streamUrl: 'http://srv.example:8080/live/jason77/Geh%20eim!/$i.ts',
      epgId: 'e$i',
      number: i + 1,
      catchupDays: i % 5 == 0 ? 3 : 0,
      headers: i == 1 ? const {'User-Agent': 'Box'} : null,
    ),
];

String _dbText(Directory dir) {
  final b = StringBuffer();
  final d = Directory('${dir.path}/databases');
  if (!d.existsSync()) return '';
  for (final f in d.listSync().whereType<File>()) {
    b.write(latin1.decode(f.readAsBytesSync(), allowInvalid: true));
  }
  return b.toString();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('db20mig_');
    ListCache.debugDirectory = dir.path;
  });
  tearDown(() {
    Catalog.closeWorker();
    ListCache.debugDirectory = null;
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('Senderliste 1.9 → Datenbank: gleiche Daten, Prüfsumme, Datei weg', () async {
    final body = ListCache.liveBody(cats, chans);
    writeLegacy(dir, 'live', body);
    final file = File('${dir.path}/live_alt-1.json');
    expect(file.readAsStringSync(), isNot(contains('jason77')));
    expect(await ListCache.exists('live', portal), isTrue);

    final first = (await ListCache.loadLive(portal))!;
    expect(first.items.length, 50);
    expect(first.items[3].name, 'Şahin HD');
    expect(first.items[7].streamUrl,
        'http://srv.example:8080/live/jason77/Geh%20eim!/7.ts');
    expect(first.items[1].headers, {'User-Agent': 'Box'});
    expect(first.hash, ListCache.hashBody(body));
    expect(first.saved, DateTime(2026, 10, 1, 8));
    // Übernahme läuft danach im Hintergrund (Start wartet nicht).
    await ListCache.debugMigrations();
    expect(file.existsSync(), isFalse, reason: 'alte Datei nach Übernahme gelöscht');

    // Zweiter Start: aus der Datenbank, identisch.
    final second = (await ListCache.loadLive(portal))!;
    expect(second.items.map((c) => c.streamUrl), first.items.map((c) => c.streamUrl));
    expect(second.hash, first.hash);
    expect(second.categories.map((c) => c.name), ['DE | Sport', 'TR | Ulusal']);
    expect(await ListCache.exists('live', portal), isTrue);
    // Datenbank enthält keine Zugangsdaten.
    final raw = _dbText(dir);
    expect(raw, contains('Sender 7'));
    expect(raw, isNot(contains('jason77')));
    expect(raw, isNot(contains('Geh')));
    // Gleicher Inhalt vom Portal → „unverändert“ (kein Neuaufbau nach Update).
    final again = ListCache.finishLive(
        await ListCache.spec('live', portal, prevHash: second.hash), cats, chans);
    expect(again.unchanged, isTrue);
    // Suchindex ist mit übernommen.
    expect(await Catalog.searchChannelIds(portal.id, 'sahin'), ['3']);
  });

  test('Filme/Serien 1.9 (inkl. Emby-Feldern) → Datenbank', () async {
    final items = [
      VodItem(id: 'm1', name: 'Gönül Dağı', categoryId: '1',
          streamUrl: 'http://srv.example:8080/movie/jason77/Geh%20eim!/1.mkv',
          rating: 7.5, year: 2020, genre: 'Dram', plot: 'P',
          added: DateTime(2024), duration: const Duration(minutes: 90),
          cast: 'Ayşe Öztürk', director: 'D', trailer: 'yt'),
    ];
    writeLegacy(dir, 'movies', ListCache.vodBody(cats, items));
    final series = [
      const VodItem(id: 's1', name: 'Serie', categoryId: '2', streamUrl: '', isSeries: true,
          plot: 'Handlung'),
    ];
    writeLegacy(dir, 'series', ListCache.vodBody(cats, series));
    const emby = Portal(id: 'emby_abc', name: 'Emby', type: PortalType.m3u, url: 'http://e');
    writeLegacy(dir, 'embymovies', ListCache.vodBody(cats, const [
      VodItem(id: 'emby_9', name: 'E', categoryId: '1', streamUrl: '',
          source: VodSource.emby, serverPosition: Duration(seconds: 30), serverPlayed: true),
    ]), p: emby);

    final m = (await ListCache.loadVod('movies', portal))!.items.single;
    expect(m.streamUrl, 'http://srv.example:8080/movie/jason77/Geh%20eim!/1.mkv');
    expect([m.rating, m.year, m.genre, m.plot, m.added, m.duration, m.cast, m.director, m.trailer],
        [7.5, 2020, 'Dram', 'P', DateTime(2024), const Duration(minutes: 90), 'Ayşe Öztürk', 'D', 'yt']);
    expect((await ListCache.loadVod('series', portal))!.items.single.plot, 'Handlung');
    final e = (await ListCache.loadVod('embymovies', emby))!.items.single;
    await ListCache.debugMigrations();
    expect(e.isEmby, isTrue);
    expect(e.serverPosition, const Duration(seconds: 30));
    expect(e.serverPlayed, isTrue);
    expect(dir.listSync().whereType<File>().where((f) => f.path.endsWith('.json')), isEmpty);
    // Zweites Laden aus der Datenbank.
    expect((await ListCache.loadVod('movies', portal))!.items.single.cast, 'Ayşe Öztürk');
  });

  test('Datei mit anderen Zugangsdaten bzw. beschädigt → neu laden, Datei weg', () async {
    writeLegacy(dir, 'live', ListCache.liveBody(cats, chans));
    const changed = Portal(id: 'alt-1', name: 'Alt', type: PortalType.xtream,
        url: 'http://srv.example:8080', username: 'jason77', password: 'neu!');
    expect(await ListCache.loadLive(changed), isNull);
    expect(File('${dir.path}/live_alt-1.json').existsSync(), isFalse);

    File('${dir.path}/movies_alt-1.json').writeAsStringSync('{"v":1,"fp":"x",[[kaputt');
    expect(await ListCache.loadVod('movies', portal), isNull);
    expect(File('${dir.path}/movies_alt-1.json').existsSync(), isFalse);
  });

  test('Datenbank nicht nutzbar → alte Datei wird wie bisher gelesen (Start klappt)', () async {
    // „databases“ ist eine Datei → Datenbank lässt sich nicht anlegen.
    File('${dir.path}/databases').writeAsStringSync('blockiert');
    writeLegacy(dir, 'live', ListCache.liveBody(cats, chans));
    final l = await ListCache.loadLive(portal);
    expect(l!.items.length, 50);
    // Datei bleibt (nichts übernommen).
    expect(File('${dir.path}/live_alt-1.json').existsSync(), isTrue);
    // Speichern vom Portal schlägt still fehl, Liste kommt trotzdem an.
    final out = ListCache.finishLive(await ListCache.spec('live', portal), cats, chans);
    expect(out.items.length, 50);
  });

  test('Favoriten, Verlauf, eigene Gruppen, Positionen, Einstellungen bleiben unverändert', () async {
    SharedPreferences.setMockInitialValues({});
    final st = await Storage.open(store: PreviewSecretStore());
    await st.addPortal(portal);
    await st.setActivePortal(portal.id);
    await st.toggleFavorite(portal.id, '3');
    await st.toggleFavorite(portal.id, '7');
    await st.pushRecent(portal.id, '7');
    await st.toggleLocked(portal.id, '9');
    await st.setOption('mygroups_${portal.id}', '[{"id":"g1","name":"Meine","channels":["3"]}]');
    await st.setResume('m1', 1234, 5000);
    await st.setGroupOrder(portal.id, ['2', '1']);
    await st.setCountries(portal.id, {'TR'});
    await st.setFlag('mergevariants', false);
    final sp = await SharedPreferences.getInstance();
    final before = {for (final k in sp.getKeys()) k: sp.get(k)};

    writeLegacy(dir, 'live', ListCache.liveBody(cats, chans));
    expect((await ListCache.loadLive(portal))!.items, hasLength(50));

    final after = {for (final k in sp.getKeys()) k: sp.get(k)};
    expect(after, before);
    expect(st.favorites(portal.id), {'3', '7'});
    expect(st.recent(portal.id), ['7']);
    expect(st.locked(portal.id), {'9'});
    expect(st.resume('m1')?.pos, 1234);
    expect(st.groupOrder(portal.id), ['2', '1']);
    expect(st.countries(portal.id), {'TR'});
    expect(st.portals().single.password, 'Geh eim!');
  });

  test('Portal löschen löscht Listen in der Datenbank und alte Dateien', () async {
    writeLegacy(dir, 'live', ListCache.liveBody(cats, chans));
    await ListCache.loadLive(portal); // → Datenbank
    await ListCache.debugMigrations();
    writeLegacy(dir, 'series', ListCache.vodBody(cats, const []));
    await ListCache.clear(portal);
    expect(await ListCache.exists('live', portal), isFalse);
    expect(File('${dir.path}/series_alt-1.json').existsSync(), isFalse);
    expect(await Catalog.portalsWithData(), isEmpty);
    final db = sqlite3.open('${dir.path}/databases/catalog.db');
    addTearDown(db.close);
    expect(db.select('SELECT count(*) FROM channels').first.columnAt(0), 0);
  });

  group('EPG', () {
    final now = DateTime.now();
    final base = DateTime(now.year, now.month, now.day, now.hour);
    Map<String, List<EpgEntry>> epg() => {
          for (final ch in ['zdf.de', 'trt1.tr'])
            ch: [
              // 5 Tage zurück … 5 Tage voraus, stündlich.
              for (var h = -120; h < 120; h++)
                EpgEntry(
                  channelEpgId: ch,
                  title: h.isEven ? 'Haberler' : 'Tatort Münster',
                  description: 'Folge $h',
                  genre: 'Krimi',
                  start: base.add(Duration(hours: h)),
                  end: base.add(Duration(hours: h + 1)),
                  hasArchive: h < 0,
                ),
            ],
        };

    test('EPG-Datei 1.9 → Datenbank: Speicher hält nur das Fenster, Archiv in der DB',
        () async {
      final raw = EpgCache.debugEncode(epg());
      final file = File('${dir.path}/epg_alt-1.bin')..writeAsBytesSync(raw);
      final near = (await EpgCache.loadWindow('alt-1', near: true))!;
      // Schnellstart direkt aus der Datei, Übernahme erst in Stufe 2.
      expect(file.existsSync(), isTrue);
      expect(EpgCache.dbBacked['alt-1'], isFalse);
      expect(near['zdf.de']!.first.start.isAfter(base.subtract(const Duration(hours: 4))), isTrue);
      final mem = (await EpgCache.loadWindow('alt-1'))!;
      expect(file.existsSync(), isFalse, reason: 'übernommen und gelöscht');
      expect(EpgCache.dbBacked['alt-1'], isTrue);
      // Prüfsumme wie bisher (md5 der alten Datei) → gleiches EPG vom Server
      // gilt nach dem Update als unverändert.
      expect(EpgCache.hashOf(mem), EpgCache.hashBytes(raw));
      expect(EpgCache.hashEpg(epg()), EpgCache.hashBytes(raw));
      // Speicher: gestern … übermorgen (≈ 3 Tage), nicht 10 Tage.
      expect(mem['zdf.de']!.length, inInclusiveRange(70, 75));
      expect(mem['zdf.de']!.first.end.isAfter(now.subtract(EpgCache.memoryBack)), isTrue);
      // Archiv (5 Tage zurück) aus der Datenbank.
      final all = (await Catalog.epgChannels('alt-1', ['zdf.de']))!['zdf.de']!;
      expect(all.length, 240);
      expect(all.first.start, base.subtract(const Duration(hours: 120)));
      expect(all.first.hasArchive, isTrue);
      expect(all.first.description, 'Folge -120');
      final info = (await Catalog.epgInfo('alt-1'))!;
      expect(info.count, 480);
      expect(info.channels, 2);
      // Suche über das ganze Programm, mit Faltung.
      await Catalog.setSearchChannels({'zdf.de': true, 'trt1.tr': false});
      final t = now.millisecondsSinceEpoch ~/ 1000;
      final hits = (await Catalog.searchEpg('alt-1', 'munster',
          now: t, from: t - 7 * 86400, to: t + 2 * 86400, limit: 500))!;
      expect(hits, isNotEmpty);
      expect(hits.where((h) => h.entry.end.isBefore(now)).map((h) => h.key).toSet(),
          {'zdf.de'}); // Vergangenes nur mit Catch-up
    });

    test('Beschädigte EPG-Datei → nichts, gelöscht (neu laden)', () async {
      final f = File('${dir.path}/epg_alt-1.bin')..writeAsStringSync('Unsinn');
      expect(await EpgCache.loadWindow('alt-1', near: true), isNull);
      expect(f.existsSync(), isFalse);
      expect(await Catalog.epgInfo('alt-1'), isNull);
    });

    test('XMLTV-Download schreibt im Isolate vorbereitet; erst save schaltet um', () async {
      String ts(DateTime d) {
        final u = d.toUtc();
        String two(int v) => v.toString().padLeft(2, '0');
        return '${u.year}${two(u.month)}${two(u.day)}${two(u.hour)}${two(u.minute)}00 +0000';
      }
      final b = StringBuffer('<?xml version="1.0"?><tv><channel id="a.de"><display-name>A</display-name></channel>');
      for (var h = -100; h < 100; h++) {
        final s = base.add(Duration(hours: h));
        b.write('<programme start="${ts(s)}" stop="${ts(s.add(const Duration(hours: 1)))}" '
            'channel="a.de"><title>Sendung $h</title></programme>');
      }
      b.write('</tv>');
      Net.client = MockClient((_) async => http.Response(b.toString(), 200));
      final path = (await Catalog.path())!;
      final mem = await XmltvParser.loadSources([('http://epg.example/a.xml', 0)],
          store: EpgStoreSpec(path, 'alt-1', null));
      // Zurück kommt nur das Fenster …
      expect(mem['a.de']!.length, lessThan(80));
      // … in der Datenbank ist noch nichts aktiv (z. B. Ergebnis verworfen).
      expect(await Catalog.epgInfo('alt-1'), isNull);
      await EpgCache.save('alt-1', mem);
      final info = (await Catalog.epgInfo('alt-1'))!;
      expect(info.count, greaterThanOrEqualTo(190)); // 7-Tage-Fenster des Parsers
      expect(info.hash, EpgCache.hashOf(mem));
      // Gleiches EPG nochmal mit prevHash → nichts Neues vorbereitet.
      final again = await XmltvParser.loadSources([('http://epg.example/a.xml', 0)],
          store: EpgStoreSpec(path, 'alt-1', info.hash));
      expect(EpgCache.hashOf(again), info.hash);
      final db = sqlite3.open(path);
      addTearDown(db.close);
      expect(db.select('SELECT count(*) FROM epg_stage').first.columnAt(0), 0);
    });
  });
}
