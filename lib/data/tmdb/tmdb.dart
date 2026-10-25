import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import '../search_norm.dart';

/// Film-Infos von TMDB (The Movie Database) – nur mit eigenem API-Schlüssel
/// des Nutzers (ab 2.3). Ohne Schlüssel gibt es keinen einzigen Abruf.
///
/// „This product uses the TMDB API but is not endorsed or certified by
/// TMDB.“ (steht auf der Lizenzseite und in den Einstellungen).

/// Quelle der Film-Infos (Einstellung `tmdbsrc`).
enum TmdbSource {
  /// Nur Anbieter – TMDB wird nie gefragt.
  provider('provider'),

  /// Anbieter, fehlende Angaben aus TMDB ergänzen (Vorgabe).
  mix('mix'),

  /// TMDB-Angaben ersetzen die des Anbieters, wo vorhanden.
  tmdb('tmdb');

  final String id;
  const TmdbSource(this.id);

  static const optionKey = 'tmdbsrc';

  static TmdbSource fromId(String? id) =>
      values.where((v) => v.id == id).firstOrNull ?? mix;
}

/// Schlüssel-Art: v3 (32 Hex-Zeichen, als `api_key`) oder v4-Lesetoken
/// (JWT „eyJ…“, als `Authorization: Bearer`).
class TmdbKey {
  TmdbKey._();

  static String clean(String raw) =>
      raw.trim().replaceFirst(RegExp(r'^Bearer\s+', caseSensitive: false), '');

  static bool isV3(String k) => RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(k);
  static bool isV4(String k) =>
      k.startsWith('eyJ') && k.length > 60 && !k.contains(RegExp(r'\s'));

  /// Formal plausibel? (Ob er gilt, zeigt erst „Verbindung testen“.)
  static bool plausible(String raw) {
    final k = clean(raw);
    return isV3(k) || isV4(k);
  }
}

enum TmdbErrorKind { invalidKey, network, rateLimited, server }

class TmdbException implements Exception {
  final TmdbErrorKind kind;
  final int? status;
  const TmdbException(this.kind, [this.status]);
  @override
  String toString() => 'TmdbException($kind, $status)';
}

/// Ein Eintrag der Besetzung (mit Foto, falls vorhanden).
class TmdbCredit {
  final int id;
  final String name;
  final String? character;
  final String? profilePath;
  const TmdbCredit(
      {required this.id, required this.name, this.character, this.profilePath});

  Map<String, Object?> toJson() =>
      {'id': id, 'n': name, 'c': character, 'p': profilePath};
  static TmdbCredit? fromJson(Object? j) {
    if (j is! Map || j['id'] is! int || j['n'] is! String) return null;
    return TmdbCredit(
        id: j['id'] as int,
        name: j['n'] as String,
        character: j['c'] as String?,
        profilePath: j['p'] as String?);
  }
}

/// Angaben zu einem Film oder einer Serie.
class TmdbInfo {
  final int id;
  final bool tv;
  final String title;
  final String? originalTitle;
  final int? year;
  final String? overview;
  final List<String> genres;
  final double? rating;
  final String? posterPath;
  final String? backdropPath;
  final List<TmdbCredit> cast;
  final String? director;
  final String? trailerKey;
  final int? runtimeMinutes;

  const TmdbInfo({
    required this.id,
    required this.tv,
    required this.title,
    this.originalTitle,
    this.year,
    this.overview,
    this.genres = const [],
    this.rating,
    this.posterPath,
    this.backdropPath,
    this.cast = const [],
    this.director,
    this.trailerKey,
    this.runtimeMinutes,
  });

  Map<String, Object?> toJson() => {
        'id': id,
        'tv': tv,
        't': title,
        'ot': originalTitle,
        'y': year,
        'o': overview,
        'g': genres,
        'r': rating,
        'pp': posterPath,
        'bp': backdropPath,
        'cast': [for (final c in cast) c.toJson()],
        'd': director,
        'tr': trailerKey,
        'rt': runtimeMinutes,
      };

