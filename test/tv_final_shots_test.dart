import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:jason_stream_player/core/secret_store.dart';
import 'package:jason_stream_player/core/theme.dart';
import 'package:jason_stream_player/data/recordings/recordings.dart';
import 'package:jason_stream_player/data/storage.dart';
import 'package:jason_stream_player/l10n/strings.dart';
import 'package:jason_stream_player/models/models.dart';
import 'package:jason_stream_player/state/my_groups.dart';
import 'package:jason_stream_player/state/providers.dart';
import 'package:jason_stream_player/state/vod_library.dart';
import 'package:jason_stream_player/ui/guide/guide_screen.dart';
import 'package:jason_stream_player/ui/live/live_screen.dart';
import 'package:jason_stream_player/ui/player/player_screen.dart';
import 'package:jason_stream_player/ui/player/zap_bar.dart';
import 'package:jason_stream_player/ui/settings/profile_modes.dart';
import 'package:jason_stream_player/ui/shell/home_shell.dart';
import 'package:jason_stream_player/ui/tv/tv_safe.dart';
import 'package:jason_stream_player/ui/vod/vod_screen.dart';
import 'package:jason_stream_player/ui/widgets/live_preview.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/app_fonts.dart';

/// Bildschirmfotos der echten TV-Oberfläche (Shell mit Leiste, sicherer
/// Bereich wie in app.dart) bei 1920×1080 / dpr 2. Läuft nur mit
/// `TV_SHOTS=ordner` (schreibt PNGs dorthin), sonst übersprungen.

final _shotDir = Platform.environment['TV_SHOTS'];

// ---------- Testdaten ----------
const _cats = [
  Category(id: 'ev', name: 'StreamTV · Live Events'),
  Category(id: 'free', name: 'DE · FreeTV/HD+ · RAW'),
  Category(id: 'sky', name: 'DE · Sky · HD'),
  Category(id: 'doku', name: 'DE · Doku'),
  Category(id: 'sport', name: 'DE · Sport'),
  Category(id: 'kids', name: 'DE · Kinder'),
  Category(id: 'at', name: 'AT · Österreich'),
  Category(id: 'ch', name: 'CH · Schweiz'),
];

const _names = [
  ('Welcome Channel', 'ev'),
  ('StreamTV Live Event 1', 'ev'),
  ('StreamTV Live Event 2', 'ev'),
  ('ZDF HD', 'free'),
  ('Das Erste HD', 'free'),
  ('RTL HD', 'free'),
  ('ProSieben HD', 'free'),
  ('SAT.1 HD', 'free'),
  ('VOX HD', 'free'),
  ('kabel eins HD', 'free'),
  ('3sat HD', 'free'),
  ('arte HD', 'doku'),
  ('phoenix HD', 'doku'),
  ('n-tv HD', 'free'),
  ('WELT HD', 'free'),
  ('Sky Cinema Premieren HD', 'sky'),
  ('Sky Sport Bundesliga 1 UHD', 'sport'),
  ('DAZN 1 HD', 'sport'),
  ('KiKA HD', 'kids'),
  ('ORF 1 HD', 'at'),
  ('SRF 1 HD', 'ch'),
];

final _channels = [
  for (var i = 0; i < _names.length; i++)
    Channel(
      id: 'c$i',
      name: _names[i].$1,
      categoryId: _names[i].$2,
      streamUrl: 'http://s/$i',
      number: i + 1,
      catchupDays: i % 3 == 0 ? 7 : 0,
    ),
];

const _titles = [
  ('UFC oder WWE – Live-Übertragungen', 'Sport'),
  ('heute journal', 'Nachrichten'),
  ('Tagesthemen', 'Nachrichten'),
  ('Wer wird Millionär?', 'Show'),
  ('The Masked Singer', 'Show'),
  ('Navy CIS', 'Krimi'),
  ('Die Höhle der Löwen', 'Show'),
  ('Bundesliga Konferenz', 'Sport'),
  ('Markus Lanz', 'Talk'),
];

