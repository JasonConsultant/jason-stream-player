import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show compute, visibleForTesting;

import '../core/security.dart';
import '../models/models.dart';
import 'epg_window.dart';
import 'host_failover.dart';
import 'net.dart';
import 'repository.dart';

/// Stalker/Ministra-Middleware („MAC-Portal“, wie bei MAG-Boxen).
///
/// Ablauf: Endpunkt suchen (load.php / portal.php) → handshake (Token) →
/// get_profile (MAC freigeschaltet?) → Sender/Genres/EPG über load.php.
/// Die MAC-Adresse steht in [Portal.username].
///
/// Abspiel-Links sind kurzlebig und werden erst beim Abspielen über
/// `create_link` erzeugt ([resolveStreamUrl]).
///
/// Noch nicht unterstützt:
/// - Catch-up: Stalker erzeugt Archiv-Links nur asynchron über
///   `type=tv_archive&action=create_link`; [catchupUrl] ist aber synchron.
///   Deshalb liefert [catchupUrl] in dieser Version immer null.
/// - Filme/Serien (VOD) für MAC-Portale folgen später ([supportsVod] = false).
class StalkerRepository extends IptvRepository {
  @override
  final Portal portal;
  StalkerRepository(this.portal);

  static const _userAgent =
      'Mozilla/5.0 (QtEmbedded; U; Linux; C) AppleWebKit/533.3 '
      '(KHTML, like Gecko) MAG200 stbapp ver: 2 rev: 250 Safari/533.3';
  static const _xUserAgent = 'Model: MAG250; Link: WiFi';
  static const _timeout = Duration(seconds: 25);

  /// Gefundener Endpunkt (…/server/load.php oder …/portal.php).
  Uri? _endpoint;
  String? _token;
  String? _mac;

  /// Laufender Handshake, damit parallele Anfragen nicht mehrfach anmelden.
  Future<void>? _session;

  // ======================================================================
  // Reine Hilfsfunktionen (ohne Netzwerk, testbar)
  // ======================================================================

  static final _macRe = RegExp(r'^[0-9A-F]{2}(:[0-9A-F]{2}){5}$');

  /// Prüft und normalisiert die MAC-Adresse (Großbuchstaben, Doppelpunkte).
  /// Wirft [RepositoryException], wenn das Format nicht passt.
  @visibleForTesting
  static String normalizeMac(String? mac) {
    final m = (mac ?? '').trim().toUpperCase().replaceAll('-', ':');
    if (!_macRe.hasMatch(m)) {
      throw RepositoryException(
          'Ungültige MAC-Adresse – Format XX:XX:XX:XX:XX:XX (z. B. 00:1A:79:12:34:56).');
    }
    return m;
  }

  /// Wurzel des Portals (Schema://Host:Port), z. B. für relative Logos.
  @visibleForTesting
  static Uri portalRoot(String url) {
    final u = _parseUserUrl(url);
    return Uri(
      scheme: u.scheme,
      host: u.host,
      port: u.hasPort ? u.port : null,
      path: '/',
    );
  }

  static Uri _parseUserUrl(String url) {
    var s = url.trim();
    if (!s.contains('://')) s = 'http://$s';
    final u = Uri.tryParse(s);
    if (u == null || u.host.isEmpty) {
      throw RepositoryException('Ungültige Portal-Adresse.');
    }
    return u;
  }