  static TmdbInfo? fromJson(Object? j) {
    if (j is! Map || j['id'] is! int || j['t'] is! String) return null;
    return TmdbInfo(
      id: j['id'] as int,
      tv: j['tv'] == true,
      title: j['t'] as String,
      originalTitle: j['ot'] as String?,
      year: j['y'] as int?,
      overview: j['o'] as String?,
      genres: [for (final g in (j['g'] as List? ?? const [])) '$g'],
      rating: (j['r'] as num?)?.toDouble(),
      posterPath: j['pp'] as String?,
      backdropPath: j['bp'] as String?,
      cast: [
        for (final c in (j['cast'] as List? ?? const []))
          if (TmdbCredit.fromJson(c) case final x?) x,
      ],
      director: j['d'] as String?,
      trailerKey: j['tr'] as String?,
      runtimeMinutes: j['rt'] as int?,
    );
  }
}

/// Ein Titel aus der Filmografie einer Person.
class TmdbPersonCredit {
  final int id;
  final bool tv;
  final String title;
  final String? originalTitle;
  final int? year;
  final String? posterPath;
  final String? role;
  final double popularity;
  const TmdbPersonCredit({
    required this.id,
    required this.tv,
    required this.title,
    this.originalTitle,
    this.year,
    this.posterPath,
    this.role,
    this.popularity = 0,
  });

  Map<String, Object?> toJson() => {
        'id': id,
        'tv': tv,
        't': title,
        'ot': originalTitle,
        'y': year,
        'pp': posterPath,
        'r': role,
        'pop': popularity,
      };
  static TmdbPersonCredit? fromJson(Object? j) {
    if (j is! Map || j['id'] is! int || j['t'] is! String) return null;
    return TmdbPersonCredit(
      id: j['id'] as int,
      tv: j['tv'] == true,
      title: j['t'] as String,
      originalTitle: j['ot'] as String?,
      year: j['y'] as int?,
      posterPath: j['pp'] as String?,
      role: j['r'] as String?,
      popularity: (j['pop'] as num?)?.toDouble() ?? 0,
    );
  }
}

class TmdbPerson {
  final int id;
  final String name;
  final String? profilePath;
  final List<TmdbPersonCredit> credits;
  const TmdbPerson(
      {required this.id,
      required this.name,
      this.profilePath,
      this.credits = const []});

  Map<String, Object?> toJson() => {
        'id': id,
        'n': name,
        'p': profilePath,
        'cr': [for (final c in credits) c.toJson()],
      };
  static TmdbPerson? fromJson(Object? j) {
    if (j is! Map || j['id'] is! int || j['n'] is! String) return null;
    return TmdbPerson(
      id: j['id'] as int,
      name: j['n'] as String,
      profilePath: j['p'] as String?,
      credits: [
        for (final c in (j['cr'] as List? ?? const []))
          if (TmdbPersonCredit.fromJson(c) case final x?) x,
      ],
    );
  }
}

/// Bildadressen (Datensparmodus: kleinere Größen).
class TmdbImages {
  TmdbImages._();
  static const defaultBase = 'https://image.tmdb.org/t/p/';

  /// Tests: andere Basis (z. B. ohne Netz-Bilder).
  static String base = defaultBase;

  static String? poster(String? path, {bool saver = false}) =>
      path == null ? null : '$base${saver ? 'w185' : 'w342'}$path';
  static String? backdrop(String? path, {bool saver = false}) =>
      path == null ? null : '$base${saver ? 'w780' : 'w1280'}$path';
  static String? profile(String? path, {bool saver = false}) =>
      path == null ? null : '$base${saver ? 'w92' : 'w185'}$path';
}

/// Zwischenspeicher für Antworten (Datenbank, Tests: Speicher).
abstract class TmdbCache {
  /// Gespeicherter Text, wenn jünger als [ttl]; sonst null.
  Future<String?> get(String key, Duration ttl);
  Future<void> put(String key, String value);
}

class MemoryTmdbCache implements TmdbCache {
  final DateTime Function() now;
  final _m = <String, (DateTime, String)>{};
  MemoryTmdbCache({DateTime Function()? now}) : now = now ?? DateTime.now;

  int get length => _m.length;

  @override
  Future<String?> get(String key, Duration ttl) async {
    final e = _m[key];
    if (e == null) return null;
    if (now().difference(e.$1) > ttl) return null;
    return e.$2;
  }

  @override
  Future<void> put(String key, String value) async =>
      _m[key] = (now(), value);
}

/// Titel-Abgleich (Anbieter-Namen sind oft „DE - Titel (2019) [4K]“).
class TmdbMatch {
  TmdbMatch._();

