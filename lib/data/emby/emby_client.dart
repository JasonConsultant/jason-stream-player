import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/security.dart';
import '../../l10n/strings.dart';

/// Schlüssel-Bereich für Emby-Einstellungen, die sonst pro Portal gelten
/// (Meine Liste, Verlauf, Kindermodus-Freigaben) – Emby gilt portalunabhängig.
const embyScope = '__emby';

/// Zugang zu einem Emby- (oder Jellyfin-)Server – unabhängig vom aktiven
/// IPTV-Portal. Gespeichert verschlüsselt (Storage.embyAccount), in
/// Sicherungen nur Adresse und Benutzername (kein Token, kein Passwort).
class EmbyAccount {
  /// Basis-Adresse ohne abschließenden Schrägstrich, z. B.
  /// `http://192.168.1.10:8096` oder `https://emby.example.org/emby`.
  final String server;
  final String userName;
  final String? userId;
  final String? token;
  final String? serverName;
  final String? serverVersion;
  final String? serverId;

  /// Jellyfin statt Emby (gleiche Schnittstelle, kleine Unterschiede).
  final bool jellyfin;

  const EmbyAccount({
    required this.server,
    required this.userName,
    this.userId,
    this.token,
    this.serverName,
    this.serverVersion,
    this.serverId,
    this.jellyfin = false,
  });

  bool get signedIn =>
      (token ?? '').isNotEmpty && (userId ?? '').isNotEmpty;

  /// Abgemeldet: Adresse und Benutzer bleiben zum erneuten Anmelden.
  EmbyAccount signedOut() => EmbyAccount(
        server: server,
        userName: userName,
        serverName: serverName,
        serverVersion: serverVersion,
        serverId: serverId,
        jellyfin: jellyfin,
      );

  Map<String, Object?> toJson() => {
        'server': server,
        'user': userName,
        if (userId != null) 'uid': userId,
        if (token != null) 'token': token,
        if (serverName != null) 'name': serverName,
        if (serverVersion != null) 'version': serverVersion,
        if (serverId != null) 'sid': serverId,
        if (jellyfin) 'jellyfin': true,
      };

  /// Für die Sicherungsdatei: ohne Token/Benutzer-ID → nach dem
  /// Wiederherstellen einmal neu anmelden.
  Map<String, Object?> toBackupJson() => {
        'server': server,
        'user': userName,
        if (serverName != null) 'name': serverName,
        if (jellyfin) 'jellyfin': true,
      };

  static EmbyAccount? fromJson(Object? j) {
    if (j is! Map) return null;
    final server = j['server'], user = j['user'];
    if (server is! String || server.isEmpty || user is! String) return null;
    String? s(Object? v) => v is String && v.isNotEmpty ? v : null;
    return EmbyAccount(
      server: server,
      userName: user,
      userId: s(j['uid']),
      token: s(j['token']),
      serverName: s(j['name']),
      serverVersion: s(j['version']),
      serverId: s(j['sid']),
      jellyfin: j['jellyfin'] == true,
    );
  }
}

/// Gerät, wie es sich beim Server meldet (X-Emby-Authorization).
class EmbyDevice {
  final String name;
  final String id;
  final String version;
  const EmbyDevice({required this.name, required this.id, required this.version});
}

enum EmbyErrorKind { badAddress, wrongCredentials, notEmby, server, network }

class EmbyException implements Exception {
  final EmbyErrorKind kind;
  final int? status;
  final String? detail;
  const EmbyException(this.kind, {this.status, this.detail});

  /// Verständliche Meldung für die Oberfläche (ohne Zugangsdaten).
  String get message => switch (kind) {
        EmbyErrorKind.badAddress => tr(
            'Ungültige Adresse. Beispiel: http://192.168.1.10:8096'),
        EmbyErrorKind.wrongCredentials =>
          tr('Benutzername oder Passwort ist falsch.'),
        EmbyErrorKind.notEmby =>
          tr('Unter dieser Adresse antwortet kein Emby-Server.'),
        EmbyErrorKind.server => trf('Der Emby-Server meldet einen Fehler ({0}).',
            [status ?? '?']),
        EmbyErrorKind.network => detail ??
            tr('Server nicht erreichbar. Internetverbindung und Adresse prüfen.'),
      };

