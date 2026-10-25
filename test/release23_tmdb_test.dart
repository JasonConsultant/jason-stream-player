import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:jason_stream_player/core/secret_store.dart';
import 'package:jason_stream_player/data/db/db_io.dart' as dbi;
import 'package:jason_stream_player/data/storage.dart';
import 'package:jason_stream_player/data/xtream_repository.dart';
import 'package:jason_stream_player/l10n/strings.dart';
import 'package:jason_stream_player/models/models.dart';
import 'package:jason_stream_player/player/data_saver.dart';
import 'package:jsp_exoplayer/jsp_cast.dart' show JspNetState;
import 'package:jason_stream_player/state/profile_mode.dart';
import 'package:jason_stream_player/state/providers.dart';
import 'package:jason_stream_player/state/tmdb.dart';
import 'package:jason_stream_player/ui/search/person_screen.dart';
import 'package:jason_stream_player/ui/settings/tmdb_settings_screen.dart';
import 'package:jason_stream_player/ui/vod/movie_detail_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/app_fonts.dart';
import 'helpers/tv_harness.dart';

/// 2.3 TMDB: Schlüssel, Abgleich Titel/Jahr, TMDB-ID vom Anbieter,
/// Zwischenspeicher/TTL, ohne Schlüssel kein Netz, Fehler, Zusammenführen,
/// Detailseite, Personen-Filmografie, Einstellungen.
///
/// `TV_SHOTS=ordner`: phone_tmdb_settings, phone_movie_detail_tmdb,
/// tv_movie_detail_tmdb, phone_person_tmdb.

const _v3 = '0123456789abcdef0123456789abcdef';
const _v4 =
    'eyJhbGciOiJIUzI1NiJ9.eyJhdWQiOiJ0ZXN0IiwibmJmIjoxLCJzdWIiOiJ4In0.c2lnbmF0dXJlLXRlc3Q';

/// Fake-TMDB. Zählt Anfragen, prüft Schlüssel (v3 als api_key, v4 Bearer).
class FakeTmdb {
  final requests = <Uri>[];
  final headers = <Map<String, String>>[];
  int status = 200;
  bool offline = false;
  int rateLimitOnce = 0;

  late final client = MockClient((req) async {
    requests.add(req.url);
    headers.add(req.headers);
    if (offline) throw http.ClientException('offline');
    if (rateLimitOnce > 0) {
      rateLimitOnce--;
      return http.Response('{}', 429, headers: {'retry-after': '1'});
    }
    final key = req.url.queryParameters['api_key'];
    final bearer = req.headers['Authorization'];
    final ok = key == _v3 || bearer == 'Bearer $_v4';
    if (!ok) return http.Response('{"status_code":7}', 401);
    if (status != 200) return http.Response('{}', status);
    final p = req.url.path.replaceFirst('/3', '');
    final q = req.url.queryParameters;
    Object body = const {};
    switch (p) {
      case '/configuration':
        body = {
          'images': {'base_url': 'x'}
        };
      case '/search/movie':
        if ((q['query'] ?? '').toLowerCase().contains('pate')) {
          body = {
            'results': [
              {
                'id': 999,
                'title': 'Der Pate',
                'release_date': '2031-01-01',
                'popularity': 200.0
              },
              {
                'id': 238,
                'title': 'Der Pate',
                'original_title': 'The Godfather',
                'release_date': '1972-03-14',
                'popularity': 80.0
              },
            ]
          };
        } else {
          body = {'results': []};
        }
      case '/movie/238':
        body = _godfather;
      case '/movie/550':
        body = {..._godfather, 'id': 550, 'title': 'Fight Club'};
      case '/search/person':
        body = {
          'results': [
            {'id': 3084, 'name': 'Marlon Brando', 'profile_path': '/mb.jpg'}
          ]
        };
      case '/person/3084/combined_credits':
        body = {
          'cast': [
            {
              'id': 238,
              'media_type': 'movie',
              'title': 'Der Pate',
              'original_title': 'The Godfather',
              'release_date': '1972-03-14',
              'poster_path': '/p.jpg',
              'popularity': 80.0,
              'character': 'Don Vito Corleone'
            },
            {
              'id': 28,
              'media_type': 'movie',
              'title': 'Apocalypse Now',
              'release_date': '1979-08-15',
              'popularity': 40.0
            },
            {
              'id': 77,
              'media_type': 'tv',
              'title': 'Talk',
              'name': 'Late Show',
              'genre_ids': [10767],
            },
          ],
          'crew': []
        };
    }
    return http.Response.bytes(utf8.encode(jsonEncode(body)), 200,
        headers: {'content-type': 'application/json; charset=utf-8'});
  });