  static final _prefix = RegExp(
      r'^\s*(?:\|[^|]{1,12}\|\s*|\[[^\]]{1,20}\]\s*|(?=[A-Z0-9]*[A-Z])[A-Z0-9]{2,4}\s*(?:-|:|\|)\s+)+');
  static final _bracket = RegExp(r'\[[^\]]*\]|\{[^}]*\}');
  static final _yearParen = RegExp(r'\((19\d\d|20\d\d)\)');
  static final _yearTail = RegExp(r'[\s\-–:]+(19\d\d|20\d\d)\s*$');
  static final _tags = RegExp(
      r'\b(4k|uhd|fhd|hd|sd|hevc|h\.?265|h\.?264|x264|x265|1080p|720p|2160p|'
      r'multi(?:[\s-]?sub)?|dual|vod|imdb|altyaz[ıi]l[ıi]|t[üu]rk[çc]e dublaj|'
      r'dublaj|subbed|dubbed|german|deutsch|engl?)\b',
      caseSensitive: false);

  /// Bereinigter Titel und (falls im Namen) Jahr.
  static ({String title, int? year}) clean(String raw) {
    var s = raw;
    int? year;
    final yp = _yearParen.firstMatch(s);
    if (yp != null) {
      year = int.parse(yp.group(1)!);
      s = s.replaceAll(_yearParen, ' ');
    }
    s = s.replaceFirst(_prefix, '');
    s = s.replaceAll(_bracket, ' ');
    final yt = _yearTail.firstMatch(s);
    if (yt != null) {
      year ??= int.parse(yt.group(1)!);
      s = s.substring(0, yt.start);
    }
    s = s.replaceAll(_tags, ' ').replaceAll(RegExp(r'\(\s*\)'), ' ');
    s = s.replaceAll(RegExp(r'[\s\-–|:]+$'), '').replaceAll(RegExp(r'\s+'), ' ');
    return (title: s.trim(), year: year);
  }

  static String norm(String s) => foldSearch(s)
      .replaceAll('&', ' and ')
      .replaceAll(RegExp(r"[^\p{L}\p{N}]+", unicode: true), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  /// Ähnlichkeit 0…1 zweier (bereinigter) Titel.
  static double similarity(String a, String b) {
    final x = norm(a), y = norm(b);
    if (x.isEmpty || y.isEmpty) return 0;
    if (x == y) return 1;
    final tx = x.split(' ').toSet(), ty = y.split(' ').toSet();
    final inter = tx.intersection(ty).length;
    final jac = inter / tx.union(ty).length;
    // „Titel: Untertitel“ gegen „Titel“.
    if (x.startsWith('$y ') || y.startsWith('$x ')) return math.max(0.8, jac);
    return jac;
  }

  /// Bewertung eines Kandidaten; null = passt nicht.
  static double? score(
      {required String title,
      int? year,
      required String candTitle,
      String? candOriginal,
      int? candYear,
      double popularity = 0}) {
    final sim = math.max(similarity(title, candTitle),
        candOriginal == null ? 0.0 : similarity(title, candOriginal));
    if (sim < 0.75) return null;
    var s = sim * 100;
    if (year != null && candYear != null) {
      final d = (year - candYear).abs();
      if (d == 0) {
        s += 30;
      } else if (d == 1) {
        s += 15;
      } else {
        return null; // anderes Jahr → anderer Film (Remake)
      }
    }
    return s + math.min(10, math.log(1 + popularity));
  }
}

/// TMDB-Abrufe mit Zwischenspeicher, Ratenbegrenzung und Abgleich.
class TmdbClient {
  static const apiBase = 'https://api.themoviedb.org/3';
  static const ttl = Duration(days: 14);

  /// Nicht gefundene Titel kürzer merken (Anbieter benennt evtl. um).
  static const missTtl = Duration(days: 3);

  final String key;
  final http.Client client;
  final TmdbCache cache;

  /// App-Sprache ('de', 'en', 'tr').
  final String lang;

  /// Höchstens so viele Anfragen gleichzeitig, mit Mindestabstand (TMDB
  /// erlaubt ~40/s – wir bleiben weit darunter).
  final int maxParallel;
  final Duration minGap;

  /// Abrufe (Tests/Messung).
  int requests = 0;

  TmdbClient({
    required String key,
    required this.client,
    required this.cache,
    this.lang = 'de',
    this.maxParallel = 4,
    this.minGap = const Duration(milliseconds: 40),
  }) : key = TmdbKey.clean(key);

