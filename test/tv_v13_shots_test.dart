import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:jason_stream_player/core/secret_store.dart';
import 'package:jason_stream_player/data/storage.dart';
import 'package:jason_stream_player/l10n/strings.dart';
import 'package:jason_stream_player/models/models.dart';
import 'package:jason_stream_player/state/providers.dart';
import 'package:jason_stream_player/ui/guide/guide_screen.dart';
import 'package:jason_stream_player/ui/live/live_screen.dart';
import 'package:jason_stream_player/ui/player/player_screen.dart';
import 'package:jason_stream_player/ui/portals/add_portal_screen.dart';
import 'package:jason_stream_player/ui/settings/country_filter_screen.dart';
import 'package:jason_stream_player/ui/shell/home_shell.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/app_fonts.dart';
import 'helpers/tv_harness.dart';

/// Bildschirmfotos der 1.3-Neuerungen (TV, 1920×1080, dpr 2, echte
/// Schriften): Varianten, Live-Pause, Wiederverbinden, Portal „Erweitert“,
/// Länderfilter, Guide-Tagesauswahl. Nur mit `TV_SHOTS=ordner`.

final _shotDir = Platform.environment['TV_SHOTS'];

const _cats = [
  Category(id: 'de', name: 'DE | Vollprogramm'),
  Category(id: 'sport', name: 'DE | Sport'),
  Category(id: 'tr', name: 'TR | Ulusal'),
  Category(id: 'uk', name: 'UK: Entertainment'),
  Category(id: 'at', name: 'AT · Österreich'),
];

const _names = [
  ('Das Erste HD', 'de'), ('Das Erste FHD', 'de'), ('Das Erste SD', 'de'),
  ('ZDF HD', 'de'), ('DE: ZDF FHD', 'de'), ('ZDF ᴴᴰ (Backup)', 'de'),
  ('ZDFneo HD', 'de'), ('RTL HD', 'de'), ('RTL FHD', 'de'),
  ('ProSieben HD', 'de'), ('ProSieben Maxx HD', 'de'), ('VOX', 'de'),
  ('Sky Sport 1 HD', 'sport'), ('Sky Sport 1 UHD', 'sport'),
  ('Sky Sport 2 HD', 'sport'), ('DAZN 1 FHD', 'sport'),
  ('TR: TRT 1', 'tr'), ('TR: TRT 1 HD', 'tr'), ('TR: ATV HD', 'tr'),
  ('TR: ATV Avrupa', 'tr'), ('TR: Kanal D', 'tr'),
  ('UK: BBC One HD', 'uk'), ('UK: BBC One FHD', 'uk'),
  ('ORF 1 HD', 'at'), ('ORF 1 FHD', 'at'),
];

final _channels = [
  for (var i = 0; i < _names.length; i++)
    Channel(
      id: 'c$i',
      name: _names[i].$1,
      categoryId: _names[i].$2,
      streamUrl: 'http://s/$i',
      number: i + 1,
      catchupDays: i % 4 == 0 ? 7 : 0,
    ),
];

const _titles = [
  'Tagesschau', 'heute journal', 'Bundesliga Konferenz', 'Tatort',
  'Wer wird Millionär?', 'Navy CIS', 'Die Höhle der Löwen', 'Markus Lanz',
  'Sportschau', 'Kurtlar Vadisi', 'EastEnders', 'Zeit im Bild',
];

Map<String, List<EpgEntry>> _epg(DateTime now) {
  final start = DateTime(now.year, now.month, now.day)
      .subtract(const Duration(days: 2));
  return {
    for (var i = 0; i < _channels.length; i++)
      '@c$i': [
        for (var p = 0; p < 6 * 24 ~/ 1.5; p++)
          EpgEntry(
            channelEpgId: '@c$i',
            title: _titles[(i + p) % _titles.length],
            description: 'Aktuelle Ausgabe mit Berichten, Interviews und '
                'Hintergründen.',
            start: start.add(Duration(minutes: 90 * p + 15 * (i % 3))),
            end: start.add(Duration(minutes: 90 * (p + 1) + 15 * (i % 3))),
          ),
      ],
  };
}

late Storage _storage;

TvData get _data => TvData(
      live: LiveData(_cats, _channels),
      epg: _epg(DateTime.now()),
      flags: const ChannelFlags({'c0', 'c3', 'c12'}, {}, {}),
      recent: const ['c3', 'c0', 'c16'],
    );

List<FocusNode> _rail(WidgetTester tester) =>
    // ignore: invalid_use_of_visible_for_testing_member
    (tester.state(find.byType(HomeShell)) as dynamic).debugRailNodes
        as List<FocusNode>;

