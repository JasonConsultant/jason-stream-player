import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:jason_stream_player/core/secret_store.dart';
import 'package:jason_stream_player/core/subtitle_style.dart';
import 'package:jason_stream_player/core/theme.dart';
import 'package:jason_stream_player/data/storage.dart';
import 'package:jason_stream_player/l10n/strings.dart';
import 'package:jason_stream_player/models/models.dart';
import 'package:jason_stream_player/state/providers.dart';
import 'package:jason_stream_player/ui/player/player_debug.dart';
import 'package:jason_stream_player/ui/player/subtitle_view.dart';
import 'package:jason_stream_player/ui/search/recent_searches.dart';
import 'package:jason_stream_player/ui/search/search_screen.dart';
import 'package:jason_stream_player/ui/settings/settings_screen.dart';
import 'package:jason_stream_player/ui/tv/tv_safe.dart';
import 'package:jason_stream_player/ui/widgets/artwork.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/app_fonts.dart';
import 'helpers/tv_harness.dart';

/// 1.5 Abschluss: Bildschirmfotos (TV, 1920×1080, dpr 2) der neuen Teile –
/// Suche mit „Letzte Suchen“ und „Löschen“, Einstellungen mit
/// „Video-Ausgabe“, Diagnose-Anzeige und Untertitel-Stile im Player.
/// Nur mit `TV_SHOTS=ordner`.

final _shotDir = Platform.environment['TV_SHOTS'];

Future<void> _shot(WidgetTester tester, String name) =>
    writeShot(tester, tvShotKey, name);

final _channels = [
  for (var i = 0; i < 12; i++)
    Channel(
        id: 'c$i',
        name: ['Das Erste HD', 'ZDF HD', 'RTL HD', 'arte HD'][i % 4],
        categoryId: 'de',
        streamUrl: 'http://s/$i',
        number: i + 1),
];

/// Videobild-Ersatz mit Untertitel wie media_kits SubtitleView
/// (gleiche Skalierung: Wurzel des Flächenverhältnisses zu 1920×1080).
class _FakePlayer extends StatelessWidget {
  final SubtitleStyle sub;
  final bool debug;
  const _FakePlayer({required this.sub, this.debug = false});

  @override
  Widget build(BuildContext context) {
    final cfg = subtitleViewConfig(sub);
    return ColoredBox(
      color: Colors.black,
      child: Stack(fit: StackFit.expand, children: [
        const GeneratedArt(seed: 'Tatort – Im Schmerz geboren'),
        LayoutBuilder(builder: (context, c) {
          final f = sqrt((c.maxWidth * c.maxHeight / (1920 * 1080))
              .clamp(0.0, 1.0));
          return Padding(
            padding: cfg.padding,
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Text(
                'Wir müssen reden.\nÜber das, was gestern passiert ist.',
                style: cfg.style,
                textAlign: cfg.textAlign,
                textScaler: TextScaler.linear(f),
              ),
            ),
          );
        }),
        if (debug)
          Positioned(
            left: 16,
            top: 16,
            child: PlayerDebugPanel(
                lines: PlayerDebugInfo.format(const {
              'hwdec-current': 'mediacodec',
              'current-vo': 'mediacodec_embed',
              'video-codec': 'h264',
              'video-params/w': '1920',
              'video-params/h': '1080',
              'container-fps': '50.000000',
              'estimated-vf-fps': '49.980000',
              'frame-drop-count': '0',
              'decoder-frame-drop-count': '2',
              'vo-delayed-frame-count': '0',
              'demuxer-cache-duration': '7.412000',
              'cache-buffering-state': '100',
            }, sent: 3)),
          ),
      ]),
    );
  }
}

