import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Ein Aufruf beim Test-Server.
class EmbyCall {
  final String method;
  final Uri uri;
  final Map<String, String> headers;
  final Object? body;
  EmbyCall(this.method, this.uri, this.headers, this.body);
  String get path => uri.path;
  Map<String, String> get query => uri.queryParameters;
  @override
  String toString() => '$method ${uri.path}';
}

/// Nachgebauter Emby-Server (die für die App wichtigen Endpunkte) – als
/// echter HTTP-Server ([start]) oder als [client] ohne Netzwerk für
/// Widget-Tests.
class FakeEmby {
  static const user = 'jason';
  static const password = 'geheim';
  static const token = 'tok_0123456789abcdef';
  static const userId = 'u1';

  /// Anzahl Filme in der Mediathek „Filme“ (> 500 → mehrere Seiten).
  int movieCount;

  /// Antwort auf PlaybackInfo (überschreibbar je Test).
  Map<String, dynamic> Function(String itemId)? playbackInfo;

  /// Jellyfin statt Emby melden.
  bool jellyfin;

  /// false = keine Bild-Kennungen liefern (Widget-Tests ohne Netzwerkbilder).
  bool images = true;

  final calls = <EmbyCall>[];
  final played = <String>{};
  HttpServer? _server;

  FakeEmby({this.movieCount = 1203, this.jellyfin = false});

