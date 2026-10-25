import 'dart:convert';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../models/models.dart';
import 'db/catalog.dart';
import 'db/catalog_sync.dart' as dbs;
import 'epg_cache/epg_file_stub.dart'
    if (dart.library.io) 'epg_cache/epg_file_io.dart' as files;

/// Alles, was ein Hintergrund-Isolate zum Speichern einer Liste braucht
/// (nur einfache Werte → billig zu senden).
class CacheSpec {
  /// Pfad der Katalog-Datenbank (null = kein Dateisystem, z. B. Web/Tests
  /// ohne Verzeichnis).
  final String? path;
  final List<String> secrets;
  final String fp;

  /// Prüfsumme der aktuell angezeigten Liste. Gleicher Inhalt → nichts
  /// schreiben und nichts zurückgeben ([ListOutcome.unchanged]).
  final String? prevHash;

  /// Portal-ID und Art der Liste (live, movies, series, embymovies …).
  final String portal;
  final String kind;

  /// Alte Cache-Datei (vor 2.0) – wird nach dem Schreiben entfernt.
  final String? legacyPath;
  const CacheSpec(this.path, this.secrets, this.fp, this.prevHash,
      {this.portal = '', this.kind = '', this.legacyPath});
}

/// Ergebnis eines Lade-/Speichervorgangs im Hintergrund.
class ListOutcome<T> {
  final List<Category> categories;
  final List<T> items;

  /// Prüfsumme des Inhalts (ohne Zeitstempel).
  final String hash;

  /// true: Inhalt identisch mit [CacheSpec.prevHash] – [categories]/[items]
  /// sind leer, es wurde nichts gespeichert.
  final bool unchanged;

  /// In der Datenbank gespeichert (dann gilt sie als Quelle für Suche und
  /// Fenster, siehe [ListCache.inDb]).
  final bool stored;
  const ListOutcome(this.categories, this.items, this.hash,
      {this.unchanged = false, this.stored = false});
}

/// Gelesener Zwischenspeicher.
typedef CachedList<T> = ({
  List<Category> categories,
  List<T> items,
  DateTime saved,
  String? hash,
});

/// Zwischenspeicher für Senderliste, Filme und Serien.
///
/// Ab 2.0 in der Katalog-Datenbank (lib/data/db): je Portal und Art eine
/// Liste, in einer Transaktion ersetzt, mit Suchindex. Vorher (bis 1.9)
/// waren es JSON-Dateien (`live_<id>.json` …); sie werden beim ersten Laden
/// einmalig übernommen und dann gelöscht. Unlesbare alte Dateien gelten als
/// nicht vorhanden (→ neu vom Portal).
///
/// Stream-Adressen enthalten bei Xtream Benutzername und Passwort
/// (`…/live/USER/PASS/123.ts`). Vor dem Speichern werden diese durch
/// Platzhalter ersetzt – die Datenbank enthält **keine Zugangsdaten**. Beim
/// Laden werden sie aus dem verschlüsselten Speicher wieder eingesetzt;
/// andere Zugangsdaten (Fingerprint) → Liste wird verworfen.
///
/// Alles Rechenintensive (Lesen, Kodieren, Maskieren, Schreiben) läuft in
/// **einem** Hintergrund-Isolate pro Liste; das Haupt-Isolate bekommt
/// fertige Objekte (per `Isolate.exit`, ohne Kopie).
class ListCache {
  static List<String> _secrets(Portal p) {
    final out = <String>[];
    void add(String? v) {
      if (v == null || v.length < 2) return;
      for (final x in [Uri.encodeComponent(v), v]) {
        if (!out.contains(x)) out.add(x);
      }
    }

    add(p.username);
    add(p.password);
    for (final u in [p.url, ...p.altUrls]) {
      final q = Uri.tryParse(u)?.queryParameters ?? const {};
      for (final k in [
        'username',
        'user',
        'password',
        'pass',
        'token',
        'key'
      ]) {
        add(q[k]);
      }
    }
    // Längste zuerst, damit Teilstrings nicht stören.
    out.sort((a, b) => b.length.compareTo(a.length));
    return out;
  }

