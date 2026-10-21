import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override, ProviderListenable;
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:jason_stream_player/core/secret_store.dart';
import 'package:jason_stream_player/core/theme.dart';
import 'package:jason_stream_player/data/storage.dart';
import 'package:jason_stream_player/l10n/strings.dart';
import 'package:jason_stream_player/models/models.dart';
import 'package:jason_stream_player/state/my_groups.dart';
import 'package:jason_stream_player/state/profile_mode.dart';
import 'package:jason_stream_player/state/providers.dart';
import 'package:jason_stream_player/state/vod_library.dart';
import 'package:jason_stream_player/ui/home/home_screen.dart';
import 'package:jason_stream_player/ui/settings/profile_modes.dart';
import 'package:jason_stream_player/ui/tv/tv_safe.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/app_fonts.dart';

/// Kinder- und Gastmodus: Filter (Live, eigene Gruppen, Filme/Serien),
/// PIN zum Ein- und Ausschalten, Gastmodus speichert nichts und blendet
/// Verlauf/Favoriten/Weiterschauen aus.
///
/// Mit `TV_SHOTS=ordner` wird zusätzlich tv_kids_mode.png geschrieben.

const _portal = Portal.demo;
final _pid = _portal.id;

const _cats = [
  Category(id: 'kids', name: 'Kinder'),
  Category(id: 'news', name: 'Nachrichten'),
  Category(id: 'adult', name: 'Erwachsene'),
];

const _channels = [
  Channel(id: 'c0', name: 'KiKA', categoryId: 'kids', streamUrl: 'http://s/0', number: 1),
  Channel(id: 'c1', name: 'Toggo', categoryId: 'kids', streamUrl: 'http://s/1', number: 2),
  Channel(id: 'c2', name: 'tagesschau24', categoryId: 'news', streamUrl: 'http://s/2', number: 3),
  Channel(id: 'c3', name: 'Nachtkanal', categoryId: 'adult', streamUrl: 'http://s/3', number: 4),
  Channel(id: 'c4', name: 'Wissen', categoryId: 'news', streamUrl: 'http://s/4', number: 5),
];

const _myGroups = [
  MyGroup('my_kids', 'Für die Kleinen', ['c4']),
  MyGroup('my_late', 'Spät', ['c3']),
];

const _movies = VodData([
  Category(id: 'mk', name: 'Kinderfilme'),
  Category(id: 'mh', name: 'Horror'),
], [
  VodItem(id: 'm1', name: 'Paddington', categoryId: 'mk', streamUrl: 'http://v/1'),
  VodItem(id: 'm2', name: 'Der Exorzist', categoryId: 'mh', streamUrl: 'http://v/2'),
]);

const _series = VodData([
  Category(id: 'sk', name: 'Kinderserien'),
  Category(id: 'sc', name: 'Krimi'),
], [
  VodItem(id: 's1', name: 'Bluey', categoryId: 'sk', streamUrl: '', isSeries: true),
  VodItem(id: 's2', name: 'Tatort', categoryId: 'sc', streamUrl: '', isSeries: true),
]);

class _Active extends ActivePortalNotifier {
  @override
  Future<Portal?> build() async => _portal;
}

class _Portals extends PortalsNotifier {
  @override
  Future<List<Portal>> build() async => const [_portal];
}

class _Live extends LiveNotifier {
  @override
  Future<LiveData> build() async => const LiveData(_cats, _channels);
}

class _Groups extends MyGroupsNotifier {
  @override
  Future<List<MyGroup>> build() async => _myGroups;
}

class _Vod extends VodNotifier {
  _Vod(super.series);
  @override
  Future<VodData> build() async => series ? _series : _movies;
}

class _Epg extends EpgNotifier {
  @override
  Future<Map<String, List<EpgEntry>>> build() async => const {};
  @override
  void want(Channel c) {}
}

class _Sort extends SortOrderNotifier {
  @override
  Future<SortOrder> build() async => SortOrder.empty;
}

/// Kindermodus an, freigegeben: Gruppe „kids“, eigene Gruppe „my_kids“,
/// Kinderfilme und Kinderserien.
Map<String, Object> _kidsPrefs({bool on = true}) => {
      'set_kids': on,
      'set_kidsgroups_$_pid': ['kids', 'my_kids'],
      'set_kidsvod_$_pid': ['m:mk', 's:sk'],
    };

