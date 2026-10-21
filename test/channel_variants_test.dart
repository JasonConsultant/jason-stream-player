import 'package:flutter_test/flutter_test.dart';
import 'package:jason_stream_player/data/channel_variants.dart';
import 'package:jason_stream_player/models/models.dart';

var _n = 0;
Channel _c(String name, {String group = 'g', String? id, String? logo, String? epg}) =>
    Channel(
        id: id ?? 'id${_n++}',
        name: name,
        categoryId: group,
        streamUrl: 'http://s/${_n++}',
        logoUrl: logo,
        epgId: epg);

/// Namen der Gruppen (sortiert), jeweils Mitglieder in Rang-Reihenfolge.
List<List<String>> _groups(List<Channel> list) => [
      for (final g in groupVariants(list)) [for (final c in g.members) c.name],
    ];

void main() {
  group('analyzeVariantName', () {
    test('Länderpräfixe in allen Schreibweisen', () {
      for (final n in ['DE: ZDF', 'DE | ZDF', '|DE| ZDF', '[DE] ZDF', 'DE - ZDF',
          'DE| ZDF HD', 'de: ZDF']) {
        final v = analyzeVariantName(n);
        expect(v.key, 'zdf', reason: n);
        expect(v.country, 'DE', reason: n);
      }
    });

    test('Qualitätsangaben werden erkannt und entfernt', () {
      expect(analyzeVariantName('ZDF HD').quality, VariantQuality.hd);
      expect(analyzeVariantName('ZDF FHD').quality, VariantQuality.fhd);
      expect(analyzeVariantName('ZDF Full HD').quality, VariantQuality.fhd);
      expect(analyzeVariantName('ZDF 1080p').quality, VariantQuality.fhd);
      expect(analyzeVariantName('ZDF 4K').quality, VariantQuality.uhd);
      expect(analyzeVariantName('ZDF UHD').quality, VariantQuality.uhd);
      expect(analyzeVariantName('ZDF RAW').quality, VariantQuality.raw);
      expect(analyzeVariantName('ZDF SD').quality, VariantQuality.sd);
      expect(analyzeVariantName('ZDF').quality, VariantQuality.unknown);
      expect(analyzeVariantName('DE: ZDF ᴴᴰ').quality, VariantQuality.hd);
      expect(analyzeVariantName('ZDFᴴᴰ').key, 'zdf');
      expect(analyzeVariantName('ZDF ᵁᴴᴰ').quality, VariantQuality.uhd);
      expect(analyzeVariantName('ZDF ᶠᴴᴰ').quality, VariantQuality.fhd);
      for (final n in ['ZDF HD', 'ZDF FHD', 'ZDF RAW', 'DE: ZDF ᴴᴰ',
          'ZDF (Backup)', 'ZDF 4K', 'ZDF SD', 'ZDF HEVC', 'ZDF H265',
          'ZDF HD 50fps', 'ZDF [HD]', 'ZDF.HD', 'zdf hd', 'ZDF HD Backup 2',
          'ZDF Alt', 'ZDF #2', 'ZDF HD 50']) {
        expect(analyzeVariantName(n).key, 'zdf', reason: n);
      }
    });

    test('Backup-Angaben', () {
      expect(analyzeVariantName('ZDF (Backup)').backup, isTrue);
      expect(analyzeVariantName('ZDF HD Alt').backup, isTrue);
      expect(analyzeVariantName('ZDF Backup1').backup, isTrue);
      expect(analyzeVariantName('ZDF #2').backup, isTrue);
      expect(analyzeVariantName('ZDF HD').backup, isFalse);
    });

    test('Ziffern im Namen bleiben erhalten', () {
      expect(analyzeVariantName('TR: TRT 1 HD').key, 'trt 1');
      expect(analyzeVariantName('Sky Sport 1 HD').key, 'sky sport 1');
      expect(analyzeVariantName('Sky Sport 2').key, 'sky sport 2');
      expect(analyzeVariantName('Sport1+').key, 'sport1+');
      expect(analyzeVariantName('Kanal 50').key, 'kanal 50');
    });

    test('Türkische Buchstaben', () {
      expect(analyzeVariantName('TR | ATV FHD').key, 'atv');
      expect(analyzeVariantName('TR | ATV FHD').country, 'TR');
      expect(analyzeVariantName('TRT BELGESEL HD').key,
          analyzeVariantName('TRT Belgesel').key);
      expect(analyzeVariantName('TR: SHOW TÜRK').key,
          analyzeVariantName('Show Türk HD').key);
      expect(analyzeVariantName('KANAL D İ').key, 'kanal d i');
    });

    test('Kurze/leere Namen', () {
      expect(analyzeVariantName('HD').key, '');
      expect(analyzeVariantName('DE: 4K').key, '');
    });
  });

  group('groupVariants', () {
    test('ZDF-Varianten werden zu einer Gruppe, FHD zuerst', () {
      final list = [
        _c('ZDF SD'),
        _c('ZDF HD'),
        _c('ZDF (Backup)'),
        _c('ZDF 4K'),
        _c('ZDF FHD'),
        _c('ZDF RAW'),
        _c('ARD HD'),
      ];
      expect(_groups(list), [
        ['ZDF FHD', 'ZDF HD', 'ZDF 4K', 'ZDF RAW', 'ZDF SD', 'ZDF (Backup)'],
      ]);
    });

    test('Ohne Qualitätsangabe zwischen HD und 4K', () {
      expect(_groups([_c('ZDF 4K'), _c('ZDF'), _c('ZDF HD')]), [
        ['ZDF HD', 'ZDF', 'ZDF 4K'],
      ]);
    });

    test('gleiche Qualität: ursprüngliche Reihenfolge', () {
      final a = _c('ZDF HD', id: 'a');
      final b = _c('ZDF ᴴᴰ', id: 'b');
      expect(groupVariants([a, b]).single.members.map((c) => c.id), ['a', 'b']);
    });

    test('verschiedene Gruppen, gleiches Land → zusammen', () {
      expect(
          _groups([
            _c('DE: ZDF HD', group: 'de_hd'),
            _c('DE | ZDF FHD', group: 'de_fhd'),
          ]),
          [
            ['DE | ZDF FHD', 'DE: ZDF HD'],
          ]);
    });

    test('verschiedene Gruppen ohne Land → getrennt', () {
      expect(_groups([_c('ZDF HD', group: 'a'), _c('ZDF FHD', group: 'b')]),
          isEmpty);
    });

    test('verschiedene Länder → nie zusammen, auch in einer Gruppe', () {
      expect(
          _groups([
            _c('DE: Eurosport 1', group: 'eu'),
            _c('UK: Eurosport 1', group: 'eu'),
          ]),
          isEmpty);
      // Kein Umweg über eine Variante ohne Land.
      final g = _groups([
        _c('DE: Eurosport 1 HD', group: 'eu'),
        _c('Eurosport 1', group: 'eu'),
        _c('UK: Eurosport 1', group: 'eu'),
      ]);
      expect(g, [
        ['DE: Eurosport 1 HD', 'Eurosport 1'],
      ]);
    });

    test('Türkische Sender', () {
      final g = _groups([
        _c('TR: TRT 1 HD', group: 'tr'),
        _c('TR: TRT 1 FHD', group: 'tr'),
        _c('TR: TRT 2', group: 'tr'),
        _c('TR | ATV FHD', group: 'tr'),
        _c('TR | ATV HD', group: 'tr'),
        _c('ATV Avrupa', group: 'tr'),
        _c('ATV Avrupa HD', group: 'tr'),
      ]);
      expect(g, unorderedEquals([
        ['TR: TRT 1 FHD', 'TR: TRT 1 HD'],
        ['TR | ATV FHD', 'TR | ATV HD'],
        ['ATV Avrupa HD', 'ATV Avrupa'],
      ]));
    });

    test('Keine Fehl-Zusammenlegungen', () {
      final list = [
        _c('ATV'),
        _c('ATV Avrupa'),
        _c('Sky Sport 1'),
        _c('Sky Sport 2'),
        _c('Sky Sport 1 HD'),
        _c('ProSieben'),
        _c('ProSieben Maxx'),
        _c('ProSieben Maxx HD'),
        _c('RTL'),
        _c('RTL II'),
        _c('RTLup'),
        _c('Sport1'),
        _c('Sport1+'),
        _c('Kabel Eins'),
        _c('Kabel Eins Doku'),
        _c('TRT 1'),
        _c('TRT 2'),
        _c('ZDF'),
        _c('ZDFneo'),
        _c('ZDF info'),
      ];
      expect(_groups(list), unorderedEquals([
        ['Sky Sport 1 HD', 'Sky Sport 1'],
        ['ProSieben Maxx HD', 'ProSieben Maxx'],
      ]));
    });

    test('Vorgaben: Fehl- und Pflicht-Zusammenlegungen', () {
      expect(_groups([_c('ATV'), _c('ATV Avrupa')]), isEmpty);
      expect(_groups([_c('Sky Sport 1'), _c('Sky Sport 2')]), isEmpty);
      expect(_groups([_c('ProSieben'), _c('ProSieben Maxx')]), isEmpty);
      expect(_groups([_c('TRT 1'), _c('TRT 1 HD')]), [
        ['TRT 1 HD', 'TRT 1'],
      ]);
      expect(_groups([_c('DE: ZDF HD'), _c('ZDF FHD')]), [
        ['ZDF FHD', 'DE: ZDF HD'],
      ]);
    });

    test('Markennamen mit Trenner sind kein Länderpräfix', () {
      // „HBO: Family“ ist nicht „Family“, „ATV - Avrupa“ nicht „Avrupa“.
      expect(analyzeVariantName('HBO: Family').country, isNull);
      expect(analyzeVariantName('HBO: Family').key, 'hbo family');
      expect(_groups([_c('HBO: Family'), _c('Family HD')]), isEmpty);
      expect(_groups([_c('ATV - Avrupa'), _c('Kanal 7 Avrupa')]), isEmpty);
      expect(analyzeVariantName('GER: ZDF').country, 'DE');
      expect(analyzeVariantName('[UK] BBC One HD').country, 'UK');
      expect(analyzeVariantName('[VIP] ZDF').key, 'vip zdf');
    });

    test('zu kurze/leere Namen werden nie zusammengelegt', () {
      expect(_groups([_c('HD'), _c('FHD'), _c('4K')]), isEmpty);
      expect(_groups([_c('X HD'), _c('X FHD')]), isEmpty);
      expect(_groups([_c('N1 HD'), _c('N1 FHD')]), [
        ['N1 FHD', 'N1 HD'],
      ]);
    });

    test('playOrder: Wahl des Nutzers zuerst', () {
      final g = groupVariants([
        _c('ZDF SD', id: 'sd'),
        _c('ZDF FHD', id: 'fhd'),
        _c('ZDF HD', id: 'hd'),
      ]).single;
      expect(g.playOrder(null).map((c) => c.id), ['fhd', 'hd', 'sd']);
      expect(g.playOrder('sd').map((c) => c.id), ['sd', 'fhd', 'hd']);
      expect(g.playOrder('unknown').map((c) => c.id), ['fhd', 'hd', 'sd']);
      expect(g.labelOf(g.members.last), 'SD');
    });
  });

  group('VariantIndex', () {
    final list = [
      _c('ARD', id: 'ard'),
      _c('ZDF SD', id: 'sd', logo: 'http://logo'),
      _c('ZDF FHD', id: 'fhd'),
      _c('ZDF HD', id: 'hd', epg: 'zdf.de'),
      _c('RTL', id: 'rtl'),
    ];

    test('collapse: beste Variante vertritt, Reihenfolge bleibt', () {
      final idx = VariantIndex.of(groupVariants(list));
      final out = idx.collapse(list);
      expect(out.map((c) => c.id), ['ard', 'fhd', 'rtl']);
      // Logo und EPG von anderen Varianten übernommen.
      expect(out[1].logoUrl, 'http://logo');
      expect(out[1].epgId, 'zdf.de');
      expect(idx.countOf('fhd'), 3);
      expect(idx.countOf('sd'), 3);
      expect(idx.countOf('ard'), 1);
      expect(idx.representativeOf('sd'), 'fhd');
      expect(idx.representativeOf('ard'), 'ard');
    });

    test('Favorit auf einer Variante vertritt die Gruppe', () {
      final idx = VariantIndex.of(groupVariants(list), favorites: {'sd'});
      expect(idx.collapse(list).map((c) => c.id), ['ard', 'sd', 'rtl']);
      expect(idx.representativeOf('hd'), 'sd');
    });

    test('Kindersicherung: gesperrte Variante vertritt die Gruppe', () {
      // „ZDF SD“ gesperrt – sonst wäre der Sender über „ZDF FHD“ ohne PIN
      // erreichbar.
      final idx = VariantIndex.of(groupVariants(list), locked: {'sd'});
      expect(idx.collapse(list).map((c) => c.id), ['ard', 'sd', 'rtl']);
      // Sperre schlägt Favorit.
      final idx2 = VariantIndex.of(groupVariants(list),
          locked: {'sd'}, favorites: {'hd'});
      expect(idx2.representativeOf('fhd'), 'sd');
      // Gesperrte, aber ausgeblendete Variante: wie vorher sichtbar die andere.
      final idx3 = VariantIndex.of(groupVariants(list),
          locked: {'sd'}, hidden: {'sd'});
      expect(idx3.representativeOf('sd'), 'fhd');
    });

    test('ausgeblendete beste Variante: andere vertritt (Sender bleibt)', () {
      final idx = VariantIndex.of(groupVariants(list), hidden: {'fhd'});
      expect(idx.collapse(list).map((c) => c.id), ['ard', 'hd', 'rtl']);
      final all = VariantIndex.of(groupVariants(list),
          hidden: {'fhd', 'hd', 'sd'});
      expect(all.representativeOf('sd'), 'fhd');
    });

    test('resolve: IDs verdeckter Varianten → Vertreter, ohne Doppelte', () {
      final idx = VariantIndex.of(groupVariants(list));
      final byId = {for (final c in idx.collapse(list)) c.id: c};
      expect(idx.resolve(['sd', 'rtl', 'fhd', 'hd', 'gone', 'ard'], byId)
          .map((c) => c.id), ['fhd', 'rtl', 'ard']);
    });

    test('leerer Index ändert nichts', () {
      expect(identical(VariantIndex.empty.collapse(list), list), isTrue);
    });

    test('große Liste in vertretbarer Zeit', () {
      final big = [
        for (var i = 0; i < 20000; i++)
          _c('DE: Sender ${i ~/ 3} ${['HD', 'FHD', 'SD'][i % 3]}',
              group: 'g${i ~/ 300}'),
      ];
      final sw = Stopwatch()..start();
      final g = groupVariants(big);
      expect(sw.elapsedMilliseconds, lessThan(3000));
      expect(g.length, greaterThan(6000));
    });
  });
}
