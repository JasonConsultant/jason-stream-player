import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:jason_stream_player/core/remote/content_ref.dart';
import 'package:jason_stream_player/core/remote/crypto.dart';
import 'package:jason_stream_player/core/remote/net.dart';
import 'package:jason_stream_player/core/remote/nsd.dart';
import 'package:jason_stream_player/core/remote/peers.dart';
import 'package:jason_stream_player/core/remote/protocol.dart';
import 'package:jason_stream_player/core/remote/transport.dart';
import 'package:jason_stream_player/core/secret_store.dart';
import 'package:jason_stream_player/core/theme.dart';
import 'package:jason_stream_player/data/storage.dart';
import 'package:jason_stream_player/l10n/strings.dart';
import 'package:jason_stream_player/models/models.dart';
import 'package:jason_stream_player/state/providers.dart';
import 'package:jason_stream_player/state/remote.dart';
import 'package:jason_stream_player/state/remote_link.dart';
import 'package:jason_stream_player/ui/remote/play_on_tv.dart';
import 'package:jason_stream_player/ui/remote/remote_screen.dart';
import 'package:jason_stream_player/ui/vod/movie_detail_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/app_fonts.dart';
import 'helpers/tv_harness.dart';

/// 2.4 Handy-Seite: Koppeln, Tasten/Touchpad, Texteingabe, Senderliste,
/// Status, Neuverbinden, „TV nicht gefunden“, „Auf dem TV abspielen“.
/// Bildschirmfotos nur mit `TV_SHOTS=ordner`.

/// Fernseher-Gegenstück (echter Server, einfache Antworten).
class TvHost implements RemoteTvHost {
  final phones = <String, RemotePeer>{};
  final got = <Map<String, Object?>>[];
  String? code;
  bool volumeCap = true;
  String? playErr;

  @override
  String get tvId => 'tv-wz';
  @override
  String get tvName => 'Wohnzimmer-TV';
  @override
  Map<String, Object?> get caps => {'volume': volumeCap};
  @override
  RemotePeer? phone(String id) => phones[id];
  @override
  Future<void> addPhone(RemotePeer p) async => phones[p.id] = p;
  @override
  void showPairingCode(String c, String n) => code = c;
  @override
  void hidePairingCode({bool paired = false, String? phoneName}) => code = null;
  @override
  void connected(String id) {}
  @override
  void disconnected(String id) {}

  static final _t0 = DateTime(2026, 10, 27, 20, 0);
  RemoteChannel _ch(int i) => RemoteChannel(
        id: 'c$i',
        name: ['Das Erste HD', 'ZDF HD', 'RTL HD', 'arte HD', 'ProSieben',
            'Sat.1', 'VOX', 'kabel eins', 'tagesschau24', 'phoenix'][i % 10],
        number: i + 1,
        now: RemoteProgramme(
            ['Tagesschau', 'heute journal', 'Wer wird Millionär?',
                'Doku: Alpen', 'Galileo', 'Lenßen', 'Die Höhle der Löwen',
                'Navy CIS', 'Nachrichten', 'Phoenix Runde'][i % 10],
            _t0.subtract(Duration(minutes: 10 + i)),
            _t0.add(Duration(minutes: 20 + i * 3))),
        next: RemoteProgramme(
            ['Tatort', 'Markus Lanz', 'Stern TV', 'Kultur', 'Joko & Klaas',
                'Krimi', 'Kitchen Impossible', 'Hawaii Five-0', 'Wetter',
                'Dokumentation'][i % 10],
            _t0.add(Duration(minutes: 20 + i * 3)),
            _t0.add(Duration(minutes: 90 + i * 3))),
        locked: i == 7,
      );

  @override
  Future<Map<String, Object?>?> handle(
      String id, Map<String, Object?> m) async {
    got.add(m);
    if (m['t'] != 'req') return null;
    switch (m['m']) {
      case 'groups':
        return {
          'total': 120,
          'groups': [
            const RemoteGroup('fav', 'Favoriten', 4).toJson(),
            const RemoteGroup('de', 'Deutschland', 20).toJson(),
            const RemoteGroup('news', 'Nachrichten', 4).toJson(),
          ],
        };
      case 'channels':
        final o = m['o'] as int, n = m['n'] as int;
        return {
          'total': 120,
          'items': [
            for (var i = o; i < 120 && i < o + n; i++) _ch(i).toJson()
          ],
        };
      case 'tune':
        return {'ok': true};
      case 'play':
        return playErr == null ? {'ok': true} : {'err': playErr};
    }
    return {'err': RemoteError.bad};
  }
}