Future<Storage> _storage(Map<String, Object> prefs) async {
  SharedPreferences.setMockInitialValues(prefs);
  return Storage.open(store: PreviewSecretStore());
}

List<Override> _overrides(Storage st, {bool tv = false}) => [
      isTvProvider.overrideWithValue(tv),
      storageProvider.overrideWith((ref) async => st),
      activePortalProvider.overrideWith(_Active.new),
      portalsProvider.overrideWith(_Portals.new),
      liveDataProvider.overrideWith(_Live.new),
      myGroupsProvider.overrideWith(_Groups.new),
      moviesProvider.overrideWith(() => _Vod(false)),
      seriesProvider.overrideWith(() => _Vod(true)),
      epgProvider.overrideWith(_Epg.new),
      sortOrderProvider.overrideWith(_Sort.new),
      minuteTickProvider.overrideWith((ref) => Stream.value(DateTime.now())),
    ];

/// Container mit allen Daten geladen.
Future<ProviderContainer> _container(Storage st) async {
  final c = ProviderContainer(overrides: _overrides(st));
  addTearDown(c.dispose);
  // Am Leben halten (wie die Oberfläche) und laden.
  for (final p in <ProviderListenable<Object?>>[
    visibleLiveDataProvider,
    visibleMyGroupsProvider,
    visibleMoviesProvider,
    visibleSeriesProvider,
    recentProvider,
    channelFlagsProvider,
    vodLibraryProvider,
  ]) {
    c.listen(p, (_, __) {});
  }
  await c.read(storageProvider.future);
  await c.read(activePortalProvider.future);
  await c.read(liveDataProvider.future);
  await c.read(myGroupsProvider.future);
  await c.read(moviesProvider.future);
  await c.read(seriesProvider.future);
  await c.read(recentProvider.future);
  await c.read(channelFlagsProvider.future);
  await c.read(vodLibraryProvider.future);
  return c;
}

List<String> _ids(Iterable<Object> l) => [
      for (final x in l)
        switch (x) {
          Channel c => c.id,
          Category c => c.id,
          MyGroup g => g.id,
          VodItem m => m.id,
          _ => '?',
        },
    ];

Future<void> _pumpApp(WidgetTester tester, Storage st, Widget home,
    {bool tv = false, Size size = const Size(800, 1200)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = tv ? 2 : 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    overrides: _overrides(st, tv: tv),
    child: MaterialApp(
      theme: buildTheme(tv: tv),
      // Wie in app.dart: Escape/Zurück-Taste schließt Dialoge.
      builder: (context, child) =>
          TvSafeMediaQuery(enabled: tv, child: child!),
      home: RepaintBoundary(key: _shotKey, child: home),
    ),
  ));
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

final _shotKey = GlobalKey();

ProviderContainer _of(WidgetTester tester, Type t) =>
    ProviderScope.containerOf(tester.element(find.byType(t).first));

