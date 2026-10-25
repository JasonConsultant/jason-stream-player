import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:jason_stream_player/core/backup.dart';
import 'package:jason_stream_player/core/secret_store.dart';
import 'package:jason_stream_player/core/theme.dart';
import 'package:jason_stream_player/data/storage.dart';
import 'package:jason_stream_player/l10n/strings.dart';
import 'package:jason_stream_player/models/models.dart';
import 'package:jason_stream_player/state/my_groups.dart';
import 'package:jason_stream_player/state/profile_mode.dart';
import 'package:jason_stream_player/state/profiles.dart';
import 'package:jason_stream_player/state/providers.dart';
import 'package:jason_stream_player/state/vod_library.dart';
import 'package:jason_stream_player/ui/settings/profile_modes.dart';
import 'package:jason_stream_player/ui/settings/profiles_screen.dart';
import 'package:jason_stream_player/ui/tv/tv_safe.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/app_fonts.dart';

/// 2.3 Profile: Migration (Altdaten = Standardprofil, nichts verloren),
/// Trennung je Profil, Gast/Kind, PIN, Sicherung, Profilwahl (Handy + TV).
///
/// `TV_SHOTS=ordner` schreibt phone_profile_picker.png, tv_profile_picker.png,
/// phone_profiles.png.

const _portal = Portal(
    id: 'px', name: 'P', type: PortalType.m3u, url: 'http://h/list.m3u');
final _pid = _portal.id;

/// Daten eines Nutzers von Version 2.2 (alle profilbezogenen Arten).
Map<String, Object> _legacy() => {
      'fav_$_pid': ['demo_1', 'demo_2'],
      'recent_$_pid': ['demo_3', 'demo_1'],
      'resume_movie_m1': '600/5400',
      'watched_movie_m2': true,
      'last_$_pid': 'demo_3',
      'set_mygroups_$_pid':
          jsonEncode([MyGroup('my_a', 'Fußball', ['demo_4']).toJson()]),
      'set_vodfav_$_pid': jsonEncode(['m:m1']),
      'set_vodhist_$_pid': jsonEncode([
        {'id': 'm1', 's': false, 't': 1700000000000}
      ]),
      'set_recentsearch_$_pid': jsonEncode(['tatort']),
      'hidden_$_pid': ['demo_9'],
      'set_fit': 'fill',
      'set_applang': 'de',
    };

Future<Storage> _open([Map<String, Object>? prefs]) async {
  SharedPreferences.setMockInitialValues(prefs ?? {});
  return Storage.open(store: PreviewSecretStore());
}

Future<Map<String, Object?>> _allPrefs() async {
  final p = await SharedPreferences.getInstance();
  return {for (final k in p.getKeys()) k: p.get(k)};
}

class _Active extends ActivePortalNotifier {
  @override
  Future<Portal?> build() async => _portal;
}

class _Portals extends PortalsNotifier {
  @override
  Future<List<Portal>> build() async => const [_portal];
}

List<Override> _overrides(Storage st, {bool tv = false}) => [
      isTvProvider.overrideWithValue(tv),
      storageProvider.overrideWith((ref) async => st),
      activePortalProvider.overrideWith(_Active.new),
      portalsProvider.overrideWith(_Portals.new),
    ];

Future<ProviderContainer> _container(Storage st) async {
  final c = ProviderContainer(overrides: _overrides(st));
  addTearDown(c.dispose);
  for (final p in [
    channelFlagsProvider,
    recentProvider,
    myGroupsProvider,
    vodLibraryProvider,
  ]) {
    c.listen(p, (_, __) {});
  }
  c.listen(profileModeProvider, (_, __) {});
  await c.read(storageProvider.future);
  await c.read(activePortalProvider.future);
  return c;
}