void main() {
  late Storage storage;
  late TvData data;
  final skip = _shotDir == null;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    L10n.lang = 'de';
    await initializeDateFormatting('de');
    await loadAppFonts();
    // Diagnose-Anzeige nutzt „monospace“ (auf dem Gerät Droid Sans Mono).
    final mono = File('/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf');
    if (mono.existsSync()) {
      final bytes = mono.readAsBytesSync();
      await (FontLoader('monospace')
            ..addFont(Future.value(ByteData.sublistView(bytes))))
          .load();
    }
    if (_shotDir != null) Directory(_shotDir!).createSync(recursive: true);
    data = TvData(
      live: LiveData(const [Category(id: 'de', name: 'DE')], _channels),
      epg: const {},
    );
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    storage = await Storage.open(store: PreviewSecretStore());
    await storage.setOption('applang', 'de');
    L10n.lang = 'de';
    // Fokusrahmen wie mit der Fernbedienung.
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
    addTearDown(() => FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.automatic);
  });

  testWidgets('Suche: Letzte Suchen und Löschen', skip: skip, (tester) async {
    await pumpTv(tester, const Scaffold(body: SearchScreen()), data,
        Future.value(storage));
    final c = ProviderScope.containerOf(
        tester.element(find.byType(SearchScreen)));
    final n = c.read(recentSearchesProvider.notifier);
    for (final q in ['Champions League', 'Tatort', 'Die Sendung mit der Maus',
        'Formel 1', 'arte']) {
      await tester.runAsync(() => n.add(q));
    }
    await tester.pump();
    await _shot(tester, 'search_recent');
    // Text im Feld → „Löschen“-Knopf; Fokus darauf.
    tester.widget<TextField>(find.byType(TextField)).controller!.text =
        'Tatort';
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    Focus.of(tester.element(find.descendant(
            of: find.byKey(const ValueKey('search-clear-chip')),
            matching: find.byType(Container))
        .first))
        .requestFocus();
    await tester.pump(const Duration(milliseconds: 300));
    await _shot(tester, 'search_recent_clear');
    await tvDone(tester);
  });

  testWidgets('Einstellungen: Video-Ausgabe', skip: skip, (tester) async {
    await storage.setOption('videoout', 'direct');
    await pumpTv(tester, const Scaffold(body: SettingsScreen()), data,
        Future.value(storage));
    final item = find.byKey(const ValueKey('video-output'));
    await tester.ensureVisible(item);
    await tester.pump(const Duration(milliseconds: 300));
    Focus.of(tester.element(find.descendant(
            of: item, matching: find.byType(Text)).first))
        .requestFocus();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('video-output')), findsOneWidget);
    await _shot(tester, 'settings_video_output');
    await tvDone(tester);
  });

  Future<void> pumpPlayer(WidgetTester tester, Widget w) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(RepaintBoundary(
      key: tvShotKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(tv: true),
        builder: (context, child) =>
            TvSafeMediaQuery(enabled: true, child: child!),
        home: Scaffold(body: w),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('Player: Diagnose-Anzeige', skip: skip, (tester) async {
    await pumpPlayer(
        tester, const _FakePlayer(sub: SubtitleStyle(), debug: true));
    await _shot(tester, 'player_debug_overlay');
  });

  testWidgets('Player: Untertitel-Stile', skip: skip, (tester) async {
    for (final (name, s) in [
      ('subtitle_normal_white', const SubtitleStyle()),
      ('subtitle_large_yellow',
          const SubtitleStyle(size: 'gross', color: 'gelb')),
      ('subtitle_xlarge_yellow_box',
          const SubtitleStyle(size: 'sehrgross', color: 'gelb', box: true)),
      ('subtitle_small_cyan_nooutline',
          const SubtitleStyle(size: 'klein', color: 'cyan', outline: false)),
    ]) {
      await pumpPlayer(tester, _FakePlayer(sub: s));
      await _shot(tester, name);
    }
  });

  // Phone (Hochformat-Player quer, 2,75 dpr): gleiche Proportionen.
  testWidgets('Player: Untertitel groß/gelb auf dem Handy', skip: skip,
      (tester) async {
    tester.view.physicalSize = const Size(2400, 1080);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(RepaintBoundary(
      key: tvShotKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(tv: false),
        home: const Scaffold(
            body: _FakePlayer(
                sub: SubtitleStyle(size: 'gross', color: 'gelb'))),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    await _shot(tester, 'subtitle_large_yellow_phone');
  });
}
