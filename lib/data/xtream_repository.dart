import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;

import '../core/security.dart';
import '../models/models.dart';
import 'host_failover.dart';
import 'net.dart';
import 'repository.dart';
import 'epg_matcher.dart';
import 'stream_headers.dart';

/// Xtream-Codes-API (player_api.php): Live, EPG mit Archiv, Catch-up,
/// Filme und Serien.
class XtreamRepository extends IptvRepository {
  @override
  final Portal portal;
  XtreamRepository(this.portal);

  /// Bevorzugte Adresse (Haupt- oder zuletzt funktionierende Ersatz-Adresse).
  String get _base => _clean(HostFailover.activeBase(portal));
  static String _clean(String b) => b.trim().replaceAll(RegExp(r'/+$'), '');
  String get _u => Uri.encodeComponent(portal.username ?? '');
  String get _p => Uri.encodeComponent(portal.password ?? '');

  Future<dynamic> _get(Map<String, String> params) async {
    final bytes = await HostFailover.run(portal, (base) {
      final uri = Uri.parse('${_clean(base)}/player_api.php')
          .replace(queryParameters: {
        'username': portal.username ?? '',
        'password': portal.password ?? '',
        ...params,
      });
      return Net.get(uri,
          timeout: const Duration(seconds: 25), headers: portalHeaders(portal));
    });
    // Große Antworten (Senderliste, Filme) im Hintergrund dekodieren,
    // damit die Oberfläche nicht ruckelt.
    if (bytes.length > 256 * 1024) return compute(_decodeJson, bytes);
    return _decodeJson(bytes);
  }

  static dynamic _decodeJson(Uint8List bytes) {
    final body = utf8.decode(bytes, allowMalformed: true);
    if (body.trim().isEmpty) return const [];
    return jsonDecode(body);
  }

  List _list(dynamic d) => d is List ? d : const [];

  // ---------- Login ----------
  @override
  Future<AccountInfo?> login() async {
    final data = await _get({});
    final user = (data is Map) ? data['user_info'] as Map? : null;
    if (user == null || '${user['auth']}' != '1') {
      throw RepositoryException(
          'Login fehlgeschlagen – Benutzername oder Passwort prüfen.');
    }
    final exp = int.tryParse('${user['exp_date']}');
    return AccountInfo(
      status: '${user['status'] ?? 'Active'}',
      expires: exp == null ? null : DateTime.fromMillisecondsSinceEpoch(exp * 1000),
      maxConnections: int.tryParse('${user['max_connections']}') ?? 1,
      activeConnections: int.tryParse('${user['active_cons']}') ?? 0,
    );
  }

  // ---------- Live ----------
  @override
  Future<List<Category>> liveCategories() async =>
      _categories(await _get({'action': 'get_live_categories'}));

  @override
  Future<List<Channel>> liveChannels() async {
    final data = _list(await _get({'action': 'get_live_streams'}));
    return data.map((s) {
      final id = '${s['stream_id']}';
      return Channel(
        id: id,
        name: '${s['name']}'.trim(),
        logoUrl: UrlPolicy.image(_str(s['stream_icon'])),
        categoryId: '${s['category_id']}',
        epgId: _str(s['epg_channel_id']),
        number: int.tryParse('${s['num']}') ?? 0,
        catchupDays: '${s['tv_archive']}' == '1'
            ? (int.tryParse('${s['tv_archive_duration']}') ?? 0)
            : 0,
        streamUrl: '$_base/live/$_u/$_p/$id.ts',
      );
    }).toList();
  }

  @override
  Future<Map<String, List<EpgEntry>>> loadEpg(
      {Set<String>? channelIds, List<Channel>? channels, EpgProgress? progress}) async {
    return loadXmltvSources(
        channelIds: channelIds, channels: channels, progress: progress);
  }

  @override
  Future<String?> providerEpgUrl() async =>
      '$_base/xmltv.php?username=$_u&password=$_p';

