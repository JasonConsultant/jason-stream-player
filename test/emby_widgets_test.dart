import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:jason_stream_player/core/secret_store.dart';
import 'package:jason_stream_player/core/theme.dart';
import 'package:jason_stream_player/data/emby/emby_client.dart';
import 'package:jason_stream_player/data/storage.dart';
import 'package:jason_stream_player/l10n/strings.dart';
import 'package:jason_stream_player/models/models.dart';
import 'package:jason_stream_player/state/emby.dart';
import 'package:jason_stream_player/state/profile_mode.dart';
import 'package:jason_stream_player/state/providers.dart';
import 'package:jason_stream_player/ui/home/home_screen.dart';
import 'package:jason_stream_player/ui/settings/emby_settings_screen.dart';
import 'package:jason_stream_player/ui/settings/profile_modes.dart';
import 'package:jason_stream_player/ui/tv/tv_safe.dart';
import 'package:jason_stream_player/ui/vod/series_detail_screen.dart';
import 'package:jason_stream_player/ui/vod/vod_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/app_fonts.dart';
import 'helpers/fake_emby.dart';
import 'helpers/tv_harness.dart';

/// Emby in der Oberfläche: Einstellungsseite (auch mit der Fernbedienung),
/// Quellen-Umschalter in Filme/Serien, Kindermodus-Freigaben. Mit
/// `TV_SHOTS=ordner` zusätzlich Bildschirmfotos.

final _shotDir = Platform.environment['TV_SHOTS'];

class _EmbyVod extends EmbyVodNotifier {
  final VodData d;
  _EmbyVod(super.series, this.d);
  @override
  Future<VodData> build() async => d;
}

VodItem _m(String id, String name, String cat,
        {int? year, double? rating, String? genre, bool series = false,
        Duration? pos, bool played = false}) =>
    VodItem(
      id: 'emby_$id',
      name: name,
      categoryId: cat,
      streamUrl: '',
      year: year,
      rating: rating,
      genre: genre,
      isSeries: series,
      duration: series ? null : const Duration(minutes: 128),
      plot: 'Aus der eigenen Mediathek – direkt vom Emby-Server.',
      source: VodSource.emby,
      serverPosition: pos,
      serverPlayed: played,
      added: DateTime(2026, 10, 1),
    );

final _embyMovies = VodData(const [
  Category(id: 'emby_v1', name: 'Filme'),
  Category(id: 'emby_v4', name: 'Kinder'),
], [
  _m('m0', 'Der Pate', 'emby_v1', year: 1972, rating: 9.2, genre: 'Drama, Krimi',
      pos: const Duration(minutes: 60)),
  _m('m1', 'Interstellar', 'emby_v1', year: 2014, rating: 8.7, genre: 'Science-Fiction', played: true),
  _m('m2', 'Das Boot', 'emby_v1', year: 1981, rating: 8.4, genre: 'Krieg, Drama'),
  _m('m3', 'Lola rennt', 'emby_v1', year: 1998, rating: 7.7, genre: 'Thriller'),
  _m('m4', 'Good Bye, Lenin!', 'emby_v1', year: 2003, rating: 7.7, genre: 'Komödie'),
  _m('m5', 'Inception', 'emby_v1', year: 2010, rating: 8.8, genre: 'Science-Fiction'),
  _m('m6', 'Die Welle', 'emby_v1', year: 2008, rating: 7.5, genre: 'Drama'),
  _m('m7', 'Der Untergang', 'emby_v1', year: 2004, rating: 8.2, genre: 'Drama'),
  _m('m8', 'Toni Erdmann', 'emby_v1', year: 2016, rating: 7.4, genre: 'Komödie'),
  _m('m9', 'Das Leben der Anderen', 'emby_v1', year: 2006, rating: 8.4, genre: 'Drama'),
  _m('m10', 'Die Sendung mit der Maus', 'emby_v4', year: 2020, genre: 'Kinder'),
  _m('m11', 'Das Sams', 'emby_v4', year: 2001, genre: 'Kinder'),
]);

final _embySeries = VodData(const [
  Category(id: 'emby_v2', name: 'Serien'),
], [
  _m('s0', 'Dark', 'emby_v2', year: 2017, rating: 8.7, genre: 'Mystery, Drama', series: true),
  _m('s1', 'Babylon Berlin', 'emby_v2', year: 2017, rating: 8.4, genre: 'Krimi', series: true),
  _m('s2', 'Tatort', 'emby_v2', year: 1970, rating: 7.0, genre: 'Krimi', series: true),
]);

