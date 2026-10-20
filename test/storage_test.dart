import 'dart:convert';

import 'package:jason_stream_player/core/secret_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jason_stream_player/data/storage.dart';
import 'package:jason_stream_player/models/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

const portal = Portal(
  id: 'p1',
  name: 'Mein Anbieter',
  type: PortalType.xtream,
  url: 'http://srv.example:8080',
  username: 'jason77',
  password: 'Geheim!123',
);

Future<String> allPlainPrefs() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getKeys().map((k) => '$k=${prefs.get(k)}').join('\n');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('Zugangsdaten landen NICHT in den normalen Einstellungen', () async {
    final s = await Storage.open(store: PreviewSecretStore());
    await s.addPortal(portal);
    final plain = await allPlainPrefs();
    expect(plain, contains('Mein Anbieter')); // Name darf sichtbar sein
    expect(plain, isNot(contains('Geheim!123')));
    expect(plain, isNot(contains('jason77')));
    expect(plain, isNot(contains('srv.example')));
  });

  test('…aber die App kann sie wieder lesen (verschlüsselter Speicher)', () async {
    final s = await Storage.open(store: PreviewSecretStore());
    await s.addPortal(portal);
    final again = await Storage.open(store: PreviewSecretStore());
    final p = again.portals().single;
    expect(p.password, 'Geheim!123');
    expect(p.username, 'jason77');
    expect(p.url, 'http://srv.example:8080');
  });

  test('Alte Klartext-Daten werden beim Start verschlüsselt umgezogen', () async {
    SharedPreferences.setMockInitialValues({
      'portals': jsonEncode([portal.toJson()]),
      'parental_pin': '4711',
    });
    final s = await Storage.open(store: PreviewSecretStore());
    final plain = await allPlainPrefs();
    expect(plain, isNot(contains('Geheim!123')));
    expect(plain, isNot(contains('4711')));
    expect(s.portals().single.password, 'Geheim!123');
    expect((await s.verifyPin('4711')).ok, isTrue);
  });

  test('Portal löschen entfernt auch die Zugangsdaten', () async {
    final s = await Storage.open(store: PreviewSecretStore());
    await s.addPortal(portal);
    await s.removePortal('p1');
    expect((await Storage.open(store: PreviewSecretStore())).portals(), isEmpty);
  });

  test('PIN: nach 5 Fehlversuchen gesperrt, richtige PIN dann auch gesperrt',
      () async {
    final s = await Storage.open(store: PreviewSecretStore());
    await s.setPin('2580');
    for (var i = 0; i < 4; i++) {
      final r = await s.verifyPin('0000');
      expect(r.ok, isFalse);
      expect(r.lockedFor, isNull);
    }
    final fifth = await s.verifyPin('0000');
    expect(fifth.lockedFor, isNotNull);
    expect((await s.verifyPin('2580')).ok, isFalse); // noch gesperrt
  });

  test('Alles löschen entfernt Portale und PIN', () async {
    final s = await Storage.open(store: PreviewSecretStore());
    await s.addPortal(portal);
    await s.setPin('1234');
    await s.wipeCredentials();
    final again = await Storage.open(store: PreviewSecretStore());
    expect(again.portals(), isEmpty);
    expect(again.hasPin(), isFalse);
  });

  test('Standort-Vermerk: setzen, lesen, wieder entfernen', () async {
    final s = await Storage.open(store: PreviewSecretStore());
    await s.markUnavailable('p1', 'ch7');
    expect(s.unavailable('p1'), {'ch7'});
    await s.markUnavailable('p1', 'ch7', on: false);
    expect(s.unavailable('p1'), isEmpty);
  });

  test('Standort-Vermerk läuft nach 24 Stunden ab', () async {
    final old = DateTime.now()
        .subtract(const Duration(hours: 25))
        .millisecondsSinceEpoch;
    SharedPreferences.setMockInitialValues({
      'unavail_p1': ['ch1|$old', 'ch2|${DateTime.now().millisecondsSinceEpoch}'],
    });
    final s = await Storage.open(store: PreviewSecretStore());
    expect(s.unavailable('p1'), {'ch2'});
  });

  test('Kaputter Schlüsselspeicher: App startet trotzdem (kein Hängen)',
      () async {
    final s = await Storage.open(store: PreviewSecretStore());
    await s.addPortal(portal);
    final broken = await Storage.open(store: _BrokenStore())
        .timeout(const Duration(seconds: 2));
    expect(broken.portals(), isEmpty); // neu anmelden statt hängen
    expect(broken.unreadableSecrets, greaterThan(0));
  });

  test('Gespeichert wird nur Chiffretext', () async {
    final s = await Storage.open(store: PreviewSecretStore());
    await s.addPortal(portal);
    final prefs = await SharedPreferences.getInstance();
    final secKeys = prefs.getKeys().where((k) => k.startsWith('sec_'));
    expect(secKeys, isNotEmpty);
    for (final k in secKeys) {
      expect(prefs.getString(k), startsWith('p1:'));
    }
  });
}

class _BrokenStore implements SecretStore {
  @override
  Future<String> encrypt(String plain) async =>
      throw SecretStoreException('kaputt');
  @override
  Future<String> decrypt(String cipher) async =>
      throw SecretStoreException('kaputt');
}