  @override
  Future<List<EpgEntry>> shortEpg(Channel c) async {
    final data = await _get({
      'action': 'get_short_epg',
      'stream_id': c.id,
      'limit': '12',
    });
    final list = (data is Map ? data['epg_listings'] : null) as List? ?? [];
    return list
        .whereType<Map>()
        .map((e) => EpgEntry(
              channelEpgId: epgKeyOf(c),
              title: _b64(e['title']),
              description: _b64(e['description']),
              start: _ts(e['start_timestamp']),
              end: _ts(e['stop_timestamp']),
            ))
        .where((e) => e.end.isAfter(e.start))
        .toList()
      ..sort((a, b) => a.start.compareTo(b.start));
  }

  /// Vollständige Sender-EPG mit Archiv-Kennzeichnung vom Server.
  @override
  Future<List<EpgEntry>> channelEpg(
      Channel c, Map<String, List<EpgEntry>> fullEpg) async {
    try {
      final data = await _get({
        'action': 'get_simple_data_table',
        'stream_id': c.id,
      });
      final list = (data is Map ? data['epg_listings'] : null) as List? ?? [];
      if (list.isEmpty) return epgOf(fullEpg, c);
      final entries = list.map((e) {
        return EpgEntry(
          channelEpgId: c.epgId ?? c.id,
          title: _b64(e['title']),
          description: _b64(e['description']),
          start: _ts(e['start_timestamp']),
          end: _ts(e['stop_timestamp']),
          hasArchive: '${e['has_archive']}' == '1',
        );
      }).toList()
        ..sort((a, b) => a.start.compareTo(b.start));
      return entries;
    } catch (_) {
      return epgOf(fullEpg, c);
    }
  }

  /// Gespeicherte Adressen zeigen evtl. noch auf einen ausgefallenen
  /// Server → auf die zuletzt funktionierende Adresse umschreiben.
  @override
  Future<String> resolveStreamUrl(Channel c) async =>
      HostFailover.rewrite(portal, c.streamUrl);

  @override
  String? catchupUrl(Channel c, EpgEntry e) {
    if (!c.hasCatchup) return null;
    String two(int n) => n.toString().padLeft(2, '0');
    final s = e.start;
    final start =
        '${s.year}-${two(s.month)}-${two(s.day)}:${two(s.hour)}-${two(s.minute)}';
    final minutes = e.duration.inMinutes.clamp(1, 24 * 60);
    return '$_base/timeshift/$_u/$_p/$minutes/$start/${c.id}.ts';
  }

  // ---------- Filme ----------
  @override
  bool get supportsVod => true;

  @override
  Future<List<Category>> movieCategories() async =>
      _categories(await _get({'action': 'get_vod_categories'}));

  @override
  Future<List<VodItem>> movies() async {
    final data = _list(await _get({'action': 'get_vod_streams'}));
    return data.map((s) {
      final id = '${s['stream_id']}';
      final ext = _str(s['container_extension']) ?? 'mp4';
      final added = int.tryParse('${s['added']}');
      return VodItem(
        id: id,
        name: '${s['name']}'.trim(),
        posterUrl: UrlPolicy.image(_str(s['stream_icon'])),
        categoryId: '${s['category_id']}',
        rating: double.tryParse('${s['rating']}'),
        year: int.tryParse('${s['year'] ?? ''}'),
        added: added == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(added * 1000),
        streamUrl: '$_base/movie/$_u/$_p/$id.$ext',
      );
    }).toList();
  }

