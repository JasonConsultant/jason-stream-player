import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:jason_stream_player/core/backup.dart';
import 'package:jason_stream_player/core/secret_store.dart';
import 'package:jason_stream_player/core/security.dart';
import 'package:jason_stream_player/data/host_failover.dart';
import 'package:jason_stream_player/data/storage.dart';
import 'package:jason_stream_player/models/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Sicherung/Übertragung mit den Portal-Einstellungen „Erweitert“ (ab 1.3)
/// und Import älterer Sicherungen ohne diese Felder.

const _full = Portal(
  id: 'px',
  name: 'Mit Extras',
  type: PortalType.xtream,
  url: 'http://main.example:8080',
  username: 'u1',
  password: 'pw-Haupt-77',
  userAgent: 'VLC/3.0.20 LibVLC/3.0.20',
  referer: 'http://ref.example/',
  altUrls: ['http://mirror1.example:8080', 'http://mirror2.example:2095'],
  autoRefreshHours: 12,
  epgOffsets: {'portal': -60, 'http://epg.example/de.xml': 90},
);

const _m3u = Portal(
  id: 'pm',
  name: 'Playlist',
  type: PortalType.m3u,
  url: 'http://lists.example/get.php?username=lu&password=geheimM3U',
  altUrls: ['http://lists2.example/get.php?username=lu&password=geheimM3U'],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    HostFailover.reset();
  });

  test('Extras werden verschlüsselt gespeichert, nicht in den Einstellungen',
      () async {
    final s = await Storage.open(store: PreviewSecretStore());
    await s.addPortal(_full);
    await s.addPortal(_m3u);
    final prefs = await SharedPreferences.getInstance();
    final plain = jsonEncode({
      for (final k in prefs.getKeys())
        if (!k.startsWith('sec_')) k: prefs.get(k)
    });
    expect(plain, isNot(contains('mirror1')));
    expect(plain, isNot(contains('geheimM3U')));
    expect(plain, isNot(contains('ref.example')));
    // Neu öffnen: alles wieder da.
    final again = await Storage.open(store: PreviewSecretStore());
    final p = again.portals().firstWhere((x) => x.id == 'px');
    expect(p.userAgent, _full.userAgent);
    expect(p.referer, _full.referer);
    expect(p.altUrls, _full.altUrls);
    expect(p.autoRefreshHours, 12);
    expect(p.epgOffsets, _full.epgOffsets);
    // Zugangsdaten in Ersatz-Adressen werden in Meldungen geschwärzt.
    expect(Redactor.redact('Fehler bei ${_m3u.altUrls.first}'),
        isNot(contains('geheimM3U')));
  });

  test('Rundreise: Sicherung mit Extras → neues Gerät', () async {
    final s = await Storage.open(store: PreviewSecretStore());
    await s.addPortal(_full);
    await s.addPortal(_m3u);
    await s.setCountries('px', {'DE', 'TR'});
    final file = await BackupCodec.encrypt(s.exportAll(), 'umzug2026');

    SharedPreferences.setMockInitialValues({});
    final fresh = await Storage.open(store: PreviewSecretStore());
    await fresh.importAll(await BackupCodec.decrypt(file, 'umzug2026'),
        merge: false);
    final again = await Storage.open(store: PreviewSecretStore());
    final p = again.portals().firstWhere((x) => x.id == 'px');
    expect(p.password, 'pw-Haupt-77');
    expect(p.userAgent, _full.userAgent);
    expect(p.referer, _full.referer);
    expect(p.altUrls, _full.altUrls);
    expect(p.autoRefreshHours, 12);
    expect(p.epgOffsets, {'portal': -60, 'http://epg.example/de.xml': 90});
    expect(again.portals().firstWhere((x) => x.id == 'pm').altUrls,
        _m3u.altUrls);
    expect(again.countries('px'), {'DE', 'TR'});
  });

  test('Alte Sicherung (vor 1.3, ohne Extras) → Standardwerte', () async {
    final old = <String, Object?>{
      'format': 1,
      'app': 'jason_stream_player',
      'created': '2026-03-01T10:00:00.000',
      'portals': [
        {
          'id': 'o1',
          'name': 'Alt',
          'type': 'xtream',
          'url': 'http://old.example:8080',
          'username': 'a',
          'password': 'b',
          'epgUrl': null,
        },
      ],
      'active': 'o1',
      'prefs': {
        'fav_o1': ['c1'],
      },
    };
    final s = await Storage.open(store: PreviewSecretStore());
    await s.importAll(old, merge: false);
    final p = (await Storage.open(store: PreviewSecretStore())).portals().single;
    expect(p.id, 'o1');
    expect(p.userAgent, isNull);
    expect(p.referer, isNull);
    expect(p.altUrls, isEmpty);
    expect(p.autoRefreshHours, 0);
    expect(p.epgOffsets, isEmpty);
    expect(s.favorites('o1'), {'c1'});
  });

  test('Kaputte Extras in einer Sicherung werden ignoriert', () async {
    final data = <String, Object?>{
      'format': 1,
      'app': 'jason_stream_player',
      'portals': [
        {
          'id': 'k1',
          'name': 'Kaputt',
          'type': 'm3u',
          'url': 'http://k.example/a.m3u',
          'ua': 42,
          'referer': '   ',
          'alt': 'kein-array',
          'autoRefresh': -5,
          'epgOffsets': {'portal': 'x', 'ok': 30},
        },
      ],
      'prefs': <String, Object?>{},
    };
    final s = await Storage.open(store: PreviewSecretStore());
    await s.importAll(data, merge: false);
    final p = s.portals().single;
    expect(p.userAgent, isNull);
    expect(p.referer, isNull);
    expect(p.altUrls, isEmpty);
    expect(p.autoRefreshHours, 0);
    expect(p.epgOffsets, {'ok': 30});
  });

  test('Geänderte Adressen verwerfen die gemerkte Ersatz-Adresse', () async {
    final s = await Storage.open(store: PreviewSecretStore());
    await s.addPortal(_full);
    HostFailover.markWorking(_full, 2);
    expect(HostFailover.activeBase(_full), 'http://mirror2.example:2095');
    // Umbenennen: Adressen gleich → Wahl bleibt.
    await s.updatePortal(_full.copyWith(name: 'Neu'));
    expect(HostFailover.activeIndex(_full), 2);
    // Ersatz-Adressen geändert → wieder Hauptadresse zuerst.
    final changed = _full.copyWith(altUrls: ['http://other.example']);
    await s.updatePortal(changed);
    expect(HostFailover.activeIndex(changed), 0);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('althost_px'), isNull);
  });
}