  @override
  String toString() => message;
}

/// Eintrag aus `/Users/{id}/Views`.
class EmbyView {
  final String id;
  final String name;

  /// movies, tvshows, (null/leer = gemischt), music, …
  final String? collectionType;
  const EmbyView(this.id, this.name, this.collectionType);

  bool get movies => collectionType == 'movies';
  bool get tvshows => collectionType == 'tvshows';
  bool get mixed => collectionType == null || collectionType!.isEmpty ||
      collectionType == 'mixed' || collectionType == 'homevideos';
}

/// Schlanker HTTP-Client für die Emby-Schnittstelle (funktioniert auch mit
/// Jellyfin: beide Kopfzeilen-Varianten werden gesendet).
class EmbyClient {
  static const clientName = 'Jason Stream Player';
  static const itemFields = 'Overview,Genres,ProductionYear,CommunityRating,'
      'OfficialRating,RunTimeTicks,DateCreated,People,UserData,ImageTags,'
      'BackdropImageTags,ProviderIds,RemoteTrailers';
  static const episodeFields = 'Overview,UserData,RunTimeTicks,ImageTags';
  static const pageSize = 500;

  final String base;
  final EmbyDevice device;
  final String? token;
  final String? userId;
  final http.Client _http;
  final Duration timeout;

  EmbyClient(
    String server, {
    required this.device,
    this.token,
    this.userId,
    http.Client? client,
    this.timeout = const Duration(seconds: 20),
  })  : base = normalizeServer(server) ?? server,
        _http = client ?? http.Client() {
    if ((token ?? '').length >= 8) Redactor.register(token, null);
  }

  factory EmbyClient.forAccount(EmbyAccount a,
          {required EmbyDevice device, http.Client? client}) =>
      EmbyClient(a.server,
          device: device, token: a.token, userId: a.userId, client: client);

