import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jason_stream_player/core/remote/content_ref.dart';
import 'package:jason_stream_player/core/remote/crypto.dart';
import 'package:jason_stream_player/core/remote/keys.dart';
import 'package:jason_stream_player/core/remote/lan.dart';
import 'package:jason_stream_player/core/remote/pairing.dart';
import 'package:jason_stream_player/core/remote/peers.dart';
import 'package:jason_stream_player/core/remote/protocol.dart';
import 'package:jason_stream_player/models/models.dart';

/// 2.4 Handy als Fernbedienung – Kern: Krypto, Koppeln, Sperre, Protokoll,
/// Tasten, Inhalts-Kennung, Netzprüfung.
void main() {
  Uint8List hex(String s) => Uint8List.fromList([
        for (var i = 0; i < s.length; i += 2)
          int.parse(s.substring(i, i + 2), radix: 16)
      ]);

  group('Krypto', () {
    test('HKDF-SHA256 = RFC 5869 Testfall 1', () {
      final okm = RemoteCrypto.hkdf(hex('0b' * 22),
          salt: hex('000102030405060708090a0b0c'),
          info: hex('f0f1f2f3f4f5f6f7f8f9'),
          length: 42);
      expect(
          okm,
          hex('3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf'
              '34007208d5b887185865'));
    });

    test('Rahmen: Hin und zurück, Manipulation, Wiederholung, Reihenfolge',
        () async {
      final k = RemoteCrypto.random(32);
      final tx = FrameCipher(k), rx = FrameCipher(k);
      final f1 = await tx.seal(utf8.encode('eins'));
      final f2 = await tx.seal(utf8.encode('zwei'));
      final f3 = await tx.seal(utf8.encode('drei'));
      expect(utf8.decode(await rx.open(f1)), 'eins');
      // Wiederholung desselben Rahmens.
      await expectLater(rx.open(f1),
          throwsA(isA<FrameRejected>().having((e) => e.reason, 'r', 'replay')));
      // Überspringen ist erlaubt (verlorene Nachricht), zurück nie.
      expect(utf8.decode(await rx.open(f3)), 'drei');
      await expectLater(rx.open(f2), throwsA(isA<FrameRejected>()));
      // Manipuliertes Byte.
      final f4 = await tx.seal(utf8.encode('vier'));
      final bad = Uint8List.fromList(f4)..[10] ^= 1;
      await expectLater(rx.open(bad),
          throwsA(isA<FrameRejected>().having((e) => e.reason, 'r', 'auth')));
      // Manipulierter Zähler (gehört zu den authentisierten Daten).
      final moved = Uint8List.fromList(f4)..[7] ^= 0x20;
      await expectLater(rx.open(moved), throwsA(isA<FrameRejected>()));
      expect(utf8.decode(await rx.open(f4)), 'vier');
      // Falscher Schlüssel.
      final other = FrameCipher(RemoteCrypto.random(32));
      await expectLater(other.open(await tx.seal([1])),
          throwsA(isA<FrameRejected>()));
      // Zu kurz.
      await expectLater(rx.open([1, 2, 3]), throwsA(isA<FrameRejected>()));
    });

    test('Sitzungsschlüssel: je Richtung und Verbindung verschieden', () {
      final k = RemoteCrypto.random(32);
      final a = RemoteCrypto.sessionKeys(k, List.filled(16, 1), List.filled(16, 2));
      final b = RemoteCrypto.sessionKeys(k, List.filled(16, 1), List.filled(16, 3));
      expect(a.toTv, isNot(a.toPhone));
      expect(a.toTv, isNot(b.toTv));
      expect(RemoteCrypto.sessionKeys(k, List.filled(16, 1), List.filled(16, 2)).toTv, a.toTv);
    });

    test('Kanal: Frame aus einer alten Verbindung passt nie wieder', () async {
      final k = RemoteCrypto.random(32);
      final old = RemoteCrypto.sessionKeys(k, List.filled(16, 1), List.filled(16, 2));
      final now = RemoteCrypto.sessionKeys(k, List.filled(16, 1), List.filled(16, 9));
      final sender = SecureChannel(sendKey: old.toTv, receiveKey: old.toPhone);
      final tv = SecureChannel(sendKey: now.toPhone, receiveKey: now.toTv);
      final frame = await sender.encode({'t': 'key', 'k': 'ok', 'a': 'tap'});
      await expectLater(tv.decode(frame), throwsA(isA<FrameRejected>()));
    });

    test('X25519: beide Seiten gleiches Geheimnis, kaputter Schlüssel abgelehnt',
        () async {
      final a = await RemoteCrypto.newKeyPair();
      final b = await RemoteCrypto.newKeyPair();
      expect(await RemoteCrypto.shared(a, b.publicKey),
          await RemoteCrypto.shared(b, a.publicKey));
      await expectLater(RemoteCrypto.shared(a, [1, 2]),
          throwsA(isA<RemoteCryptoException>()));
      await expectLater(RemoteCrypto.shared(a, List.filled(32, 0)),
          throwsA(isA<RemoteCryptoException>()));
    });
  });

  group('Koppeln mit Code', () {
    Future<(TvPairing, PhonePairing)> setup(String tvCode) async {
      final phone = await PhonePairing.start(tvId: 'tv1', deviceId: 'ph1');
      final tv = await TvPairing.start(
          tvId: 'tv1', deviceId: 'ph1', phonePub: phone.phonePub, code: tvCode);
      await phone.setTvKey(tv.tvPub);
      return (tv, phone);
    }

    Future<void> rounds(TvPairing tv, PhonePairing phone) async {
      for (var i = 0; i < 4; i++) {
        phone.onTvCommit(i, tv.onPhoneCommit(i, phone.commit()));
        phone.onTvReveal(i, tv.onPhoneReveal(i, phone.reveal()));
      }
    }

    test('richtiger Code → gleicher Geräteschlüssel, Bestätigung beidseitig',
        () async {
      final (tv, phone) = await setup('0427');
      phone.setCode('0427');
      await rounds(tv, phone);
      expect(phone.deviceKey, tv.deviceKey);
      phone.onTvConfirm(tv.onPhoneConfirm(phone.confirm()));
    });

    test('falscher Code: Fernseher bricht bei der falschen Ziffer ab', () async {
      final (tv, phone) = await setup('1234');
      phone.setCode('1294'); // dritte Ziffer falsch
      phone.onTvCommit(0, tv.onPhoneCommit(0, phone.commit()));
      phone.onTvReveal(0, tv.onPhoneReveal(0, phone.reveal()));
      phone.onTvCommit(1, tv.onPhoneCommit(1, phone.commit()));
      phone.onTvReveal(1, tv.onPhoneReveal(1, phone.reveal()));
      phone.onTvCommit(2, tv.onPhoneCommit(2, phone.commit()));
      expect(() => tv.onPhoneReveal(2, phone.reveal()),
          throwsA(isA<PairingFailed>().having((e) => e.wrongCode, 'code', true)));
      expect(() => tv.deviceKey, throwsStateError);
    });

    test('Mittelsmann ohne Code: Handy erkennt die falsche Ziffer', () async {
      // Das Handy spricht mit einem Angreifer, der sich als Fernseher
      // ausgibt und den Code nicht kennt (rät „0000“).
      final phone = await PhonePairing.start(tvId: 'tv1', deviceId: 'ph1');
      final fake = await TvPairing.start(
          tvId: 'tv1', deviceId: 'ph1', phonePub: phone.phonePub, code: '0000');
      await phone.setTvKey(fake.tvPub);
      phone.setCode('5000');
      phone.onTvCommit(0, fake.onPhoneCommit(0, phone.commit()));
      // Der Angreifer kann seinen Commit nicht mehr ändern: sein Reveal
      // passt nicht zur Ziffer 5 → Handy bricht ab, bevor der Angreifer
      // eine weitere Ziffer erfährt.
      final r = phone.reveal();
      expect(() => fake.onPhoneReveal(0, r), throwsA(isA<PairingFailed>()));
    });

    test('vertauschte Schlüssel (Mittelsmann) fallen in Runde 0 auf', () async {
      final phone = await PhonePairing.start(tvId: 'tv1', deviceId: 'ph1');
      final mitm = await RemoteCrypto.newKeyPair();
      // Fernseher sieht den Schlüssel des Angreifers statt des Handys.
      final tv = await TvPairing.start(
          tvId: 'tv1', deviceId: 'ph1', phonePub: mitm.publicKey, code: '1111');
      await phone.setTvKey(tv.tvPub);
      phone.setCode('1111');
      // Commit des Handys (über pubP) weitergereicht → TV prüft mit pubM.
      phone.onTvCommit(0, tv.onPhoneCommit(0, phone.commit()));
      expect(() => tv.onPhoneReveal(0, phone.reveal()),
          throwsA(isA<PairingFailed>()));
    });

    test('Ablauf-Fehler: falsche Runde, doppelter Commit', () async {
      final (tv, phone) = await setup('1111');
      phone.setCode('1111');
      expect(() => tv.onPhoneCommit(1, phone.commit()),
          throwsA(isA<PairingFailed>()));
      tv.onPhoneCommit(0, phone.commit());
      expect(() => tv.onPhoneCommit(0, RemoteCrypto.random(32)),
          throwsA(isA<PairingFailed>()));
      expect(() => phone.setCode('12a4'), throwsA(isA<PairingFailed>()));
    });

    test('Code: 4 Ziffern, zufällig', () {
      final codes = {for (var i = 0; i < 50; i++) PairingMath.newCode()};
      expect(codes.every(PairingMath.validCode), isTrue);
      expect(codes.length, greaterThan(30));
    });
  });

  group('Fehlversuch-Sperre', () {
    test('nach 3 Fehlern gesperrt, Sperre verdoppelt sich, Erfolg setzt zurück',
        () {
      var now = DateTime(2026, 10, 27, 20);
      withClock(Clock(() => now), () {
        final g = FailureGate();
        g.fail('pair');
        g.fail('pair');
        expect(g.allowed('pair'), isTrue);
        g.fail('pair');
        expect(g.lockedFor('pair'), const Duration(minutes: 1));
        expect(g.allowed('other'), isTrue);
        now = now.add(const Duration(seconds: 61));
        expect(g.allowed('pair'), isTrue);
        for (var i = 0; i < 3; i++) {
          g.fail('pair');
        }
        expect(g.lockedFor('pair'), const Duration(minutes: 2));
        now = now.add(const Duration(minutes: 3));
        for (var n = 0; n < 6; n++) {
          for (var i = 0; i < 3; i++) {
            g.fail('pair');
          }
          now = now.add(const Duration(hours: 1));
        }
        for (var i = 0; i < 3; i++) {
          g.fail('pair');
        }
        expect(g.lockedFor('pair'), const Duration(minutes: 15)); // Obergrenze
        g.success('pair');
        expect(g.allowed('pair'), isTrue);
      });
    });
  });

  group('Protokoll', () {
    test('Tasten: Leitungsnamen eindeutig und umkehrbar', () {
      final wires = RemoteKey.values.map((k) => k.wire).toSet();
      expect(wires.length, RemoteKey.values.length);
      for (final k in RemoteKey.values) {
        expect(RemoteKey.fromWire(k.wire), k);
      }
      expect(RemoteKey.fromWire('rm -rf'), isNull);
      expect(RemoteKey.fromWire(3), isNull);
      expect(KeyAction.fromWire('down'), KeyAction.down);
      expect(KeyAction.fromWire('x'), isNull);
    });

    test('Status hin und zurück', () {
      const s = RemoteStatus(
          kind: 'live',
          title: 'ZDF HD',
          channelId: 'c2',
          channelNumber: 2,
          programme: 'heute',
          playing: true,
          position: 3,
          duration: 0);
      final back = RemoteStatus.fromJson(
          jsonDecode(jsonEncode(s.toJson())) as Map<String, Object?>);
      expect(back, s);
      expect(RemoteStatus.fromJson({'kind': 'evil'}).kind, 'none');
    });

    test('Textfeld: verdeckter Inhalt geht nie über das Netz', () {
      const t = RemoteTextState(focus: true, text: 'geheim', obscure: true);
      expect(jsonEncode(t.toJson()), isNot(contains('geheim')));
      const s = RemoteTextState(focus: true, text: 'tagess', hint: 'Suche');
      expect(RemoteTextState.fromJson(s.toJson()), s);
    });

    test('Sender: Logo nur ohne Zugangsdaten', () {
      expect(isSafeLogoUrl('https://logo.example/zdf.png'), isTrue);
      expect(isSafeLogoUrl('http://u:p@host/x.png'), isFalse);
      expect(isSafeLogoUrl('http://host/x.png?token=abc'), isFalse);
      expect(isSafeLogoUrl('http://host/user123/pw/x.png',
          secrets: ['user123', 'pw']), isFalse);
      expect(isSafeLogoUrl('file:///etc/passwd'), isFalse);
      final c = RemoteChannel.fromJson({
        'id': 'c1',
        'name': 'Das Erste',
        'logo': 'http://h/x.png?u=1',
        'now': {'title': 'Tagesschau', 's': 100, 'e': 1000},
      })!;
      expect(c.logo, isNull);
      expect(c.now!.title, 'Tagesschau');
      expect(RemoteChannel.fromJson({'id': 3}), isNull);
    });

    test('Lesehilfen lehnen falsche Typen und Überlängen ab', () {
      expect(Wire.str({'a': 'x' * 600}, 'a'), isNull);
      expect(Wire.str({'a': 5}, 'a'), isNull);
      expect(Wire.integer({'a': -1}, 'a'), isNull);
      expect(Wire.integer({'a': '5'}, 'a'), isNull);
    });
  });

  group('Inhalts-Kennung', () {
    const tvPortal = Portal(
        id: 'tv-uuid',
        name: 'Mein Anbieter',
        type: PortalType.xtream,
        url: 'HTTP://Example.com:80/',
        username: 'max',
        password: 'geheim');
    const phonePortal = Portal(
        id: 'phone-uuid',
        name: 'Anbieter (Handy)',
        type: PortalType.xtream,
        url: 'http://example.com',
        username: 'max',
        password: 'geheim');

    test('gleiches Konto auf zwei Geräten → gleicher Fingerabdruck', () {
      expect(portalFingerprints(tvPortal), portalFingerprints(phonePortal));
      const other = Portal(
          id: 'x',
          name: 'x',
          type: PortalType.xtream,
          url: 'http://example.com',
          username: 'moritz',
          password: 'geheim');
      expect(portalFingerprints(other), isNot(portalFingerprints(phonePortal)));
    });

    test('Ersatzadresse genügt', () {
      const a = Portal(
          id: 'a',
          name: 'a',
          type: PortalType.xtream,
          url: 'http://mirror.example.net:8080',
          altUrls: ['http://example.com'],
          username: 'max');
      final ref = ContentRef(
          source: 'portal',
          scope: portalFingerprints(phonePortal),
          kind: ContentKind.live,
          id: '17');
      expect(matchPortal(ref, [a], a), PortalMatch.active);
    });

    test('Zuordnung: aktiv, eingerichtet aber inaktiv, fehlt', () {
      final ref = ContentRef(
          source: 'portal',
          scope: portalFingerprints(phonePortal),
          kind: ContentKind.movie,
          id: '99',
          position: 600);
      const demo = Portal.demo;
      expect(matchPortal(ref, [tvPortal], tvPortal), PortalMatch.active);
      expect(matchPortal(ref, [demo, tvPortal], demo), PortalMatch.inactive);
      expect(matchPortal(ref, [demo], demo), PortalMatch.none);
    });

    test('Übertragung enthält weder Adresse noch Zugangsdaten', () {
      final ref = ContentRef(
          source: 'portal',
          scope: portalFingerprints(tvPortal),
          kind: ContentKind.episode,
          id: 'e5',
          seriesId: 's1',
          position: 1234,
          title: 'Folge 5');
      final wire = jsonEncode(ref.toJson());
      for (final s in ['example', 'max', 'geheim', 'http']) {
        expect(wire, isNot(contains(s)));
      }
      final back = ContentRef.fromJson(
          jsonDecode(wire) as Map<String, Object?>)!;
      expect(back.kind, ContentKind.episode);
      expect(back.seriesId, 's1');
      expect(back.position, 1234);
      expect(back.scope, ref.scope);
    });

    test('ungültige Kennungen abgelehnt', () {
      expect(ContentRef.fromJson({'src': 'x', 'scope': ['a'], 'kind': 'live', 'id': '1'}),
          isNull);
      expect(ContentRef.fromJson({'src': 'portal', 'scope': [], 'kind': 'live', 'id': '1'}),
          isNull);
      expect(ContentRef.fromJson({'src': 'emby', 'scope': ['a'], 'kind': 'live', 'id': '1'}),
          isNull);
      expect(ContentRef.fromJson({'src': 'emby', 'scope': ['a'], 'kind': 'movie', 'id': '1'})!
          .isEmby, isTrue);
      expect(embyFingerprint('ABC'), embyFingerprint('abc'));
    });
  });

  group('Netz', () {
    InternetAddress a(String s) => InternetAddress(s);
    test('nur private Adressen', () {
      for (final s in ['10.0.0.5', '172.16.1.1', '172.31.255.1', '192.168.178.20',
          '169.254.3.4', 'fe80::1', 'fd12::3', '::ffff:192.168.1.2']) {
        expect(isPrivateLan(a(s)), isTrue, reason: s);
      }
      for (final s in ['8.8.8.8', '172.32.0.1', '100.64.0.1', '127.0.0.1',
          '2001:db8::1', '::ffff:8.8.8.8', '0.0.0.0']) {
        expect(isPrivateLan(a(s)), isFalse, reason: s);
      }
      expect(isAllowedPeer(a('127.0.0.1'), loopbackServer: false), isFalse);
      expect(isAllowedPeer(a('127.0.0.1'), loopbackServer: true), isTrue);
      expect(isAllowedPeer(a('93.184.216.34'), loopbackServer: true), isFalse);
    });

    test('Adresswahl: WLAN vor Link-Local, nie öffentlich', () {
      expect(pickPrivateLanAddress([a('8.8.8.8')]), isNull);
      expect(
          pickPrivateLanAddress(
                  [a('169.254.1.1'), a('8.8.8.8'), a('192.168.0.9')])!
              .address,
          '192.168.0.9');
    });
  });

  group('Gekoppelte Geräte', () {
    test('Liste hin und zurück, Schlüssel nicht im toString', () {
      final p = RemotePeer(
          id: 'id1',
          name: 'Pixel',
          key: RemoteCrypto.random(32),
          pairedAt: DateTime(2026),
          host: '192.168.0.2',
          port: 4711);
      final list = RemotePeer.decodeList(RemotePeer.encodeList([p]));
      expect(list.single.key, p.key);
      expect(list.single.port, 4711);
      expect(p.toString(), isNot(contains(RemoteCrypto.b64(p.key))));
      expect(RemotePeer.decodeList('kaputt'), isEmpty);
      expect(RemotePeer.decodeList('[{"id":"x","name":"y","key":"zu-kurz"}]'),
          isEmpty);
    });
  });

  group('Tasten → KeyEvents', () {
    final events = <KeyEvent>[];
    var backs = 0;
    KeyInjector make({bool handled = true}) => KeyInjector(
          dispatch: (e) {
            events.add(e);
            return handled;
          },
          onUnhandledBack: () => backs++,
        );
    setUp(() {
      events.clear();
      backs = 0;
    });

    String desc(KeyEvent e) =>
        '${e.runtimeType.toString().replaceAll('Event', '')}:${e.logicalKey.keyLabel}';

    test('kurz drücken = Down + Up mit der Fernbedienungs-Taste', () {
      final k = make();
      k.tap(RemoteKey.ok);
      k.tap(RemoteKey.channelUp);
      k.tap(RemoteKey.red);
      k.tap(RemoteKey.digit7);
      expect(events.map((e) => e.logicalKey), [
        LogicalKeyboardKey.select, LogicalKeyboardKey.select,
        LogicalKeyboardKey.channelUp, LogicalKeyboardKey.channelUp,
        LogicalKeyboardKey.colorF0Red, LogicalKeyboardKey.colorF0Red,
        LogicalKeyboardKey.digit7, LogicalKeyboardKey.digit7,
      ]);
      expect(events.first, isA<KeyDownEvent>());
      expect(events[1], isA<KeyUpEvent>());
      expect(events[0].physicalKey, events[1].physicalKey);
    });

    test('jede Taste hat eine Abbildung, Lautstärke/Home nie als Taste', () {
      for (final k in RemoteKey.values) {
        expect(remoteKeyMap[k], isNotNull, reason: k.name);
      }
      final k = make();
      k.tap(RemoteKey.volumeUp);
      k.tap(RemoteKey.home);
      expect(events, isEmpty);
    });

    test('halten: Wiederholung nach 500 ms alle 50 ms, Loslassen beendet', () {
      fakeAsync((fa) {
        final k = make();
        k.down(RemoteKey.down);
        fa.elapse(const Duration(milliseconds: 499));
        expect(events.map(desc), ['KeyDown:Arrow Down']);
        fa.elapse(const Duration(milliseconds: 1 + 200));
        expect(events.whereType<KeyRepeatEvent>().length, 4);
        k.up(RemoteKey.down);
        final n = events.length;
        fa.elapse(const Duration(seconds: 1));
        expect(events.length, n);
        expect(events.last, isA<KeyUpEvent>());
        expect(k.held, isEmpty);
      });
    });

    test('ohne Loslassen endet das Halten spätestens nach 15 s', () {
      fakeAsync((fa) {
        final k = make();
        k.down(RemoteKey.right);
        fa.elapse(const Duration(seconds: 16));
        expect(events.last, isA<KeyUpEvent>());
        expect(k.held, isEmpty);
      });
    });

    test('doppeltes Down zählt einmal, releaseAll lässt alles los', () {
      fakeAsync((fa) {
        final k = make();
        k.down(RemoteKey.left);
        k.down(RemoteKey.left);
        k.down(RemoteKey.up);
        expect(events.whereType<KeyDownEvent>().length, 2);
        k.releaseAll();
        expect(events.whereType<KeyUpEvent>().length, 2);
        fa.elapse(const Duration(seconds: 2));
        expect(events.whereType<KeyRepeatEvent>(), isEmpty);
      });
    });

    test('Zurück ohne Abnehmer → System-Zurück (wie Android)', () {
      make(handled: false).tap(RemoteKey.back);
      expect(backs, 1);
      make().tap(RemoteKey.back);
      expect(backs, 1);
    });
  });
}