Future<void> _key(WidgetTester tester, LogicalKeyboardKey k) async {
  await tester.sendKeyEvent(k);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

/// PIN-Dialog: Text eingeben und mit „OK“ bestätigen.
Future<void> _enterPin(WidgetTester tester, String pin,
    {bool tv = false}) async {
  // Fernseher: das Feld hat den Fokus, OK startet die Eingabe.
  if (tv) await _key(tester, LogicalKeyboardKey.select);
  await tester.enterText(
      find.descendant(
          of: find.byType(AlertDialog), matching: find.byType(TextField)),
      pin);
  await tester.tap(find.widgetWithText(FilledButton, 'OK'));
  // PIN-Hash (PBKDF2) läuft echt asynchron.
  await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)));
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _shot(WidgetTester tester, String name) =>
    writeShot(tester, _shotKey, name);

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    L10n.lang = 'de';
    await initializeDateFormatting('de');
    await loadAppFonts();
  });

  group('Kindermodus-Filter', () {
    test('Live: nur freigegebene Gruppen und Sender eigener Gruppen', () {
      final d = KidsFilter.live(const LiveData(_cats, _channels),
          {'kids', 'my_kids'}, _myGroups);
      expect(_ids(d.categories), ['kids']);
      expect(_ids(d.channels), ['c0', 'c1', 'c4']);
      // Nichts freigegeben → nichts sichtbar.
      final none =
          KidsFilter.live(const LiveData(_cats, _channels), {}, _myGroups);
      expect(none.categories, isEmpty);
      expect(none.channels, isEmpty);
    });

    test('Filme/Serien: nur freigegebene Kategorien, getrennt nach Art', () {
      final m = KidsFilter.vod(_movies, false, {'m:mk', 's:mh'});
      expect(_ids(m.categories), ['mk']);
      expect(_ids(m.items), ['m1']);
      final s = KidsFilter.vod(_series, true, {'s:sk', 'm:sc'});
      expect(_ids(s.categories), ['sk']);
      expect(_ids(s.items), ['s1']);
    });

    test('Sichtbare Listen (Live, eigene Gruppen, Filme, Serien)', () async {
      final c = await _container(await _storage(_kidsPrefs()));
      expect(c.read(kidsModeProvider), isTrue);
      final live = c.read(visibleLiveDataProvider).value!;
      expect(_ids(live.categories), ['kids']);
      expect(_ids(live.channels), ['c0', 'c1', 'c4']);
      expect(_ids(c.read(visibleMyGroupsProvider)), ['my_kids']);
      expect(_ids(c.read(visibleMoviesProvider).value!.items), ['m1']);
      expect(_ids(c.read(visibleMoviesProvider).value!.categories), ['mk']);
      expect(_ids(c.read(visibleSeriesProvider).value!.items), ['s1']);

      // Freigaben ändern wirkt sofort.
      await c
          .read(profileModeProvider.notifier)
          .setKidsGroups({'news'});
      expect(_ids(c.read(visibleLiveDataProvider).value!.channels),
          ['c2', 'c4']);
      expect(c.read(visibleMyGroupsProvider), isEmpty);

      // Kindermodus aus → alles sichtbar (automatische 18+-Sperre ist
      // vorerst abgeschaltet).
      await c.read(profileModeProvider.notifier).setKids(false);
      expect(c.read(visibleLiveDataProvider).value!.channels.length, 5);
      expect(c.read(visibleMyGroupsProvider).length, 2);
      expect(c.read(visibleMoviesProvider).value!.items.length, 2);
      expect(c.read(visibleSeriesProvider).value!.items.length, 2);
    });

    testWidgets(
        'readVisibleLive (TV-Startbildschirm, Erinnerungen, Deep-Link) '
        'filtert auch beim Kaltstart', (tester) async {
      final st = await _storage(_kidsPrefs());
      late WidgetRef wref;
      await tester.pumpWidget(ProviderScope(
        overrides: _overrides(st),
        child: Consumer(builder: (_, ref, __) {
          wref = ref;
          return const SizedBox();
        }),
      ));
      // Sofort lesen – profileModeProvider wurde noch nie aufgebaut.
      List<String>? ids;
      readVisibleLive(wref).then((d) => ids = _ids(d.channels));
      for (var i = 0; i < 10 && ids == null; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(ids, ['c0', 'c1', 'c4']);
    });
  });

  group('Kindermodus: PIN', () {
    testWidgets('Einschalten verlangt eine PIN (legt sie an)', (tester) async {
      final st = await _storage(_kidsPrefs(on: false));
      await _pumpApp(tester, st, const KidsModeScreen());
      final c = _of(tester, KidsModeScreen);
      expect(find.text('Für die Kleinen'), findsOneWidget);
      expect(find.text('Paddington'), findsNothing); // nur Kategorien
      expect(find.text('Kinderfilme'), findsOneWidget);

      // Abbrechen → bleibt aus.
      await tester.tap(find.byKey(const ValueKey('kids-enable')));
      await tester.pumpAndSettle();
      expect(find.text('Neue PIN festlegen'), findsOneWidget);
      await tester.tap(find.text('Abbrechen'));
      await tester.pumpAndSettle();
      expect(c.read(kidsModeProvider), isFalse);
      expect(st.hasPin(), isFalse);

      // Zu kurz → bleibt aus, keine PIN.
      await tester.tap(find.byKey(const ValueKey('kids-enable')));
      await tester.pumpAndSettle();
      await _enterPin(tester, '12');
      expect(c.read(kidsModeProvider), isFalse);
      expect(st.hasPin(), isFalse);
      expect(st.kidsMode, isFalse);

      // Gültige PIN → an und gespeichert.
      await tester.tap(find.byKey(const ValueKey('kids-enable')));
      await tester.pumpAndSettle();
      await _enterPin(tester, '1234');
      expect(st.hasPin(), isTrue);
      expect(c.read(kidsModeProvider), isTrue);
      expect(st.kidsMode, isTrue);
    });

    testWidgets('Einschalten mit vorhandener PIN fragt sie ab',
        (tester) async {
      final st = await _storage(_kidsPrefs(on: false));
      await tester.runAsync(() => st.setPin('4321'));
      await _pumpApp(tester, st, const KidsModeScreen());
      final c = _of(tester, KidsModeScreen);

      await tester.tap(find.byKey(const ValueKey('kids-enable')));
      await tester.pumpAndSettle();
      expect(find.text('PIN eingeben'), findsOneWidget);
      await _enterPin(tester, '0000');
      expect(find.text('Falsche PIN – noch 4 Versuche'), findsOneWidget);
      await tester.tap(find.text('Abbrechen'));
      await tester.pumpAndSettle();
      expect(c.read(kidsModeProvider), isFalse);

      await tester.tap(find.byKey(const ValueKey('kids-enable')));
      await tester.pumpAndSettle();
      await _enterPin(tester, '4321');
      expect(c.read(kidsModeProvider), isTrue);
    });

    testWidgets('Beenden nur mit PIN – Zurück und falsche PIN lassen ihn an '
        '(Fernbedienung)', (tester) async {
      final st = await _storage(_kidsPrefs());
      await tester.runAsync(() => st.setPin('1234'));
      await _pumpApp(
        tester,
        st,
        const Scaffold(body: KidsSettingsLock()),
        tv: true,
        size: const Size(1920, 1080),
      );
      final c = _of(tester, KidsSettingsLock);
      expect(find.text('Kindermodus ist aktiv'), findsOneWidget);

      // Autofokus auf „Beenden“; OK öffnet die PIN-Abfrage.
      await _key(tester, LogicalKeyboardKey.select);
      expect(find.text('PIN eingeben'), findsOneWidget);
      // Zurück (Escape) schließt nur den Dialog.
      await _key(tester, LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('PIN eingeben'), findsNothing);
      expect(c.read(kidsModeProvider), isTrue);
      expect(find.text('Kindermodus ist aktiv'), findsOneWidget);

      // Falsche PIN → bleibt an.
      expect(FocusManager.instance.primaryFocus?.context?.widget,
          isNot(isA<EditableText>()));
      await _key(tester, LogicalKeyboardKey.select);
      expect(find.text('PIN eingeben'), findsOneWidget);
      await _enterPin(tester, '9999', tv: true);
      expect(find.text('Falsche PIN – noch 4 Versuche'), findsOneWidget);
      expect(c.read(kidsModeProvider), isTrue);
      await _key(tester, LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(c.read(kidsModeProvider), isTrue);
      expect(st.kidsMode, isTrue);

      // Richtige PIN → aus.
      await _key(tester, LogicalKeyboardKey.select);
      await _enterPin(tester, '1234', tv: true);
      expect(c.read(kidsModeProvider), isFalse);
      expect(st.kidsMode, isFalse);
    });

    testWidgets('Kindermodus-Seite auf dem Fernseher (Bildschirmfoto)',
        (tester) async {
      final st = await _storage({..._kidsPrefs(on: false)});
      await _pumpApp(tester, st, const TvSafeArea(enabled: true, child: KidsModeScreen()),
          tv: true, size: const Size(1920, 1080));
      expect(tester.takeException(), isNull);
      expect(find.text('2 Gruppen freigegeben'), findsOneWidget);
      await _shot(tester, 'tv_kids_mode');
    });
  });

  group('Gastmodus', () {
    test('Speicher: kein Verlauf, kein Weiterschauen, keine Favoriten',
        () async {
      final st = await _storage({'set_guest': true});
      expect(st.guestMode, isTrue);
      await st.pushRecent(_pid, 'c1');
      await st.setLastChannel(_pid, 'c1');
      await st.setResume('movie_m1', 600, 5400);
      await st.setResume('movie_m2', 5300, 5400); // fast fertig → „gesehen“
      await st.toggleFavorite(_pid, 'c1');
      expect(st.recent(_pid), isEmpty);
      expect(st.lastChannel(_pid), isNull);
      expect(st.resume('movie_m1'), isNull);
      expect(st.isWatched('movie_m2'), isFalse);
      expect(st.favorites(_pid), isEmpty);

      // Gast aus → wieder normal.
      await st.setFlag(Storage.guestFlag, false);
      await st.pushRecent(_pid, 'c1');
      await st.setResume('movie_m1', 600, 5400);
      await st.toggleFavorite(_pid, 'c1');
      expect(st.recent(_pid), ['c1']);
      expect(st.resume('movie_m1'), isNotNull);
      expect(st.favorites(_pid), {'c1'});
    });

    test('Provider: Verlauf/Favoriten/Meine Liste leer und unveränderbar',
        () async {
      final hist = jsonEncode([VodHistoryEntry(false, 'm1', DateTime(2026)).toJson()]);
      final st = await _storage({
        'recent_$_pid': ['c0'],
        'fav_$_pid': ['c2'],
        'set_vodhist_$_pid': hist,
        'set_vodfav_$_pid': '["m:m1"]',
      });
      final c = await _container(st);
      expect(c.read(recentProvider).value, ['c0']);
      expect(c.read(channelFlagsProvider).value!.favorites, {'c2'});
      expect(c.read(vodLibraryProvider).value!.history, hasLength(1));

      await c.read(profileModeProvider.notifier).setGuest(true);
      expect(c.read(guestModeProvider), isTrue);
      expect(await c.read(recentProvider.future), isEmpty);
      expect((await c.read(channelFlagsProvider.future)).favorites, isEmpty);
      final lib = await c.read(vodLibraryProvider.future);
      expect(lib.history, isEmpty);
      expect(lib.favorites, isEmpty);

      await c.read(recentProvider.notifier).push('c3');
      await c.read(recentProvider.notifier).clear();
      await c.read(channelFlagsProvider.notifier).toggleFavorite('c3');
      await c.read(vodLibraryProvider.notifier).watchedMovie(_movies.items[1]);
      await c.read(vodLibraryProvider.notifier).toggleFavorite(_movies.items[1]);
      // Gespeichertes bleibt unberührt.
      expect(st.recent(_pid), ['c0']);
      expect(st.favorites(_pid), {'c2'});
      expect(st.option('vodhist_$_pid', ''), hist);
      expect(st.option('vodfav_$_pid', ''), '["m:m1"]');

      // Gast aus → alles wieder da.
      await c.read(profileModeProvider.notifier).setGuest(false);
      expect(await c.read(recentProvider.future), ['c0']);
      expect((await c.read(channelFlagsProvider.future)).favorites, {'c2'});
      expect((await c.read(vodLibraryProvider.future)).history, hasLength(1));
    });

    for (final tv in [false, true]) {
      testWidgets('Startseite blendet Verlauf, Favoriten, Weiterschauen aus '
          '(tv=$tv)', (tester) async {
        final hist =
            jsonEncode([VodHistoryEntry(false, 'm1', DateTime(2026)).toJson()]);
        final st = await _storage({
          'recent_$_pid': ['c0'],
          'fav_$_pid': ['c2'],
          'set_vodhist_$_pid': hist,
        });
        await _pumpApp(
            tester, st, Scaffold(body: HomeScreen(onOpenTab: (_) {})),
            tv: tv, size: tv ? const Size(1920, 1080) : const Size(420, 2400));
        // Überschriften (TV: in Großbuchstaben), auch außerhalb des Bildes.
        Finder heading(String t) => find.byWidgetPredicate(
            (w) => w is Text && w.data?.toLowerCase() == t.toLowerCase(),
            skipOffstage: false);
        final rows = ['Zuletzt gesehen', 'Favoriten', 'Weiterschauen'];
        for (final r in rows) {
          expect(heading(r), findsOneWidget, reason: r);
        }

        final c = _of(tester, HomeScreen);
        await c.read(profileModeProvider.notifier).setGuest(true);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        for (final r in rows) {
          expect(heading(r), findsNothing, reason: r);
        }
        expect(tester.takeException(), isNull);
      });
    }
  });
}
