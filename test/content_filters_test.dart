import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;
import 'package:flutter_test/flutter_test.dart';
import 'package:jason_stream_player/core/secret_store.dart';
import 'package:jason_stream_player/data/content_filters.dart';
import 'package:jason_stream_player/data/storage.dart';
import 'package:jason_stream_player/models/models.dart';
import 'package:jason_stream_player/state/content_filter.dart';
import 'package:jason_stream_player/state/my_groups.dart';
import 'package:jason_stream_player/state/profile_mode.dart';
import 'package:jason_stream_player/state/providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Erwachsenen-Erkennung (knifflige Namen), Ländererkennung und das
/// Zusammenspiel der Filter mit dem Kindermodus.
void main() {
  group('AdultDetector', () {
    const adult = [
      'XXX',
      'xxx Movies',
      'VIP | XXX 18+',
      'Adult',
      'ADULTS ONLY',
      'For Adults',
      'adultos',
      'Canales Adultos',
      '18+',
      '+18 Kanäle',
      'DE: Erwachsene',
      'Erwachsenenkanäle',
      'TR: YETİŞKİN',
      'Yetişkin Kanallar',
      'yetiskin',
      'Porn',
      'Pornhub',
      'Hustler TV',
      'Playboy TV',
      'Brazzers',
      'Private',
      '|XXX| Private HD',
      'adult (Premium)',
    ];
    const harmless = [
      'Essex TV',
      'Sexy Hits',
      'Middlesex',
      'Adult Swim',
      'Kinder',
      'Sport 18',
      'U18 Fußball',
      '118 Comedy',
      'Formel 1 +180',
      'Privatsender',
      'Playtime',
      'Boxen XXL',
    ];

    for (final n in adult) {
      test('sperrt „$n“', () => expect(AdultDetector.isAdult(n), isTrue));
    }
    for (final n in harmless) {
      test('lässt „$n“', () => expect(AdultDetector.isAdult(n), isFalse));
    }
    test('„Porno…“ zählt bewusst als Erwachsene (lieber sperren)', () {
      expect(AdultDetector.isAdult('Pornografie-Doku'), isTrue);
    });
  });

  group('CountryDetector', () {
    test('Kürzel am Anfang / als Abschnitt', () {
      expect(CountryDetector.fromPrefix('DE | Sport'), 'DE');
      expect(CountryDetector.fromPrefix('DE: ZDF HD'), 'DE');
      expect(CountryDetector.fromPrefix('[TR] TRT 1'), 'TR');
      expect(CountryDetector.fromPrefix('|UK| BBC One'), 'UK');
      expect(CountryDetector.fromPrefix('GB • ITV'), 'UK');
      expect(CountryDetector.fromPrefix('EX-YU: RTS 1'), 'EXYU');
      expect(CountryDetector.fromPrefix('RS - Pink'), 'EXYU');
      // Sendernamen, die wie Kürzel aussehen.
      expect(CountryDetector.fromPrefix('HR Fernsehen'), isNull);
      expect(CountryDetector.fromPrefix('AL JAZEERA'), isNull);
      expect(CountryDetector.fromPrefix('HR | Kroatien'), 'EXYU');
      expect(CountryDetector.fromPrefix('AL: Top Channel'), 'AL');
      expect(CountryDetector.fromPrefix('AL: Top Channel'), 'AL');
      expect(CountryDetector.fromPrefix('VIP | DE | Sky Sport'), 'DE');
      expect(CountryDetector.fromPrefix('AR: MBC'), 'AR');
      expect(CountryDetector.fromPrefix('US: CNN'), 'US');
      expect(CountryDetector.fromPrefix('DE ZDF'), 'DE');
    });

    test('keine Fehlalarme', () {
      expect(CountryDetector.fromPrefix('Al Jazeera'), isNull); // klein
      expect(CountryDetector.fromPrefix('ARD'), isNull);
      expect(CountryDetector.fromPrefix('ZDF'), isNull);
      expect(CountryDetector.fromPrefix('IT Crowd'), isNull); // mehrdeutig
      expect(CountryDetector.fromPrefix('US Open Tennis'), isNull);
      expect(CountryDetector.fromPrefix('NO Limit'), isNull);
      expect(CountryDetector.fromPrefix('Sport'), isNull);
      expect(CountryDetector.fromPrefix('DEUTSCHLAND'), isNull); // Name ≠ Kürzel
    });

    test('Ländernamen in Gruppen', () {
      expect(CountryDetector.fromGroup('Deutschland HD'), 'DE');
      expect(CountryDetector.fromGroup('TÜRKIYE ULUSAL'), 'TR');
      expect(CountryDetector.fromGroup('Türkiye Ulusal'), 'TR');
      expect(CountryDetector.fromGroup('Germany Sports'), 'DE');
      expect(CountryDetector.fromGroup('Balkan Music'), 'EXYU');
      expect(CountryDetector.fromGroup('Arabic News'), 'AR');
      expect(CountryDetector.fromGroup('Nachrichten'), isNull);
    });

    test('Sender: eigenes Kürzel vor Gruppe', () {
      expect(CountryDetector.forItem('TR: Show TV', 'DE'), 'TR');
      expect(CountryDetector.forItem('Show TV', 'TR'), 'TR');
      expect(CountryDetector.forItem('Show TV', null), isNull);
    });
  });

  group('Filter-Komposition', () {
    const cats = [
      Category(id: 'de', name: 'DE | Allgemein'),
      Category(id: 'tr', name: 'TR | Ulusal'),
      Category(id: 'kids', name: 'Kinder'),
      Category(id: 'xxx', name: 'XXX'),
      Category(id: 'mix', name: 'Sport'),
    ];
    const chans = [
      Channel(id: 'd1', name: 'ZDF', categoryId: 'de', streamUrl: 'http://s/1'),
      Channel(id: 't1', name: 'TRT 1', categoryId: 'tr', streamUrl: 'http://s/2'),
      Channel(id: 'k1', name: 'DE: KiKA', categoryId: 'kids', streamUrl: 'http://s/3'),
      Channel(id: 'k2', name: 'TR: Minika', categoryId: 'kids', streamUrl: 'http://s/4'),
      Channel(id: 'x1', name: 'DE: Nacht', categoryId: 'xxx', streamUrl: 'http://s/5'),
      Channel(id: 'm1', name: 'Eurosport', categoryId: 'mix', streamUrl: 'http://s/6'),
    ];
    const movies = VodData([
      Category(id: 'mde', name: 'DE Filme'),
      Category(id: 'madult', name: 'Adult Movies'),
      Category(id: 'mtr', name: 'Türk Filmleri'),
    ], [
      VodItem(id: 'a', name: 'Tatort', categoryId: 'mde', streamUrl: 'x'),
      VodItem(id: 'b', name: 'Nacht', categoryId: 'madult', streamUrl: 'x'),
      VodItem(id: 'c', name: 'Babam ve Oğlum', categoryId: 'mtr', streamUrl: 'x'),
      VodItem(id: 'e', name: 'TR: Eşkıya', categoryId: 'mde', streamUrl: 'x'),
    ]);

    List<String> ids(Iterable<Object> l) => [
          for (final x in l)
            switch (x) {
              Channel c => c.id,
              Category c => c.id,
              VodItem m => m.id,
              _ => '?',
            }
        ];

    test('reine Funktionen: Länder + Erwachsene', () {
      const d = LiveData(cats, chans);
      final de = applyContentFilters(d, adultLocked: true, countries: {'DE'});
      expect(ids(de.channels), ['d1', 'k1']);
      expect(ids(de.categories), ['de', 'kids']);
      final deNone = applyContentFilters(d,
          adultLocked: true, countries: {'DE', CountryDetector.none});
      expect(ids(deNone.channels), ['d1', 'k1', 'm1']);
      final unlocked =
          applyContentFilters(d, adultLocked: false, countries: {'DE'});
      expect(ids(unlocked.channels), ['d1', 'k1', 'x1']);
      final v = applyVodContentFilters(movies,
          adultLocked: true, countries: {'TR'});
      expect(ids(v.items), ['c', 'e']);
      expect(ids(v.categories), ['mde', 'mtr']);
    });

    Future<ProviderContainer> container(Map<String, Object> prefs) async {
      SharedPreferences.setMockInitialValues(prefs);
      final st = await Storage.open(store: PreviewSecretStore());
      final c = ProviderContainer(overrides: [
        storageProvider.overrideWith((ref) async => st),
        activePortalProvider.overrideWith(_Active.new),
        liveDataProvider.overrideWith(() => _Live(const LiveData(cats, chans))),
        myGroupsProvider.overrideWith(_Groups.new),
        moviesProvider.overrideWith(() => _Vod(movies)),
        seriesProvider.overrideWith(() => _Vod(const VodData([], []))),
      ]);
      addTearDown(c.dispose);
      for (final p in <ProviderListenable<Object?>>[
        visibleLiveDataProvider,
        visibleMoviesProvider,
        adultLockEnabledProvider,
        countryFilterProvider,
      ]) {
        c.listen(p, (_, __) {});
      }
      await c.read(storageProvider.future);
      await c.read(activePortalProvider.future);
      await c.read(liveDataProvider.future);
      await c.read(myGroupsProvider.future);
      await c.read(moviesProvider.future);
      return c;
    }

    test('Provider: 18+-Sperre vorerst aus (nichts versteckt), '
        'Länderfilter, Kindermodus obendrauf', () async {
      expect(kAdultAutoLockFeature, isFalse);
      final c = await container({});
      var live = c.read(visibleLiveDataProvider).value!;
      // Automatische 18+-Sperre ist abgeschaltet → Gruppe bleibt sichtbar.
      expect(ids(live.categories), contains('xxx'));
      expect(ids(live.channels), contains('x1'));
      expect(c.read(adultLockActiveProvider), isFalse);
      // Auch Filme/Serien unverändert, kein Hinweis-Dialog fällig.
      expect(ids(c.read(visibleMoviesProvider).value!.items), contains('b'));
      expect(c.read(adultInfoDueProvider), isFalse);

      // Länderfilter: nur TR (pro Portal gespeichert).
      await c.read(countryFilterProvider.notifier).set({'TR'});
      live = c.read(visibleLiveDataProvider).value!;
      expect(ids(live.channels), ['t1', 'k2']);
      final st = await c.read(storageProvider.future);
      expect(st.countries(Portal.demo.id), {'TR'});

      // Kindermodus: nur Gruppe „kids“ – wirkt zusätzlich.
      await st.setKidsGroups(Portal.demo.id, {'kids'});
      await c.read(profileModeProvider.notifier).setKids(true);
      c.invalidate(profileModeProvider);
      live = c.read(visibleLiveDataProvider).value!;
      expect(ids(live.channels), ['k2']);
      expect(ids(live.categories), ['kids']);

      // Alle Länder wieder → Kindermodus allein.
      await c.read(countryFilterProvider.notifier).set(const {});
      expect(ids(c.read(visibleLiveDataProvider).value!.channels),
          ['k1', 'k2']);
    });

    test('Sperre ausgeschaltet → Erwachsene sichtbar', () async {
      final c = await container({'set_adultlock': false});
      expect(ids(c.read(visibleLiveDataProvider).value!.channels),
          contains('x1'));
      expect(c.read(adultInfoDueProvider), isFalse);
    });

    test('Einmaliger Hinweis nur ohne PIN und nur einmal',
        skip: !kAdultAutoLockFeature, () async {
      final c = await container({});
      expect(c.read(adultInfoDueProvider), isTrue);
      final st = await c.read(storageProvider.future);
      await st.setAdultInfoShown();
      c.invalidate(adultInfoDueProvider);
      expect(c.read(adultInfoDueProvider), isFalse);
    });
  });
}

class _Active extends ActivePortalNotifier {
  @override
  Future<Portal?> build() async => Portal.demo;
}

class _Live extends LiveNotifier {
  final LiveData data;
  _Live(this.data);
  @override
  Future<LiveData> build() async => data;
}

class _Groups extends MyGroupsNotifier {
  @override
  Future<List<MyGroup>> build() async => const [];
}

class _Vod extends VodNotifier {
  final VodData data;
  _Vod(this.data) : super(false);
  @override
  Future<VodData> build() async => data;
}