  int count(String path) =>
      requests.where((u) => u.path == '/3$path').length;
}

const _godfather = {
  'id': 238,
  'title': 'Der Pate',
  'original_title': 'The Godfather',
  'release_date': '1972-03-14',
  'overview': 'Die Geschichte der Familie Corleone.',
  'genres': [
    {'id': 18, 'name': 'Drama'},
    {'id': 80, 'name': 'Krimi'}
  ],
  'vote_average': 8.69,
  'runtime': 175,
  'poster_path': '/poster.jpg',
  'backdrop_path': '/back.jpg',
  'credits': {
    'cast': [
      {
        'id': 3084,
        'name': 'Marlon Brando',
        'character': 'Don Vito Corleone',
        'profile_path': '/mb.jpg'
      },
      {'id': 1158, 'name': 'Al Pacino', 'character': 'Michael Corleone'},
    ],
    'crew': [
      {'id': 1776, 'name': 'Francis Ford Coppola', 'job': 'Director'}
    ]
  },
  'videos': {
    'results': [
      {'site': 'YouTube', 'type': 'Teaser', 'key': 'teaserDE001', 'iso_639_1': 'de'},
      {'site': 'YouTube', 'type': 'Trailer', 'key': 'trailerEN01', 'iso_639_1': 'en'},
      {'site': 'YouTube', 'type': 'Trailer', 'key': 'trailerDE01', 'iso_639_1': 'de'},
    ]
  },
};

TmdbClient _client(FakeTmdb f,
        {String key = _v3, TmdbCache? cache, String lang = 'de'}) =>
    TmdbClient(
        key: key,
        client: f.client,
        cache: cache ?? MemoryTmdbCache(),
        lang: lang,
        minGap: Duration.zero);

const _portal = Portal(
    id: 'tp', name: 'P', type: PortalType.xtream, url: 'http://srv');

const _godfatherItem = VodItem(
    id: 'm1',
    name: 'DE - Der Pate (1972) [4K]',
    categoryId: 'c',
    streamUrl: 'http://srv/movie/u/p/m1.mkv',
    plot: 'Anbieter-Text');

