import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jason_stream_player/core/backup.dart';
import 'package:jason_stream_player/core/secret_store.dart';
import 'package:jason_stream_player/data/storage.dart';
import 'package:jason_stream_player/models/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

const p1 = Portal(
  id: 'p1',
  name: 'Mein Anbieter',
  type: PortalType.xtream,
  url: 'http://srv.example:8080',
  username: 'jason77',
  password: 'Geheim!123',
);
const p2 = Portal(
  id: 'p2',
  name: 'Playlist',
  type: PortalType.m3u,
  url: 'http://lists.example/a.m3u',
  epgUrl: 'http://lists.example/epg.xml',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('BackupCodec', () {
    final sample = <String, Object?>{
      'app': 'jason_stream_player',
      'portals': [
        {'id': 'x', 'password': 'Geheim!123'}
      ],
      'prefs': {'fav_x': ['1', '2']},
    };

    test('Ver- und Entschlüsseln mit Passwort (Rundreise)', () async {
      final bytes = await BackupCodec.encrypt(sample, 'korrekt1');
      expect(utf8.decode(bytes.sublist(0, 5)), 'JSPB1');
      // Nichts im Klartext in der Datei
      expect(latin1.decode(bytes), isNot(contains('Geheim')));
      expect(latin1.decode(bytes), isNot(contains('jason_stream')));
      final back = await BackupCodec.decrypt(bytes, 'korrekt1');
      expect(back, sample);
    });

    test('Falsches Passwort schlägt fehl', () async {
      final bytes = await BackupCodec.encrypt(sample, 'korrekt1');
      expect(
        () => BackupCodec.decrypt(bytes, 'falsch99'),
        throwsA(isA<BackupException>().having(
            (e) => e.error, 'error', BackupError.wrongPasswordOrCorrupt)),
      );
    });

    test('Veränderter Chiffretext schlägt fehl', () async {
      final bytes = await BackupCodec.encrypt(sample, 'korrekt1');
      final tampered = Uint8List.fromList(bytes);
      tampered[40] ^= 0x01; // im Chiffretext (nach Magic+Salz+Nonce = 33)
      expect(
        () => BackupCodec.decrypt(tampered, 'korrekt1'),
        throwsA(isA<BackupException>().having(
            (e) => e.error, 'error', BackupError.wrongPasswordOrCorrupt)),
      );
    });

    test('Fremde Datei / zu kurzes Passwort', () async {
      expect(
        () => BackupCodec.decrypt(Uint8List.fromList(utf8.encode('#EXTM3U\n')),
            'korrekt1'),
        throwsA(isA<BackupException>()
            .having((e) => e.error, 'error', BackupError.notABackup)),
      );
      expect(() => BackupCodec.encrypt(sample, 'kurz'),
          throwsA(isA<BackupException>()));
    });

    test('Jede Sicherung hat eigenes Salz/Nonce', () async {
      final a = await BackupCodec.encrypt(sample, 'korrekt1');
      final b = await BackupCodec.encrypt(sample, 'korrekt1');
      expect(a, isNot(equals(b)));
    });

    test('PBKDF2-HMAC-SHA256 Testvektor (RFC 6070 übertragen auf SHA-256)',
        () {
      // "password"/"salt", 1 Runde, 32 Byte:
      final k = BackupCodec.deriveKey('password', utf8.encode('salt'),
          rounds: 1);
      expect(
          k.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
          '120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b');
    });
  });

  group('Storage.exportAll / importAll', () {
    Future<Storage> filled() async {
      final s = await Storage.open(store: PreviewSecretStore());
      await s.addPortal(p1);
      await s.addPortal(p2);
      await s.setActivePortal('p2');
      await s.toggleFavorite('p1', 'ch1');
      await s.toggleFavorite('p1', 'ch2');
      await s.toggleHidden('p1', 'ch9');
      await s.toggleLocked('p1', 'ch8');
      await s.setGroupOrder('p1', ['g2', 'g1']);
      await s.setChannelOrder('p1', 'g1', ['c3', 'c1']);
      await s.setHiddenGroups('p1', {'g7'});
      await s.setOption('mygroups_p1', jsonEncode([
        {'id': 'my_1', 'n': 'Fußball', 'c': ['c1']},
        {'id': 'my_2', 'n': 'Kinder', 'c': []},
      ]));
      await s.setOption('vodfav_p1', jsonEncode(['m1', 'm2', 'm3']));
      await s.setOption('applang', 'tr');
      await s.setOption('starttab', 'live');
      await s.setFlag('hwdec', false);
      await s.setEpgHour(3);
      await s.setResume('m1', 100, 1000);
      await s.setPin('1234');
      // Nicht zu sichern:
      await s.setOption('recordings', 'x');
      await s.setFlag('applock', true);
      await s.setFlag('riskack', true);
      await s.setOption('updcheck', '123');
      return s;
    }

    test('Export enthält Daten, aber weder PIN noch Chiffretext', () async {
      final s = await filled();
      final data = s.exportAll();
      final json = jsonEncode(data);
      expect(json, contains('Geheim!123')); // im Container erlaubt
      expect(json, isNot(contains('sec_')));
      expect(json, isNot(contains('pin_')));
      expect(json, isNot(contains('1234')));
      expect(json, isNot(contains('set_recordings')));
      expect(json, isNot(contains('set_applock')));
      expect(json, isNot(contains('set_riskack')));
      expect(json, isNot(contains('set_updcheck')));
      final prefs = data['prefs'] as Map;
      expect(prefs['fav_p1'], unorderedEquals(['ch1', 'ch2']));
      expect(prefs['set_epghour'], 3);
      expect(prefs['set_hwdec'], false);
      expect(prefs['resume_m1'], '100/1000');
      final sum = BackupSummary.of(data);
      expect(sum.portals, 2);
      expect(sum.favorites, 2);
      expect(sum.myGroups, 2);
      expect(sum.vodFavorites, 3);
    });

    test('Rundreise über verschlüsselte Datei auf „neues Gerät“ (ersetzen)',
        () async {
      final data = (await filled()).exportAll();
      final file = await BackupCodec.encrypt(data, 'umzug2026');

      SharedPreferences.setMockInitialValues({}); // neues Gerät
      final fresh = await Storage.open(store: PreviewSecretStore());
      await fresh.addPortal(const Portal(
          id: 'old', name: 'Alt', type: PortalType.m3u, url: 'http://x/'));
      await fresh.importAll(await BackupCodec.decrypt(file, 'umzug2026'),
          merge: false);

      final again = await Storage.open(store: PreviewSecretStore());
      final ids = again.portals().map((p) => p.id).toList();
      expect(ids, ['p1', 'p2']); // „old“ ist weg, Reihenfolge erhalten
      final r1 = again.portals().first;
      expect(r1.password, 'Geheim!123');
      expect(r1.username, 'jason77');
      expect(again.portals().last.epgUrl, 'http://lists.example/epg.xml');
      expect(again.activePortalId(), 'p2');
      expect(again.favorites('p1'), {'ch1', 'ch2'});
      expect(again.hidden('p1'), {'ch9'});
      expect(again.locked('p1'), {'ch8'});
      expect(again.groupOrder('p1'), ['g2', 'g1']);
      expect(again.channelOrder('p1', 'g1'), ['c3', 'c1']);
      expect(again.hiddenGroups('p1'), {'g7'});
      expect(jsonDecode(again.option('mygroups_p1', '[]')), hasLength(2));
      expect(again.option('applang', 'system'), 'tr');
      expect(again.option('starttab', 'home'), 'live');
      expect(again.flag('hwdec', fallback: true), isFalse);
      expect(again.epgSchedule().hour, 3);
      expect(again.resume('m1'), (pos: 100, total: 1000));
      // Gerätebezogenes bleibt unberührt
      expect(again.hasPin(), isFalse);
      expect(again.option('recordings', ''), '');
      expect(again.flag('applock'), isFalse);
    });

    test('Zusammenführen behält vorhandene Portale und aktives Portal',
        () async {
      final data = (await filled()).exportAll();

      SharedPreferences.setMockInitialValues({});
      final s = await Storage.open(store: PreviewSecretStore());
      await s.addPortal(const Portal(
          id: 'old', name: 'Alt', type: PortalType.m3u, url: 'http://x/'));
      await s.addPortal(const Portal(
          id: 'p1', name: 'Alter Name', type: PortalType.xtream, url: 'http://y/'));
      await s.setActivePortal('old');
      await s.toggleFavorite('old', 'z');
      await s.importAll(data, merge: true);

      expect(s.portals().map((p) => p.id), ['old', 'p1', 'p2']);
      expect(s.portals()[1].name, 'Mein Anbieter'); // aktualisiert
      expect(s.activePortalId(), 'old');
      expect(s.favorites('old'), {'z'});
      expect(s.favorites('p1'), {'ch1', 'ch2'});
    });

    test('Fremde Struktur wird abgelehnt', () async {
      final s = await Storage.open(store: PreviewSecretStore());
      expect(() => s.importAll({'foo': 1}), throwsFormatException);
    });
  });
}
