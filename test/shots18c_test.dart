import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:jason_stream_player/core/secret_store.dart';
import 'package:jason_stream_player/core/theme.dart';
import 'package:jason_stream_player/data/storage.dart';
import 'package:jason_stream_player/l10n/strings.dart';
import 'package:jason_stream_player/models/models.dart';
import 'package:jason_stream_player/player/cast.dart';
import 'package:jason_stream_player/player/data_saver.dart';
import 'package:jason_stream_player/player/media_session.dart';
import 'package:jason_stream_player/state/playback_session.dart';
import 'package:jason_stream_player/state/providers.dart';
import 'package:jason_stream_player/ui/nav.dart';
import 'package:jason_stream_player/ui/player/mini_player.dart';
import 'package:jason_stream_player/ui/player/player_screen.dart';
import 'package:jason_stream_player/ui/settings/settings_screen.dart';
import 'package:jason_stream_player/ui/shell/reminder_host.dart'
    show appNavigatorKey;
import 'package:jsp_exoplayer/jsp_cast.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/app_fonts.dart';
import 'helpers/fake_engine.dart';
import 'helpers/tv_harness.dart';

/// 1.8c: Bildschirmfotos – Cast-Knopf im Player, Geräteauswahl,
/// „Läuft auf …“ im Mini-Player, Einstellung „Datensparmodus“.
/// Nur mit `TV_SHOTS=ordner`.
final _shotDir = Platform.environment['TV_SHOTS'];

Future<void> _shot(WidgetTester tester, String name) =>
    writeShot(tester, tvShotKey, name);

const _portal = Portal(
    id: 'pa', name: 'Anbieter A', type: PortalType.xtream, url: 'http://a');

Channel _ch(int i) => Channel(
      id: 'c$i',
      name: ['Das Erste HD', 'ZDF HD', 'RTL HD', 'arte HD'][i % 4],
      categoryId: 'de',
      streamUrl: 'http://a/live/u/p/$i.ts',
      number: i + 1,
    );

final _channels = [for (var i = 0; i < 4; i++) _ch(i)];

class _TestCast extends JspCast {
  final StreamController<Map<Object?, Object?>> ctl;
  const _TestCast(this.ctl);
  @override
  Stream<Map<Object?, Object?>> events() => ctl.stream;
}

void main() {
  late Storage storage;
  late StreamController<Map<Object?, Object?>> events;
  final skip = _shotDir == null;
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

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
    await storage.setOption('applang', 'de');
    await storage.setFlag(castNoticeFlag, true);
    L10n.lang = 'de';
    FakeEngine.created.clear();
    events = StreamController.broadcast();
    messenger.setMockMethodCallHandler(SystemChannels.platform, (c) async => null);
    messenger.setMockMethodCallHandler(
        const MethodChannel('de.jasonstream.player/platform'),
        (c) async => c.method == 'isTv' ? false : null);
    messenger.setMockMethodCallHandler(JspCastChannels.method, (c) async {
      if (c.method == 'connect') return true;
      if (c.method == 'load') return {'ok': true, 'code': 0};
      return null;
    });
  });

  tearDown(() {
    events.close();
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    messenger.setMockMethodCallHandler(
        const MethodChannel('de.jasonstream.player/platform'), null);
    messenger.setMockMethodCallHandler(JspCastChannels.method, null);
  });

  Future<void> pump(WidgetTester tester, [int n = 4]) async {
    for (var i = 0; i < n; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> pumpPhone(WidgetTester tester, Widget home,
      {Size size = const Size(1080, 2280), bool cellular = false}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        ...tvOverrides(
            TvData(
                live: LiveData(
                    const [Category(id: 'de', name: 'Deutschland')], _channels),
                portal: _portal),
            Future.value(storage),
            tv: false),
        playbackEngineProvider.overrideWithValue(FakeEngine.factory),
        mediaSessionProvider.overrideWithValue(NoopMediaSession()),
        castSupportedProvider.overrideWithValue(true),
        castApiProvider.overrideWithValue(_TestCast(events)),
        networkStateProvider.overrideWith((ref) => Stream.value(JspNetState(
            connected: true, metered: cellular, cellular: cellular))),
      ],
      child: RepaintBoundary(
        key: tvShotKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          navigatorKey: appNavigatorKey,
          theme: buildTheme(tv: false),
          builder: (context, child) => MiniPlayerHost(child: child!),
          home: home,
        ),
      ),
    ));
    await pump(tester, 6);
  }

  Future<void> done(WidgetTester tester) async {
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 12));
  }

  Future<FakeEngine> openLive(WidgetTester tester) async {
    unawaited(openPlayerAttached(PlayRequest(
      title: _channels[1].name,
      url: _channels[1].streamUrl,
      isLive: true,
      channels: _channels,
      channel: _channels[1],
    )));
    await pump(tester, 8);
    expect(find.byType(PlayerScreen), findsOneWidget);
    final e = FakeEngine.created.last;
    e.emit(width: 1920, buffering: false, playing: true);
    await tester.pump(const Duration(milliseconds: 300));
    return e;
  }

  void devices() => events.add({
        'e': 'devices',
        'devices': [
          {'id': 'tv1', 'name': 'Wohnzimmer'},
          {'id': 'tv2', 'name': 'Schlafzimmer'},
        ],
      });

  testWidgets('Cast-Knopf im Player (mit Datensparmodus)', skip: skip,
      (tester) async {
    await storage.setOption(DataSaverMode.optionKey, 'auto');
    await pumpPhone(tester, const Scaffold(body: SizedBox()),
        size: const Size(2280, 1080), cellular: true);
    await openLive(tester);
    devices();
    await pump(tester, 3);
    expect(find.byKey(const ValueKey('player-cast')), findsOneWidget);
    expect(find.byKey(const ValueKey('data-saver-badge')), findsOneWidget);
    await _shot(tester, 'phone_player_cast_button');
    await tester.tap(find.byKey(const ValueKey('player-cast')));
    await pump(tester, 6);
    expect(find.byKey(const ValueKey('cast-device-tv1')), findsOneWidget);
    await _shot(tester, 'phone_cast_device_picker');
    await done(tester);
  });

  testWidgets('Mini-Player „Läuft auf …“', skip: skip, (tester) async {
    await pumpPhone(
        tester,
        Scaffold(
          appBar: AppBar(title: const Text('Live TV')),
          body: ListView(children: [
            for (final c in _channels)
              ListTile(
                  leading: const Icon(Icons.live_tv_rounded),
                  title: Text(c.name)),
          ]),
        ));
    devices();
    await pump(tester, 2);
    await openLive(tester);
    events.add({'e': 'session', 'state': 'connected', 'device': 'Wohnzimmer'});
    await pump(tester, 8);
    events.add({'e': 'status', 'state': 'playing', 'ms': 0});
    await pump(tester, 3);
    expect(find.byKey(const ValueKey('mini-casting')), findsOneWidget);
    await _shot(tester, 'phone_mini_player_casting');
    await done(tester);
  });

  testWidgets('Einstellung „Datensparmodus im Mobilfunk“', skip: skip,
      (tester) async {
    await storage.setOption(DataSaverMode.optionKey, 'auto');
    await pumpPhone(tester, const Scaffold(body: SettingsScreen()),
        cellular: true);
    final item = find.byKey(const ValueKey('data-saver'));
    await tester.scrollUntilVisible(item, 300,
        scrollable: find.byType(Scrollable).first);
    await tester.pump(const Duration(milliseconds: 300));
    await _shot(tester, 'phone_setting_data_saver');
    await done(tester);
  });
}