  /// „192.168.1.10:8096/“ → „http://192.168.1.10:8096“; ungültig → null.
  /// Angehängte Weboberfläche (`/web/index.html`) wird entfernt.
  static String? normalizeServer(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return null;
    if (!s.contains('://')) s = 'http://$s';
    final u = Uri.tryParse(s);
    if (u == null ||
        (u.scheme != 'http' && u.scheme != 'https') ||
        u.host.isEmpty) {
      return null;
    }
    var path = u.path;
    final web = path.indexOf('/web');
    if (web >= 0 && (path.length == web + 4 || path[web + 4] == '/')) {
      path = path.substring(0, web);
    }
    while (path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    return Uri(
            scheme: u.scheme,
            host: u.host,
            port: u.hasPort ? u.port : null,
            path: path)
        .toString();
  }

  /// Wert der Kopfzeile `X-Emby-Authorization` (Jellyfin: `Authorization:
  /// MediaBrowser …`).
  String authValue() {
    String q(String v) => v.replaceAll('"', "'");
    final parts = [
      'Client="${q(clientName)}"',
      'Device="${q(device.name.isEmpty ? 'Android' : device.name)}"',
      'DeviceId="${q(device.id)}"',
      'Version="${q(device.version.isEmpty ? '1.0' : device.version)}"',
      if ((token ?? '').isNotEmpty) 'Token="${q(token!)}"',
    ];
    return 'Emby ${parts.join(', ')}';
  }

  Map<String, String> get headers => {
        'X-Emby-Authorization': authValue(),
        'Authorization': authValue().replaceFirst('Emby ', 'MediaBrowser '),
        if ((token ?? '').isNotEmpty) 'X-Emby-Token': token!,
        'Accept': 'application/json',
      };

  Uri uri(String path, [Map<String, String?>? query]) {
    final q = <String, String>{
      if (query != null)
        for (final e in query.entries)
          if (e.value != null) e.key: e.value!,
    };
    final u = Uri.parse('$base$path');
    return q.isEmpty ? u : u.replace(queryParameters: q);
  }

  String get _uid {
    final u = userId;
    if (u == null || u.isEmpty) {
      throw const EmbyException(EmbyErrorKind.wrongCredentials);
    }
    return u;
  }

  Future<Object?> _send(String method, String path,
      {Map<String, String?>? query, Object? body, bool auth = true}) async {
    final req = http.Request(method, uri(path, query));
    req.headers.addAll(headers);
    if (body != null) {
      req.headers['Content-Type'] = 'application/json';
      req.body = jsonEncode(body);
    }
    http.Response res;
    try {
      res = await http.Response.fromStream(
          await _http.send(req).timeout(timeout)).timeout(timeout);
    } on EmbyException {
      rethrow;
    } catch (e) {
      throw EmbyException(EmbyErrorKind.network,
          detail: Redactor.friendly(e));
    }
    if (res.statusCode == 401 || res.statusCode == 403) {
      throw EmbyException(EmbyErrorKind.wrongCredentials,
          status: res.statusCode);
    }
    if (res.statusCode == 404 && !auth) {
      throw const EmbyException(EmbyErrorKind.notEmby, status: 404);
    }
    if (res.statusCode >= 400) {
      throw EmbyException(EmbyErrorKind.server, status: res.statusCode);
    }
    if (res.body.trim().isEmpty) return null;
    try {
      return jsonDecode(utf8.decode(res.bodyBytes));
    } on FormatException {
      if (!auth) throw const EmbyException(EmbyErrorKind.notEmby);
      return null;
    }
  }

  Future<Map<String, dynamic>> _map(String method, String path,
      {Map<String, String?>? query, Object? body, bool auth = true}) async {
    final r = await _send(method, path, query: query, body: body, auth: auth);
    if (r is Map<String, dynamic>) return r;
    throw const EmbyException(EmbyErrorKind.notEmby);
  }

  // ------------------------------------------------------------ Anmeldung
  /// Öffentliche Serverdaten (ohne Anmeldung): Name, Version, Id, Produkt.
  Future<Map<String, dynamic>> publicInfo() async {
    final j = await _map('GET', '/System/Info/Public', auth: false);
    if (j['Id'] == null && j['ServerName'] == null) {
      throw const EmbyException(EmbyErrorKind.notEmby);
    }
    return j;
  }

  /// Anmelden; liefert das vollständige Konto (Token, Benutzer-ID, Server).
  Future<EmbyAccount> authenticate(String user, String password) async {
    Map<String, dynamic> info = const {};
    try {
      info = await publicInfo();
    } on EmbyException catch (e) {
      if (e.kind != EmbyErrorKind.notEmby) rethrow;
      // Manche Proxys sperren /System/Info/Public – Anmeldung trotzdem
      // versuchen.
    }
    final Map<String, dynamic> j;
    try {
      j = await _map('POST', '/Users/AuthenticateByName',
          body: {'Username': user, 'Pw': password, 'Password': password});
    } on EmbyException catch (e) {
      // Emby antwortet bei falschem Passwort mit 401, manche Versionen mit
      // 500 („Invalid username or password entered“).
      if (e.kind == EmbyErrorKind.server && e.status == 500) {
        throw const EmbyException(EmbyErrorKind.wrongCredentials, status: 500);
      }
      rethrow;
    }
    final token = j['AccessToken'];
    final u = j['User'];
    final uid = u is Map ? u['Id'] : null;
    if (token is! String || token.isEmpty || uid is! String) {
      throw const EmbyException(EmbyErrorKind.notEmby);
    }
    Redactor.register(token, null);
    final product = '${info['ProductName'] ?? ''}'.toLowerCase();
    return EmbyAccount(
      server: base,
      userName: (u is Map && u['Name'] is String) ? u['Name'] as String : user,
      userId: uid,
      token: token,
      serverName: _str(info['ServerName']) ??
          _str((j['SessionInfo'] as Map?)?['ServerName']),
      serverVersion: _str(info['Version']),
      serverId: _str(info['Id']) ?? _str(j['ServerId']),
      jellyfin: product.contains('jellyfin'),
    );
  }

  /// Token beim Server abmelden (Fehler egal).
  Future<void> logout() async {
    try {
      await _send('POST', '/Sessions/Logout');
    } catch (_) {}
  }

  // ------------------------------------------------------------ Inhalte
  Future<List<EmbyView>> views() async {
    final j = await _map('GET', '/Users/$_uid/Views');
    return [
      for (final v in _items(j))
        if (v['Id'] is String)
          EmbyView(v['Id'] as String, _str(v['Name']) ?? '',
              _str(v['CollectionType'])),
    ];
  }

  /// Eine Seite Titel einer Mediathek.
  Future<({List<Map<String, dynamic>> items, int total})> itemsPage(
      String parentId, String types,
      {int start = 0, int limit = pageSize}) async {
    final j = await _map('GET', '/Users/$_uid/Items', query: {
      'ParentId': parentId,
      'IncludeItemTypes': types,
      'Recursive': 'true',
      'Fields': itemFields,
      'SortBy': 'SortName',
      'SortOrder': 'Ascending',
      'StartIndex': '$start',
      'Limit': '$limit',
      'EnableImageTypes': 'Primary,Backdrop',
    });
    final items = _items(j);
    final total = j['TotalRecordCount'];
    return (items: items, total: total is int ? total : items.length);
  }

  /// Alle Titel einer Mediathek (seitenweise, je [pageSize]).
  Future<List<Map<String, dynamic>>> allItems(String parentId, String types,
      {int limit = pageSize}) async {
    final out = <Map<String, dynamic>>[];
    var start = 0;
    while (true) {
      final p = await itemsPage(parentId, types, start: start, limit: limit);
      out.addAll(p.items);
      start += p.items.length;
      if (p.items.isEmpty || start >= p.total) break;
    }
    return out;
  }

  Future<Map<String, dynamic>> item(String id) =>
      _map('GET', '/Users/$_uid/Items/$id', query: {'Fields': itemFields});

  Future<List<Map<String, dynamic>>> seasons(String seriesId) async =>
      _items(await _map('GET', '/Shows/$seriesId/Seasons',
          query: {'UserId': _uid, 'Fields': 'UserData,ImageTags'}));

  Future<List<Map<String, dynamic>>> episodes(String seriesId,
          {String? seasonId}) async =>
      _items(await _map('GET', '/Shows/$seriesId/Episodes', query: {
        'UserId': _uid,
        'SeasonId': seasonId,
        'Fields': episodeFields,
      }));

  /// „Weiterschauen“ (angefangene Filme/Folgen).
  Future<List<Map<String, dynamic>>> resume({int limit = 20}) async =>
      _items(await _map('GET', '/Users/$_uid/Items/Resume', query: {
        'Limit': '$limit',
        'Recursive': 'true',
        'MediaTypes': 'Video',
        'Fields': '$itemFields,SeriesId,ParentIndexNumber,IndexNumber',
        'EnableImageTypes': 'Primary,Backdrop,Thumb',
      }));

  /// „Neu hinzugefügt“ (Filme und Serien; Folgen werden gruppiert).
  Future<List<Map<String, dynamic>>> latest(
      {String? parentId, int limit = 20}) async {
    final r = await _send('GET', '/Users/$_uid/Items/Latest', query: {
      'ParentId': parentId,
      'Limit': '$limit',
      'Fields': itemFields,
      'IncludeItemTypes': 'Movie,Series',
      'GroupItems': 'true',
      'EnableImageTypes': 'Primary,Backdrop',
    });
    if (r is List) return [for (final x in r) if (x is Map<String, dynamic>) x];
    if (r is Map<String, dynamic>) return _items(r);
    return const [];
  }

  // ------------------------------------------------------------ Wiedergabe
  /// Medienquellen eines Titels für dieses Gerät (POST PlaybackInfo).
  Future<Map<String, dynamic>> playbackInfo(String itemId,
          {int? maxBitrate, int? audioStreamIndex}) =>
      _map('POST', '/Items/$itemId/PlaybackInfo', query: {
        'UserId': _uid,
      }, body: {
        'UserId': _uid,
        if (maxBitrate != null) 'MaxStreamingBitrate': maxBitrate,
        if (audioStreamIndex != null) 'AudioStreamIndex': audioStreamIndex,
        'IsPlayback': true,
        'AutoOpenLiveStream': true,
        'DeviceProfile': deviceProfile(maxBitrate),
      });

  /// Was die App (mpv) direkt abspielen kann: praktisch alle Container und
  /// Codecs. Umgewandelt wird nur nach H.264/AAC als HLS.
  static Map<String, Object?> deviceProfile(int? maxBitrate) => {
        'Name': clientName,
        'MaxStreamingBitrate': maxBitrate ?? 120000000,
        'MaxStaticBitrate': maxBitrate ?? 120000000,
        'MusicStreamingTranscodingBitrate': 192000,
        'DirectPlayProfiles': [
          {'Type': 'Video', 'Container': directContainers.join(',')},
          {'Type': 'Audio'},
        ],
        'TranscodingProfiles': [
          {
            'Type': 'Video',
            'Container': 'ts',
            'VideoCodec': 'h264',
            'AudioCodec': 'aac,mp3,ac3',
            'Context': 'Streaming',
            'Protocol': 'hls',
            'MaxAudioChannels': '6',
            'MinSegments': '1',
            'BreakOnNonKeyFrames': true,
          },
        ],
        'ContainerProfiles': const [],
        'CodecProfiles': const [],
        'SubtitleProfiles': [
          for (final f in ['srt', 'subrip', 'ass', 'ssa', 'vtt', 'sub'])
            {'Format': f, 'Method': 'External'},
          for (final f in ['srt', 'subrip', 'ass', 'ssa', 'pgssub', 'dvdsub', 'dvbsub', 'vtt', 'mov_text'])
            {'Format': f, 'Method': 'Embed'},
        ],
      };

  /// Container, die der Player sicher direkt öffnet.
  static const directContainers = [
    'mkv', 'mp4', 'm4v', 'mov', 'avi', 'ts', 'mpegts', 'm2ts', 'webm', 'wmv',
    'asf', 'flv', 'mpg', 'mpeg', 'vob', '3gp', 'ogv', 'ogm', 'divx', 'xvid',
  ];

  /// Original-Datei (Direktwiedergabe).
  String directUrl(String itemId,
      {required String mediaSourceId,
      String? container,
      String? playSessionId}) {
    final ext = container == null || container.isEmpty || container.contains(',')
        ? ''
        : '.$container';
    return uri('/Videos/$itemId/stream$ext', {
      'static': 'true',
      'MediaSourceId': mediaSourceId,
      'PlaySessionId': playSessionId,
      'DeviceId': device.id,
      'api_key': token,
    }).toString();
  }

  /// Umgewandelter Stream (HLS, H.264/AAC).
  String transcodeUrl(String itemId,
      {required String mediaSourceId,
      String? playSessionId,
      int? maxBitrate,
      int? audioStreamIndex}) {
    return uri('/Videos/$itemId/master.m3u8', {
      'MediaSourceId': mediaSourceId,
      'PlaySessionId': playSessionId,
      'DeviceId': device.id,
      'VideoCodec': 'h264',
      'AudioCodec': 'aac',
      'MaxAudioChannels': '6',
      'MaxStreamingBitrate': '${maxBitrate ?? 120000000}',
      'VideoBitrate': maxBitrate == null ? null : '${(maxBitrate * 0.9).round()}',
      'AudioStreamIndex':
          audioStreamIndex == null ? null : '$audioStreamIndex',
      'SegmentContainer': 'ts',
      'BreakOnNonKeyFrames': 'True',
      'api_key': token,
    }).toString();
  }

  /// Vom Server vorgeschlagene Umwandlungs-Adresse (relativ) vervollständigen.
  String absolute(String relative) {
    final rel = relative.startsWith('/') ? relative : '/$relative';
    var url = '$base$rel';
    final hasKey = RegExp(r'[?&](api_key|ApiKey)=').hasMatch(url);
    if (!hasKey && (token ?? '').isNotEmpty) {
      url += '${url.contains('?') ? '&' : '?'}api_key=$token';
    }
    return url;
  }

  /// Für Downloads: darf der Benutzer laden (`CanDownload`), Container,
  /// Größe und Spuren (externe Untertitel).
  Future<Map<String, dynamic>> downloadInfo(String id) =>
      _map('GET', '/Users/$_uid/Items/$id',
          query: {'Fields': 'CanDownload,MediaSources,MediaStreams,Path'});

  /// Originaldatei zum Herunterladen (Emby und Jellyfin).
  String downloadUrl(String id) =>
      uri('/Items/$id/Download', {'api_key': token}).toString();

  /// Externe (oder als Text auslesbare) Untertitel-Spur als SRT.
  String subtitleUrl(String itemId, String mediaSourceId, int index) =>
      uri('/Videos/$itemId/$mediaSourceId/Subtitles/$index/Stream.srt',
          {'api_key': token}).toString();

  // ------------------------------------------------------------ Fortschritt
  static int ticksOf(Duration d) => d.inMicroseconds * 10;

  Map<String, Object?> _playState(
          {required String itemId,
          required Duration position,
          String? mediaSourceId,
          String? playSessionId,
          bool paused = false,
          String playMethod = 'DirectStream'}) =>
      {
        'ItemId': itemId,
        if (mediaSourceId != null) 'MediaSourceId': mediaSourceId,
        if (playSessionId != null) 'PlaySessionId': playSessionId,
        'PositionTicks': ticksOf(position),
        'IsPaused': paused,
        'IsMuted': false,
        'CanSeek': true,
        'PlayMethod': playMethod,
      };

  Future<void> reportStart(
          {required String itemId,
          required Duration position,
          String? mediaSourceId,
          String? playSessionId,
          String playMethod = 'DirectStream'}) =>
      _send('POST', '/Sessions/Playing',
          body: _playState(
              itemId: itemId,
              position: position,
              mediaSourceId: mediaSourceId,
              playSessionId: playSessionId,
              playMethod: playMethod));

  Future<void> reportProgress(
          {required String itemId,
          required Duration position,
          required bool paused,
          String? mediaSourceId,
          String? playSessionId,
          String playMethod = 'DirectStream'}) =>
      _send('POST', '/Sessions/Playing/Progress',
          body: {
            ..._playState(
                itemId: itemId,
                position: position,
                paused: paused,
                mediaSourceId: mediaSourceId,
                playSessionId: playSessionId,
                playMethod: playMethod),
            'EventName': paused ? 'Pause' : 'TimeUpdate',
          });

  Future<void> reportStopped(
          {required String itemId,
          required Duration position,
          String? mediaSourceId,
          String? playSessionId}) =>
      _send('POST', '/Sessions/Playing/Stopped',
          body: _playState(
              itemId: itemId,
              position: position,
              mediaSourceId: mediaSourceId,
              playSessionId: playSessionId));

  /// Als gesehen ([played] = true) bzw. ungesehen markieren.
  Future<void> setPlayed(String itemId, bool played) =>
      _send(played ? 'POST' : 'DELETE', '/Users/$_uid/PlayedItems/$itemId');

  // ------------------------------------------------------------ Bilder
  /// Bild-Adresse (ohne Token – Emby liefert Bilder ohne Anmeldung).
  String imageUrl(String itemId, String type,
          {String? tag, int maxWidth = 400, int? index}) =>
      uri('/Items/$itemId/Images/$type${index == null ? '' : '/$index'}', {
        'maxWidth': '$maxWidth',
        'tag': tag,
        'quality': '90',
      }).toString();

  static List<Map<String, dynamic>> _items(Map<String, dynamic> j) {
    final items = j['Items'];
    if (items is! List) return const [];
    return [for (final x in items) if (x is Map<String, dynamic>) x];
  }

  static String? _str(Object? v) => v is String && v.isNotEmpty ? v : null;
}
