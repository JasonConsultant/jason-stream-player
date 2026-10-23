import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:jason_stream_player/core/secret_store.dart';
import 'package:jason_stream_player/core/theme.dart';
import 'package:jason_stream_player/data/storage.dart';
import 'package:jason_stream_player/l10n/strings.dart';
import 'package:jason_stream_player/models/models.dart';
import 'package:jason_stream_player/state/providers.dart';
import 'package:jason_stream_player/ui/home/home_screen.dart';
import 'package:jason_stream_player/ui/live/live_screen.dart';
import 'package:jason_stream_player/ui/player/subtitle_delay.dart';
import 'package:jason_stream_player/ui/portals/add_portal_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/app_fonts.dart';
import 'helpers/tv_harness.dart';

/// 1.7 Abschluss: Bildschirmfotos der neuen Teile. Nur mit `TV_SHOTS=ordner`.
final _shotDir = Platform.environment['TV_SHOTS'];

Future<void> _shot(WidgetTester tester, String name) =>
    writeShot(tester, tvShotKey, name);

const _portalA = Portal(
    id: 'pa', name: 'Anbieter A', type: PortalType.xtream, url: 'http://a');
const _portalB = Portal(
    id: 'pb', name: 'Anbieter B', type: PortalType.xtream, url: 'http://b');

Channel _ch(int i, {int catchup = 0}) => Channel(
      id: 'c$i',
      name: ['Das Erste HD', 'ZDF HD', 'RTL HD', 'arte HD', 'ProSieben HD',
          'SAT.1 HD'][i % 6],
      categoryId: 'de',
      streamUrl: 'http://s/$i',
      number: i + 1,
      catchupDays: catchup,
    );

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
    L10n.lang = 'de';
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
    addTearDown(() => FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.automatic);
  });

  TvData home({int days = 3}) => TvData(
        live: LiveData(const [Category(id: 'de', name: 'Deutschland')],
            [for (var i = 0; i < 6; i++) _ch(i, catchup: i.isEven ? 7 : 0)]),
        portal: _portalA,
        portals: const [_portalA, _portalB],
        account: AccountInfo(
            status: 'Active',
            expires: DateTime.now().add(Duration(days: days))),
      );

  testWidgets('Abo-Hinweis TV', skip: skip, (tester) async {
    await pumpTv(tester, Scaffold(body: HomeScreen(onOpenTab: (_) {})),
        home(), Future.value(storage));
    await tester.pump(const Duration(milliseconds: 300));
    await _shot(tester, 'tv_expiry_banner');
    await tvDone(tester);
  });

  testWidgets('Abo-Hinweis Handy', skip: skip, (tester) async {
    await pumpTv(tester, Scaffold(body: HomeScreen(onOpenTab: (_) {})),
        home(days: 1), Future.value(storage),
        tv: false, size: const Size(1080, 2280));
    await tester.pump(const Duration(milliseconds: 300));
    await _shot(tester, 'phone_expiry_banner');
    await tvDone(tester);
  });

  testWidgets('Archiv-Tage Live TV', skip: skip, (tester) async {
    await pumpTv(tester, const Scaffold(body: LiveScreen()), home(),
        Future.value(storage));
    await tester.pump(const Duration(milliseconds: 400));
    await _shot(tester, 'tv_live_archive');
    await tvDone(tester);
  });

  Future<void> addPortal(WidgetTester tester, {required bool tv}) async {
    await pumpTv(
        tester,
        Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                        builder: (_) => const AddPortalScreen())),
                child: const Text('öffnen'),
              ),
            ),
          ),
        ),
        TvData(live: const LiveData([], [])),
        Future.value(storage),
        tv: tv,
        size: tv ? null : const Size(1080, 2280));
    await tester.tap(find.text('öffnen'));
    await tester.pumpAndSettle();
  }

  testWidgets('Einfügen & erkennen Handy', skip: skip, (tester) async {
    await addPortal(tester, tv: false);
    await tester.enterText(find.byKey(const ValueKey('portal-paste')),
        'Server: tv.example.com\nPort: 8080\nBenutzer: jason77\nPasswort: Geheim!23');
    await tester.tap(find.byKey(const ValueKey('portal-detect')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await _shot(tester, 'phone_portal_detect');
    await tvDone(tester);
  });

  testWidgets('Einfügen & erkennen TV', skip: skip, (tester) async {
    await addPortal(tester, tv: true);
    await tester.enterText(find.byKey(const ValueKey('portal-paste')),
        'http://tv.example.com:8080/get.php?username=jason77&password=Geheim!23&type=m3u_plus');
    await tester.tap(find.byKey(const ValueKey('portal-detect')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await _shot(tester, 'tv_portal_detect');
    await tvDone(tester);
  });

  testWidgets('Untertitel-Verzögerung', skip: skip, (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final d = SubtitleDelay((k, v) async {});
    await tester.pumpWidget(RepaintBoundary(
      key: tvShotKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(tv: true),
        home: Builder(
          builder: (context) => Scaffold(
            backgroundColor: Colors.black,
            body: Center(
              child: TextButton(
                onPressed: () => SubtitleDelaySheet.show(context, d),
                child: const Text('öffnen'),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('öffnen'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    await _shot(tester, 'tv_subtitle_delay');
    await tester.pumpAndSettle();
  });
}