  /// Mögliche API-Endpunkte zur eingegebenen Portal-Adresse, in der
  /// Reihenfolge, in der sie probiert werden.
  ///
  /// - `http://h:p/c/` → `http://h:p/server/load.php`
  /// - `http://h:p/stalker_portal/c/` → `…/stalker_portal/server/load.php`
  /// - `http://h:p/portal.php` → genau diese Adresse zuerst
  /// - danach immer `<root>/portal.php` und
  ///   `<root>/stalker_portal/server/load.php`
  @visibleForTesting
  static List<Uri> endpointCandidates(String url) {
    final u = _parseUserUrl(url);
    final root = portalRoot(url);
    final out = <Uri>[];
    void add(Uri c) {
      if (!out.any((e) => e.toString() == c.toString())) out.add(c);
    }

    var path = u.path;
    // Direkt angegebener PHP-Endpunkt (portal.php, load.php).
    if (path.toLowerCase().endsWith('.php')) {
      add(root.replace(path: path));
      // Für den Basis-Pfad den Dateinamen entfernen.
      path = path.substring(0, path.lastIndexOf('/') + 1);
      if (path.endsWith('/server/')) {
        path = path.substring(0, path.length - 'server/'.length);
      }
    }
    // index.html o. Ä. am Ende entfernen.
    path = path.replaceFirst(RegExp(r'/[^/]+\.html?$', caseSensitive: false), '/');
    if (!path.endsWith('/')) path = '$path/';
    // …/c/ ist die Oberfläche der Box – die API liegt eine Ebene höher.
    if (path.endsWith('/c/')) path = path.substring(0, path.length - 2);
    add(root.replace(path: '${path}server/load.php'));
    add(root.replace(path: '/portal.php'));
    add(root.replace(path: '/stalker_portal/server/load.php'));
    return out;
  }

  /// Entfernt Player-Präfixe wie `ffmpeg `, `ffrt `, `auto ` aus einem cmd.
  @visibleForTesting
  static String stripCmd(String? cmd) {
    var s = (cmd ?? '').trim();
    final re = RegExp(r'^(ffmpeg|ffrt\d*|auto)\s+', caseSensitive: false);
    while (re.hasMatch(s)) {
      s = s.replaceFirst(re, '').trim();
    }
    return s;
  }

  /// `{js: …}`-Hülle entfernen (manche Portale schachteln sie).
  @visibleForTesting
  static dynamic unwrapJs(dynamic d) {
    var cur = d;
    for (var i = 0; i < 3; i++) {
      if (cur is Map && cur.containsKey('js')) {
        cur = cur['js'];
      } else {
        break;
      }
    }
    return cur;
  }

  static String? _str(dynamic v) {
    if (v == null) return null;
    final s = '$v'.trim();
    return s.isEmpty || s == 'null' ? null : s;
  }

  static int? _int(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    final s = _str(v);
    if (s == null) return null;
    return int.tryParse(s) ?? double.tryParse(s)?.toInt();
  }

  /// `js.data` bzw. die Liste selbst.
  static List _dataList(dynamic js) {
    final d = unwrapJs(js);
    if (d is List) return d;
    if (d is Map) {
      final data = d['data'];
      if (data is List) return data;
      if (data is Map) return data.values.toList();
    }
    return const [];
  }

  /// Genres (`get_genres`) → Kategorien. „Alle“ (`*`) wird ausgelassen.
  @visibleForTesting
  static List<Category> parseGenres(dynamic js) {
    final out = <Category>[];
    for (final g in _dataList(js)) {
      if (g is! Map) continue;
      final id = _str(g['id']);
      if (id == null || id == '*') continue;
      out.add(Category(id: id, name: _str(g['title']) ?? _str(g['name']) ?? id));
    }
    return out;
  }

  /// Senderliste (`get_all_channels` / `get_ordered_list`) → [Channel].
  /// [root] dient zum Auflösen relativer Logo-Pfade.
  @visibleForTesting
  static List<Channel> parseChannels(dynamic js, Uri root) {
    final out = <Channel>[];
    for (final s in _dataList(js)) {
      if (s is! Map) continue;
      final id = _str(s['id']);
      final cmd = _str(s['cmd']);
      if (id == null || cmd == null) continue;
      final archive = _str(s['tv_archive']) == '1';
      final hours = _int(s['tv_archive_duration']) ?? 0;
      var days = 0;
      if (archive) {
        days = (hours / 24).ceil();
        if (days < 1) days = 1;
      }
      out.add(Channel(
        id: id,
        name: _str(s['name']) ?? 'Sender $id',
        categoryId: _str(s['tv_genre_id']) ?? '',
        streamUrl: cmd,
        // Stalker-ID, damit das EPG des Portals (get_epg_info) passt.
        epgId: id,
        number: _int(s['number']) ?? 0,
        logoUrl: _logo(_str(s['logo']), root),
        // Catch-up für MAC-Portale folgt (asynchroner Archiv-Link) – bis dahin
        // nichts anbieten, was dann nicht abspielbar wäre.
        catchupDays: 0, // Archiv laut Portal: $days Tage
      ));
    }
    return out;
  }

