import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:jason_stream_player/core/app_messages.dart';
import 'package:jason_stream_player/core/remote/content_ref.dart';
import 'package:jason_stream_player/core/remote/net.dart';
import 'package:jason_stream_player/core/remote/nsd.dart';
import 'package:jason_stream_player/core/remote/protocol.dart';
import 'package:jason_stream_player/core/remote/transport.dart';
import 'package:jason_stream_player/core/secret_store.dart';
import 'package:jason_stream_player/core/theme.dart';
import 'package:jason_stream_player/data/storage.dart';
import 'package:jason_stream_player/l10n/strings.dart';
import 'package:jason_stream_player/models/models.dart';
import 'package:jason_stream_player/player/media_session.dart';
import 'package:jason_stream_player/state/downloads.dart' show downloadHostProvider;
import 'package:jason_stream_player/state/playback_session.dart';
import 'package:jason_stream_player/state/providers.dart';
import 'package:jason_stream_player/state/remote.dart';
import 'package:jason_stream_player/ui/player/player_screen.dart';
import 'package:jason_stream_player/ui/remote/tv_remote_service.dart';
import 'package:jason_stream_player/ui/shell/app_guard.dart' show AppLock;
import 'package:jason_stream_player/ui/shell/reminder_host.dart'
    show appNavigatorKey;
import 'package:jason_stream_player/ui/tv/tv_safe.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/fake_downloads.dart' as dl;
import 'helpers/fake_engine.dart';
import 'helpers/tv_harness.dart';

/// 2.4 Ende-zu-Ende im Dart-VM: TV-Dienst (echter WebSocket-Server auf
/// Loopback) + Handy-Verbindung, ohne NSD. Tasten bewegen den Fokus wie die
/// Fernbedienung, Senderwechsel/Inhalte kommen an, Kinderschutz bleibt.

class FakeDiscovery implements RemoteDiscovery {
  final registered = <String>[];
  bool unregistered = false;
  final volumes = <int>[];
  bool controllable = true;
  @override
  Future<String?> register(
      {required String name,
      required int port,
      required Map<String, String> attrs}) async {
    registered.add('$name:${attrs['id']}');
    unregistered = false;
    return name;
  }

  @override
  Future<void> unregister() async => unregistered = true;
  @override
  Stream<FoundTv> discover() => const Stream.empty();
  @override
  Stream<String> get lost => const Stream.empty();
  @override
  Future<void> stopDiscover() async {}
  @override
  Future<bool> volume(int dir) async {
    volumes.add(dir);
    return true;
  }

  @override
  Future<bool> volumeControllable() async => controllable;
}

const _portal = Portal(
    id: 'tv-portal',
    name: 'Anbieter',
    type: PortalType.xtream,
    url: 'http://iptv.example:8080',
    username: 'max',
    password: 'geheim');
const _other = Portal(
    id: 'tv-other',
    name: 'Zweitanbieter',
    type: PortalType.xtream,
    url: 'http://other.example',
    username: 'eva',
    password: 'x');

final _channels = [
  for (var i = 0; i < 6; i++)
    Channel(
        id: 'c$i',
        name: 'Sender $i',
        categoryId: i < 4 ? 'de' : 'news',
        streamUrl: 'http://s/$i',
        number: i + 1,
        logoUrl: i == 0 ? 'http://logo.example/c0.png' : 'http://s/logo.php?u=max'),
];

final _t0 = DateTime.now();
final _epg = {
  for (final c in _channels)
    '@${c.id}': [
      EpgEntry(
          channelEpgId: '@${c.id}',
          title: 'Jetzt ${c.id}',
          start: _t0.subtract(const Duration(minutes: 20)),
          end: _t0.add(const Duration(minutes: 40))),
      EpgEntry(
          channelEpgId: '@${c.id}',
          title: 'Danach ${c.id}',
          start: _t0.add(const Duration(minutes: 40)),
          end: _t0.add(const Duration(minutes: 100))),
    ],
};

final _movies = VodData([
  const Category(id: 'm', name: 'Filme')
], [
  const VodItem(
      id: 'mv1', name: 'Nebelgrenze', categoryId: 'm', streamUrl: 'http://s/mv1'),
]);

const _quiet = [
  MethodChannel('de.jasonstream/network'),
  MethodChannel('de.jasonstream/network/events'),
  MethodChannel('de.jasonstream/cast/events'),
];