  bool get _v4 => TmdbKey.isV4(key);

  String get _locale => switch (lang) {
        'de' => 'de-DE',
        'tr' => 'tr-TR',
        _ => 'en-US',
      };

  // ------------------------------------------------- Ratenbegrenzung
  int _inFlight = 0;
  DateTime _last = DateTime(0);
  final _waiting = <Completer<void>>[];

  Future<void> _acquire() async {
    while (_inFlight >= maxParallel) {
      final c = Completer<void>();
      _waiting.add(c);
      await c.future;
    }
    _inFlight++;
    final gap = minGap - DateTime.now().difference(_last);
    _last = DateTime.now().add(gap.isNegative ? Duration.zero : gap);
    if (!gap.isNegative && gap > Duration.zero) await Future.delayed(gap);
  }

  void _release() {
    _inFlight--;
    if (_waiting.isNotEmpty) _waiting.removeAt(0).complete();
  }

  Future<Map<String, dynamic>> _get(String path, Map<String, String> q,
      {bool retried = false}) async {
    final params = {...q, if (!_v4) 'api_key': key};
    final uri = Uri.parse('$apiBase$path').replace(queryParameters: params);
    final headers = {
      'Accept': 'application/json',
      if (_v4) 'Authorization': 'Bearer $key',
    };
    http.Response r;
    await _acquire();
    try {
      requests++;
      r = await client
          .get(uri, headers: headers)
          .timeout(const Duration(seconds: 15));
    } on TimeoutException {
      throw const TmdbException(TmdbErrorKind.network);
    } on http.ClientException {
      throw const TmdbException(TmdbErrorKind.network);
    } catch (e) {
      if (e is TmdbException) rethrow;
      throw const TmdbException(TmdbErrorKind.network);
    } finally {
      _release();
    }
    if (r.statusCode == 401) {
      throw const TmdbException(TmdbErrorKind.invalidKey, 401);
    }
    if (r.statusCode == 429) {
      if (retried) throw const TmdbException(TmdbErrorKind.rateLimited, 429);
      final wait = int.tryParse(r.headers['retry-after'] ?? '') ?? 2;
      await Future.delayed(Duration(seconds: wait.clamp(1, 10)));
      return _get(path, q, retried: true);
    }
    if (r.statusCode == 404) return const {};
    if (r.statusCode >= 400) {
      throw TmdbException(TmdbErrorKind.server, r.statusCode);
    }
    try {
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      return j is Map<String, dynamic> ? j : const {};
    } catch (_) {
      throw TmdbException(TmdbErrorKind.server, r.statusCode);
    }
  }

  /// Schlüssel prüfen. Wirft [TmdbException] (ungültig, kein Netz …).
  Future<void> test() async {
    final j = await _get('/configuration', const {});
    if (j['images'] == null) {
      throw const TmdbException(TmdbErrorKind.server);
    }
  }

  // ------------------------------------------------- Cache
  /// Aus dem Zwischenspeicher (14 Tage) oder neu laden. „Nicht gefunden“
  /// wird als „-“ gemerkt, gilt aber nur [missTtl].
  Future<T?> _cachedMiss<T>(String ck, T? Function(Object? json) decode,
      Future<T?> Function() load) async {
    final hit = await cache.get(ck, ttl);
    if (hit != null) {
      if (hit == '-') {
        if (await cache.get(ck, missTtl) != null) return null;
      } else {
        try {
          final v = decode(jsonDecode(hit));
          if (v != null) return v;
        } catch (_) {}
      }
    }
    final v = await load();
    await cache.put(ck, v == null ? '-' : jsonEncode((v as dynamic).toJson()));
    return v;
  }

  // ------------------------------------------------- Titel
  /// Film/Serie suchen und Details laden. [tmdbId] (vom Anbieter) hat
  /// Vorrang vor dem Abgleich über Titel + Jahr.
  Future<TmdbInfo?> lookup(
      {required String title,
      int? year,
      required bool tv,
      String? tmdbId}) async {
    final id = int.tryParse((tmdbId ?? '').trim());
    if (id != null && id > 0) {
      final info = await details(id, tv: tv);
      if (info != null) return info;
    }
    final c = TmdbMatch.clean(title);
    final y = year ?? c.year;
    if (c.title.isEmpty) return null;
    final ck =
        'tmdb:$lang:${tv ? 't' : 'm'}:q:${TmdbMatch.norm(c.title)}|${y ?? ''}';
    final found = await _cachedMiss<_Id>(ck, _Id.fromJson,
        () => _search(c.title, y, tv: tv));
    if (found == null) return null;
    return details(found.id, tv: tv);
  }

