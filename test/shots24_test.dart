import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:jason_stream_player/core/remote/crypto.dart';
import 'package:jason_stream_player/core/remote/peers.dart';
import 'package:jason_stream_player/core/secret_store.dart';
import 'package:jason_stream_player/core/theme.dart';
import 'package:jason_stream_player/data/storage.dart';
import 'package:jason_stream_player/l10n/strings.dart';
import 'package:jason_stream_player/models/models.dart';
import 'package:jason_stream_player/state/providers.dart' show LiveData;
import 'package:jason_stream_player/state/remote.dart';
import 'package:jason_stream_player/ui/live/live_screen.dart';
import 'package:jason_stream_player/ui/remote/remote_devices_screen.dart';
import 'package:jason_stream_player/ui/remote/tv_remote_service.dart';
import 'package:jason_stream_player/ui/settings/settings_screen.dart';
import 'package:jason_stream_player/ui/tv/tv_safe.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/app_fonts.dart';
import 'helpers/tv_harness.dart';

/// 2.4 Bildschirmfotos Fernseher: Code-Anzeige beim Koppeln, Einstellung
/// „Handy als Fernbedienung“, Gekoppelte Geräte. Nur mit `TV_SHOTS=ordner`.
/// (Handy-Bilder entstehen in remote24_phone_test.dart.)
final _shotDir = Platform.environment['TV_SHOTS'];

class _Info extends RemoteServerInfoNotifier {
  @override
  RemoteServerInfo build() => const RemoteServerInfo(
      running: true, address: '192.168.178.40', clients: 1);
}

class _Prompt extends PairPromptNotifier {
  @override
  PairPrompt? build() => const PairPrompt('4827', 'Pixel 9');
}

final _channels = [
  for (var i = 0; i < 12; i++)
    Channel(
        id: 'c$i',
        name: ['Das Erste HD', 'ZDF HD', 'RTL HD', 'arte HD', 'ProSieben',
            'Sat.1', 'VOX', 'kabel eins', 'tagesschau24', 'phoenix',
            '3sat', 'ZDFneo'][i],
        categoryId: 'de',
        streamUrl: 'http://s/$i',
        number: i + 1),
];

void main() {
  late Storage storage;
  final skip = _shotDir == null;

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
    await storage.setRemotePeers([
      RemotePeer(
          id: 'p1',
          name: 'Pixel 9',
          key: RemoteCrypto.random(32),
          pairedAt: DateTime(2026, 10, 20),
          lastSeen: DateTime(2026, 10, 27)),
      RemotePeer(
          id: 'p2',
          name: 'Galaxy Tab S9',
          key: RemoteCrypto.random(32),
          pairedAt: DateTime(2026, 9, 3)),
    ], tv: true);
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    m.setMockMethodCallHandler(SystemChannels.platform, (c) async => null);
    for (final ch in [
      'de.jasonstream/cast/events',
      'de.jasonstream/network/events',
      'de.jasonstream/network',
    ]) {
      m.setMockMethodCallHandler(MethodChannel(ch), (c) async => null);
    }
    m.setMockMethodCallHandler(
        const MethodChannel('de.jasonstream.player/platform'),
        (c) async => c.method == 'isTv' ? true : null);
  });

  tearDown(() {
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    m.setMockMethodCallHandler(SystemChannels.platform, null);
    m.setMockMethodCallHandler(
        const MethodChannel('de.jasonstream.player/platform'), null);
  });

  Future<void> pump(WidgetTester tester, Widget home,
      {bool prompt = false}) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: tvOverrides(
          TvData(
              live: LiveData(
                  const [Category(id: 'de', name: 'Deutschland')], _channels)),
          Future.value(storage),
          extra: [
            remoteServerInfoProvider.overrideWith(_Info.new),
            if (prompt) remotePairPromptProvider.overrideWith(_Prompt.new),
          ]),
      child: RepaintBoundary(
        key: tvShotKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(tv: true).copyWith(
              pageTransitionsTheme: TvSafePageTransitionsBuilder.theme()),
          builder: (context, child) => TvSafeMediaQuery(
              enabled: true,
              child: Consumer(
                  builder: (context, ref, _) => Stack(children: [
                        child!,
                        if (ref.watch(remotePairPromptProvider) case final p?)
                          Positioned.fill(child: PairCodeOverlay(p)),
                      ]))),
          home: home,
        ),
      ),
    ));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> done(WidgetTester tester) async {
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  }

  testWidgets('TV: Code-Anzeige beim Koppeln', skip: skip, (tester) async {
    await pump(tester, const Scaffold(body: LiveScreen()), prompt: true);
    expect(find.byKey(const ValueKey('remote-pair-code')), findsOneWidget);
    await writeShot(tester, tvShotKey, 'tv_remote_pair_code');
    await done(tester);
  });

  testWidgets('TV: Einstellung „Handy als Fernbedienung“', skip: skip,
      (tester) async {
    await pump(tester, const Scaffold(body: SettingsScreen()));
    final item = find.byKey(const ValueKey('settings-remote-enabled'));
    await tester.scrollUntilVisible(item, 300,
        scrollable: find.byType(Scrollable).first);
    await tester.pump(const Duration(milliseconds: 300));
    await writeShot(tester, tvShotKey, 'tv_remote_settings');
    await done(tester);
  });

  testWidgets('TV: Gekoppelte Geräte', skip: skip, (tester) async {
    await pump(tester, const RemoteDevicesScreen());
    await writeShot(tester, tvShotKey, 'tv_remote_devices');
    await done(tester);
  });
}
