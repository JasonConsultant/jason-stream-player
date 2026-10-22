import 'dart:convert';
import 'dart:typed_data';

/// Synthetische Xtream-Antworten (JSON-Bytes) für Last-/Laufzeittests.

Uint8List xtreamCategories(int n) => utf8.encode(jsonEncode([
      for (var i = 0; i < n; i++)
        {'category_id': '$i', 'category_name': 'DE | Gruppe $i', 'parent_id': 0}
    ]));

Uint8List xtreamLiveStreams(int n, {int groups = 800, String tag = ''}) =>
    utf8.encode(jsonEncode([
      for (var i = 0; i < n; i++)
        {
          'num': i + 1,
          'name': 'DE: Sender $i$tag HD',
          'stream_type': 'live',
          'stream_id': 100000 + i,
          'stream_icon': 'http://logo.example/l/$i.png',
          'epg_channel_id': 'sender$i.de',
          'added': '1700000000',
          'category_id': '${i % groups}',
          'tv_archive': i % 5 == 0 ? 1 : 0,
          'tv_archive_duration': i % 5 == 0 ? 7 : 0,
        }
    ]));

Uint8List xtreamMovies(int n, {int groups = 400, String tag = ''}) =>
    utf8.encode(jsonEncode([
      for (var i = 0; i < n; i++)
        {
          'num': i + 1,
          'name': 'Film $i$tag (${1980 + i % 45})',
          'stream_type': 'movie',
          'stream_id': 500000 + i,
          'stream_icon': 'http://img.example/p/$i.jpg',
          'rating': '${(i % 90) / 10}',
          'added': '${1600000000 + i}',
          'category_id': '${i % groups}',
          'container_extension': i % 3 == 0 ? 'mkv' : 'mp4',
          'genre': i % 2 == 0 ? 'Drama, Thriller' : null,
        }
    ]));

Uint8List xtreamSeries(int n, {int groups = 200}) => utf8.encode(jsonEncode([
      for (var i = 0; i < n; i++)
        {
          'num': i + 1,
          'name': 'Serie $i',
          'series_id': 900000 + i,
          'cover': 'http://img.example/s/$i.jpg',
          'plot': 'Handlung $i',
          'releaseDate': '${1990 + i % 35}-01-01',
          'last_modified': '${1600000000 + i}',
          'rating': '7.${i % 10}',
          'backdrop_path': ['http://img.example/b/$i.jpg'],
          'episode_run_time': '45',
          'category_id': '${i % groups}',
        }
    ]));

/// Misst die längste Pause der Ereignisschleife des Haupt-Isolates, während
/// [work] läuft (Takt alle 2 ms). Ergebnis in Millisekunden.
Future<(T, int)> measureMainStall<T>(Future<T> Function() work) async {
  var maxGap = 0;
  var running = true;
  final sw = Stopwatch()..start();
  var last = sw.elapsedMilliseconds;
  Future<void> beat() async {
    while (running) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
      final now = sw.elapsedMilliseconds;
      final gap = now - last - 2;
      if (gap > maxGap) maxGap = gap;
      last = now;
    }
  }

  final hb = beat();
  final r = await work();
  running = false;
  await hb;
  return (r, maxGap);
}