Future<void> _settle(ProviderContainer c) async {
  await c.read(channelFlagsProvider.future);
  await c.read(recentProvider.future);
  await c.read(myGroupsProvider.future);
  await c.read(vodLibraryProvider.future);
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    L10n.lang = 'de';
    await loadAppFonts();
  });

  group('Migration (Update von 2.2)', () {
    test('Altdaten werden das Standardprofil – kein Schlüssel verändert',
        () async {
      final st = await _open(_legacy());
      final before = await _allPrefs();
      expect(st.profiles(), [UserProfile.main]);
      expect(st.activeProfileId, UserProfile.mainId);
      expect(st.favorites(_pid), {'demo_1', 'demo_2'});
      expect(st.recent(_pid), ['demo_3', 'demo_1']);
      expect(st.resume('movie_m1'), (pos: 600, total: 5400));
      expect(st.isWatched('movie_m2'), isTrue);
      expect(st.lastChannel(_pid), 'demo_3');
      expect(st.option('mygroups_$_pid', ''), contains('Fußball'));
      expect(st.option('vodfav_$_pid', ''), contains('m:m1'));
      expect(st.option('recentsearch_$_pid', ''), contains('tatort'));
      // Nichts umkopiert oder gelöscht.
      expect(await _allPrefs(), before);
      for (final e in _legacy().entries) {
        expect(before[e.key], e.value, reason: e.key);
      }
    });

    test('Altdaten erscheinen in den Providern unverändert', () async {
      final st = await _open(_legacy());
      final c = await _container(st);
      await _settle(c);
      expect(c.read(channelFlagsProvider).value!.favorites,
          {'demo_1', 'demo_2'});
      expect(c.read(recentProvider).value, ['demo_3', 'demo_1']);
      expect(c.read(myGroupsProvider).value!.single.name, 'Fußball');
      expect(c.read(vodLibraryProvider).value!.favorites, {'m:m1'});
      expect(c.read(profilesProvider).list, [UserProfile.main]);
      expect(c.read(profilePickPendingProvider), isFalse,
          reason: 'ein Profil → keine Profilwahl beim Start');
    });

    test('Kindermodus von 2.2 bleibt aktiv (gleiches Verhalten)', () async {
      final st = await _open({..._legacy(), 'set_kids': true});
      expect(st.kidsMode, isTrue);
      final c = await _container(st);
      expect(c.read(profileModeProvider).kids, isTrue);
      expect(c.read(activeProfileProvider).kid, isFalse);
    });

    test('Gastmodus von 2.2 bleibt aktiv und schreibt nichts', () async {
      final st = await _open({..._legacy(), 'set_guest': true});
      expect(st.guestMode, isTrue);
      final before = await _allPrefs();
      await st.toggleFavorite(_pid, 'demo_7');
      await st.pushRecent(_pid, 'demo_7');
      await st.setResume('movie_m9', 10, 100);
      await st.setLastChannel(_pid, 'demo_7');
      expect(await _allPrefs(), before);
    });
  });

  group('Trennung je Profil', () {
    test('Favoriten, Verlauf, Weiterschauen, Gruppen, Suche getrennt; '
        'Geräte-Einstellungen gemeinsam', () async {
      final st = await _open(_legacy());
      final b = await st.addProfile(name: 'Ayşe', color: 3);
      await st.setActiveProfile(b.id);
      expect(st.favorites(_pid), isEmpty);
      expect(st.recent(_pid), isEmpty);
      expect(st.resume('movie_m1'), isNull);
      expect(st.isWatched('movie_m2'), isFalse);
      expect(st.lastChannel(_pid), isNull);
      expect(st.option('mygroups_$_pid', '[]'), '[]');
      expect(st.option('recentsearch_$_pid', ''), '');
      // Gemeinsam: versteckte Sender, Bildformat, Sprache.
      expect(st.hidden(_pid), {'demo_9'});
      expect(st.option('fit', ''), 'fill');
      expect(st.option('applang', ''), 'de');

      await st.toggleFavorite(_pid, 'demo_5');
      await st.pushRecent(_pid, 'demo_5');
      await st.setResume('movie_m1', 30, 5400);
      await st.setLastChannel(_pid, 'demo_5');
      await st.setOption('vodfav_$_pid', jsonEncode(['m:m7']));
      final prefs = await _allPrefs();
      expect(prefs['p.${b.id}.fav_$_pid'], ['demo_5']);
      expect(prefs['p.${b.id}.resume_movie_m1'], '30/5400');
      expect(prefs['p.${b.id}.set_vodfav_$_pid'], jsonEncode(['m:m7']));

      // Zurück: Standardprofil unverändert.
      await st.setActiveProfile(UserProfile.mainId);
      expect(st.favorites(_pid), {'demo_1', 'demo_2'});
      expect(st.resume('movie_m1'), (pos: 600, total: 5400));
      expect(st.lastChannel(_pid), 'demo_3');
      expect(st.option('vodfav_$_pid', ''), contains('m:m1'));

      // Aktives Profil überlebt den Neustart.
      await st.setActiveProfile(b.id);
      final again = await Storage.open(store: PreviewSecretStore());
      expect(again.activeProfileId, b.id);
      expect(again.favorites(_pid), {'demo_5'});
    });

    test('Provider laden beim Profilwechsel neu', () async {
      final st = await _open(_legacy());
      final c = await _container(st);
      await _settle(c);
      final b = await c.read(profilesProvider.notifier).add(name: 'Mehmet');
      await c.read(profilesProvider.notifier).switchTo(b.id);
      await _settle(c);
      expect(c.read(channelFlagsProvider).value!.favorites, isEmpty);
      expect(c.read(recentProvider).value, isEmpty);
      expect(c.read(myGroupsProvider).value, isEmpty);
      expect(c.read(vodLibraryProvider).value!.favorites, isEmpty);
      await c.read(channelFlagsProvider.notifier).toggleFavorite('demo_8');
      await c.read(profilesProvider.notifier).switchTo(UserProfile.mainId);
      await _settle(c);
      expect(c.read(channelFlagsProvider).value!.favorites,
          {'demo_1', 'demo_2'});
      expect(c.read(myGroupsProvider).value!.single.name, 'Fußball');
    });

    test('Profil löschen entfernt nur seine Daten', () async {
      final st = await _open(_legacy());
      final b = await st.addProfile(name: 'B');
      await st.setActiveProfile(b.id);
      await st.toggleFavorite(_pid, 'demo_5');
      await st.setProfilePin(b.id, '1234');
      await st.removeProfile(b.id);
      final prefs = await _allPrefs();
      expect(prefs.keys.where((k) => k.startsWith('p.')), isEmpty);
      expect(st.activeProfileId, UserProfile.mainId);
      expect(st.favorites(_pid), {'demo_1', 'demo_2'});
      expect(st.profileHasPin(b.id), isFalse);
      // Standardprofil lässt sich nicht löschen.
      await st.removeProfile(UserProfile.mainId);
      expect(st.profiles().single.isMain, isTrue);
    });

    test('Gast schreibt auch in einem anderen Profil nichts', () async {
      final st = await _open();
      final b = await st.addProfile(name: 'B');
      await st.setActiveProfile(b.id);
      await st.setFlag(Storage.guestFlag, true);
      final before = await _allPrefs();
      await st.toggleFavorite(_pid, 'x');
      await st.setResume('movie_1', 10, 100);
      await st.setWatched('movie_2');
      expect(await _allPrefs(), before);
    });

    test('Kinderprofil = Kindermodus; Standardprofil nicht', () async {
      final st = await _open();
      final k = await st.addProfile(name: 'Lina', kid: true);
      expect(st.kidsMode, isFalse);
      await st.setActiveProfile(k.id);
      expect(st.kidsMode, isTrue);
      final c = await _container(st);
      expect(c.read(profileModeProvider).kids, isTrue);
      await c.read(profilesProvider.notifier).switchTo(UserProfile.mainId);
      expect(c.read(profileModeProvider).kids, isFalse);
    });

    test('Profil-PIN: nur Hash, Fehlversuche, Sperre', () async {
      final st = await _open();
      final b = await st.addProfile(name: 'B');
      await st.setProfilePin(b.id, '2580');
      expect(st.profileHasPin(b.id), isTrue);
      final plain = (await _allPrefs()).toString();
      expect(plain, isNot(contains('2580')));
      expect((await st.verifyProfilePin(b.id, '2580')).ok, isTrue);
      for (var i = 0; i < 4; i++) {
        expect((await st.verifyProfilePin(b.id, '0000')).ok, isFalse);
      }
      final locked = await st.verifyProfilePin(b.id, '0000');
      expect(locked.lockedFor, isNotNull);
      // Eltern-PIN unberührt.
      expect(st.hasPin(), isFalse);
    });

    test('Profilwahl beim Start nur bei > 1 Profil und Einstellung an',
        () async {
      final st = await _open();
      expect(st.askProfileOnStart, isFalse);
      await st.addProfile(name: 'B');
      expect(st.askProfileOnStart, isTrue);
      await st.setFlag(Storage.askProfileFlag, false);
      expect(st.askProfileOnStart, isFalse);
    });
  });

  group('Sicherung', () {
    test('Export enthält Profile + Daten je Profil, PIN nur als Hash; '
        'Import stellt alles wieder her', () async {
      final st = await _open(_legacy());
      final b = await st.addProfile(name: 'Ayşe', color: 2, kid: true);
      await st.setProfilePin(b.id, '7391');
      await st.setActiveProfile(b.id);
      await st.toggleFavorite(_pid, 'demo_5');
      await st.setResume('movie_m1', 30, 5400);
      final data = st.exportAll();
      final text = jsonEncode(data);
      expect(text, isNot(contains('7391')));
      final profiles = (data['profiles'] as List).cast<Map>();
      expect(profiles.map((p) => p['id']), [UserProfile.mainId, b.id]);
      expect(profiles[1]['pin'], isA<String>());
      expect((data['prefs'] as Map)['p.${b.id}.fav_$_pid'], ['demo_5']);
      expect(BackupSummary.of(data).profiles, 2);
      expect(BackupSummary.of(data).favorites, 3);

      // Neues Gerät.
      final fresh = await _open();
      await fresh.importAll(data, merge: false);
      expect(fresh.profiles().map((p) => p.name), ['', 'Ayşe']);
      expect(fresh.profiles()[1].kid, isTrue);
      expect(fresh.favorites(_pid), {'demo_1', 'demo_2'});
      await fresh.setActiveProfile(b.id);
      expect(fresh.favorites(_pid), {'demo_5'});
      expect(fresh.resume('movie_m1'), (pos: 30, total: 5400));
      expect((await fresh.verifyProfilePin(b.id, '7391')).ok, isTrue);
      expect((await fresh.verifyProfilePin(b.id, '1111')).ok, isFalse);
    });

    test('Klartext-PIN in einer (manipulierten) Sicherung wird verworfen',
        () async {
      final fresh = await _open();
      await fresh.importAll({
        'app': 'jason_stream_player',
        'portals': [],
        'profiles': [
          {'id': 'main', 'name': ''},
          {'id': 'x1', 'name': 'X', 'pin': '1234'},
        ],
      });
      expect(fresh.profiles().length, 2);
      expect(fresh.profileHasPin('x1'), isFalse);
    });

    test('Alte Sicherung (ohne Profile) lässt Profile unberührt', () async {
      final st = await _open();
      final b = await st.addProfile(name: 'B');
      await st.importAll({
        'app': 'jason_stream_player',
        'portals': [],
        'prefs': {'fav_$_pid': ['z']},
      });
      expect(st.profiles().map((p) => p.id), [UserProfile.mainId, b.id]);
      expect(st.favorites(_pid), {'z'});
    });

    test('Zusammenführen behält vorhandene Profile', () async {
      final a = await _open();
      final pa = await a.addProfile(name: 'A');
      final data = a.exportAll();
      final st = await _open();
      final pb = await st.addProfile(name: 'B');
      await st.importAll(data, merge: true);
      expect(st.profiles().map((p) => p.id).toSet(),
          {UserProfile.mainId, pa.id, pb.id});
    });
  });

  group('Oberfläche', () {
    Future<Storage> twoProfiles({bool pin = false, bool kid = false}) async {
      final st = await _open(_legacy());
      final b = await st.addProfile(name: 'Ayşe', color: 1, kid: kid);
      if (pin) await st.setProfilePin(b.id, '2468');
      if (kid) await st.setPin('9999');
      return st;
    }

    Future<void> pump(WidgetTester tester, Storage st, Widget home,
        {bool tv = false}) async {
      tester.view.physicalSize = tv ? const Size(1920, 1080) : const Size(800, 1400);
      tester.view.devicePixelRatio = tv ? 2 : 2;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ProviderScope(
        overrides: _overrides(st, tv: tv),
        child: MaterialApp(
          theme: buildTheme(tv: tv),
          builder: (context, child) =>
              TvSafeMediaQuery(enabled: tv, child: child!),
          home: RepaintBoundary(key: _shot, child: home),
        ),
      ));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    Future<void> enterPin(WidgetTester tester, String pin) async {
      await tester.enterText(
          find.descendant(
              of: find.byType(AlertDialog), matching: find.byType(TextField)),
          pin);
      await tester.tap(find.widgetWithText(FilledButton, 'OK'));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 300)));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    ProviderContainer of(WidgetTester tester) => ProviderScope.containerOf(
        tester.element(find.byType(ProfilePickerScreen)));

    testWidgets('Profilwahl (Handy): Profil wählen, PIN wird verlangt',
        (tester) async {
      final st = await twoProfiles(pin: true);
      await pump(tester, st, const ProfilePickerScreen());
      expect(find.text('Wer schaut?'), findsOneWidget);
      expect(find.text('Ich'), findsOneWidget);
      expect(find.text('Ayşe'), findsOneWidget);
      expect(find.text('Gast'), findsOneWidget);
      await writeShot(tester, _shot, 'phone_profile_picker');
      final c = of(tester);
      expect(c.read(profilePickPendingProvider), isTrue);
      final id = st.profiles()[1].id;
      await tester.tap(find.byKey(ValueKey('profile-pick-$id')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(AlertDialog), findsOneWidget);
      await enterPin(tester, '0000');
      expect(c.read(activeProfileProvider).isMain, isTrue);
      expect(find.text('Falsche PIN – noch 4 Versuche'), findsOneWidget);
      await enterPin(tester, '2468');
      expect(c.read(activeProfileProvider).id, id);
      expect(c.read(profilePickPendingProvider), isFalse);
    });

    testWidgets('Profilwahl (TV): ◀▶ und OK, Gast speichert nichts',
        (tester) async {
      final st = await twoProfiles();
      await pump(tester, st, const ProfilePickerScreen(), tv: true);
      await writeShot(tester, _shot, 'tv_profile_picker');
      final c = of(tester);
      // Fokus startet auf dem aktiven Profil („Ich“).
      Future<void> key(LogicalKeyboardKey k) async {
        await tester.sendKeyEvent(k);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
      }

      await key(LogicalKeyboardKey.arrowRight);
      await key(LogicalKeyboardKey.select);
      expect(c.read(activeProfileProvider).name, 'Ayşe');
      expect(c.read(profilePickPendingProvider), isFalse);
      // Zurück zum Gast-Eintrag: ▶ und OK.
      await key(LogicalKeyboardKey.arrowRight);
      await key(LogicalKeyboardKey.select);
      expect(c.read(guestModeProvider), isTrue);
    });

    testWidgets('Kinderprofil verlassen nur mit Eltern-PIN', (tester) async {
      final st = await twoProfiles(kid: true);
      final kid = st.profiles()[1];
      await st.setActiveProfile(kid.id);
      await pump(tester, st, const ProfilePickerScreen(startup: false));
      final c = of(tester);
      expect(c.read(profileModeProvider).kids, isTrue);
      expect(find.byKey(const ValueKey('profile-manage')), findsNothing,
          reason: 'Kinder verwalten keine Profile');
      await tester.tap(find.byKey(const ValueKey('profile-pick-main')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.text('Abbrechen'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(c.read(activeProfileProvider).id, kid.id);
      await tester.tap(find.byKey(const ValueKey('profile-pick-main')));
      await tester.pump(const Duration(milliseconds: 300));
      await enterPin(tester, '9999');
      expect(c.read(activeProfileProvider).isMain, isTrue);
      expect(c.read(profileModeProvider).kids, isFalse);
    });

    testWidgets('Kinderprofil: Einstellungen gesperrt, Beenden → Standard',
        (tester) async {
      final st = await twoProfiles(kid: true);
      await st.setActiveProfile(st.profiles()[1].id);
      await pump(tester, st, const Scaffold(body: KidsSettingsLock()));
      expect(find.byKey(const ValueKey('kids-switch-profile')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('kids-exit')));
      await tester.pump(const Duration(milliseconds: 300));
      await enterPin(tester, '9999');
      final c = ProviderScope.containerOf(
          tester.element(find.byType(KidsSettingsLock)));
      expect(c.read(activeProfileProvider).isMain, isTrue);
      expect(c.read(profileModeProvider).kids, isFalse);
    });

    testWidgets('Profile verwalten: anlegen, Name, Farbe, löschen',
        (tester) async {
      final st = await _open();
      await pump(tester, st, const ProfilesScreen());
      expect(find.text('Ich'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('profile-add')));
      await tester.pumpAndSettle();
      expect(find.text('Neues Profil'), findsOneWidget);
      await tester.enterText(
          find.byKey(const ValueKey('profile-name')), 'Deniz');
      await tester.tap(find.byKey(const ValueKey('profile-color-4')));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(st.profiles()[1].name, 'Deniz');
      expect(st.profiles()[1].color, 4);
      await writeShot(tester, _shot, 'phone_profiles');
      await tester.tap(find.text('Deniz'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
          find.byKey(const ValueKey('profile-delete')), 200,
          scrollable: find
              .ancestor(
                  of: find.byKey(const ValueKey('profile-pin')),
                  matching: find.byType(Scrollable))
              .first);
      await tester.tap(find.byKey(const ValueKey('profile-delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Löschen'));
      await tester.pumpAndSettle();
      expect(st.profiles().length, 1);
    });
  });
}

final _shot = GlobalKey();