Map<String, List<EpgEntry>> _epg(DateTime now) {
  final base = DateTime(now.year, now.month, now.day, now.hour);
  final m = <String, List<EpgEntry>>{};
  for (var i = 0; i < _channels.length; i++) {
    if (i == 9) continue; // ein Sender ohne Programm
    final key = '@c$i';
    final start = base.subtract(Duration(minutes: 15 * (i % 4)));
    final (t, g) = _titles[i % _titles.length];
    final (t2, _) = _titles[(i + 3) % _titles.length];
    m[key] = [
      EpgEntry(
          channelEpgId: key,
          title: t,
          genre: g,
          description:
              'Live-Kämpfe der Nacht mit Vorberichten, Interviews und Analyse. '
              'Danach: Highlights des Wochenendes und ein Ausblick auf die '
              'kommenden Events – präsentiert vom Studio-Team.',
          start: start,
          end: start.add(Duration(minutes: 60 + 15 * (i % 3)))),
      EpgEntry(
          channelEpgId: key,
          title: t2,
          start: start.add(Duration(minutes: 60 + 15 * (i % 3))),
          end: start.add(Duration(minutes: 150))),
    ];
  }
  return m;
}

const _flags = ChannelFlags({'c1', 'c3', 'c4', 'c6', 'c11', 'c16'}, {}, {'c7'});
const _recent = ['c1', 'c3', 'c5', 'c15', 'c12', 'c8'];
const _myGroups = [
  MyGroup('my_1', 'Fußball', ['c16', 'c17'])
];

const _movieNames = [
  'Dune: Part Two',
  'Oppenheimer',
  'Der Schuh des Manitu',
  'Im Westen nichts Neues',
  'Barbie',
  'John Wick: Kapitel 4',
  'Das Boot',
  'Lola rennt',
  'Toni Erdmann',
  'Inception',
  'Interstellar',
  'Good Bye, Lenin!',
];

List<VodItem> _vod(bool series) => [
      for (var i = 0; i < _movieNames.length; i++)
        VodItem(
          id: '${series ? 's' : 'm'}$i',
          name: series ? 'Serie ${_movieNames[i]}' : _movieNames[i],
          categoryId: i.isEven ? 'action' : 'drama',
          streamUrl: 'http://v/$i',
          rating: 6 + (i % 4) * 0.7,
          year: 1990 + i * 3,
          genre: i.isEven ? 'Action' : 'Drama',
          plot: 'Ein junger Mann zieht in die Wüste, um sein Volk zu rächen '
              'und eine Prophezeiung zu erfüllen.',
          duration: Duration(minutes: 95 + i * 7),
          added: DateTime(2026, 1, 1 + i),
          isSeries: series,
        ),
    ];

const _vodCats = [
  Category(id: 'action', name: 'Action'),
  Category(id: 'drama', name: 'Drama'),
];

final _lib = VodLibrary({
  'm:m1',
  'm:m4',
  's:s2'
}, [
  VodHistoryEntry(false, 'm0', DateTime(2026, 10, 19)),
  VodHistoryEntry(true, 's1', DateTime(2026, 10, 18),
      episodeId: 'e1', season: 2, episode: 3),
  VodHistoryEntry(false, 'm5', DateTime(2026, 10, 17)),
  VodHistoryEntry(false, 'm7', DateTime(2026, 10, 16)),
]);

// ---------- Fakes ----------
class _Live extends LiveNotifier {
  @override
  Future<LiveData> build() async => LiveData(_cats, _channels);
}

class _Epg extends EpgNotifier {
  final Map<String, List<EpgEntry>> data;
  _Epg(this.data);
  @override
  Future<Map<String, List<EpgEntry>>> build() async => data;
  @override
  void want(Channel c) {}
}

