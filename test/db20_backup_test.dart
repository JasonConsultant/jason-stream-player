import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jason_stream_player/core/backup.dart';
import 'package:jason_stream_player/core/secret_store.dart';
import 'package:jason_stream_player/data/db/catalog.dart';
import 'package:jason_stream_player/data/epg_cache/epg_cache.dart';
import 'package:jason_stream_player/data/list_cache.dart';
import 'package:jason_stream_player/data/storage.dart';
import 'package:jason_stream_player/models/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 2.0: Sicherung bleibt kompatibel und enthält keine Datenbank-Inhalte;
/// die Datenbank selbst enthält keine Zugangsdaten; Portal löschen bzw.
/// Wiederherstellen (ersetzen) räumt die Datenbank auf.

const portal = Portal(
  id: 'bk1',
  name: 'Mein Anbieter',
  type: PortalType.xtream,
  url: 'http://srv.example:8080',
  username: 'jason77',
  password: 'Geheim!123',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('db20bk_');
    ListCache.debugDirectory = dir.path;
    SharedPreferences.setMockInitialValues({});
    final cats = [const Category(id: '1', name: 'DE | Sport')];
    final chans = [
      for (var i = 0; i < 20; i++)
        Channel(
            id: '$i',
            name: 'Kanal Nummer $i',
            categoryId: '1',
            streamUrl: 'http://srv.example:8080/live/jason77/Geheim!123/$i.ts',
            epgId: 'k$i.de'),
    ];
    ListCache.finishLive(await ListCache.spec('live', portal), cats, chans);
    ListCache.finishVod(await ListCache.spec('movies', portal), cats, const [
      VodItem(id: 'm', name: 'Filmtitel Einmalig', categoryId: '1',
          streamUrl: 'http://srv.example:8080/movie/jason77/Geheim!123/m.mkv'),
    ]);
    final now = DateTime.now();
    await EpgCache.save(portal.id, {
      'k1.de': [
        EpgEntry(channelEpgId: 'k1.de', title: 'Sendung Einmalig',
            start: now, end: now.add(const Duration(hours: 1))),
      ],
    });
  });
  tearDown(() {
    Catalog.closeWorker();
    ListCache.debugDirectory = null;
    dir.deleteSync(recursive: true);
  });

  String dbText() {
    final b = StringBuffer();
    for (final f in Directory('${dir.path}/databases').listSync().whereType<File>()) {
      b.write(latin1.decode(f.readAsBytesSync(), allowInvalid: true));
    }
    return b.toString();
  }

  test('Datenbank (inkl. WAL) enthält keine Zugangsdaten', () async {
    final raw = dbText();
    expect(raw, contains('Kanal Nummer 7'));
    expect(raw, contains('Filmtitel Einmalig'));
    expect(raw, contains('Sendung Einmalig'));
    expect(raw, isNot(contains('jason77')));
    expect(raw, isNot(contains('Geheim')));
  });

  test('Sicherung: keine DB-Inhalte, Format unverändert, Rundreise', () async {
    final st = await Storage.open(store: PreviewSecretStore());
    await st.addPortal(portal);
    await st.toggleFavorite(portal.id, '7');
    final data = st.exportAll();
    final json = jsonEncode(data);
    expect(data['format'], 1);
    expect(json, isNot(contains('Kanal Nummer')));
    expect(json, isNot(contains('Filmtitel')));
    expect(json, isNot(contains('Sendung Einmalig')));
    expect(json, isNot(contains('catalog')));
    final bytes = await BackupCodec.encrypt(data, 'passwort1');
    final back = await BackupCodec.decrypt(bytes, 'passwort1');
    SharedPreferences.setMockInitialValues({});
    final fresh = await Storage.open(store: PreviewSecretStore());
    await fresh.importAll(back);
    expect(fresh.portals().single.password, 'Geheim!123');
    expect(fresh.favorites(portal.id), {'7'});
  });

  test('Portal löschen bzw. Wiederherstellen (ersetzen) räumt die DB auf', () async {
    final st = await Storage.open(store: PreviewSecretStore());
    await st.addPortal(portal);
    expect(await Catalog.portalsWithData(), [portal.id]);
    final backup = st.exportAll();
    await st.removePortal(portal.id);
    expect(await Catalog.portalsWithData(), isEmpty);
    expect(await ListCache.exists('live', portal), isFalse);
    expect(await Catalog.epgInfo(portal.id), isNull);
    // Wiederherstellen legt das Portal wieder an – Listen kommen neu vom Portal.
    await st.importAll(backup, merge: false);
    expect(st.portals().single.id, portal.id);
    expect(await ListCache.loadLive(portal), isNull);
  });
}