const _movies = VodData([Category(id: 'c', name: 'Filme')], [_godfatherItem]);

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    L10n.lang = 'de';
    await initializeDateFormatting('de');
    await loadAppFonts();
  });

  group('Schlüssel und Abgleich', () {
    test('Schlüssel v3/v4 erkennen', () {
      expect(TmdbKey.plausible(_v3), isTrue);
      expect(TmdbKey.plausible('Bearer $_v4'), isTrue);
      expect(TmdbKey.plausible('abc'), isFalse);
      expect(TmdbKey.plausible('${_v3}x'), isFalse);
    });

    test('Anbieter-Titel bereinigen', () {
      const cases = {
        'DE - Der Pate (1972) [4K]': ('Der Pate', 1972),
        '|TR| Kurtlar Vadisi Irak 2006': ('Kurtlar Vadisi Irak', 2006),
        'Inception - 2010': ('Inception', 2010),
        '[DE] Matrix HD': ('Matrix', null),
        'EN: The Office (US)': ('The Office (US)', null),
        'Babylon Berlin': ('Babylon Berlin', null),
        'TR: Aşk-ı Memnu FHD MULTI SUB': ('Aşk-ı Memnu', null),
        '4K - Dune: Part Two (2024)': ('Dune: Part Two', 2024),
      };
      for (final e in cases.entries) {
        final c = TmdbMatch.clean(e.key);
        expect((c.title, c.year), e.value, reason: e.key);
      }
    });

    test('Ähnlichkeit und Jahr', () {
      expect(TmdbMatch.similarity('Der Pate', 'der pate'), 1);
      expect(TmdbMatch.similarity('Sahin', 'Şahin'), 1);
      expect(
          TmdbMatch.score(
              title: 'Der Pate', year: 1972, candTitle: 'Der Pate', candYear: 1990),
          isNull,
          reason: 'anderes Jahr = anderer Film');
      expect(
          TmdbMatch.score(
              title: 'Der Pate', year: 1972, candTitle: 'Der Pate', candYear: 1973),
          isNotNull);
      expect(
          TmdbMatch.score(title: 'Der Pate', candTitle: 'Titanic'), isNull);
    });

    test('Anbieter-Feld tmdb/tmdb_id', () {
      expect(XtreamRepository.tmdbOf(238), '238');
      expect(XtreamRepository.tmdbOf('238'), '238');
      expect(XtreamRepository.tmdbOf('movie/238'), '238');
      expect(XtreamRepository.tmdbOf(''), isNull);
      expect(XtreamRepository.tmdbOf('0'), isNull);
      expect(XtreamRepository.tmdbOf(null), isNull);
    });
  });

  group('Client (Fake-HTTP)', () {
    test('Titel + Jahr: richtiger Kandidat, Details, Trailer in App-Sprache',
        () async {
      final f = FakeTmdb();
      final c = _client(f);
      final i = await c.lookup(title: _godfatherItem.name, tv: false);
      expect(i, isNotNull);
      expect(i!.id, 238, reason: 'Remake 2031 hat anderes Jahr');
      final search = f.requests.firstWhere((u) => u.path == '/3/search/movie');
      expect(search.queryParameters['query'], 'Der Pate');
      expect(search.queryParameters['year'], '1972');
      expect(search.queryParameters['language'], 'de-DE');
      expect(search.queryParameters['api_key'], _v3);
      expect(i.genres, ['Drama', 'Krimi']);
      expect(i.director, 'Francis Ford Coppola');
      expect(i.cast.first.name, 'Marlon Brando');
      expect(i.cast.first.profilePath, '/mb.jpg');
      expect(i.trailerKey, 'trailerDE01');
      expect(i.runtimeMinutes, 175);
      expect(i.rating, closeTo(8.69, 0.001));
    });

    test('v4-Token als Bearer, nicht in der Adresse', () async {
      final f = FakeTmdb();
      await _client(f, key: 'Bearer $_v4').test();
      expect(f.requests.single.queryParameters.containsKey('api_key'), isFalse);
      expect(f.headers.single['Authorization'], 'Bearer $_v4');
    });

    test('TMDB-ID des Anbieters hat Vorrang (keine Suche)', () async {
      final f = FakeTmdb();
      final i = await _client(f)
          .lookup(title: 'Irgendwas', tv: false, tmdbId: '550');
      expect(i!.title, 'Fight Club');
      expect(f.count('/search/movie'), 0);
    });

    test('Zwischenspeicher: zweiter Abruf ohne Netz, nach 14 Tagen neu',
        () async {
      var now = DateTime(2026, 10, 1);
      final cache = MemoryTmdbCache(now: () => now);
      final f = FakeTmdb();
      await _client(f, cache: cache).lookup(title: 'Der Pate (1972)', tv: false);
      final n = f.requests.length;
      expect(n, 2); // Suche + Details
      // Neuer Client (App-Neustart), gleicher Speicher.
      await _client(f, cache: cache).lookup(title: 'Der Pate (1972)', tv: false);
      expect(f.requests.length, n);
      now = now.add(const Duration(days: 13));
      await _client(f, cache: cache).lookup(title: 'Der Pate (1972)', tv: false);
      expect(f.requests.length, n);
      now = now.add(const Duration(days: 2));
      await _client(f, cache: cache).lookup(title: 'Der Pate (1972)', tv: false);
      expect(f.requests.length, n + 2);
    });

    test('Nicht gefunden wird 3 Tage gemerkt', () async {
      var now = DateTime(2026, 10, 1);
      final cache = MemoryTmdbCache(now: () => now);
      final f = FakeTmdb();
      expect(await _client(f, cache: cache).lookup(title: 'Unbekannt', tv: false),
          isNull);
      expect(await _client(f, cache: cache).lookup(title: 'Unbekannt', tv: false),
          isNull);
      expect(f.count('/search/movie'), 1);
      now = now.add(const Duration(days: 4));
      await _client(f, cache: cache).lookup(title: 'Unbekannt', tv: false);
      expect(f.count('/search/movie'), 2);
    });

    test('Fehler: falscher Schlüssel, kein Netz, Server, Bremse', () async {
      final f = FakeTmdb();
      await expectLater(
          _client(f, key: 'ffffffffffffffffffffffffffffffff').test(),
          throwsA(isA<TmdbException>()
              .having((e) => e.kind, 'kind', TmdbErrorKind.invalidKey)));
      f.offline = true;
      await expectLater(
          _client(f).test(),
          throwsA(isA<TmdbException>()
              .having((e) => e.kind, 'kind', TmdbErrorKind.network)));
      f.offline = false;
      f.status = 500;
      await expectLater(
          _client(f).test(),
          throwsA(isA<TmdbException>()
              .having((e) => e.kind, 'kind', TmdbErrorKind.server)));
      f.status = 200;
      f.rateLimitOnce = 1;
      await _client(f).test(); // 429 → wartet Retry-After, zweiter Versuch
      expect(f.requests.length, 5);
    });

    test('Ratenbegrenzung: höchstens 4 gleichzeitig', () async {
      var inFlight = 0, peak = 0;
      final client = MockClient((req) async {
        inFlight++;
        peak = peak > inFlight ? peak : inFlight;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        inFlight--;
        return http.Response('{"id":1,"title":"x"}', 200);
      });
      final c = TmdbClient(
          key: _v3, client: client, cache: MemoryTmdbCache(), minGap: Duration.zero);
      await Future.wait([for (var i = 0; i < 12; i++) c.details(i + 1, tv: false)]);
      expect(peak, lessThanOrEqualTo(4));
      expect(c.requests, 12);
    });

    test('Personen-Filmografie ohne Talkshows', () async {
      final f = FakeTmdb();
      final p = await _client(f).person('Marlon Brando');
      expect(p!.id, 3084);
      expect(p.credits.map((c) => c.title), ['Der Pate', 'Apocalypse Now']);
    });

    test('Datenbank-Speicher (Schema 2, auch nach Update von Schema 1)', () {
      final db = dbi.openCatalogInMemory();
      addTearDown(db.close);
      dbi.kvPut(db, 'a', 'eins', 1000);
      expect(dbi.kvGet(db, 'a', 999), 'eins');
      expect(dbi.kvGet(db, 'a', 1001), isNull, reason: 'zu alt');
      // Update: Datei mit Schema 1 → 2, vorhandene Daten bleiben.
      final old = dbi.openCatalogInMemory();
      addTearDown(old.close);
      old.execute('DROP TABLE meta_cache');
      old.userVersion = 1;
      old.execute("INSERT INTO src(key) VALUES ('portal1')");
      dbi.migrateCatalog(old);
      expect(old.userVersion, 2);
      expect(old.select('SELECT key FROM src').single['key'], 'portal1');
      dbi.kvPut(old, 'k', 'v', 5);
      expect(dbi.kvGet(old, 'k', 0), 'v');
    });
  });

  group('Zusammenführen', () {
    final info = TmdbClient.parseInfo(
        Map<String, dynamic>.from(jsonDecode(jsonEncode(_godfather))),
        tv: false);

    test('Anbieter + TMDB: nur Fehlendes ergänzen', () {
      final m = mergeTmdb(_godfatherItem, info, source: TmdbSource.mix);
      expect(m.plot, 'Anbieter-Text');
      expect(m.genre, 'Drama, Krimi');
      expect(m.posterUrl, 'https://image.tmdb.org/t/p/w342/poster.jpg');
      expect(m.backdropUrl, 'https://image.tmdb.org/t/p/w1280/back.jpg');
      expect(m.rating, 8.7);
      expect(m.trailer, 'trailerDE01');
      expect(m.duration, const Duration(minutes: 175));
      expect(m.tmdbId, '238');
      expect(m.id, 'm1');
      expect(m.streamUrl, _godfatherItem.streamUrl);
    });

    test('TMDB bevorzugt ersetzt; Datensparmodus kleinere Bilder', () {
      final m = mergeTmdb(_godfatherItem, info,
          source: TmdbSource.tmdb, saver: true);
      expect(m.plot, 'Die Geschichte der Familie Corleone.');
      expect(m.posterUrl, 'https://image.tmdb.org/t/p/w185/poster.jpg');
      expect(m.backdropUrl, 'https://image.tmdb.org/t/p/w780/back.jpg');
    });

    test('Nur Anbieter: unverändert', () {
      expect(
          identical(
              mergeTmdb(_godfatherItem, info, source: TmdbSource.provider),
              _godfatherItem),
          isTrue);
    });

    test('Portal-Abgleich der Filmografie (Titel + Jahr ±1)', () {
      final idx = PortalTitleIndex(const [
        _godfatherItem,
        VodItem(
            id: 'm2',
            name: 'Apocalypse Now',
            year: 1990,
            categoryId: 'c',
            streamUrl: ''),
      ]);
      expect(
          idx.find(const TmdbPersonCredit(
                  id: 238, tv: false, title: 'Der Pate', year: 1972))
              ?.id,
          'm1');
      expect(
          idx.find(const TmdbPersonCredit(
              id: 28, tv: false, title: 'Apocalypse Now', year: 1979)),
          isNull,
          reason: 'Jahr passt nicht');
      expect(
          idx.find(const TmdbPersonCredit(
              id: 238, tv: true, title: 'Der Pate', year: 1972)),
          isNull,
          reason: 'Serie ≠ Film');
    });
  });

  group('Provider und Oberfläche', () {
    late FakeTmdb fake;
    setUp(() {
      fake = FakeTmdb();
      // Keine echten Netz-Bilder im Widget-Test (Platzhalter-Grafik).
      TmdbImages.base = 'tmdb-img:';
    });
    tearDown(() => TmdbImages.base = TmdbImages.defaultBase);

    Future<Storage> storage({String? key, TmdbSource? src}) async {
      SharedPreferences.setMockInitialValues({'set_applang': 'de'});
      final st = await Storage.open(store: PreviewSecretStore());
      if (key != null) await st.setTmdbKey(key);
      if (src != null) await st.setOption(TmdbSource.optionKey, src.id);
      return st;
    }

    List<Override> extra() => [
          tmdbHttpProvider.overrideWithValue(fake.client),
          tmdbCacheProvider.overrideWithValue(MemoryTmdbCache()),
          movieDetailsProvider.overrideWith((ref, m) async => m),
          networkStateProvider.overrideWith((ref) => Stream.value(
              const JspNetState(
                  connected: true, metered: false, cellular: false))),
        ];

    TvData data() => TvData(
          live: const LiveData([], []),
          portal: _portal,
          movies: _movies,
          series: const VodData([], []),
        );

    test('Ohne Schlüssel: kein einziger Abruf', () async {
      final st = await storage();
      final c = ProviderContainer(
          overrides: tvOverrides(data(), Future.value(st), extra: extra()));
      addTearDown(c.dispose);
      await c.read(storageProvider.future);
      expect(c.read(tmdbClientProvider), isNull);
      expect(await c.read(tmdbInfoProvider(TmdbQuery.of(_godfatherItem)).future),
          isNull);
      expect(await c.read(tmdbPersonProvider((name: 'Marlon Brando', id: null))
          .future), isNull);
      expect(fake.requests, isEmpty);
    });

    test('„Nur Anbieter“ mit Schlüssel: ebenfalls kein Abruf', () async {
      final st = await storage(key: _v3, src: TmdbSource.provider);
      final c = ProviderContainer(
          overrides: tvOverrides(data(), Future.value(st), extra: extra()));
      addTearDown(c.dispose);
      await c.read(storageProvider.future);
      expect(c.read(tmdbClientProvider), isNull);
      expect(fake.requests, isEmpty);
    });

    test('Schlüssel verschlüsselt gespeichert, nicht in der Sicherung',
        () async {
      final st = await storage(key: _v3);
      final prefs = await SharedPreferences.getInstance();
      final plain = prefs.getKeys().map((k) => '$k=${prefs.get(k)}').join();
      expect(plain, isNot(contains(_v3)));
      expect(st.tmdbKey, _v3);
      expect(jsonEncode(st.exportAll()), isNot(contains(_v3)));
      final again = await Storage.open(store: PreviewSecretStore());
      expect(again.tmdbKey, _v3);
    });

    test('Kindermodus: keine Personensuche über TMDB', () async {
      final st = await storage(key: _v3);
      await st.setFlag(Storage.kidsFlag, true);
      final c = ProviderContainer(
          overrides: tvOverrides(data(), Future.value(st), extra: extra()));
      addTearDown(c.dispose);
      await c.read(storageProvider.future);
      c.listen(profileModeProvider, (_, __) {});
      expect(c.read(kidsModeProvider), isTrue);
      expect(
          await c.read(tmdbPersonProvider((name: 'Marlon Brando', id: null))
              .future),
          isNull);
      expect(fake.count('/search/person'), 0);
    });

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 4; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    testWidgets('Detailseite (Handy) mit TMDB-Daten', (tester) async {
      final st = await storage(key: _v3);
      await pumpTv(tester, const MovieDetailScreen(movie: _godfatherItem),
          data(), Future.value(st),
          tv: false,
          size: const Size(1080, 2340),
          dpr: 3,
          extra: extra());
      await settle(tester);
      expect(find.text('Anbieter-Text'), findsOneWidget);
      expect(find.textContaining('Drama, Krimi'), findsOneWidget);
      expect(find.byKey(const ValueKey('trailer-button')), findsOneWidget);
      expect(find.text('Francis Ford Coppola'), findsOneWidget);
      await tester.scrollUntilVisible(
          find.byKey(const ValueKey('tmdb-cast')), 300,
          scrollable: find.byType(Scrollable).first);
      expect(find.text('Marlon Brando'), findsOneWidget);
      expect(find.text('Al Pacino'), findsOneWidget);
      expect(find.text('Zusätzliche Infos: TMDB'), findsOneWidget);
      await tester.scrollUntilVisible(
          find.byKey(const ValueKey('tmdb-cast')), -600,
          scrollable: find.byType(Scrollable).first);
      await writeShot(tester, tvShotKey, 'phone_movie_detail_tmdb');
      await tvDone(tester);
    });

    testWidgets('Detailseite (TV): Besetzung per D-Pad erreichbar',
        (tester) async {
      final st = await storage(key: _v3);
      await pumpTv(tester, const MovieDetailScreen(movie: _godfatherItem),
          data(), Future.value(st),
          extra: extra());
      await settle(tester);
      await writeShot(tester, tvShotKey, 'tv_movie_detail_tmdb');
      // ▼ mehrmals: Knöpfe → Beschreibung → Besetzung.
      var reached = false;
      for (var i = 0; i < 8 && !reached; i++) {
        await tvKey(tester, LogicalKeyboardKey.arrowDown);
        final f = FocusManager.instance.primaryFocus?.context;
        reached = f != null &&
            find
                .ancestor(
                    of: find.byElementPredicate((e) => e == f),
                    matching: find.byKey(const ValueKey('tmdb-cast-3084')))
                .evaluate()
                .isNotEmpty;
        if (!reached && f != null) {
          final w = f.widget;
          reached = w.key == const ValueKey('tmdb-cast-3084');
        }
      }
      // Fokus liegt in der Besetzungsreihe; OK öffnet die Person.
      await tvKey(tester, LogicalKeyboardKey.select);
      await settle(tester);
      expect(find.byType(PersonScreen), findsOneWidget);
      await tvDone(tester);
    });

    testWidgets('Person: im Portal verfügbare Titel markiert', (tester) async {
      final st = await storage(key: _v3);
      await pumpTv(
          tester,
          const PersonScreen(name: 'Marlon Brando', titles: [], tmdbId: 3084),
          data(),
          Future.value(st),
          tv: false,
          size: const Size(1080, 2340),
          dpr: 3,
          extra: extra());
      await settle(tester);
      expect(find.text('1 im Portal · 2 laut TMDB'), findsOneWidget);
      expect(find.byKey(const ValueKey('person-available')), findsOneWidget);
      expect(find.byKey(const ValueKey('person-missing-m28')), findsOneWidget);
      expect(find.text('Nicht im Portal'), findsOneWidget);
      await writeShot(tester, tvShotKey, 'phone_person_tmdb');
      await tvDone(tester);
    });

    testWidgets('Einstellungen: Schlüssel speichern, testen, Fehler',
        (tester) async {
      final st = await storage();
      await pumpTv(tester, const TmdbSettingsScreen(), data(), Future.value(st),
          tv: false, size: const Size(1080, 2340), dpr: 3, extra: extra());
      expect(find.text('Kein Schlüssel – TMDB ist aus'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('tmdb-key')), 'abc');
      await tester.tap(find.byKey(const ValueKey('tmdb-save')));
      await settle(tester);
      expect(find.byKey(const ValueKey('tmdb-error')), findsOneWidget);
      expect(st.tmdbKey, isNull);
      await tester.enterText(find.byKey(const ValueKey('tmdb-key')),
          'ffffffffffffffffffffffffffffffff');
      await tester.tap(find.byKey(const ValueKey('tmdb-save')));
      await settle(tester);
      expect(find.textContaining('lehnt den Schlüssel ab'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('tmdb-key')), _v3);
      await tester.tap(find.byKey(const ValueKey('tmdb-save')));
      await settle(tester);
      expect(find.byKey(const ValueKey('tmdb-ok')), findsOneWidget);
      expect(st.tmdbKey, _v3);
      expect(find.text('Schlüssel gespeichert (verschlüsselt)'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('tmdb-src-tmdb')));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.byKey(const ValueKey('tmdb-src-tmdb')));
      await settle(tester);
      expect(st.option(TmdbSource.optionKey, ''), 'tmdb');
      await tester.scrollUntilVisible(find.text(tmdbNotice), 300,
          scrollable: find.byType(Scrollable).first);
      expect(find.text(tmdbNotice), findsOneWidget);
      await tester.scrollUntilVisible(
          find.byKey(const ValueKey('tmdb-key-state')), -300,
          scrollable: find.byType(Scrollable).first);
      await writeShot(tester, tvShotKey, 'phone_tmdb_settings');
      await tvDone(tester);
    });
  });
}