class _Flags extends ChannelFlagsNotifier {
  @override
  Future<ChannelFlags> build() async => _flags;
}

class _Sort extends SortOrderNotifier {
  @override
  Future<SortOrder> build() async => SortOrder.empty;
}

class _Recent extends RecentNotifier {
  @override
  Future<List<String>> build() async => _recent;
}

class _Groups extends MyGroupsNotifier {
  @override
  Future<List<MyGroup>> build() async => _myGroups;
}

class _Lib extends VodLibraryNotifier {
  @override
  Future<VodLibrary> build() async => _lib;
}

class _Vod extends VodNotifier {
  _Vod(super.series);
  @override
  Future<VodData> build() async => VodData(_vodCats, _vod(series));
}


class _Active extends ActivePortalNotifier {
  @override
  Future<Portal?> build() async => Portal.demo;
}

class _Portals extends PortalsNotifier {
  @override
  Future<List<Portal>> build() async => const [Portal.demo];
}

class _Recs extends RecordingsNotifier {
  @override
  List<Recording> build() => const [];
}

class _NoPreview extends LivePreviewController {
  _NoPreview(super.ref);
  @override
  Future<void> play(Object owner, Channel c) async {}
}

final _shotKey = GlobalKey();

List<Override> _overrides(Future<Storage> storage) => [
      isTvProvider.overrideWithValue(true),
      storageProvider.overrideWith((ref) => storage),
      activePortalProvider.overrideWith(_Active.new),
      portalsProvider.overrideWith(_Portals.new),
      liveDataProvider.overrideWith(_Live.new),
      epgProvider.overrideWith(() => _Epg(_epg(DateTime.now()))),
      channelFlagsProvider.overrideWith(_Flags.new),
      sortOrderProvider.overrideWith(_Sort.new),
      recentProvider.overrideWith(_Recent.new),
      myGroupsProvider.overrideWith(_Groups.new),
      vodLibraryProvider.overrideWith(_Lib.new),
      moviesProvider.overrideWith(() => _Vod(false)),
      seriesProvider.overrideWith(() => _Vod(true)),
      recordingsProvider.overrideWith(_Recs.new),
      minuteTickProvider.overrideWith((ref) => Stream.value(DateTime.now())),
      livePreviewEnabledProvider.overrideWith((ref) async => false),
      livePreviewProvider.overrideWith(_NoPreview.new),
    ];

/// Wie app.dart (TV): sicherer Bereich im Builder, Seitenübergänge im Theme.
Future<void> _pumpApp(WidgetTester tester, Widget home,
    {Future<Storage>? storage}) async {
  tester.view.physicalSize = const Size(1920, 1080);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    overrides: _overrides(storage ?? Future.value(_storage)),
    child: RepaintBoundary(
      key: _shotKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(tv: true).copyWith(
            pageTransitionsTheme: TvSafePageTransitionsBuilder.theme()),
        builder: (context, child) =>
            TvSafeMediaQuery(enabled: true, child: child!),
        home: home,
      ),
    ),
  ));
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _key(WidgetTester tester, LogicalKeyboardKey k) async {
  await tester.sendKeyEvent(k);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

List<FocusNode> _rail(WidgetTester tester) =>
    // ignore: invalid_use_of_visible_for_testing_member
    (tester.state(find.byType(HomeShell)) as dynamic).debugRailNodes
        as List<FocusNode>;

/// Über die Leiste zu einem Reiter und mit ▶ in den Inhalt.
Future<void> _tab(WidgetTester tester, int i) async {
  _rail(tester)[i].requestFocus();
  await tester.pump(const Duration(milliseconds: 300));
  await _key(tester, LogicalKeyboardKey.arrowRight);
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _done(WidgetTester tester) async {
  expect(tester.takeException(), isNull);
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 5));
}