const _portalMovies = VodData([
  Category(id: 'p1', name: 'Portal-Filme'),
], [
  VodItem(id: '1', name: 'Portal-Film Eins', categoryId: 'p1', streamUrl: 'http://s/1', year: 2020, rating: 7),
  VodItem(id: '2', name: 'Portal-Film Zwei', categoryId: 'p1', streamUrl: 'http://s/2', year: 2021, rating: 6),
]);

void main() {
  late Storage storage;
  late FakeEmby fake;

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
    fake = FakeEmby(movieCount: 3)..images = false;
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
    addTearDown(() => FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.automatic);
  });

  Future<void> signedIn() => storage.setEmbyAccount(const EmbyAccount(
        server: 'http://emby.local:8096',
        userName: 'Jason',
        userId: FakeEmby.userId,
        token: FakeEmby.token,
        serverName: 'Jasons Mediathek',
        serverVersion: '4.8.10.0',
      ));

  Future<void> pump(WidgetTester tester, Widget home,
      {bool tv = true,
      VodData movies = _portalMovies,
      List<Override> extra = const [],
      Size? size}) async {
    tester.view.physicalSize = size ?? const Size(1920, 1080);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final data = TvData(
        live: const LiveData([], []), movies: movies);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        ...tvOverrides(data, Future.value(storage), tv: tv),
        embyHttpClientProvider.overrideWithValue(fake.client),
        embyDeviceProvider.overrideWith((ref) async => const EmbyDevice(
            name: 'NVIDIA SHIELD Android TV', id: 'jsp-test', version: '1.6.0')),
        embyMoviesProvider.overrideWith(() => _EmbyVod(false, _embyMovies)),
        embySeriesProvider.overrideWith(() => _EmbyVod(true, _embySeries)),
        ...extra,
      ],
      child: RepaintBoundary(
        key: tvShotKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          // Wie app.dart: OK der Fernbedienung löst Knöpfe aus.
          shortcuts: {
            ...WidgetsApp.defaultShortcuts,
            const SingleActivator(LogicalKeyboardKey.select):
                const ActivateIntent(),
          },
          theme: buildTheme(tv: tv).copyWith(
              pageTransitionsTheme: TvSafePageTransitionsBuilder.theme()),
          builder: (context, child) =>
              TvSafeMediaQuery(enabled: tv, child: child!),
          home: home,
        ),
      ),
    ));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  bool focusedIn(Key k) {
    final ctx = FocusManager.instance.primaryFocus?.context;
    if (ctx == null) return false;
    if (ctx.widget.key == k) return true;
    var hit = false;
    ctx.visitAncestorElements((e) {
      if (e.widget.key == k) {
        hit = true;
        return false;
      }
      return true;
    });
    return hit;
  }

  void setText(WidgetTester tester, Key k, String v) =>
      tester.widget<TextField>(find.byKey(k)).controller!.text = v;

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  void focusKey(WidgetTester tester, Key k) {
    Focus.of(tester.element(find
            .descendant(of: find.byKey(k), matching: find.byType(Text))
            .first))
        .requestFocus();
  }

  group('Einstellungen „Emby-Server“', () {
    testWidgets('D-Pad durch das Formular, falsches Passwort, Anmelden',
        (tester) async {
      await pump(tester, const EmbySettingsScreen());
      expect(focusedIn(const ValueKey('emby-url')), isTrue);
      await tvKey(tester, LogicalKeyboardKey.arrowDown);
      expect(focusedIn(const ValueKey('emby-user')), isTrue);
      await tvKey(tester, LogicalKeyboardKey.arrowDown);
      expect(focusedIn(const ValueKey('emby-pass')), isTrue);
      await tvKey(tester, LogicalKeyboardKey.arrowDown);
      expect(focusedIn(const ValueKey('emby-login')), isTrue);
      await tvKey(tester, LogicalKeyboardKey.arrowDown);
      expect(focusedIn(const ValueKey('emby-test')), isTrue);
      // ▲ zurück ins Formular (keine Falle).
      await tvKey(tester, LogicalKeyboardKey.arrowUp);
      expect(focusedIn(const ValueKey('emby-login')), isTrue);
      await tvKey(tester, LogicalKeyboardKey.arrowUp);
      expect(focusedIn(const ValueKey('emby-pass')), isTrue);

      setText(tester, const ValueKey('emby-url'), 'emby.local:8096');
      setText(tester, const ValueKey('emby-user'), FakeEmby.user);
      setText(tester, const ValueKey('emby-pass'), 'falsch');
      focusKey(tester, const ValueKey('emby-login'));
      await tester.pump();
      await tvKey(tester, LogicalKeyboardKey.select);
      await settle(tester);
      expect(find.text('Benutzername oder Passwort ist falsch.'), findsOneWidget);
      expect(storage.embyAccount(), isNull);

      // „Verbindung testen“ mit richtigem Passwort speichert nichts.
      setText(tester, const ValueKey('emby-pass'), FakeEmby.password);
      focusKey(tester, const ValueKey('emby-test'));
      await tester.pump();
      await tvKey(tester, LogicalKeyboardKey.select);
      await settle(tester);
      expect(find.textContaining('Verbindung OK: Jasons Mediathek'),
          findsOneWidget);
      expect(storage.embyAccount(), isNull);

      focusKey(tester, const ValueKey('emby-login'));
      await tester.pump();
      await tvKey(tester, LogicalKeyboardKey.select);
      await settle(tester);
      final acc = storage.embyAccount()!;
      expect(acc.signedIn, isTrue);
      expect(acc.server, 'http://emby.local:8096');
      expect(find.byKey(const ValueKey('emby-status')), findsOneWidget);
      expect(find.text('Angemeldet als Jason'), findsOneWidget);
      expect(find.textContaining('Emby 4.8.10.0'), findsOneWidget);
      // Fokus landet auf „Listen neu laden“, ▼ → Abmelden.
      expect(focusedIn(const ValueKey('emby-reload')), isTrue);
      await tvKey(tester, LogicalKeyboardKey.arrowDown);
      expect(focusedIn(const ValueKey('emby-logout')), isTrue);
      await tvKey(tester, LogicalKeyboardKey.select);
      await settle(tester);
      expect(fake.callsTo('/Sessions/Logout'), isNotEmpty);
      expect(storage.embyAccount()!.signedIn, isFalse);
      // Adresse und Benutzer bleiben, Fokus auf „Anmelden“.
      expect(tester.widget<TextField>(find.byKey(const ValueKey('emby-url')))
          .controller!.text, 'http://emby.local:8096');
      expect(focusedIn(const ValueKey('emby-login')), isTrue);
      await tvDone(tester);
    });

    testWidgets('Bitrate wählen (Handy)', (tester) async {
      await signedIn();
      await pump(tester, const EmbySettingsScreen(),
          tv: false, size: const Size(1080, 2200));
      await tester.tap(find.byKey(const ValueKey('emby-bitrate-10')));
      await settle(tester);
      expect(storage.option('embybitrate', 'auto'), '10');
      await tvDone(tester);
    });
  });

  group('Quellen-Umschalter Filme/Serien', () {
    testWidgets('ohne Emby kein Umschalter', (tester) async {
      await pump(tester, const Scaffold(body: VodScreen(series: false)));
      expect(find.byKey(const ValueKey('vod-source-emby')), findsNothing);
      expect(find.text('Portal-Film Eins'), findsWidgets);
      await tvDone(tester);
    });

    testWidgets('TV: D-Pad auf „Emby“, OK → Emby-Filme; ◀ zurück zu Portal',
        (tester) async {
      await signedIn();
      await pump(tester, const Scaffold(body: VodScreen(series: false)));
      expect(find.byKey(const ValueKey('vod-source-emby')), findsOneWidget);
      expect(find.text('FILME'), findsOneWidget);
      focusKey(tester, const ValueKey('vod-source-portal'));
      await tester.pump();
      await tvKey(tester, LogicalKeyboardKey.arrowRight);
      expect(focusedIn(const ValueKey('vod-source-emby')), isTrue);
      await tvKey(tester, LogicalKeyboardKey.select);
      await settle(tester);
      expect(find.text('EMBY · FILME'), findsOneWidget);
      expect(find.text('Der Pate'), findsWidgets);
      expect(find.text('Portal-Film Eins'), findsNothing);
      expect(storage.option('vodsrc_m', 'portal'), 'emby');
      // Fokus bleibt am Umschalter; ▼ führt in den Inhalt (keine Falle).
      expect(focusedIn(const ValueKey('vod-source-emby')), isTrue);
      await tvKey(tester, LogicalKeyboardKey.arrowDown);
      expect(focusedIn(const ValueKey('vod-source-emby')), isFalse);
      expect(FocusManager.instance.primaryFocus?.context, isNotNull);
      // Zurück zum Portal.
      focusKey(tester, const ValueKey('vod-source-emby'));
      await tester.pump();
      await tvKey(tester, LogicalKeyboardKey.arrowLeft);
      expect(focusedIn(const ValueKey('vod-source-portal')), isTrue);
      await tvKey(tester, LogicalKeyboardKey.select);
      await settle(tester);
      expect(find.text('Portal-Film Eins'), findsWidgets);
      expect(find.text('Der Pate'), findsNothing);
      await tvDone(tester);
    });

    testWidgets('Handy: Antippen wechselt, Portal ohne Inhalte bleibt bedienbar',
        (tester) async {
      await signedIn();
      await pump(tester, const Scaffold(body: VodScreen(series: true)),
          tv: false, size: const Size(1080, 2200));
      // Portal hat keine Serien → leere Seite, Umschalter trotzdem da.
      expect(find.text('Keine Serien'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('vod-source-emby')));
      await settle(tester);
      expect(find.text('Emby · Serien'), findsOneWidget);
      expect(find.text('Dark'), findsWidgets);
      expect(storage.option('vodsrc_s', 'portal'), 'emby');
      await tvDone(tester);
    });
  });

  testWidgets('Kindermodus: Emby-Mediatheken freigeben', (tester) async {
    await signedIn();
    await pump(tester, const KidsModeScreen(),
        tv: false, size: const Size(1080, 2400));
    await tester.scrollUntilVisible(
        find.byKey(const ValueKey('kids-emby-m:emby_v4')), 200);
    await tester.tap(find.byKey(const ValueKey('kids-emby-m:emby_v4')));
    await settle(tester);
    expect(storage.kidsVod(embyScope), {'m:emby_v4'});
    final c = ProviderScope.containerOf(
        tester.element(find.byType(KidsModeScreen)));
    expect(c.read(profileModeProvider).kidsEmby, {'m:emby_v4'});
    await tvDone(tester);
  });

  // ------------------------------------------------------------ Fotos
  group('Bildschirmfotos', skip: _shotDir == null, () {
    Future<void> shot(WidgetTester tester, String name) =>
        writeShot(tester, tvShotKey, name);

    testWidgets('Einstellungen: Formular und verbunden', (tester) async {
      // Wie nach dem Wiederherstellen einer Sicherung: Adresse und
      // Benutzer stehen schon da, nur das Passwort fehlt.
      await storage.setEmbyAccount(const EmbyAccount(
          server: 'http://192.168.178.20:8096', userName: 'jason'));
      await pump(tester, const EmbySettingsScreen());
      setText(tester, const ValueKey('emby-pass'), 'geheim');
      // Feld kurz fokussieren, damit die Beschriftung nach oben rückt.
      focusKey(tester, const ValueKey('emby-pass'));
      await tester.pump(const Duration(milliseconds: 400));
      focusKey(tester, const ValueKey('emby-login'));
      await tester.pump(const Duration(milliseconds: 400));
      await shot(tester, 'emby_settings_form');
      focusKey(tester, const ValueKey('emby-login'));
      await tester.pump();
      await tvKey(tester, LogicalKeyboardKey.select);
      await settle(tester);
      await shot(tester, 'emby_settings_connected');
      await tvDone(tester);
    });

    testWidgets('Emby-Filme (Raster)', (tester) async {
      await signedIn();
      await storage.setOption('vodsrc_m', 'emby');
      await pump(tester, const Scaffold(body: VodScreen(series: false)));
      await shot(tester, 'emby_movies_discover');
      // Mediathek „Filme“ als Raster.
      await tester.tap(find.text('Filme').last);
      await settle(tester);
      await shot(tester, 'emby_movies_grid');
      await tvDone(tester);
    });

    testWidgets('Emby-Serie mit Staffeln', (tester) async {
      await signedIn();
      await pump(tester, SeriesDetailScreen(series: _embySeries.items.first));
      await settle(tester);
      expect(find.byKey(const ValueKey('season-tab-1')), findsOneWidget);
      await shot(tester, 'emby_series_detail');
      await tvDone(tester);
    });

    testWidgets('Startseite mit Emby-Reihen', (tester) async {
      await signedIn();
      await pump(tester, Scaffold(body: HomeScreen(onOpenTab: (_) {})),
          extra: [
            embyResumeProvider.overrideWith((ref) async => [
                  _embyMovies.items[0],
                  _embySeries.items[0],
                  _embyMovies.items[5],
                ]),
            embyLatestProvider.overrideWith((ref) async => [
                  ..._embyMovies.items.skip(1).take(6),
                  _embySeries.items[1],
                ]),
          ]);
      expect(find.byKey(const ValueKey('home-emby-resume')), findsOneWidget);
      expect(find.byKey(const ValueKey('home-emby-latest')), findsOneWidget);
      await shot(tester, 'emby_home_rows');
      await tvDone(tester);
    });
  });
}