  static String? _logo(String? logo, Uri root) {
    if (logo == null) return null;
    if (UrlPolicy.isWeb(logo)) return UrlPolicy.image(logo);
    if (logo.contains('://')) return null; // fremdes Schema (file:, data: …)
    try {
      return UrlPolicy.image(root.resolve(logo).toString());
    } catch (_) {
      return null;
    }
  }

  /// EPG (`get_epg_info`) → Map Sender-ID → Sendungen (sortiert).
  /// [channelIds]: nur diese Sender behalten (null = alle).
  @visibleForTesting
  static Map<String, List<EpgEntry>> parseEpg(dynamic js,
      {Set<String>? channelIds}) {
    final out = <String, List<EpgEntry>>{};
    var data = unwrapJs(js);
    if (data is Map && data['data'] != null) data = data['data'];

    void addEntry(String? key, dynamic e) {
      if (e is! Map) return;
      final ch = key ?? _str(e['ch_id']);
      if (ch == null) return;
      if (channelIds != null && !channelIds.contains(ch)) return;
      final start = _time(e['start_timestamp']) ?? _time(e['time']);
      var end = _time(e['stop_timestamp']) ?? _time(e['time_to']);
      if (start == null) return;
      if (end == null) {
        final dur = _int(e['duration']);
        if (dur == null || dur <= 0) return;
        end = start.add(Duration(seconds: dur));
      }
      if (!end.isAfter(start)) return;
      out.putIfAbsent(ch, () => []).add(EpgEntry(
            channelEpgId: ch,
            title: _str(e['name']) ?? '',
            description: _str(e['descr']),
            genre: _str(e['category']),
            start: start,
            end: end,
          ));
    }

    if (data is Map) {
      data.forEach((k, v) {
        if (v is List) {
          for (final e in v) {
            addEntry('$k', e);
          }
        }
      });
    } else if (data is List) {
      for (final e in data) {
        addEntry(null, e);
      }
    }
    for (final l in out.values) {
      l.sort((a, b) => a.start.compareTo(b.start));
    }
    return out;
  }

  /// Unix-Sekunden oder „YYYY-MM-DD HH:MM:SS“ (Ortszeit des Portals).
  static DateTime? _time(dynamic v) {
    final s = _str(v);
    if (s == null) return null;
    final n = int.tryParse(s);
    if (n != null) {
      return n > 0 ? DateTime.fromMillisecondsSinceEpoch(n * 1000) : null;
    }
    return DateTime.tryParse(s);
  }

  /// Fehlertext, wenn get_profile die MAC ablehnt, sonst null.
  @visibleForTesting
  static String? profileError(dynamic js) {
    final p = unwrapJs(js);
    if (p is! Map) return 'Portal lehnt die MAC-Adresse ab.';
    final status = _str(p['status']);
    final id = _str(p['id']);
    if (status != null && status != '0') {
      return 'Portal lehnt die MAC-Adresse ab.';
    }
    if (status == null && (id == null || id == '0')) {
      return 'Portal lehnt die MAC-Adresse ab.';
    }
    return null;
  }

  static const _months = {
    'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4, 'may': 5, 'jun': 6, //
    'jul': 7, 'aug': 8, 'sep': 9, 'oct': 10, 'nov': 11, 'dec': 12,
  };

  /// Ablaufdatum in den üblichen Portal-Formaten:
  /// Unix-Sekunden, ISO („2025-12-31 23:59:59“), „December 31, 2025, 11:59 pm“,
  /// „31.12.2025“.
  @visibleForTesting
  static DateTime? parseExpiry(dynamic v) {
    final s = _str(v);
    if (s == null) return null;
    final n = int.tryParse(s);
    if (n != null) {
      return n > 0 ? DateTime.fromMillisecondsSinceEpoch(n * 1000) : null;
    }
    final iso = DateTime.tryParse(s);
    if (iso != null) return iso;
    final de = RegExp(r'^(\d{1,2})\.(\d{1,2})\.(\d{4})').firstMatch(s);
    if (de != null) {
      return DateTime(
          int.parse(de[3]!), int.parse(de[2]!), int.parse(de[1]!), 23, 59);
    }
    final en = RegExp(r'([A-Za-z]{3})[a-z]*\.?\s+(\d{1,2}),?\s+(\d{4})')
        .firstMatch(s);
    if (en != null) {
      final m = _months[en[1]!.toLowerCase()];
      if (m != null) {
        return DateTime(int.parse(en[3]!), m, int.parse(en[2]!), 23, 59);
      }
    }
    return null;
  }