late Storage _storage;

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    L10n.lang = 'de';
    await initializeDateFormatting('de');
    await loadAppFonts();
  });

  setUp(() async {
    L10n.lang = 'de';
    SharedPreferences.setMockInitialValues({
      'resume_movie_m0': '2400/6000',
      'resume_movie_m5': '600/6000',
      'resume_ep_e1': '900/2700',
      'set_applang': 'de',
      'set_kidsgroups_${Portal.demo.id}': ['kids', 'free', 'my_1'],
      'set_kidsvod_${Portal.demo.id}': ['m:drama', 's:drama'],
    });
    _storage = await Storage.open(store: PreviewSecretStore());
  });

  final skip = _shotDir == null ? 'nur mit TV_SHOTS=ordner' : null;

  testWidgets('Startseite, Live TV, TV-Guide, Filme', skip: skip != null,
      (tester) async {
    await _pumpApp(tester, const HomeShell());
    await writeShot(tester, _shotKey, 'home');

    await _tab(tester, 1);
    expect(find.byType(LiveScreen), findsOneWidget);
    await _key(tester, LogicalKeyboardKey.arrowDown);
    await writeShot(tester, _shotKey, 'live_tv');

    await _tab(tester, 2);
    expect(find.byType(GuideScreen), findsOneWidget);
    await _key(tester, LogicalKeyboardKey.arrowDown);
    await _key(tester, LogicalKeyboardKey.arrowDown);
    await writeShot(tester, _shotKey, 'guide');

    await _tab(tester, 3);
    expect(find.byType(VodScreen), findsOneWidget);
    await writeShot(tester, _shotKey, 'movies');
    await _done(tester);
  });

  testWidgets('Kindermodus: Einrichtung und gesperrte Einstellungen',
      skip: skip != null, (tester) async {
    await _pumpApp(tester, const HomeShell());
    Navigator.of(tester.element(find.byType(HomeShell)))
        .push(MaterialPageRoute<void>(builder: (_) => const KidsModeScreen()));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.byType(KidsModeScreen), findsOneWidget);
    await writeShot(tester, _shotKey, 'kids_mode_setup');
    Navigator.of(tester.element(find.byType(KidsModeScreen))).pop();
    await tester.pumpAndSettle(const Duration(milliseconds: 100));

    await _storage.setFlag(Storage.kidsFlag, true);
    final c = ProviderScope.containerOf(tester.element(find.byType(HomeShell)));
    c.invalidate(storageProvider);
    await tester.pump(const Duration(milliseconds: 300));
    _rail(tester)[6].requestFocus();
    await tester.pump(const Duration(milliseconds: 300));
    await _key(tester, LogicalKeyboardKey.arrowRight);
    expect(find.byType(KidsSettingsLock), findsOneWidget);
    await writeShot(tester, _shotKey, 'kids_settings_locked');
    await _done(tester);
  });

  testWidgets('Player mit Zapping-Leiste', skip: skip != null,
      (tester) async {
    // Speicher antwortet nie → kein echter Player, nur die Oberfläche.
    final never = Completer<Storage>();
    await _pumpApp(
      tester,
      PlayerScreen(
          request: PlayRequest(
              title: _channels[3].name,
              url: _channels[3].streamUrl,
              isLive: true,
              channels: _channels,
              channel: _channels[3])),
      storage: never.future,
    );
    final c =
        ProviderScope.containerOf(tester.element(find.byType(PlayerScreen)));
    c.read(liveDataProvider);
    c.read(channelFlagsProvider);
    await tester.pump(const Duration(milliseconds: 100));
    await _key(tester, LogicalKeyboardKey.arrowDown); // Bedienelemente
    await tester.pump(const Duration(seconds: 6));
    await _key(tester, LogicalKeyboardKey.arrowRight); // Vorschau ZDF → Erste
    expect(find.byType(ZapBar), findsOneWidget);
    await writeShot(tester, _shotKey, 'player_zap_bar');
    await _done(tester);
  });
}