  Future<_Id?> _search(String title, int? year, {required bool tv}) async {
    Future<_Id?> once(int? yr) async {
      final j = await _get(tv ? '/search/tv' : '/search/movie', {
        'query': title,
        'language': _locale,
        'include_adult': 'false',
        if (yr != null) (tv ? 'first_air_date_year' : 'year'): '$yr',
      });
      final results = j['results'];
      if (results is! List) return null;
      _Id? best;
      double bestScore = -1;
      for (final r in results.whereType<Map>()) {
        final rid = r['id'];
        if (rid is! int) continue;
        final t = '${r[tv ? 'name' : 'title'] ?? ''}';
        final ot = r[tv ? 'original_name' : 'original_title'] as String?;
        final date = '${r[tv ? 'first_air_date' : 'release_date'] ?? ''}';
        final cy = int.tryParse(date.split('-').first);
        final s = TmdbMatch.score(
            title: title,
            year: year,
            candTitle: t,
            candOriginal: ot,
            candYear: cy,
            popularity: (r['popularity'] as num?)?.toDouble() ?? 0);
        if (s != null && s > bestScore) {
          bestScore = s;
          best = _Id(rid);
        }
      }
      return best;
    }

    // Mit Jahr zuerst; manche Anbieter-Jahre weichen ab (Kinostart vs.
    // DVD) → ohne Jahr erneut, der Abgleich erlaubt ±1.
    return await once(year) ?? (year != null ? await once(null) : null);
  }

  /// Details (mit Besetzung und Trailer) zu einer TMDB-ID.
  Future<TmdbInfo?> details(int id, {required bool tv}) =>
      _cachedMiss<TmdbInfo>('tmdb:$lang:${tv ? 't' : 'm'}:$id', TmdbInfo.fromJson,
          () async {
        final j = await _get(tv ? '/tv/$id' : '/movie/$id', {
          'language': _locale,
          'append_to_response': 'credits,videos',
          'include_video_language': '$lang,en,null',
        });
        if (j['id'] is! int) return null;
        return parseInfo(j, tv: tv, lang: lang);
      });

  static TmdbInfo parseInfo(Map<String, dynamic> j,
      {required bool tv, String lang = 'de'}) {
    final date = '${j[tv ? 'first_air_date' : 'release_date'] ?? ''}';
    final credits = j['credits'] is Map ? j['credits'] as Map : const {};
    final cast = <TmdbCredit>[];
    for (final c in (credits['cast'] as List? ?? const []).whereType<Map>()) {
      if (c['id'] is! int || c['name'] is! String) continue;
      cast.add(TmdbCredit(
          id: c['id'] as int,
          name: c['name'] as String,
          character: (c['character'] as String?)?.trim().isEmpty ?? true
              ? null
              : c['character'] as String,
          profilePath: c['profile_path'] as String?));
      if (cast.length >= 15) break;
    }
    String? director;
    for (final c in (credits['crew'] as List? ?? const []).whereType<Map>()) {
      if (c['job'] == 'Director' && c['name'] is String) {
        director = c['name'] as String;
        break;
      }
    }
    if (tv && director == null) {
      final by = j['created_by'];
      if (by is List && by.isNotEmpty && by.first is Map) {
        director = (by.first as Map)['name'] as String?;
      }
    }
    String? trailer;
    final vids = j['videos'] is Map ? (j['videos'] as Map)['results'] : null;
    if (vids is List) {
      final yt = [
        for (final v in vids.whereType<Map>())
          if (v['site'] == 'YouTube' &&
              v['key'] is String &&
              (v['type'] == 'Trailer' || v['type'] == 'Teaser'))
            v,
      ];
      int rank(Map v) =>
          (v['type'] == 'Trailer' ? 0 : 4) +
          (v['iso_639_1'] == lang ? 0 : (v['iso_639_1'] == 'en' ? 1 : 2)) +
          (v['official'] == true ? 0 : 1);
      yt.sort((a, b) => rank(a).compareTo(rank(b)));
      if (yt.isNotEmpty) trailer = yt.first['key'] as String;
    }
    final runtime = tv
        ? ((j['episode_run_time'] as List?)?.whereType<int>().firstOrNull)
        : j['runtime'] as int?;
    final overview = (j['overview'] as String?)?.trim();
    final vote = (j['vote_average'] as num?)?.toDouble();
    return TmdbInfo(
      id: j['id'] as int,
      tv: tv,
      title: '${j[tv ? 'name' : 'title'] ?? ''}',
      originalTitle: j[tv ? 'original_name' : 'original_title'] as String?,
      year: int.tryParse(date.split('-').first),
      overview: overview == null || overview.isEmpty ? null : overview,
      genres: [
        for (final g in (j['genres'] as List? ?? const []).whereType<Map>())
          if (g['name'] is String) g['name'] as String,
      ],
      rating: vote == null || vote <= 0 ? null : vote,
      posterPath: j['poster_path'] as String?,
      backdropPath: j['backdrop_path'] as String?,
      cast: cast,
      director: director,
      trailerKey: trailer,
      runtimeMinutes: runtime == null || runtime <= 0 ? null : runtime,
    );
  }