  String get base => 'http://${_server!.address.host}:${_server!.port}';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen((req) async {
      final body = await utf8.decoder.bind(req).join();
      final headers = <String, String>{};
      req.headers.forEach((k, v) => headers[k.toLowerCase()] = v.join(','));
      final (status, json) = handle(req.method, req.uri, headers,
          body.isEmpty ? null : jsonDecode(body));
      req.response.statusCode = status;
      if (json != null) {
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(json));
      }
      await req.response.close();
    });
  }

  Future<void> stop() async => _server?.close(force: true);

  /// HTTP-Client ohne Netzwerk (für testWidgets).
  http.Client get client => MockClient((r) async {
        final headers = {
          for (final e in r.headers.entries) e.key.toLowerCase(): e.value
        };
        final (status, json) = handle(r.method, r.url, headers,
            r.body.isEmpty ? null : jsonDecode(r.body));
        return http.Response(json == null ? '' : jsonEncode(json), status,
            headers: {'content-type': 'application/json; charset=utf-8'});
      });

  List<EmbyCall> callsTo(String path) =>
      [for (final c in calls) if (c.path == path) c];

  static Map<String, dynamic> movie(int i, {String lib = 'v1'}) => {
        'Id': 'm$i',
        'Name': i == 0 ? 'Der Pate' : 'Film ${i.toString().padLeft(4, '0')}',
        'Type': 'Movie',
        'ProductionYear': 1972 + (i % 50),
        'CommunityRating': 9.2,
        'OfficialRating': 'FSK-16',
        'Overview': 'Die Geschichte der Familie Corleone.',
        'Genres': ['Drama', 'Krimi'],
        'RunTimeTicks': 105000000000, // 175 min
        'DateCreated': '2024-05-01T12:00:00.0000000Z',
        'People': [
          {'Name': 'Marlon Brando', 'Type': 'Actor'},
          {'Name': 'Al Pacino', 'Type': 'Actor'},
          {'Name': 'Francis Ford Coppola', 'Type': 'Director'},
        ],
        'UserData': {
          'PlaybackPositionTicks': i == 0 ? 36000000000 : 0, // 60 min
          'Played': i == 1,
        },
        'ImageTags': {'Primary': 'ptag$i'},
        'BackdropImageTags': ['btag$i'],
        'ProviderIds': {'Tmdb': '238'},
        'RemoteTrailers': [
          {'Url': 'https://www.youtube.com/watch?v=sY1S34973zA'}
        ],
      };

  static Map<String, dynamic> series(int i) => {
        'Id': 's$i',
        'Name': ['Dark', 'Babylon Berlin', 'Tatort'][i % 3],
        'Type': 'Series',
        'ProductionYear': 2017 + i,
        'CommunityRating': 8.7,
        'Overview': 'Eine Kleinstadt, vier Familien, ein Rätsel.',
        'Genres': ['Mystery', 'Drama'],
        'People': [
          {'Name': 'Louis Hofmann', 'Type': 'Actor'},
        ],
        'UserData': {'Played': false},
        'ImageTags': {'Primary': 'stag$i'},
        'BackdropImageTags': [],
      };

  static Map<String, dynamic> episode(String series, int season, int n) => {
        'Id': '${series}e${season}x$n',
        'Name': 'Folge $n',
        'Type': 'Episode',
        'SeriesId': series,
        'SeriesName': 'Dark',
        'ParentIndexNumber': season,
        'IndexNumber': n,
        'Overview': 'Inhalt der Folge $n.',
        'RunTimeTicks': 30000000000, // 50 min
        'UserData': {
          'PlaybackPositionTicks': season == 1 && n == 2 ? 6000000000 : 0,
          'Played': season == 1 && n == 1,
        },
        'ImageTags': {'Primary': 'etag$n'},
      };

  Map<String, dynamic> defaultPlaybackInfo(String id) => {
        'PlaySessionId': 'ps1',
        'MediaSources': [
          {
            'Id': 'ms_$id',
            'Container': 'mkv',
            'Bitrate': 8000000,
            'SupportsDirectPlay': true,
            'SupportsDirectStream': true,
            'SupportsTranscoding': true,
            'MediaStreams': [
              {'Type': 'Video', 'Index': 0, 'Codec': 'hevc'},
              {'Type': 'Audio', 'Index': 1, 'Language': 'eng', 'Codec': 'ac3'},
              {'Type': 'Audio', 'Index': 2, 'Language': 'ger', 'Codec': 'ac3'},
              {
                'Type': 'Subtitle',
                'Index': 3,
                'Language': 'ger',
                'Codec': 'subrip',
                'IsExternal': false,
                'IsTextSubtitleStream': true,
                'DisplayTitle': 'Deutsch'
              },
              {
                'Type': 'Subtitle',
                'Index': 4,
                'Language': 'eng',
                'Codec': 'srt',
                'IsExternal': true,
                'IsTextSubtitleStream': true,
                'DisplayTitle': 'English (SRT)'
              },
            ],
          }
        ],
      };

  (int, Object?) handle(
      String method, Uri uri, Map<String, String> headers, Object? body) {
    final (status, json) = _handle(method, uri, headers, body);
    return (status, images ? json : _noImages(json));
  }

  static Object? _noImages(Object? j) {
    if (j is Map) {
      return {
        for (final e in j.entries)
          if (e.key != 'ImageTags' && e.key != 'BackdropImageTags')
            e.key: _noImages(e.value),
      };
    }
    if (j is List) return [for (final x in j) _noImages(x)];
    return j;
  }

  (int, Object?) _handle(
      String method, Uri uri, Map<String, String> headers, Object? body) {
    calls.add(EmbyCall(method, uri, headers, body));
    final p = uri.path;
    final q = uri.queryParameters;
    if (p == '/System/Info/Public') {
      return (
        200,
        {
          'ServerName': 'Jasons Mediathek',
          'Version': jellyfin ? '10.9.11' : '4.8.10.0',
          'Id': 'srv1',
          'ProductName': jellyfin ? 'Jellyfin Server' : 'Emby Server',
        }
      );
    }
    if (p == '/Users/AuthenticateByName' && method == 'POST') {
      final b = body as Map;
      if (b['Username'] == user && b['Pw'] == password) {
        return (
          200,
          {
            'AccessToken': token,
            'ServerId': 'srv1',
            'User': {'Id': userId, 'Name': 'Jason'},
          }
        );
      }
      return (401, null);
    }
    // Ab hier nur mit Token.
    if (headers['x-emby-token'] != token) return (401, null);
    if (p == '/Sessions/Logout') return (204, null);
    if (p == '/Users/$userId/Views') {
      return (
        200,
        {
          'Items': [
            {'Id': 'v1', 'Name': 'Filme', 'CollectionType': 'movies'},
            {'Id': 'v2', 'Name': 'Serien', 'CollectionType': 'tvshows'},
            {'Id': 'v3', 'Name': 'Musik', 'CollectionType': 'music'},
            {'Id': 'v4', 'Name': 'Kinder', 'CollectionType': null},
          ]
        }
      );
    }
    if (p == '/Users/$userId/Items') {
      final parent = q['ParentId'];
      final type = q['IncludeItemTypes'];
      final start = int.parse(q['StartIndex'] ?? '0');
      final limit = int.parse(q['Limit'] ?? '100');
      List<Map<String, dynamic>> all;
      if (parent == 'v1' && type == 'Movie') {
        all = [for (var i = 0; i < movieCount; i++) movie(i)];
      } else if (parent == 'v4' && type == 'Movie') {
        all = [
          {...movie(9000, lib: 'v4'), 'Name': 'Die Sendung mit der Maus'}
        ];
      } else if (parent == 'v2' && type == 'Series') {
        all = [for (var i = 0; i < 3; i++) series(i)];
      } else {
        all = const [];
      }
      final page = all.skip(start).take(limit).toList();
      return (200, {'Items': page, 'TotalRecordCount': all.length, 'StartIndex': start});
    }
    if (p == '/Users/$userId/Items/Resume') {
      return (
        200,
        {
          'Items': [
            movie(0),
            episode('s0', 1, 2),
          ]
        }
      );
    }
    if (p == '/Users/$userId/Items/Latest') {
      return (200, [movie(5), series(1)]);
    }
    final item = RegExp(r'^/Users/u1/Items/(\w+)$').firstMatch(p);
    if (item != null) {
      final id = item[1]!;
      if (id.startsWith('m')) {
        return (200, movie(int.tryParse(id.substring(1)) ?? 0));
      }
      if (id.startsWith('s')) {
        return (200, series(int.tryParse(id.substring(1)) ?? 0));
      }
      return (404, null);
    }
    final seasons = RegExp(r'^/Shows/(\w+)/Seasons$').firstMatch(p);
    if (seasons != null) {
      final s = seasons[1]!;
      return (
        200,
        {
          'Items': [
            {'Id': '${s}_se2', 'Name': 'Staffel 2', 'IndexNumber': 2},
            {'Id': '${s}_se1', 'Name': 'Staffel 1', 'IndexNumber': 1},
          ]
        }
      );
    }
    final eps = RegExp(r'^/Shows/(\w+)/Episodes$').firstMatch(p);
    if (eps != null) {
      final s = eps[1]!;
      final season = q['SeasonId'] == '${s}_se2' ? 2 : 1;
      return (
        200,
        {
          'Items': [
            for (var n = 3; n >= 1; n--) episode(s, season, n),
          ]
        }
      );
    }
    final pi = RegExp(r'^/Items/(\w+)/PlaybackInfo$').firstMatch(p);
    if (pi != null && method == 'POST') {
      return (200, (playbackInfo ?? defaultPlaybackInfo)(pi[1]!));
    }
    if (p.startsWith('/Sessions/Playing')) return (204, null);
    final pl = RegExp(r'^/Users/u1/PlayedItems/(\w+)$').firstMatch(p);
    if (pl != null) {
      method == 'POST' ? played.add(pl[1]!) : played.remove(pl[1]!);
      return (200, {'Played': method == 'POST'});
    }
    return (404, null);
  }
}

/// Für [FakeEmby] gebaute Zeitspanne in Ticks (100 ns).
int ticks(Duration d) => d.inMicroseconds * 10;

/// Nicht-blockierend warten, bis [f] true liefert.
Future<void> until(bool Function() f,
    {Duration timeout = const Duration(seconds: 5)}) async {
  final end = DateTime.now().add(timeout);
  while (!f()) {
    if (DateTime.now().isAfter(end)) throw TimeoutException('until');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