  /// Kontoinfos aus `account_info/get_main_info` (best effort).
  @visibleForTesting
  static AccountInfo? parseAccount(dynamic js) {
    final d = unwrapJs(js);
    if (d is! Map) return null;
    final expires = parseExpiry(d['end_date']) ??
        parseExpiry(d['phone']) ??
        parseExpiry(d['expire_billing_date']);
    final status = _str(d['status']) ?? 'Active';
    return AccountInfo(
      status: status == '0' || status == '1' ? 'Active' : status,
      expires: expires,
    );
  }

  // ======================================================================
  // Netzwerk
  // ======================================================================

  Map<String, String> _headers() {
    final mac = _mac!;
    return {
      // Eigener User-Agent/Referer aus „Erweitert“ hat Vorrang.
      'User-Agent': portal.userAgent ?? _userAgent,
      'X-User-Agent': _xUserAgent,
      'Cookie': 'mac=${Uri.encodeQueryComponent(mac)}; stb_lang=en; '
          'timezone=${Uri.encodeQueryComponent('Europe/Berlin')}',
      'Referer': portal.referer ?? HostFailover.activeBase(portal),
      'Accept': '*/*',
      if (_token != null) 'Authorization': 'Bearer $_token',
    };
  }

  static dynamic _decode(Uint8List bytes) {
    final body = utf8.decode(bytes, allowMalformed: true).trim();
    if (body.isEmpty) return null;
    try {
      return jsonDecode(body);
    } on FormatException {
      // Kein JSON (z. B. „Authorization failed.“) – Text zurückgeben.
      return body.length > 200 ? body.substring(0, 200) : body;
    }
  }

  static bool _isAuthFailure(Object e) =>
      e is _AuthFailed ||
      (e is RepositoryException &&
          (e.message.contains('HTTP 401') || e.message.contains('HTTP 403')));

  /// Eine Anfrage an [endpoint]; liefert den Inhalt von `js`.
  Future<dynamic> _call(Uri endpoint, Map<String, String> params) async {
    final uri = endpoint.replace(queryParameters: {
      ...params,
      'JsHttpRequest': '1-xml',
    });
    final bytes = await Net.get(uri,
        headers: _headers(), timeout: _timeout, maxBytes: 64 * 1024 * 1024);
    final decoded = bytes.length > 256 * 1024
        ? await compute(_decode, bytes)
        : _decode(bytes);
    if (decoded is String) {
      if (decoded.toLowerCase().contains('authorization failed')) {
        throw _AuthFailed();
      }
      throw RepositoryException('Das Portal hat eine ungültige Antwort geschickt.');
    }
    if (decoded is Map && !decoded.containsKey('js') && decoded.isNotEmpty) {
      // Manche Portale antworten ohne Hülle.
      return decoded;
    }
    return unwrapJs(decoded);
  }