Future<void> _tab(WidgetTester tester, int i) async {
  _rail(tester)[i].requestFocus();
  await tester.pump(const Duration(milliseconds: 300));
  await tvKey(tester, LogicalKeyboardKey.arrowRight);
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _shot(WidgetTester tester, String name) =>
    writeShot(tester, tvShotKey, name);

Future<void> _openPlayer(WidgetTester tester, Channel c) async {
  final never = Completer<Storage>();
  await pumpTv(
      tester,
      PlayerScreen(
          request: PlayRequest(
              title: c.name,
              url: c.streamUrl,
              isLive: true,
              channels: _channels,
              channel: c)),
      _data,
      never.future);
  final ct = ProviderScope.containerOf(tester.element(find.byType(PlayerScreen)));
  ct.read(liveDataProvider);
  ct.read(channelFlagsProvider);
  await tester.pump(const Duration(milliseconds: 200));
  await tester.pump(const Duration(milliseconds: 200));
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    L10n.lang = 'de';
    await initializeDateFormatting('de');
    await loadAppFonts();
  });

  setUp(() async {
    L10n.lang = 'de';
    SharedPreferences.setMockInitialValues({'set_applang': 'de'});
    _storage = await Storage.open(store: PreviewSecretStore());
  });

  final skip = _shotDir == null;

  testWidgets('Live TV mit Varianten-Hinweis', skip: skip, (tester) async {
    await pumpTv(tester, const HomeShell(), _data, Future.value(_storage));
    await _tab(tester, 1);
    expect(find.byType(LiveScreen), findsOneWidget);
    await tvKey(tester, LogicalKeyboardKey.arrowDown);
    expect(find.text('3 Varianten'), findsWidgets);
    await _shot(tester, 'v13_live_variants');
    await tvDone(tester);
  });

  testWidgets('Player: Variantenauswahl', skip: skip, (tester) async {
    await _openPlayer(tester, _channels[4]); // ZDF FHD (Vertreter)
    final btn = find.byKey(const ValueKey('variant-btn'));
    expect(btn, findsOneWidget);
    await tester.tap(btn);
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Qualität/Quelle wählen'), findsWidgets);
    await _shot(tester, 'v13_player_variant_picker');
    await tvDone(tester);
  });

  testWidgets('Player: Live-Pause (zeitversetzt)', skip: skip, (tester) async {
    PlayerScreen.debugTimeshiftBehind = const Duration(minutes: 4, seconds: 37);
    addTearDown(() => PlayerScreen.debugTimeshiftBehind = null);
    await _openPlayer(tester, _channels[0]);
    await tvKey(tester, LogicalKeyboardKey.arrowDown);
    expect(find.text('−4:37 zeitversetzt'), findsOneWidget);
    expect(find.text('Zurück zu Live'), findsOneWidget);
    await _shot(tester, 'v13_player_timeshift');
    // Ohne Bedienelemente: Hinweis oben links.
    await tester.pump(const Duration(seconds: 7));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('timeshift-status')), findsOneWidget);
    await _shot(tester, 'v13_player_timeshift_pill');
    await tvDone(tester);
  });

  testWidgets('Player: Wiederverbinden', skip: skip, (tester) async {
    PlayerScreen.debugStatus = tr('Verbindung wird wiederhergestellt …');
    addTearDown(() => PlayerScreen.debugStatus = null);
    await _openPlayer(tester, _channels[3]);
    await tvKey(tester, LogicalKeyboardKey.arrowDown);
    await tester.pump(const Duration(seconds: 7)); // Bedienelemente weg
    await tester.pump(const Duration(milliseconds: 400)); // Ausblenden
    expect(find.byKey(const ValueKey('player-status')), findsOneWidget);
    await _shot(tester, 'v13_player_reconnect');
    await tvDone(tester);
  });

  testWidgets('Portal bearbeiten: Erweitert', skip: skip, (tester) async {
    const p = Portal(
      id: 'px',
      name: 'Mein Anbieter',
      type: PortalType.xtream,
      url: 'http://main.example:8080',
      username: 'jason',
      password: 'geheim',
      userAgent: 'VLC/3.0.20 LibVLC/3.0.20',
      referer: 'http://portal.example/',
      altUrls: ['http://backup1.example:8080', 'http://backup2.example:2095'],
      autoRefreshHours: 12,
    );
    await pumpTv(tester, const AddPortalScreen(edit: p), _data,
        Future.value(_storage));
    final adv = find.byKey(const ValueKey('portal-advanced'));
    await tester.scrollUntilVisible(adv, 300,
        scrollable: find.byType(Scrollable).first);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -260));
    await tester.pumpAndSettle();
    expect(find.text('Ersatz-Adressen'), findsOneWidget);
    await _shot(tester, 'v13_portal_advanced');
    await tvDone(tester);
  });

  testWidgets('Länder anzeigen', skip: skip, (tester) async {
    await _storage.setCountries(Portal.demo.id, {'DE', 'TR'});
    await pumpTv(tester, const CountryFilterScreen(), _data,
        Future.value(_storage));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Deutschland'), findsOneWidget);
    await tvKey(tester, LogicalKeyboardKey.arrowDown);
    await _shot(tester, 'v13_country_filter');
    await tvDone(tester);
  });

  testWidgets('TV-Guide mit Tagesauswahl', skip: skip, (tester) async {
    await pumpTv(tester, const HomeShell(), _data, Future.value(_storage));
    await _tab(tester, 2);
    expect(find.byType(GuideScreen), findsOneWidget);
    // Zur Tagesauswahl (Chip „Heute“) und öffnen.
    final day = find.text('Heute');
    expect(day, findsWidgets);
    // Fokus auf den Chip, OK öffnet (TV-Bedienung).
    Focus.of(tester.element(day.first)).requestFocus();
    await tester.pump(const Duration(milliseconds: 200));
    await tvKey(tester, LogicalKeyboardKey.select);
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.text('Tag wählen'), findsOneWidget);
    await _shot(tester, 'v13_guide_day_picker');
    // „Morgen“ wählen → Raster zeigt morgen.
    await tvKey(tester, LogicalKeyboardKey.arrowRight);
    await tvKey(tester, LogicalKeyboardKey.select);
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    await tvKey(tester, LogicalKeyboardKey.arrowDown);
    expect(find.text('Morgen'), findsWidgets);
    await _shot(tester, 'v13_guide_tomorrow');
    await tvDone(tester);
  });
}