void main() {
  late Storage storage;
  late FakeDiscovery disco;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    L10n.lang = 'de';
    await initializeDateFormatting('de');
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    storage = await Storage.open(store: PreviewSecretStore());
    disco = FakeDiscovery();
    FakeEngine.created.clear();
    AppLock.locked.value = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (c) async => null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('de.jasonstream.player/platform'),
            (c) async => c.method == 'isTv' ? true : null);
    for (final ch in _quiet) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ch, (c) async => null);
    }
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (c) async => Directory.systemTemp.path);
  });

  tearDown(() {
    for (final ch in [
      ..._quiet,
      const MethodChannel('plugins.flutter.io/path_provider')
    ]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ch, null);
    }
    AppLock.locked.value = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('de.jasonstream.player/platform'), null);
  });

  TvData data({ChannelFlags flags = ChannelFlags.empty}) => TvData(
        live: LiveData(const [
          Category(id: 'de', name: 'Deutschland'),
          Category(id: 'news', name: 'Nachrichten'),
        ], _channels),
        epg: _epg,
        flags: flags,
        movies: _movies,
        portal: _portal,
        portals: const [_portal, _other],
      );

  /// Server läuft im Wurzel-Zone (echte Sockets); Handy-Seite über
  /// [WidgetTester.runAsync].
  Future<void> pumpTvApp(WidgetTester tester, Widget home,
      {ChannelFlags flags = ChannelFlags.empty}) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final overrides = <Override>[
      ...tvOverrides(data(flags: flags), Future.value(storage)),
      playbackEngineProvider.overrideWithValue(FakeEngine.factory),
      mediaSessionProvider.overrideWithValue(NoopMediaSession()),
      downloadHostProvider.overrideWithValue(dl.FakeHost(dl.FakeFileServer())),
      remoteDiscoveryProvider.overrideWithValue(disco),
      remoteServerStarterProvider.overrideWithValue((h) => Zone.root.run(() =>
          startRemoteServer(h,
              bindAddress: InternetAddress.loopbackIPv4, preferredPort: 0))),
    ];
    await tester.pumpWidget(ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        navigatorKey: appNavigatorKey,
        scaffoldMessengerKey: appMessengerKey,
        theme: buildTheme(tv: true).copyWith(
            pageTransitionsTheme: TvSafePageTransitionsBuilder.theme()),
        builder: (context, child) => TvSafeMediaQuery(
            enabled: true,
            child: TvRemoteService(enabled: true, child: child!)),
        home: home,
      ),
    ));
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 50));
      if (_service(tester).server != null) break;
    }
    expect(_service(tester).server, isNotNull, reason: 'Server läuft');
  }

  ProviderContainer container(WidgetTester tester) =>
      ProviderScope.containerOf(tester.element(find.byType(TvRemoteService)));

  /// Netzaufruf mit echten Sockets: starten (echte Zone) und währenddessen
  /// Bilder/Mikrotasks der Test-Zone weiterlaufen lassen (Riverpod, Speicher).
  Future<T> net<T>(WidgetTester tester, Future<T> Function() f) async {
    late Future<T> fut;
    var finished = false;
    await tester.runAsync(() async {
      fut = f();
      fut.then((_) => finished = true, onError: (Object _) => finished = true);
    });
    for (var i = 0; i < 400 && !finished; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)));
    }
    expect(finished, isTrue, reason: 'Netzaufruf hängt');
    late T r;
    await tester.runAsync(() async => r = await fut);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    return r;
  }

  /// Handy koppeln und anmelden (Code von der TV-Anzeige ablesen).
  Future<RemoteConnection> pairAndConnect(WidgetTester tester) async {
    final port = _service(tester).server!.port;
    final c = await net(tester,
        () => connectRemote('127.0.0.1', port, allowLoopback: true));
    final flow = await net(tester, () => c.pair('phone-1', 'Pixel 9'));
    final code = container(tester).read(remotePairPromptProvider)!.code;
    final key = await net(tester, () => flow.submit(code));
    final conn = await net(tester,
        () => connectRemote('127.0.0.1', port, allowLoopback: true));
    await net(tester, () => conn.authenticate('phone-1', key));
    expect(container(tester).read(remotePhonesProvider).single.name, 'Pixel 9');
    // Schlüssel liegt verschlüsselt im Speicher.
    expect(storage.remotePeers(tv: true).single.id, 'phone-1');
    return conn;
  }

  Future<void> settle(WidgetTester tester, [int n = 6]) async {
    for (var i = 0; i < n; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> done(WidgetTester tester, RemoteConnection c) async {
    await tester.runAsync(() => c.close());
    await tester.pumpWidget(const SizedBox());
    await settle(tester, 3);
    await tester.pump(const Duration(seconds: 12));
  }

  testWidgets('Code-Anzeige am TV beim Koppeln, Ankündigung per NSD',
      (tester) async {
    await pumpTvApp(tester, const Scaffold(body: SizedBox()));
    expect(disco.registered.single, endsWith(':${await storage.remoteSelfId()}'));
    final port = _service(tester).server!.port;
    final c = await net(tester,
        () => connectRemote('127.0.0.1', port, allowLoopback: true));
    final flow = await net(tester, () => c.pair('phone-1', 'Pixel 9'));
    expect(find.byKey(const ValueKey('remote-pair-code')), findsOneWidget);
    expect(find.textContaining('Pixel 9'), findsOneWidget);
    final code = container(tester).read(remotePairPromptProvider)!.code;
    for (final d in code.split('')) {
      expect(find.text(d), findsWidgets);
    }
    await net(tester, () => flow.submit(code));
    expect(find.byKey(const ValueKey('remote-pair-code')), findsNothing);
    expect(AppMessages.history.last, contains('Pixel 9'));
    await tester.pumpWidget(const SizedBox());
    await settle(tester, 2);
  });

  testWidgets('Tastenbefehl vom Handy bewegt den Fokus wie die Fernbedienung',
      (tester) async {
    var pressed = '';
    await pumpTvApp(
        tester,
        Scaffold(
          body: Center(
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              for (final n in ['A', 'B', 'C'])
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: ElevatedButton(
                    key: ValueKey('btn-$n'),
                    autofocus: n == 'A',
                    onPressed: () => pressed = n,
                    child: Text(n),
                  ),
                ),
            ]),
          ),
        ));
    await tester.pump();
    bool focused(String n) => Focus.of(tester.element(find.text(n))).hasFocus;
    expect(focused('A'), isTrue);
    final c = await pairAndConnect(tester);

    await net(tester, () => c.send({'t': 'key', 'k': 'right', 'a': 'tap'}));
    await settle(tester, 2);
    expect(focused('B'), isTrue);
    await net(tester, () => c.send({'t': 'key', 'k': 'right', 'a': 'tap'}));
    await settle(tester, 2);
    expect(focused('C'), isTrue);
    // OK = select → Knopf ausgelöst.
    await net(tester, () => c.send({'t': 'key', 'k': 'ok', 'a': 'tap'}));
    await settle(tester, 2);
    expect(pressed, 'C');
    await net(tester, () => c.send({'t': 'key', 'k': 'left', 'a': 'tap'}));
    await settle(tester, 2);
    expect(focused('B'), isTrue);
    // Unbekannte Taste wird ignoriert.
    await net(tester, () => c.send({'t': 'key', 'k': 'reboot', 'a': 'tap'}));
    // Lautstärke über das System (nicht als Taste).
    await net(tester, () => c.send({'t': 'key', 'k': 'volUp', 'a': 'tap'}));
    await settle(tester, 2);
    expect(disco.volumes, [1]);
    expect(focused('B'), isTrue);
    expect((c.ready['caps'] as Map)['volume'], isTrue);
    await done(tester, c);
  });

  testWidgets('Texteingabe: TV-Feld fokussiert → Handy bekommt es, Tippen '
      'kommt live an, Passwort bleibt geheim', (tester) async {
    final ctl = TextEditingController(text: 'ta');
    final changes = <String>[];
    final pw = TextEditingController(text: 'geheim');
    final searchFocus = FocusNode();
    final pwFocus = FocusNode();
    await pumpTvApp(
        tester,
        Scaffold(
          body: Column(children: [
            TextField(
                controller: ctl,
                focusNode: searchFocus,
                decoration: const InputDecoration(hintText: 'Suche'),
                onChanged: changes.add),
            TextField(controller: pw, focusNode: pwFocus, obscureText: true),
          ]),
        ));
    final c = await pairAndConnect(tester);
    final events = <Map<String, Object?>>[];
    final sub = c.events.listen(events.add);
    searchFocus.requestFocus();
    await settle(tester, 4);
    final t = RemoteTextState.fromJson(
        events.lastWhere((e) => e['t'] == 'text'));
    expect(t.focus, isTrue);
    expect(t.text, 'ta');
    expect(t.hint, 'Suche');
    await net(tester, () => c.send({'t': 'text', 'v': 'tagesschau'}));
    await settle(tester, 2);
    expect(ctl.text, 'tagesschau');
    expect(changes.last, 'tagesschau');
    pwFocus.requestFocus();
    await settle(tester, 4);
    final p = RemoteTextState.fromJson(
        events.lastWhere((e) => e['t'] == 'text'));
    expect(p.obscure, isTrue);
    expect(p.text, isEmpty);
    expect(events.toString(), isNot(contains('geheim')));
    pwFocus.unfocus();
    await settle(tester, 4);
    expect(RemoteTextState.fromJson(events.last).focus, isFalse);
    await tester.runAsync(() => sub.cancel());
    await done(tester, c);
  });

  testWidgets('Senderliste/Guide vom TV, Senderwechsel kommt an, Status',
      (tester) async {
    await pumpTvApp(tester, const Scaffold(body: SizedBox()));
    final c = await pairAndConnect(tester);
    final groups = await net(tester, () => c.request('groups'));
    final gs = [
      for (final g in groups['groups'] as List) RemoteGroup.fromJson(g)!
    ];
    expect(gs.map((g) => '${g.id}:${g.count}'), ['de:4', 'news:2']);
    final page = await net(
        tester, () => c.request('channels', {'g': 'de', 'o': 1, 'n': 2}));
    expect(page['total'], 4);
    final items = [
      for (final j in page['items'] as List) RemoteChannel.fromJson(j)!
    ];
    expect(items.map((x) => x.id), ['c1', 'c2']);
    expect(items.first.now!.title, 'Jetzt c1');
    expect(items.first.next!.title, 'Danach c1');
    expect(items.first.logo, isNull, reason: 'Logo mit Zugangsdaten');
    final first = await net(tester, () => c.request('channels', {'o': 0, 'n': 1}));
    expect(RemoteChannel.fromJson((first['items'] as List).single)!.logo,
        'http://logo.example/c0.png');

    final events = <Map<String, Object?>>[];
    final sub = c.events.listen(events.add);
    final r = await net(tester, () => c.request('tune', {'ch': 'c2'}));
    expect(r['ok'], isTrue);
    await settle(tester, 8);
    expect(find.byType(PlayerScreen), findsOneWidget);
    expect(FakeEngine.created.last.calls, contains('open http://s/2'));
    await settle(tester, 4);
    final st = RemoteStatus.fromJson(
        events.lastWhere((e) => e['t'] == 'status'));
    expect(st.live, isTrue);
    expect(st.channelId, 'c2');
    expect(st.programme, 'Jetzt c2');

    // Player offen: Umschalten über die Player-Seite (eine Seite, Zapping).
    final r2 = await net(tester, () => c.request('tune', {'ch': 'c4'}));
    expect(r2['ok'], isTrue);
    await settle(tester, 10);
    expect(find.byType(PlayerScreen), findsOneWidget);
    expect(FakeEngine.created.expand((e) => e.calls),
        contains('open http://s/4'));
    final unknown = await net(tester, () => c.request('tune', {'ch': 'zzz'}));
    expect(unknown['err'], RemoteError.notAvailable);
    await tester.runAsync(() => sub.cancel());
    await done(tester, c);
  });

  testWidgets('Kinderschutz: gesperrter Sender verlangt die PIN am TV, '
      'versteckte Sender gibt es nicht, App-Sperre blockiert', (tester) async {
    await storage.setPin('1234');
    await pumpTvApp(tester, const Scaffold(body: SizedBox()),
        flags: const ChannelFlags({}, {'c5'}, {'c3'}));
    final c = await pairAndConnect(tester);
    final groups = await net(tester, () => c.request('groups'));
    expect(groups['total'], 5, reason: 'versteckter Sender fehlt');
    final hidden = await net(tester, () => c.request('tune', {'ch': 'c5'}));
    expect(hidden['err'], RemoteError.notAvailable);

    late Future<Map<String, Object?>> pending;
    var answered = false;
    await tester.runAsync(() async {
      pending = c.request('tune', {'ch': 'c3'}, const Duration(seconds: 30));
      pending.then((_) => answered = true, onError: (Object _) {});
    });
    await settle(tester, 6);
    expect(answered, isFalse);
    expect(find.text('PIN eingeben'), findsOneWidget);
    expect(find.byType(PlayerScreen), findsNothing);
    // Abbrechen am TV (Zurück per Handy-Taste).
    await net(tester, () => c.send({'t': 'key', 'k': 'back', 'a': 'tap'}));
    await settle(tester, 6);
    final res = await net(tester, () => pending);
    expect(res['err'], RemoteError.refused);
    expect(find.byType(PlayerScreen), findsNothing);

    AppLock.locked.value = true;
    final locked = await net(tester, () => c.request('tune', {'ch': 'c1'}));
    expect(locked['err'], RemoteError.locked);
    final list = await net(tester, () => c.request('groups'));
    expect(list['err'], RemoteError.locked);
    AppLock.locked.value = false;
    await done(tester, c);
  });

  testWidgets('Auf dem TV abspielen: Kennung → eigenes Portal des TVs',
      (tester) async {
    await pumpTvApp(tester, const Scaffold(body: SizedBox()));
    final c = await pairAndConnect(tester);
    // Handy hat dasselbe Konto (andere ID, Schreibweise der Adresse).
    const phonePortal = Portal(
        id: 'phone-uuid',
        name: 'Handy',
        type: PortalType.xtream,
        url: 'HTTP://iptv.example:8080/',
        username: 'max',
        password: 'geheim');
    ContentRef ref(Portal p, ContentKind k, String id, {int pos = 0}) =>
        ContentRef(
            source: 'portal',
            scope: portalFingerprints(p),
            kind: k,
            id: id,
            position: pos);

    final none = await net(
        tester,
        () => c.request('play', {
              'ref': ref(const Portal(
                      id: 'x',
                      name: 'x',
                      type: PortalType.xtream,
                      url: 'http://fremd.example',
                      username: 'max'),
                  ContentKind.movie, 'mv1')
                  .toJson()
            }));
    expect(none['err'], RemoteError.notAvailable);
    final inactive = await net(
        tester,
        () => c.request('play',
            {'ref': ref(_other, ContentKind.movie, 'mv1').toJson()}));
    expect(inactive['err'], RemoteError.portalInactive);
    final missing = await net(
        tester,
        () => c.request('play',
            {'ref': ref(phonePortal, ContentKind.movie, 'gibtsnicht').toJson()}));
    expect(missing['err'], RemoteError.notAvailable);

    final ok = await net(
        tester,
        () => c.request('play', {
              'ref': ref(phonePortal, ContentKind.movie, 'mv1', pos: 1800)
                  .toJson()
            }));
    expect(ok['ok'], isTrue);
    await settle(tester, 8);
    expect(find.byType(PlayerScreen), findsOneWidget);
    expect(FakeEngine.created.last.calls, contains('open http://s/mv1'));
    expect(storage.resume('movie_mv1')!.pos, 1800);

    final live = await net(
        tester,
        () => c.request('play',
            {'ref': ref(phonePortal, ContentKind.live, 'c1').toJson()}));
    expect(live['ok'], isTrue);
    await settle(tester, 10);
    expect(find.byType(PlayerScreen), findsOneWidget,
        reason: 'Film-Player geschlossen, Live-Player offen');
    expect(FakeEngine.created.last.calls, contains('open http://s/1'));
    final emby = await net(
        tester,
        () => c.request('play', {
              'ref': ContentRef(
                      source: 'emby',
                      scope: [embyFingerprint('srv')],
                      kind: ContentKind.movie,
                      id: 'e1')
                  .toJson()
            }));
    expect(emby['err'], RemoteError.notAvailable, reason: 'kein Emby am TV');
    await done(tester, c);
  });

  testWidgets('Einstellung aus → Dienst gestoppt, Abmelden bei NSD',
      (tester) async {
    await pumpTvApp(tester, const Scaffold(body: SizedBox()));
    await container(tester).read(remoteEnabledProvider.notifier).set(false);
    await settle(tester, 4);
    expect(_service(tester).server, isNull);
    expect(disco.unregistered, isTrue);
    expect(container(tester).read(remoteServerInfoProvider).running, isFalse);
    await container(tester).read(remoteEnabledProvider.notifier).set(true);
    for (var i = 0; i < 20 && _service(tester).server == null; i++) {
      await settle(tester, 1);
    }
    expect(_service(tester).server, isNotNull);
    // App in den Hintergrund → Dienst aus (kein Dauerdienst).
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await settle(tester, 4);
    expect(_service(tester).server, isNull);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    for (var i = 0; i < 20 && _service(tester).server == null; i++) {
      await settle(tester, 1);
    }
    expect(_service(tester).server, isNotNull);
    await tester.pumpWidget(const SizedBox());
    await settle(tester, 2);
  });
}

TvRemoteServiceState _service(WidgetTester tester) =>
    tester.state<TvRemoteServiceState>(find.byType(TvRemoteService));