  @override
  Future<VodItem> movieDetails(VodItem m) async {
    final data = await _get({'action': 'get_vod_info', 'vod_id': m.id});
    final info = (data is Map ? data['info'] : null) as Map? ?? {};
    final backdrops = info['backdrop_path'];
    return m.copyWith(
      plot: _str(info['plot']) ?? _str(info['description']),
      genre: _str(info['genre']),
      cast: _str(info['cast']) ?? _str(info['actors']),
      director: _str(info['director']),
      rating: double.tryParse('${info['rating']}'),
      year: int.tryParse('${info['releasedate'] ?? ''}'.split('-').first),
      duration: Duration(
          seconds: int.tryParse('${info['duration_secs']}') ?? 0),
      backdropUrl: backdrops is List && backdrops.isNotEmpty
          ? '${backdrops.first}'
          : null,
    );
  }

  // ---------- Serien ----------
  @override
  Future<List<Category>> seriesCategories() async =>
      _categories(await _get({'action': 'get_series_categories'}));

  @override
  Future<List<VodItem>> series() async {
    final data = _list(await _get({'action': 'get_series'}));
    return data.map((s) {
      final backdrops = s['backdrop_path'];
      return VodItem(
        id: '${s['series_id']}',
        isSeries: true,
        streamUrl: '',
        name: '${s['name']}'.trim(),
        posterUrl: UrlPolicy.image(_str(s['cover'])),
        backdropUrl: backdrops is List && backdrops.isNotEmpty
            ? '${backdrops.first}'
            : null,
        categoryId: '${s['category_id']}',
        rating: double.tryParse('${s['rating']}'),
        year: int.tryParse('${s['releaseDate'] ?? s['year'] ?? ''}'
            .split('-')
            .first),
        plot: _str(s['plot']),
        genre: _str(s['genre']),
      );
    }).toList();
  }

  @override
  Future<SeriesDetails> seriesDetails(VodItem s) async {
    final data = await _get({'action': 'get_series_info', 'series_id': s.id});
    final info = (data is Map ? data['info'] : null) as Map? ?? {};
    final eps = (data is Map ? data['episodes'] : null);
    final seasons = <int, List<Episode>>{};
    if (eps is Map) {
      eps.forEach((season, list) {
        final n = int.tryParse('$season') ?? 0;
        seasons[n] = (list as List).map((e) {
          final epInfo = (e['info'] as Map?) ?? {};
          final ext = _str(e['container_extension']) ?? 'mp4';
          return Episode(
            id: '${e['id']}',
            season: n,
            number: int.tryParse('${e['episode_num']}') ?? 0,
            title: '${e['title']}',
            plot: _str(epInfo['plot']),
            stillUrl: UrlPolicy.image(_str(epInfo['movie_image'])),
            duration:
                Duration(seconds: int.tryParse('${epInfo['duration_secs']}') ?? 0),
            streamUrl: '$_base/series/$_u/$_p/${e['id']}.$ext',
          );
        }).toList()
          ..sort((a, b) => a.number.compareTo(b.number));
      });
    }
    final backdrops = info['backdrop_path'];
    return SeriesDetails(
      series: s.copyWith(
        plot: _str(info['plot']),
        genre: _str(info['genre']),
        backdropUrl: backdrops is List && backdrops.isNotEmpty
            ? '${backdrops.first}'
            : null,
      ),
      cast: _str(info['cast']),
      seasons: Map.fromEntries(
          seasons.entries.toList()..sort((a, b) => a.key.compareTo(b.key))),
    );
  }

  // ---------- Helfer ----------
  List<Category> _categories(dynamic data) => _list(data)
      .map((c) => Category(
            id: '${c['category_id']}',
            name: '${c['category_name']}'.trim(),
          ))
      .toList();

  static String? _str(dynamic v) {
    final s = v?.toString().trim();
    return (s == null || s.isEmpty || s == 'null') ? null : s;
  }

  static DateTime _ts(dynamic v) =>
      DateTime.fromMillisecondsSinceEpoch((int.tryParse('$v') ?? 0) * 1000);

  static String _b64(dynamic v) {
    final s = _str(v);
    if (s == null) return '';
    try {
      return utf8.decode(base64.decode(s), allowMalformed: true);
    } catch (_) {
      return s;
    }
  }
}