  // ------------------------------------------------- Personen
  /// Person per Name (oder TMDB-ID) mit Filmografie (Rollen + Regie).
  Future<TmdbPerson?> person(String name, {int? id}) async {
    final n = TmdbMatch.norm(name);
    if (n.isEmpty && id == null) return null;
    final ck = id != null ? 'tmdb:$lang:p:$id' : 'tmdb:$lang:pq:$n';
    return _cachedMiss<TmdbPerson>(ck, TmdbPerson.fromJson, () async {
      var pid = id;
      String? profile;
      var pname = name;
      if (pid == null) {
        final j = await _get('/search/person',
            {'query': name, 'language': _locale, 'include_adult': 'false'});
        final res = (j['results'] as List? ?? const []).whereType<Map>();
        final hit = res
            .where((r) =>
                r['id'] is int && TmdbMatch.norm('${r['name']}') == n)
            .firstOrNull;
        if (hit == null) return null;
        pid = hit['id'] as int;
        profile = hit['profile_path'] as String?;
        pname = '${hit['name']}';
      }
      final j = await _get('/person/$pid/combined_credits',
          {'language': _locale});
      final out = <String, TmdbPersonCredit>{};
      void add(Map c, String? role) {
        final cid = c['id'];
        final mt = c['media_type'];
        if (cid is! int || (mt != 'movie' && mt != 'tv')) return;
        final tv = mt == 'tv';
        // Talkshows/Nachrichten (Gastauftritte) sind keine Filmografie.
        final genres = (c['genre_ids'] as List?) ?? const [];
        if (tv && (genres.contains(10767) || genres.contains(10763))) return;
        final k = '${tv ? 't' : 'm'}$cid';
        final date = '${c[tv ? 'first_air_date' : 'release_date'] ?? ''}';
        out.putIfAbsent(
            k,
            () => TmdbPersonCredit(
                  id: cid,
                  tv: tv,
                  title: '${c[tv ? 'name' : 'title'] ?? ''}',
                  originalTitle:
                      c[tv ? 'original_name' : 'original_title'] as String?,
                  year: int.tryParse(date.split('-').first),
                  posterPath: c['poster_path'] as String?,
                  role: role,
                  popularity: (c['popularity'] as num?)?.toDouble() ?? 0,
                ));
      }

      for (final c in (j['cast'] as List? ?? const []).whereType<Map>()) {
        add(c, (c['character'] as String?)?.trim());
      }
      for (final c in (j['crew'] as List? ?? const []).whereType<Map>()) {
        if (c['job'] == 'Director') add(c, 'Director');
      }
      final list = out.values.where((c) => c.title.isNotEmpty).toList()
        ..sort((a, b) => b.popularity.compareTo(a.popularity));
      return TmdbPerson(
          id: pid,
          name: pname,
          profilePath: profile,
          credits: list.length > 120 ? list.sublist(0, 120) : list);
    });
  }
}

class _Id {
  final int id;
  const _Id(this.id);
  Map<String, Object> toJson() => {'id': id};
  static _Id? fromJson(Object? j) =>
      j is Map && j['id'] is int ? _Id(j['id'] as int) : null;
}