  /// Sucht den Endpunkt (einmalig) und holt ein neues Token.
  Future<void> _handshake() async {
    _mac ??= normalizeMac(portal.username);
    Redactor.register(_mac, null);
    _token = null;
    // Alle Adressen (Haupt- und Ersatz-Adressen, zuletzt funktionierende
    // zuerst) mit ihren möglichen Endpunkten.
    final bases = HostFailover.bases(portal);
    final candidates = <(Uri, int)>[
      if (_endpoint != null)
        (_endpoint!, HostFailover.activeIndex(portal))
      else
        for (final i in HostFailover.order(portal))
          if (i < bases.length)
            for (final ep in _safeCandidates(bases[i])) (ep, i),
    ];
    if (candidates.isEmpty) endpointCandidates(portal.url); // wirft
    Object? lastError;
    for (final (ep, baseIndex) in candidates) {
      try {
        final js = await _call(ep, {
          'type': 'stb',
          'action': 'handshake',
          'token': '',
          'prehash': '',
        });
        final token = js is Map ? _str(js['token']) : null;
        if (token == null) {
          lastError = RepositoryException('Kein Token vom Portal erhalten.');
          continue;
        }
        _endpoint = ep;
        _token = token;
        HostFailover.markWorking(portal, baseIndex);
        Redactor.register(token, null);
        return;
      } catch (e) {
        lastError = e;
      }
    }
    if (lastError is RepositoryException &&
        lastError.message.contains('Unsichere Adresse')) {
      throw lastError;
    }
    throw RepositoryException(
        'Kein MAC-Portal unter dieser Adresse gefunden. Adresse prüfen '
        '(z. B. http://server:port/c/).');
  }

  static List<Uri> _safeCandidates(String url) {
    try {
      return endpointCandidates(url);
    } on RepositoryException {
      return const [];
    }
  }

  Future<void> _ensureSession() {
    if (_token != null && _endpoint != null) return Future.value();
    return _session ??= _handshake().whenComplete(() => _session = null);
  }

  /// Anfrage mit gültigem Token; bei abgelaufenem Token einmal neu anmelden.
  Future<dynamic> _get(Map<String, String> params) async {
    await _ensureSession();
    try {
      return await _call(_endpoint!, params);
    } catch (e) {
      if (HostFailover.isHostFailure(e) &&
          HostFailover.bases(portal).length > 1) {
        // Server ausgefallen → neu suchen (auch auf Ersatz-Adressen).
        _endpoint = null;
        _token = null;
        await _ensureSession();
        await _profile();
        return await _call(_endpoint!, params);
      }
      if (!_isAuthFailure(e)) rethrow;
      _token = null;
      await _ensureSession();
      await _profile();
      try {
        return await _call(_endpoint!, params);
      } on _AuthFailed {
        throw RepositoryException(
            'Portal verweigert den Zugriff – MAC-Adresse freischalten lassen.');
      }
    }
  }

  /// get_profile: meldet die „Box“ an und prüft die Freischaltung.
  Future<dynamic> _profile() async {
    final mac = _mac!;
    final sn = md5
        .convert(utf8.encode(mac))
        .toString()
        .toUpperCase()
        .substring(0, 13);
    final deviceId = sha256.convert(utf8.encode(mac)).toString().toUpperCase();
    final js = await _call(_endpoint!, {
      'type': 'stb',
      'action': 'get_profile',
      'hd': '1',
      'ver': 'ImageDescription: 0.2.18-r23-250; ImageDate: Thu Sep 13 11:31:16 '
          'EEST 2018; PORTAL version: 5.6.1; API Version: JS API version: 343; '
          'STB API version: 146; Player Engine version: 0x58c',
      'num_banks': '2',
      'sn': sn,
      'stb_type': 'MAG250',
      'image_version': '218',
      'video_out': 'hdmi',
      'device_id': deviceId,
      'device_id2': deviceId,
      'signature': '',
      'auth_second_step': '1',
      'hw_version': '1.7-BD-00',
      'not_valid_token': '0',
      'metrics': '',
    });
    return js;
  }

  // ---------- Login ----------
  @override
  Future<AccountInfo?> login() async {
    _mac = normalizeMac(portal.username);
    Redactor.register(_mac, null);
    _token = null;
    await _ensureSession();
    dynamic profile;
    try {
      profile = await _profile();
    } catch (e) {
      if (_isAuthFailure(e)) {
        throw RepositoryException('Portal lehnt die MAC-Adresse ab.');
      }
      rethrow;
    }
    final err = profileError(profile);
    if (err != null) throw RepositoryException(err);

    // Kontoinfos sind optional – Fehler ignorieren.
    try {
      final info = await _get({'type': 'account_info', 'action': 'get_main_info'});
      final acc = parseAccount(info);
      if (acc != null) return acc;
    } catch (_) {}
    return const AccountInfo(status: 'Active');
  }