class FakeDiscovery implements RemoteDiscovery {
  final found = <FoundTv>[];
  final _c = StreamController<FoundTv>.broadcast();
  int searches = 0;
  @override
  Future<String?> register(
          {required String name,
          required int port,
          required Map<String, String> attrs}) async =>
      name;
  @override
  Future<void> unregister() async {}
  @override
  Stream<FoundTv> discover() {
    searches++;
    Timer.run(() {
      for (final f in found) {
        _c.add(f);
      }
    });
    return _c.stream;
  }

  @override
  Stream<String> get lost => const Stream.empty();
  @override
  Future<void> stopDiscover() async {}
  @override
  Future<bool> volume(int dir) async => false;
  @override
  Future<bool> volumeControllable() async => false;
}

const _quiet = [
  MethodChannel('de.jasonstream/network'),
  MethodChannel('de.jasonstream/network/events'),
  MethodChannel('de.jasonstream/cast/events'),
  MethodChannel('de.jasonstream.player/platform'),
];

const _portal = Portal(
    id: 'ph',
    name: 'Anbieter',
    type: PortalType.xtream,
    url: 'http://iptv.example:8080',
    username: 'max',
    password: 'geheim');

final _shotDir = Platform.environment['TV_SHOTS'];

void main() {
  late Storage storage;
  late TvHost host;
  late FakeDiscovery disco;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    L10n.lang = 'de';
    await initializeDateFormatting('de');
    await loadAppFonts();
    if (_shotDir != null) Directory(_shotDir!).createSync(recursive: true);
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    storage = await Storage.open(store: PreviewSecretStore());
    host = TvHost();
    disco = FakeDiscovery();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (c) async => null);
    for (final ch in _quiet) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ch, (c) async => null);
    }
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    for (final ch in _quiet) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ch, null);
    }
  });

  Future<T> net<T>(WidgetTester tester, Future<T> Function() f) async {
    late Future<T> fut;
    var finished = false;
    await tester.runAsync(() async {
      fut = f();
      fut.then((_) => finished = true, onError: (Object _) => finished = true);
    });
    for (var i = 0; i < 600 && !finished; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)));
    }
    expect(finished, isTrue, reason: 'Netzaufruf hängt');
    late T r;
    await tester.runAsync(() async => r = await fut);
    await tester.pump();
    return r;
  }

  Future<void> settle(WidgetTester tester, [int n = 6]) async {
    for (var i = 0; i < n; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  /// Warten, bis [cond] gilt (echte Sockets + Test-Zeit).
  Future<void> until(WidgetTester tester, bool Function() cond,
      {int max = 150}) async {
    for (var i = 0; i < max && !cond(); i++) {
      await settle(tester, 1);
    }
    expect(cond(), isTrue,
        reason: StackTrace.current.toString().split('\n').take(3).join(' | '));
  }

  Future<RemoteServerHandle> startServer(WidgetTester tester) async {
    final s = await net(
        tester,
        () => Zone.root.run(() => startRemoteServer(host,
            bindAddress: InternetAddress.loopbackIPv4, preferredPort: 0)));
    addTearDown(() async {
      await tester.runAsync(() => s.close());
    });
    return s;
  }

  ProviderContainer container(WidgetTester tester) =>
      ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));

  Future<void> pumpPhone(WidgetTester tester, Widget home,
      {List<Override> extra = const []}) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        ...tvOverrides(
            TvData(
                live: const LiveData([], []),
                portal: _portal,
                movies: const VodData([], [])),
            Future.value(storage),
            tv: false),
        remoteDiscoveryProvider.overrideWithValue(disco),
        // Echte Sockets in der Wurzel-Zone; Ergebnis/Fehler zurück in die
        // Test-Zone (Fehler überqueren sonst keine Fehler-Zonen-Grenze).
        remoteConnectorProvider.overrideWithValue((h, p) {
          final c = Completer<RemoteConnection>();
          Zone.root.run(() => connectRemote(h, p, allowLoopback: true)
              .then(c.complete, onError: c.completeError));
          return c.future;
        }),
        remoteDeviceNameProvider.overrideWith((ref) async => 'Pixel 9'),
        ...extra,
      ],
      child: RepaintBoundary(
        key: tvShotKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(tv: false),
          home: home,
        ),
      ),
    ));
    await settle(tester, 3);
  }

  /// Gekoppelten Fernseher direkt anlegen (Schlüssel auf beiden Seiten).
  Future<RemotePeer> preparePaired(RemoteServerHandle s,
      {int? port}) async {
    final key = RemoteCrypto.random(32);
    final me = await storage.remoteSelfId();
    host.phones[me] = RemotePeer(
        id: me, name: 'Pixel 9', key: key, pairedAt: DateTime(2026));
    final tv = RemotePeer(
        id: 'tv-wz',
        name: 'Wohnzimmer-TV',
        key: key,
        pairedAt: DateTime(2026),
        host: '127.0.0.1',
        port: port ?? s.port);
    await storage.setRemotePeers([tv], tv: false);
    return tv;
  }

  Future<void> shot(WidgetTester tester, String name) =>
      writeShot(tester, tvShotKey, name);

  Future<void> done(WidgetTester tester) async {
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await settle(tester, 3);
  }

  testWidgets('Koppeln: TV im WLAN finden, Code eingeben, danach Fernbedienung',
      (tester) async {
    final s = await startServer(tester);
    disco.found.add(FoundTv(
        name: 'Wohnzimmer-TV', host: '127.0.0.1', port: s.port, id: 'tv-wz'));
    disco.found.add(const FoundTv(
        name: 'Schlafzimmer', host: '192.168.178.77', port: 47231, id: 'x'));
    await pumpPhone(tester, const RemoteScreen());
    await until(tester,
        () => find.text('Wohnzimmer-TV').evaluate().isNotEmpty);
    await shot(tester, 'phone_remote_pair_list');
    await tester.tap(find.byKey(const ValueKey('remote-found-Wohnzimmer-TV')));
    await until(tester, () => host.code != null);
    expect(find.byKey(const ValueKey('remote-pair-dialog')), findsOneWidget);
    await shot(tester, 'phone_remote_pair_code');
    // Falscher Code → neuer Versuch mit neuem Code am Fernseher.
    final first = host.code!;
    final wrong = first == '1111' ? '2222' : '1111';
    await tester.enterText(
        find.byKey(const ValueKey('remote-pair-code-field')), wrong);
    await until(tester,
        () => host.code != null && find.byKey(const ValueKey('remote-pair-error')).evaluate().isNotEmpty && find.byType(LinearProgressIndicator).evaluate().isEmpty);
    expect(host.phones, isEmpty);
    await tester.enterText(
        find.byKey(const ValueKey('remote-pair-code-field')), host.code!);
    await until(tester,
        () => find.byKey(const ValueKey('remote-dpad')).evaluate().isNotEmpty);
    expect(host.phones.values.single.name, 'Pixel 9');
    final saved = storage.remotePeers(tv: false).single;
    expect(saved.id, 'tv-wz');
    expect(saved.key, host.phones.values.single.key);
    await until(tester, () => container(tester).read(remoteLinkProvider).connected);
    await done(tester);
  });

  testWidgets('Tasten: Drücken/Halten, Touchpad, Lautstärke, Status oben',
      (tester) async {
    final s = await startServer(tester);
    await preparePaired(s);
    await pumpPhone(tester, const RemoteScreen());
    await until(tester, () => container(tester).read(remoteLinkProvider).connected);
    await s.broadcast(const RemoteStatus(
            kind: 'live',
            title: 'ZDF HD',
            channelId: 'c1',
            channelNumber: 2,
            programme: 'heute journal',
            playing: true)
        .toJson());
    await until(tester, () => find.text('heute journal').evaluate().isNotEmpty);
    await shot(tester, 'phone_remote_keys');

    host.got.clear();
    await tester.tap(find.byKey(const ValueKey('rk-right')));
    await until(tester, () => host.got.length >= 2);
    expect(host.got.map((m) => '${m['k']}:${m['a']}'), ['right:down', 'right:up']);

    // Halten: Down, nach einer Weile Up (Wiederholung macht der Fernseher).
    host.got.clear();
    final g = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('rk-down'))));
    await settle(tester, 4);
    expect(host.got.map((m) => '${m['k']}:${m['a']}'), ['down:down']);
    await g.up();
    await until(tester, () => host.got.length >= 2);
    expect(host.got.last['a'], 'up');

    // Zurück/Home: einzelne Taste beim Loslassen.
    host.got.clear();
    await tester.tap(find.byKey(const ValueKey('rk-back')));
    await until(tester, () => host.got.isNotEmpty);
    expect(host.got.single['k'], 'back');
    expect(host.got.single['a'], 'tap');

    // Lautstärke nur, wenn der TV sie regeln kann (hier ja).
    host.got.clear();
    await tester.ensureVisible(find.byKey(const ValueKey('rk-volUp')));
    await tester.tap(find.byKey(const ValueKey('rk-volUp')));
    await until(tester, () => host.got.isNotEmpty);
    expect(host.got.first['k'], 'volUp');

    // Touchpad: Wischen nach rechts = Pfeil rechts, Tippen = OK.
    await tester.tap(find.byKey(const ValueKey('remote-touchpad-toggle')));
    await tester.pump();
    await tester.ensureVisible(find.byKey(const ValueKey('remote-touchpad')));
    await settle(tester, 2);
    host.got.clear();
    // Finger gleitet in kleinen Schritten (wie echt) nach rechts.
    final swipe = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('remote-touchpad'))));
    for (var i = 0; i < 12; i++) {
      await swipe.moveBy(const Offset(20, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await swipe.up();
    await until(tester, () => host.got.length >= 3);
    expect(host.got.map((m) => m['k']).toSet(), {'right'});
    host.got.clear();
    await tester.tap(find.byKey(const ValueKey('remote-touchpad')));
    await until(tester, () => host.got.isNotEmpty);
    expect(host.got.single['k'], 'ok');
    await shot(tester, 'phone_remote_touchpad');
    await done(tester);
  });

  testWidgets('Texteingabe: TV-Feld fokussiert → Eingabefeld, Tippen live',
      (tester) async {
    final s = await startServer(tester);
    await preparePaired(s);
    await pumpPhone(tester, const RemoteScreen());
    await until(tester, () => container(tester).read(remoteLinkProvider).connected);
    await s.broadcast(const RemoteTextState(
            focus: true, text: 'ta', hint: 'Sender, Sendung, Film …')
        .toJson());
    await until(tester, () =>
        find.byKey(const ValueKey('remote-text-field')).evaluate().isNotEmpty);
    expect(find.text('ta'), findsOneWidget);
    host.got.clear();
    await tester.enterText(
        find.byKey(const ValueKey('remote-text-field')), 'tagesschau');
    await until(tester, () => host.got.any((m) => m['t'] == 'text'));
    expect(host.got.lastWhere((m) => m['t'] == 'text')['v'], 'tagesschau');
    await shot(tester, 'phone_remote_text');
    await tester.tap(find.text('Fertig'));
    await until(tester, () => host.got.any((m) => m['t'] == 'textDone'));
    // Feld am TV verlassen → Eingabe verschwindet.
    await s.broadcast(RemoteTextState.none.toJson());
    await until(tester, () =>
        find.byKey(const ValueKey('remote-text-field')).evaluate().isEmpty);
    await done(tester);
  });

  testWidgets('Senderliste und Guide vom TV, Antippen schaltet um',
      (tester) async {
    final s = await startServer(tester);
    await preparePaired(s);
    await pumpPhone(tester, const RemoteScreen());
    await until(tester, () => container(tester).read(remoteLinkProvider).connected);
    await s.broadcast(const RemoteStatus(
            kind: 'live', title: 'ZDF HD', channelId: 'c1', channelNumber: 2)
        .toJson());
    await tester.tap(find.text('Sender'));
    await until(tester,
        () => find.byKey(const ValueKey('remote-ch-c3')).evaluate().isNotEmpty);
    await settle(tester, 8); // Seitenwechsel abwarten
    expect(find.text('Favoriten'), findsOneWidget);
    await shot(tester, 'phone_remote_channels');
    host.got.clear();
    await tester.tap(find.byKey(const ValueKey('remote-ch-c3')));
    await settle(tester, 10);
    await until(tester, () => host.got.any((m) => m['m'] == 'tune'));
    expect(host.got.firstWhere((m) => m['m'] == 'tune')['ch'], 'c3');
    await until(tester,
        () => find.textContaining('Umgeschaltet').evaluate().isNotEmpty);
    // Seitenweise: am Ende nachladen.
    await tester.fling(find.byType(ListView).last, const Offset(0, -3000), 3000);
    await until(tester, () =>
        host.got.where((m) => m['m'] == 'channels').isNotEmpty);
    final ch = host.got.where((m) => m['m'] == 'channels').toList();
    expect(ch.last['o'], remotePageSize);
    await tester.tap(find.text('TV-Guide'));
    await until(tester, () => find.textContaining('Tatort').evaluate().isNotEmpty);
    await settle(tester, 8);
    await shot(tester, 'phone_remote_guide');
    await done(tester);
  });

  testWidgets('Verbindungsabbruch → automatisch neu verbunden; TV weg → Hinweise',
      (tester) async {
    final s = await startServer(tester);
    await preparePaired(s);
    await pumpPhone(tester, const RemoteScreen());
    final link = container(tester).read(remoteLinkProvider.notifier);
    await until(tester, () => container(tester).read(remoteLinkProvider).connected);
    final me = await storage.remoteSelfId();
    s.disconnect(me);
    await until(tester,
        () => !container(tester).read(remoteLinkProvider).connected, max: 40);
    await until(tester, () => container(tester).read(remoteLinkProvider).connected,
        max: 200);
    // Fernseher aus: Server weg, keine Suche erfolgreich.
    await tester.runAsync(() => s.close());
    await until(tester,
        () => container(tester).read(remoteLinkProvider).phase ==
            LinkPhase.unreachable,
        max: 400);
    await until(tester, () =>
        find.byKey(const ValueKey('remote-hints')).evaluate().isNotEmpty);
    expect(disco.searches, greaterThan(0));
    await shot(tester, 'phone_remote_not_found');
    expect(link, isNotNull);
    await done(tester);
  });

  testWidgets('TV mit neuer Adresse wird per Suche wiedergefunden',
      (tester) async {
    final s = await startServer(tester);
    await preparePaired(s, port: 1); // alte, falsche Adresse
    disco.found.add(FoundTv(
        name: 'Wohnzimmer-TV', host: '127.0.0.1', port: s.port, id: 'tv-wz'));
    await pumpPhone(tester, const RemoteScreen());
    await until(tester, () => container(tester).read(remoteLinkProvider).connected,
        max: 300);
    await settle(tester, 4);
    expect(storage.remotePeers(tv: false).single.port, s.port,
        reason: 'neue Adresse gemerkt');
    await done(tester);
  });

  testWidgets('„Auf dem TV abspielen“: nur Kennung, Meldungen', (tester) async {
    final s = await startServer(tester);
    await preparePaired(s);
    const movie = VodItem(
        id: '4711',
        name: 'Nebelgrenze',
        categoryId: 'm',
        streamUrl: 'http://iptv.example:8080/movie/max/geheim/4711.mkv');
    await storage.setResume('movie_4711', 1234, 6000);
    await pumpPhone(tester, const MovieDetailScreen(movie: movie));
    await until(tester,
        () => find.byKey(const ValueKey('play-on-tv')).evaluate().isNotEmpty,
        max: 200);
    await shot(tester, 'phone_play_on_tv_button');
    host.got.clear();
    await tester.ensureVisible(find.byKey(const ValueKey('play-on-tv')));
    await tester.tap(find.byKey(const ValueKey('play-on-tv')));
    await until(tester, () => host.got.any((m) => m['m'] == 'play'));
    final req = host.got.firstWhere((m) => m['m'] == 'play');
    final wire = jsonEncode(req);
    for (final secret in ['geheim', 'max', 'iptv.example', 'http']) {
      expect(wire, isNot(contains(secret)), reason: secret);
    }
    final ref = ContentRef.fromJson((req['ref'] as Map).cast())!;
    expect(ref.kind, ContentKind.movie);
    expect(ref.id, '4711');
    expect(ref.position, 1234);
    expect(ref.scope, portalFingerprints(_portal));
    await until(tester,
        () => find.textContaining('Läuft jetzt auf').evaluate().isNotEmpty);

    host.playErr = RemoteError.notAvailable;
    await tester.pump(const Duration(seconds: 5));
    await tester.tap(find.byKey(const ValueKey('play-on-tv')));
    await until(tester, () => find
        .text('Dieser Inhalt ist auf dem TV nicht verfügbar.')
        .evaluate()
        .isNotEmpty);
    await done(tester);
  });

  testWidgets('ohne gekoppelten TV kein Knopf, keine Verbindung',
      (tester) async {
    await pumpPhone(
        tester,
        Scaffold(
            body: PlayOnTvButton(
                content: (ref) => contentRefFor(ref,
                    channel: const Channel(
                        id: 'c1',
                        name: 'X',
                        categoryId: 'a',
                        streamUrl: 'http://s/1')))));
    expect(find.byKey(const ValueKey('play-on-tv')), findsNothing);
    expect(disco.searches, 0);
    await done(tester);
  });

  test('Adresse manuell: nur Heimnetz, Standard-Port', () {
    expect(parseTvAddress('192.168.178.40'), ('192.168.178.40', remoteDefaultPort));
    expect(parseTvAddress(' 10.0.0.2:5000 '), ('10.0.0.2', 5000));
    expect(parseTvAddress('8.8.8.8'), isNull);
    expect(parseTvAddress('192.168.1.300'), isNull);
    expect(parseTvAddress('tv.local'), isNull);
    expect(parseTvAddress('192.168.1.2:0'), isNull);
  });
}