  /// Prüfsumme der Zugangsdaten: ändern sie sich, wird der Speicher verworfen.
  static String _fingerprint(List<String> secrets) =>
      sha256.convert(utf8.encode(secrets.join('\u0001'))).toString();

  static String _file(String kind, String portalId) =>
      '${kind}_${portalId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')}.json';

  /// Nur für Tests: Verzeichnis der Zwischenspeicher-Dateien.
  @visibleForTesting
  static set debugDirectory(String? dir) => files.cacheDirOverride = dir;

  /// Angaben fürs Speichern im Hintergrund.
  static Future<CacheSpec> spec(String kind, Portal p,
      {String? prevHash}) async {
    final secrets = _secrets(p);
    return CacheSpec(
        await Catalog.path(), secrets, _fingerprint(secrets), prevHash,
        portal: p.id,
        kind: kind,
        legacyPath: await files.cacheFilePath(_file(kind, p.id)));
  }

  /// Gibt es einen Zwischenspeicher dieser Liste? (Datenbank oder alte
  /// Datei, die beim Laden übernommen wird)
  static Future<bool> exists(String kind, Portal p) async =>
      await files.cacheFileExists(_file(kind, p.id)) ||
      await Catalog.hasList(p.id, kind);

  /// Zeitpunkt des letzten erfolgreichen Abrufs der Senderliste in dieser
  /// Sitzung (gespeichert oder unverändert; für die automatische
  /// Aktualisierung).
  static final lastSaved = <String, DateTime>{};

  // ---------------------------------------------------------------- Laden
  static Future<CachedList<Channel>?> loadLive(Portal p) => _load(p, 'live');

  static Future<CachedList<VodItem>?> loadVod(String kind, Portal p) =>
      _load(p, kind);

  static Future<CachedList<T>?> _load<T>(Portal p, String kind) async {
    try {
      final db = await Catalog.path();
      final legacy = await files.cacheFilePath(_file(kind, p.id));
      if (db == null && legacy == null) return null;
      final secrets = _secrets(p);
      final fp = _fingerprint(secrets);
      // Lesen (Datenbank, sonst alte Datei übernehmen) in einem Isolate.
      final job = _LoadJob(db, legacy, p.id, kind, secrets, fp);
      final (out, inDb) = await Isolate.run(_loadTask(job));
      noteStored(p.id, kind, out != null && inDb);
      if (out != null && !inDb && db != null && legacy != null) {
        // Alte Datei (bis 1.9): Liste ist schon da; die Übernahme in die
        // Datenbank läuft danach im Hintergrund (erster Start nach dem
        // Update wartet nicht darauf).
        final key = '${p.id}/$kind';
        _migrations[key] ??= Isolate.run(_migrateTask(job)).then((ok) {
          if (ok) noteStored(p.id, kind, true);
        }, onError: (Object _) {}).whenComplete(() {
          _migrations.remove(key);
        });
      }
      return out as CachedList<T>?;
    } catch (_) {
      return null;
    }
  }

  static (Object?, bool) Function() _loadTask(_LoadJob j) =>
      () => _loadJob(j, migrate: false);
  static bool Function() _migrateTask(_LoadJob j) =>
      () => _loadJob(j, migrate: true).$2;

  /// Laufende Übernahmen alter Dateien (`<Portal-ID>/<Art>`).
  static final _migrations = <String, Future<void>>{};

  /// Nur für Tests: auf laufende Übernahmen warten.
  @visibleForTesting
  static Future<void> debugMigrations() => Future.wait([..._migrations.values]);

  /// Listen, deren angezeigter Stand in der Datenbank liegt
  /// (`<Portal-ID>/<Art>`): nur dann sucht die Suche dort.
  static final _inDb = <String>{};

  static bool inDb(String portalId, String kind) =>
      _inDb.contains('$portalId/$kind');

  /// Nach Laden/Speichern vermerken, ob die Datenbank den Stand hat.
  static void noteStored(String portalId, String kind, bool stored) =>
      stored ? _inDb.add('$portalId/$kind') : _inDb.remove('$portalId/$kind');

  /// Im Hintergrund-Isolate: erst die Datenbank, sonst die alte Datei (bis
  /// 1.9) lesen. [migrate]: sie dann auch in die Datenbank übernehmen (nur,
  /// wenn dort noch keine Liste steht) und löschen.
  static (Object?, bool) _loadJob(_LoadJob j, {required bool migrate}) {
    final live = j.kind == 'live';
    String restore(String s) => _unmask(s, j.secrets);
    var dbOk = false;
    final db = j.db;
    if (db != null) {
      try {
        final r = live
            ? dbs.syncReadLive(db, j.portal, j.fp, restore)
            : dbs.syncReadVod(db, j.portal, j.kind, j.fp, restore);
        dbOk = true;
        if (r != null) {
          // Übrig gebliebene alte Datei (z. B. Abbruch beim Löschen).
          if (j.legacy != null) files.deleteFileSync(j.legacy!);
          if (live) {
            return (
              (
                categories: r.categories,
                items: r.items as List<Channel>,
                saved: r.saved,
                hash: r.hash,
              ),
              true
            );
          }
          return (
            (
              categories: r.categories,
              items: r.items as List<VodItem>,
              saved: r.saved,
              hash: r.hash,
            ),
            true
          );
        }
      } catch (_) {
        dbOk = false; // Datenbank nicht nutzbar → alte Datei wie bisher
      }
    }
    final path = j.legacy;
    if (path == null) return (null, false);
    final raw = files.readFileSync(path);
    if (raw == null) return (null, false);
    Object? out;
    try {
      final restored = _restore((raw, j.secrets, j.fp));
      if (restored == null) {
        // Andere Zugangsdaten → neu laden (Datei ist wertlos).
        if (dbOk) files.deleteFileSync(path);
        return (null, false);
      }
      out = live ? _decodeLive(restored) : _decodeVod(restored);
    } catch (_) {
      out = null;
    }
    if (out == null) {
      files.deleteFileSync(path); // beschädigt
      return (null, false);
    }
    var inDb = false;
    if (dbOk && migrate) {
      // Einmalige Übernahme in die Datenbank, danach Datei weg.
      try {
        String mask(String s) => _mask((s, j.secrets));
        if (out is CachedList<Channel>) {
          dbs.syncWriteLive(db!, j.portal,
              fp: j.fp,
              hash: out.hash,
              saved: out.saved,
              cats: out.categories,
              items: out.items,
              mask: mask,
              onlyIfMissing: true);
        } else if (out is CachedList<VodItem>) {
          dbs.syncWriteVod(db!, j.portal, j.kind,
              fp: j.fp,
              hash: out.hash,
              saved: out.saved,
              cats: out.categories,
              items: out.items,
              mask: mask,
              onlyIfMissing: true);
        }
        files.deleteFileSync(path);
        inDb = true;
      } catch (_) {
        // Übernahme klappt beim nächsten Mal; die Liste ist trotzdem da.
      }
    }
    return (out, inDb);
  }

  // ---------------------------------------------------------------- Speichern
  /// Liste (bereits als Objekte vorhanden, z. B. M3U/Stalker) speichern –
  /// Kodieren, Prüfsumme, Maskieren und Schreiben im Hintergrund.
  static Future<ListOutcome<Channel>> storeLive(
          CacheSpec? spec, List<Category> cats, List<Channel> chans) =>
      Isolate.run(_liveTask(spec, cats, chans));
  static ListOutcome<Channel> Function() _liveTask(
          CacheSpec? spec, List<Category> cats, List<Channel> chans) =>
      () => finishLive(spec, cats, chans);

  static Future<ListOutcome<VodItem>> storeVod(
          CacheSpec? spec, List<Category> cats, List<VodItem> items) =>
      Isolate.run(_vodTask(spec, cats, items));
  static ListOutcome<VodItem> Function() _vodTask(
          CacheSpec? spec, List<Category> cats, List<VodItem> items) =>
      () => finishVod(spec, cats, items);

  /// Im Hintergrund-Isolate aufzurufen: Prüfsumme bilden, bei Änderung
  /// speichern. Unverändert → leeres Ergebnis (nichts zu übertragen).
  static ListOutcome<Channel> finishLive(
      CacheSpec? spec, List<Category> cats, List<Channel> chans) {
    return _finish(spec, cats, chans, liveBody(cats, chans), (s, hash) {
      dbs.syncWriteLive(s.path!, s.portal,
          fp: s.fp,
          hash: hash,
          saved: DateTime.now(),
          cats: cats,
          items: chans,
          mask: (v) => _mask((v, s.secrets)));
    });
  }

  static ListOutcome<VodItem> finishVod(
      CacheSpec? spec, List<Category> cats, List<VodItem> items) {
    return _finish(spec, cats, items, vodBody(cats, items), (s, hash) {
      dbs.syncWriteVod(s.path!, s.portal, s.kind,
          fp: s.fp,
          hash: hash,
          saved: DateTime.now(),
          cats: cats,
          items: items,
          mask: (v) => _mask((v, s.secrets)));
    });
  }

  static ListOutcome<T> _finish<T>(CacheSpec? spec, List<Category> cats,
      List<T> items, String body, void Function(CacheSpec, String) write) {
    final hash = hashBody(body);
    if (spec != null && spec.prevHash == hash) {
      return ListOutcome<T>(const [], const [], hash, unchanged: true);
    }
    var stored = false;
    if (spec != null && spec.path != null && spec.portal.isNotEmpty) {
      try {
        write(spec, hash);
        stored = true;
        // Alte Datei (bis 1.9) ist damit überholt.
        final legacy = spec.legacyPath;
        if (legacy != null) files.deleteFileSync(legacy);
      } catch (_) {
        // Zwischenspeicher ist optional.
      }
    }
    return ListOutcome<T>(cats, items, hash, stored: stored);
  }

  /// Dateiinhalt: Kopf (unmaskiert, nur Prüfsummen) + maskierter Inhalt.
  static String fileContent(CacheSpec spec, String body, String hash,
      {DateTime? saved}) {
    final head =
        '{"v":1,"saved":${(saved ?? DateTime.now()).millisecondsSinceEpoch},'
        '"fp":"${spec.fp}","h":"$hash",';
    // body beginnt mit „{“ → durch den Kopf ersetzen.
    return head + _mask((body.substring(1), spec.secrets));
  }

  static String hashBody(String body) =>
      md5.convert(utf8.encode(body)).toString();

  static String liveBody(List<Category> cats, List<Channel> chans) =>
      jsonEncode({
        'cats': [
          for (final c in cats) [c.id, c.name]
        ],
        'ch': [
          for (final c in chans)
            [
              c.id,
              c.name,
              c.logoUrl,
              c.categoryId,
              c.streamUrl,
              c.epgId,
              c.catchupDays,
              c.number,
              c.catchupMode,
              c.catchupSource,
              c.headers,
              c.epgShift
            ]
        ],
      });

  static String vodBody(List<Category> cats, List<VodItem> items) =>
      jsonEncode({
        'cats': [
          for (final c in cats) [c.id, c.name]
        ],
        'items': [
          for (final m in items)
            [
              m.id, m.name, m.posterUrl, m.backdropUrl, m.categoryId,
              m.streamUrl,
              m.rating, m.year, m.plot, m.genre,
              m.added?.millisecondsSinceEpoch,
              m.isSeries ? 1 : 0, m.duration?.inSeconds,
              // Ab 1.4: Besetzung, Regie, Trailer.
              m.cast, m.director, m.trailer,
              // Ab 1.6: Emby (Herkunft, Server-Position in s, gesehen) –
              // nur bei Emby-Titeln, Portal-Listen bleiben unverändert.
              if (m.isEmby) ...[
                1,
                m.serverPosition?.inSeconds,
                m.serverPlayed ? 1 : 0
              ],
            ]
        ],
      });

  /// Kompatibel zu älteren Aufrufern: speichern ohne Vergleich.
  static Future<void> saveLive(
      Portal p, List<Category> cats, List<Channel> chans) async {
    lastSaved[p.id] = DateTime.now();
    try {
      await storeLive(await spec('live', p), cats, chans);
    } catch (_) {}
  }

  static Future<void> saveVod(
      String kind, Portal p, List<Category> cats, List<VodItem> items) async {
    try {
      await storeVod(await spec(kind, p), cats, items);
    } catch (_) {}
  }

  /// Alle Listen eines Portals löschen (Datenbank und alte Dateien).
  static Future<void> clear(Portal p) => clearId(p.id);

  static Future<void> clearId(String portalId) async {
    _inDb.removeWhere((k) => k.startsWith('$portalId/'));
    for (final k in ['live', 'movies', 'series', 'embymovies', 'embyseries']) {
      try {
        await files.deleteCacheFile(_file(k, portalId));
      } catch (_) {}
    }
    await Catalog.deletePortal(portalId);
  }

  /// Nur für Tests: Maskieren/Wiederherstellen ohne Datei.
  static String debugMask(String json, Portal p) => _mask((json, _secrets(p)));
  static String? debugRestore(String raw, Portal p) {
    final secrets = _secrets(p);
    return _restore((raw, secrets, _fingerprint(secrets)));
  }

  @visibleForTesting
  static CachedList<Channel>? debugDecodeLive(String raw) => _decodeLive(raw);
  @visibleForTesting
  static CachedList<VodItem>? debugDecodeVod(String raw) => _decodeVod(raw);

  static String fingerprintFor(Portal p) => _fingerprint(_secrets(p));

  // ---------- intern ----------
  static String _mask((String, List<String>) job) {
    var s = job.$1;
    for (var i = 0; i < job.$2.length; i++) {
      s = s.replaceAll(job.$2[i], '\u0000S$i\u0000');
    }
    return s;
  }

  /// Platzhalter in einem einzelnen Wert zurücktauschen.
  static String _unmask(String s, List<String> secrets) {
    if (!s.contains('\u0000')) return s;
    var out = s;
    for (var i = 0; i < secrets.length; i++) {
      out = out.replaceAll('\u0000S$i\u0000', secrets[i]);
    }
    return out;
  }

  /// Platzhalter zurück → null, wenn sich die Zugangsdaten geändert haben.
  static String? _restore((String, List<String>, String) job) {
    final (raw, secrets, fp) = job;
    final fpAt = raw.indexOf('"fp":"');
    if (fpAt < 0 ||
        raw.length < fpAt + 6 + 64 ||
        raw.substring(fpAt + 6, fpAt + 6 + 64) != fp) {
      return null;
    }
    if (!raw.contains('\u0000')) return raw;
    var s = raw;
    for (var i = 0; i < secrets.length; i++) {
      s = s.replaceAll('\u0000S$i\u0000', secrets[i]);
    }
    return s;
  }

  static String? _s(Object? v) => v is String ? v : null;
  static int? _i(Object? v) => v is int ? v : (v is num ? v.toInt() : null);

  static List<Category> _cats(Object? raw) => [
        if (raw is List)
          for (final c in raw.whereType<List>())
            if (c.length >= 2 && c[0] is String && c[1] is String)
              Category(id: c[0] as String, name: c[1] as String)
      ];

  static String? _hashOf(Map j) => _s(j['h']);

  /// Liefert null bei kaputter Struktur (→ Datei wird gelöscht). Einzelne
  /// fehlerhafte Einträge werden übersprungen.
  static CachedList<Channel>? _decodeLive(String raw) {
    final j = jsonDecode(raw);
    if (j is! Map || j['saved'] is! int || j['ch'] is! List) return null;
    final items = <Channel>[];
    for (final c in (j['ch'] as List).whereType<List>()) {
      if (c.length < 10) continue;
      final id = _s(c[0]), name = _s(c[1]), cat = _s(c[3]), url = _s(c[4]);
      if (id == null || name == null || cat == null || url == null) continue;
      final h = c.length > 10 ? c[10] : null;
      items.add(Channel(
        id: id,
        name: name,
        logoUrl: _s(c[2]),
        categoryId: cat,
        streamUrl: url,
        epgId: _s(c[5]),
        catchupDays: _i(c[6]) ?? 0,
        number: _i(c[7]) ?? 0,
        catchupMode: _s(c[8]),
        catchupSource: _s(c[9]),
        // Ab 1.3 (ältere Zwischenspeicher haben diese Felder nicht).
        headers: h is Map
            ? {
                for (final e in h.entries)
                  if (e.key is String && e.value is String)
                    e.key as String: e.value as String,
              }
            : null,
        epgShift: c.length > 11 ? _i(c[11]) ?? 0 : 0,
      ));
    }
    return (
      saved: DateTime.fromMillisecondsSinceEpoch(j['saved'] as int),
      categories: _cats(j['cats']),
      items: items,
      hash: _hashOf(j),
    );
  }

  static CachedList<VodItem>? _decodeVod(String raw) {
    final j = jsonDecode(raw);
    if (j is! Map || j['saved'] is! int || j['items'] is! List) return null;
    final items = <VodItem>[];
    for (final m in (j['items'] as List).whereType<List>()) {
      if (m.length < 13) continue;
      final id = _s(m[0]), name = _s(m[1]), cat = _s(m[4]), url = _s(m[5]);
      if (id == null || name == null || cat == null || url == null) continue;
      final added = _i(m[10]), dur = _i(m[12]);
      items.add(VodItem(
        id: id,
        name: name,
        posterUrl: _s(m[2]),
        backdropUrl: _s(m[3]),
        categoryId: cat,
        streamUrl: url,
        rating: m[6] is num ? normalizeRating(m[6]) : null,
        year: _i(m[7]),
        plot: _s(m[8]),
        genre: _s(m[9]),
        added:
            added == null ? null : DateTime.fromMillisecondsSinceEpoch(added),
        isSeries: m[11] == 1,
        duration: dur == null ? null : Duration(seconds: dur),
        cast: m.length > 13 ? _s(m[13]) : null,
        director: m.length > 14 ? _s(m[14]) : null,
        trailer: m.length > 15 ? _s(m[15]) : null,
        source: m.length > 16 && m[16] == 1 ? VodSource.emby : VodSource.portal,
        serverPosition: m.length > 17 && _i(m[17]) != null
            ? Duration(seconds: _i(m[17])!)
            : null,
        serverPlayed: m.length > 18 && m[18] == 1,
      ));
    }
    return (
      saved: DateTime.fromMillisecondsSinceEpoch(j['saved'] as int),
      categories: _cats(j['cats']),
      items: items,
      hash: _hashOf(j),
    );
  }
}

/// Angaben für das Laden im Hintergrund (nur einfache Werte).
class _LoadJob {
  final String? db;
  final String? legacy;
  final String portal;
  final String kind;
  final List<String> secrets;
  final String fp;
  const _LoadJob(
      this.db, this.legacy, this.portal, this.kind, this.secrets, this.fp);
}