  // ---------- Live ----------
  @override
  Future<List<Category>> liveCategories() async =>
      parseGenres(await _get({'type': 'itv', 'action': 'get_genres'}));

  @override
  Future<List<Channel>> liveChannels() async {
    final root = portalRoot(portal.url);
    List<Channel> all = const [];
    try {
      all = parseChannels(
          await _get({'type': 'itv', 'action': 'get_all_channels'}), root);
    } on RepositoryException {
      rethrow;
    } catch (_) {
      all = const [];
    }
    if (all.isNotEmpty) return all;

    // Ausweichweg: seitenweise Liste (manche Portale sperren get_all_channels).
    final out = <Channel>[];
    final seen = <String>{};
    int? total;
    for (var p = 1; p <= 100; p++) {
      final js = await _get({
        'type': 'itv',
        'action': 'get_ordered_list',
        'genre': '*',
        'force_ch_link_check': '',
        'fav': '0',
        'sortby': 'number',
        'hd': '0',
        'p': '$p',
      });
      if (js is Map) total ??= _int(js['total_items']);
      final page = parseChannels(js, root);
      final fresh = page.where((c) => seen.add(c.id)).toList();
      if (fresh.isEmpty) break;
      out.addAll(fresh);
      if (total != null && out.length >= total) break;
    }
    return out;
  }

  @override
  Future<String> resolveStreamUrl(Channel c) async {
    final original = stripCmd(c.streamUrl);
    String? link;
    try {
      final js = await _get({
        'type': 'itv',
        'action': 'create_link',
        'cmd': c.streamUrl,
        'series': '',
        'forced_storage': '0',
        'disable_ad': '0',
        'download': '0',
      });
      link = js is Map ? stripCmd(_str(js['cmd'])) : null;
    } catch (_) {
      link = null;
    }
    if (link != null && link.isNotEmpty && UrlPolicy.isStream(link)) {
      return link;
    }
    // Fallback: cmd ist bereits eine direkte Adresse.
    final direct = Uri.tryParse(original);
    if (direct != null &&
        (direct.scheme == 'http' || direct.scheme == 'https') &&
        !direct.host.toLowerCase().contains('localhost') &&
        UrlPolicy.isStream(original)) {
      return original;
    }
    throw RepositoryException(
        'Das Portal hat keinen abspielbaren Link für diesen Sender geliefert.');
  }

  @override
  Future<Map<String, List<EpgEntry>>> loadEpg(
      {Set<String>? channelIds,
      List<Channel>? channels,
      EpgProgress? progress,
      EpgStoreSpec? store}) async {
    // Eigene EPG-Quellen (z. B. Deutschland) zuerst, Portal-EPG füllt Lücken.
    Map<String, List<EpgEntry>> ext = const {};
    if (portal.epgSources.any((x) => x != 'portal')) {
      try {
        ext = await loadXmltvSources(
            channelIds: channelIds, channels: channels, progress: progress);
      } catch (_) {}
    }
    if (!portal.epgSources.contains('portal')) return ext;
    final offset = EpgWindow.clampOffset(portal.epgOffsets['portal'] ?? 0);
    final own = EpgWindow.shift(
        await _loadOwnEpg(channelIds), Duration(minutes: offset));
    return {...own, ...ext};
  }

  Future<Map<String, List<EpgEntry>>> _loadOwnEpg(Set<String>? channelIds) async {
    // EPG ist optional: bei Fehlern leer statt tausender Einzelabfragen.
    try {
      final js = await _get({
        'type': 'itv',
        'action': 'get_epg_info',
        'period': '48',
      });
      return parseEpg(js, channelIds: channelIds);
    } catch (_) {
      return {};
    }
  }

  /// Catch-up für MAC-Portale wird in dieser Version nicht unterstützt
  /// (Archiv-Links entstehen nur asynchron über tv_archive/create_link).
  @override
  String? catchupUrl(Channel c, EpgEntry e) => null;

  /// Filme/Serien für MAC-Portale folgen später.
  @override
  bool get supportsVod => false;
}

/// Portal meldet „Authorization failed“ (Token abgelaufen).
class _AuthFailed implements Exception {
  @override
  String toString() => 'Autorisierung fehlgeschlagen.';
}
