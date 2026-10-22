// Messung (nicht Teil von `flutter test`): flutter test test/bench/list_stall_bench.dart
// Längste Pause des Haupt-Isolates beim Nachladen großer Listen –
// vorher (1.4: Umwandeln + JSON-Kodieren im Haupt-Isolate) und nachher
// (1.5: alles in einem Hintergrund-Isolate, unverändert → nichts).
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jason_stream_player/data/list_cache.dart';
import 'package:jason_stream_player/data/net.dart';
import 'package:jason_stream_player/data/xtream_repository.dart';
import 'package:jason_stream_player/models/models.dart';

import '../helpers/xtream_stress.dart';

const portal = Portal(
    id: 'b',
    name: 'B',
    type: PortalType.xtream,
    url: 'http://srv.example:8080',
    username: 'user1',
    password: 'pass1');
const ctx = ('http://srv.example:8080', 'user1', 'pass1');

dynamic _decode(Uint8List b) => jsonDecode(utf8.decode(b));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final dir = Directory.systemTemp.createTempSync('bench15_');
  ListCache.debugDirectory = dir.path;
  tearDownAll(() => dir.deleteSync(recursive: true));

  Future<void> run(String name, Uint8List cats, Uint8List items, bool live,
      bool series) async {
    final b = <int>[], a = <int>[], u = <int>[], l = <int>[];
    late int count;
    for (var rep = 0; rep < 3; rep++) {
      final r = await once(cats, items, live, series);
      b.add(r.$1);
      a.add(r.$2);
      u.add(r.$3);
      l.add(r.$4);
      count = r.$5;
    }
    String f(List<int> x) {
      x.sort();
      return '${x[1]}ms (min ${x.first})';
    }

    // ignore: avoid_print
    print('BENCH $name ($count): main stall median before=${f(b)} '
        'after=${f(a)} unchanged=${f(u)} cacheLoad=${f(l)}');
  }

  test(
      'live 50k',
      () => run(
          'live', xtreamCategories(800), xtreamLiveStreams(50000), true, false),
      timeout: Timeout.none);
  test(
      'movies 100k',
      () => run(
          'movies', xtreamCategories(400), xtreamMovies(100000), false, false),
      timeout: Timeout.none);
  test(
      'series 20k',
      () => run(
          'series', xtreamCategories(200), xtreamSeries(20000), false, true),
      timeout: Timeout.none);
}

Future<(int, int, int, int, int)> once(
    Uint8List cats, Uint8List items, bool live, bool series) async {
  {
    // ---- vorher (Nachbau des 1.4-Ablaufs) ----
    final (_, before) = await measureMainStall(() async {
      final c = XtreamRepository.mapCategories(await compute(_decode, cats));
      final data = await compute(_decode, items);
      final List<Object> l = live
          ? XtreamRepository.mapLive(data, ctx.$1, ctx.$2, ctx.$3)
          : series
              ? XtreamRepository.mapSeries(data)
              : XtreamRepository.mapMovies(data, ctx.$1, ctx.$2, ctx.$3);
      // 1.4: jsonEncode im Haupt-Isolate, Maskieren im Isolate.
      final body = live
          ? ListCache.liveBody(c, l.cast<Channel>())
          : ListCache.vodBody(c, l.cast<VodItem>());
      await compute((String s) => s.replaceAll('user1', 'x'), body);
      return l.length;
    });
    // ---- nachher ----
    final kind = live ? 'live' : (series ? 'series' : 'movies');
    final spec = await ListCache.spec(kind, portal);
    // Netz simulieren: Antwort in 64-KB-Stücken (wie vom Socket).
    Net.client = MockClient.streaming((req, _) async {
      final a = req.url.queryParameters['action']!;
      final body = a.endsWith('categories') ? cats : items;
      // Jedes Stück als eigenes Ereignis (wie echte Socket-Daten).
      Stream<List<int>> chunks() async* {
        for (var i = 0; i < body.length; i += 65536) {
          await Future<void>.delayed(Duration.zero);
          yield Uint8List.fromList(Uint8List.sublistView(
              body, i, i + 65536 > body.length ? body.length : i + 65536));
        }
      }

      return http.StreamedResponse(chunks(), 200, contentLength: body.length);
    });
    final repo = XtreamRepository(portal);
    final (out, after) = await measureMainStall(
        () => live ? repo.liveBundle(spec) : repo.vodBundle(series, spec));
    final spec2 = await ListCache.spec(kind, portal, prevHash: out.hash);
    final (same, unchanged) = await measureMainStall(
        () => live ? repo.liveBundle(spec2) : repo.vodBundle(series, spec2));
    expect(same.unchanged, isTrue);
    // Start: Zwischenspeicher lesen.
    final (_, load) = await measureMainStall(() =>
        live ? ListCache.loadLive(portal) : ListCache.loadVod(kind, portal));
    return (before, after, unchanged, load, out.items.length);
  }
}
