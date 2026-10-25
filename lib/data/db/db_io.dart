import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../../models/models.dart';
import '../search_norm.dart';
import 'db_types.dart';

/// Katalog-Datenbank (SQLite): Senderlisten, Filme, Serien und EPG je
/// Portal, dazu Volltext-Suchindizes (FTS5, Trigramme → „enthält“).
///
/// Alle Funktionen sind synchron und laufen in Hintergrund-Isolates (Abgleich)
/// bzw. im Datenbank-Isolate (Abfragen) – nie im UI-Isolate.
///
/// Zugangsdaten: Stream-Adressen werden – wie bisher in den Cache-Dateien –
/// vor dem Schreiben maskiert (Platzhalter statt Benutzer/Passwort) und erst
/// beim Lesen wieder eingesetzt. Die Datenbank enthält keine Zugangsdaten.

// ---------------------------------------------------------------- Öffnen

/// Öffnet (und migriert) die Datenbank. Lässt sie sich nicht öffnen
/// (beschädigt, fremdes Format), wird sie gelöscht und neu angelegt – sie
/// enthält nur Zwischenspeicher, die vom Portal neu geladen werden können.
Database openCatalog(String path) {
  try {
    return _open(path);
  } catch (_) {
    deleteCatalogFiles(path);
    return _open(path);
  }
}

Database _open(String path) {
  Directory(File(path).parent.path).createSync(recursive: true);
  final db = sqlite3.open(path);
  try {
    db.execute('PRAGMA busy_timeout = 60000');
    if (db.userVersion == 0) {
      // Nur bei neuer Datei wirksam (vor der ersten Tabelle).
      db.execute('PRAGMA auto_vacuum = INCREMENTAL');
    }
    db.select('PRAGMA journal_mode = WAL');
    db.execute('PRAGMA synchronous = NORMAL');
    migrateCatalog(db);
  } catch (_) {
    db.close();
    rethrow;
  }
  return db;
}

/// In-Memory-Datenbank (Tests).
Database openCatalogInMemory() {
  final db = sqlite3.openInMemory();
  migrateCatalog(db);
  return db;
}

void deleteCatalogFiles(String path) {
  for (final p in [path, '$path-wal', '$path-shm', '$path-journal']) {
    try {
      final f = File(p);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }
}

// ---------------------------------------------------------------- Schema

/// Migrationen: Eintrag i hebt Version i auf i+1. Neue Versionen werden nur
/// angehängt, nie geändert.
final List<void Function(Database)> catalogMigrations = [_v1, _v2];

/// v2 (2.3): kleiner Schlüssel-Wert-Zwischenspeicher (TMDB-Antworten).
void _v2(Database db) {
  db.execute('''
CREATE TABLE IF NOT EXISTS meta_cache(
  k TEXT PRIMARY KEY,
  saved INTEGER NOT NULL,
  v TEXT NOT NULL
) WITHOUT ROWID''');
}

/// Wert aus `meta_cache`, wenn nicht älter als [minSaved] (ms).
String? kvGet(Database db, String key, int minSaved) {
  final r = db.select(
      'SELECT v FROM meta_cache WHERE k = ? AND saved >= ?', [key, minSaved]);
  return r.isEmpty ? null : r.first['v'] as String;
}

void kvPut(Database db, String key, String value, int now) {
  db.execute(
      'INSERT OR REPLACE INTO meta_cache(k, saved, v) VALUES (?, ?, ?)',
      [key, now, value]);
  // Gelegentlich aufräumen (älter als 60 Tage).
  if (now % 50 == 0) {
    db.execute('DELETE FROM meta_cache WHERE saved < ?',
        [now - const Duration(days: 60).inMilliseconds]);
  }
}

/// Schema auf [catalogSchemaVersion] bringen (in einer Transaktion; zwei
/// Isolates, die gleichzeitig öffnen, migrieren nicht doppelt). Ist die
/// Datei neuer als diese App (Rückkehr zu einer älteren Version), wird
/// alles verworfen und neu angelegt.
void migrateCatalog(Database db, {int target = catalogSchemaVersion}) {
  if (db.userVersion == target) return;
  db.execute('BEGIN IMMEDIATE');
  try {
    var v = db.userVersion;
    if (v > target) {
      _dropAll(db);
      v = 0;
    }
    for (var i = v; i < target; i++) {
      catalogMigrations[i](db);
    }
    db.userVersion = target;
    db.execute('COMMIT');
  } catch (_) {
    db.execute('ROLLBACK');
    rethrow;
  }
}

void _dropAll(Database db) {
  final rows = db.select(
      "SELECT type, name, sql FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'");
  // Zuerst virtuelle Tabellen (löschen ihre Schattentabellen mit).
  final virt = <String>{
    for (final r in rows)
      if ('${r['sql']}'.toUpperCase().startsWith('CREATE VIRTUAL'))
        r['name'] as String,
  };
  for (final n in virt) {
    db.execute('DROP TABLE IF EXISTS "$n"');
  }
  final rest = db.select(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'");
  for (final r in rest) {
    db.execute('DROP TABLE IF EXISTS "${r['name']}"');
  }
}

void _v1(Database db) {
  db.execute('''
CREATE TABLE src(sid INTEGER PRIMARY KEY, key TEXT NOT NULL UNIQUE);

CREATE TABLE lists(
  src INTEGER NOT NULL, kind TEXT NOT NULL, saved INTEGER NOT NULL,
  fp TEXT NOT NULL, hash TEXT, count INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY(src, kind)) WITHOUT ROWID;

CREATE TABLE categories(
  src INTEGER NOT NULL, kind TEXT NOT NULL, pos INTEGER NOT NULL,
  id TEXT NOT NULL, name TEXT NOT NULL,
  PRIMARY KEY(src, kind, pos)) WITHOUT ROWID;

CREATE TABLE channels(
  rid INTEGER PRIMARY KEY, src INTEGER NOT NULL, pos INTEGER NOT NULL,
  id TEXT NOT NULL, name TEXT NOT NULL, norm TEXT NOT NULL, logo TEXT,
  cat TEXT NOT NULL, url TEXT NOT NULL, epg TEXT, catchup INTEGER NOT NULL DEFAULT 0,
  num INTEGER NOT NULL DEFAULT 0, cmode TEXT, csrc TEXT, headers TEXT,
  shift INTEGER NOT NULL DEFAULT 0);
CREATE UNIQUE INDEX channels_pos ON channels(src, pos);
CREATE INDEX channels_cat ON channels(src, cat, pos);
CREATE INDEX channels_id ON channels(src, id);
CREATE INDEX channels_norm ON channels(src, pos, norm, id);
CREATE VIRTUAL TABLE channels_fts USING fts5(
  norm, content='', contentless_delete=1, tokenize='trigram');

CREATE TABLE vod(
  rid INTEGER PRIMARY KEY, src INTEGER NOT NULL, kind TEXT NOT NULL,
  pos INTEGER NOT NULL, id TEXT NOT NULL, name TEXT NOT NULL,
  norm TEXT NOT NULL, poster TEXT, backdrop TEXT, cat TEXT NOT NULL, url TEXT NOT NULL,
  rating REAL, year INTEGER, plot TEXT, genre TEXT, added INTEGER,
  series INTEGER NOT NULL DEFAULT 0, dur INTEGER, actors TEXT,
  director TEXT, trailer TEXT, emby INTEGER NOT NULL DEFAULT 0,
  spos INTEGER, splayed INTEGER NOT NULL DEFAULT 0);
CREATE UNIQUE INDEX vod_pos ON vod(src, kind, pos);
CREATE INDEX vod_cat ON vod(src, kind, cat, pos);
CREATE INDEX vod_id ON vod(src, kind, id);
CREATE INDEX vod_norm ON vod(src, kind, pos, norm, id);
CREATE VIRTUAL TABLE vod_fts USING fts5(
  norm, people, content='', contentless_delete=1, tokenize='trigram');

CREATE TABLE epg_meta(
  src INTEGER PRIMARY KEY, gen INTEGER NOT NULL, saved INTEGER NOT NULL,
  hash TEXT, lo INTEGER, hi INTEGER, maxdur INTEGER NOT NULL DEFAULT 0,
  count INTEGER NOT NULL DEFAULT 0);
CREATE TABLE epg_stage(
  src INTEGER NOT NULL, gen INTEGER NOT NULL, saved INTEGER NOT NULL,
  hash TEXT, lo INTEGER, hi INTEGER, maxdur INTEGER NOT NULL DEFAULT 0,
  count INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(src, gen));
CREATE TABLE epg_chan(
  cid INTEGER PRIMARY KEY, src INTEGER NOT NULL, gen INTEGER NOT NULL,
  ch TEXT NOT NULL);
CREATE UNIQUE INDEX epg_chan_key ON epg_chan(src, gen, ch);
CREATE TABLE epg_text(
  id INTEGER PRIMARY KEY, src INTEGER NOT NULL, gen INTEGER NOT NULL,
  s TEXT NOT NULL, norm TEXT);
CREATE INDEX epg_text_gen ON epg_text(src, gen);
CREATE INDEX epg_text_titles ON epg_text(src, gen) WHERE norm IS NOT NULL;
CREATE TABLE epg(
  cid INTEGER NOT NULL, start INTEGER NOT NULL, seq INTEGER NOT NULL,
  stop INTEGER NOT NULL, title INTEGER NOT NULL, descr INTEGER,
  genre INTEGER, archive INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY(cid, start, seq)) WITHOUT ROWID;
CREATE INDEX epg_title ON epg(title, start);
CREATE VIRTUAL TABLE epg_fts USING fts5(
  norm, content='', contentless_delete=1, tokenize='trigram');
''');
}

// ---------------------------------------------------------------- Hilfen

void _tx(Database db, void Function() body) {
  db.execute('BEGIN IMMEDIATE');
  try {
    body();
    db.execute('COMMIT');
  } catch (_) {
    if (!db.autocommit) db.execute('ROLLBACK');
    rethrow;
  }
}

T _read<T>(Database db, T Function() body) {
  // Lesetransaktion: konsistenter Stand, auch wenn parallel geschrieben wird.
  final own = db.autocommit;
  if (own) db.execute('BEGIN');
  try {
    return body();
  } finally {
    if (own && !db.autocommit) db.execute('COMMIT');
  }
}

/// Interne Nummer eines Portals (Schlüssel = Portal-ID).
int? srcOf(Database db, String key, {bool create = false}) {
  if (create) {
    db.execute('INSERT OR IGNORE INTO src(key) VALUES (?)', [key]);
  }
  final r = db.select('SELECT sid FROM src WHERE key = ?', [key]);
  return r.isEmpty ? null : r.first.columnAt(0) as int;
}

/// FTS5-Ausdruck für „enthält [q]“ (q bereits gefaltet, ≥ 3 Zeichen).
String ftsPhrase(String q) => '"${q.replaceAll('"', '""')}"';

/// LIKE-Muster für „enthält [q]“ (für Begriffe unter 3 Zeichen).
String likeContains(String q) =>
    '%${q.replaceAll(r'\', r'\\').replaceAll('%', r'\%').replaceAll('_', r'\_')}%';

String? _s(Object? v) => v is String ? v : null;
int? _i(Object? v) => v is int ? v : (v is num ? v.toInt() : null);

String? _m(String? s, String Function(String) f) => s == null ? null : f(s);

// ---------------------------------------------------------------- Listen

/// Gibt es eine gespeicherte Liste?
bool hasList(Database db, String portal, String kind) {
  final src = srcOf(db, portal);
  if (src == null) return false;
  return db.select(
      'SELECT 1 FROM lists WHERE src = ? AND kind = ?', [src, kind]).isNotEmpty;
}

/// Stand einer gespeicherten Liste: (gespeichert, Fingerprint, Prüfsumme).
({DateTime saved, String fp, String? hash, int count})? listInfo(
    Database db, String portal, String kind) {
  final src = srcOf(db, portal);
  if (src == null) return null;
  final r = db.select(
      'SELECT saved, fp, hash, count FROM lists WHERE src = ? AND kind = ?',
      [src, kind]);
  if (r.isEmpty) return null;
  final row = r.first;
  return (
    saved: DateTime.fromMillisecondsSinceEpoch(row['saved'] as int),
    fp: row['fp'] as String,
    hash: _s(row['hash']),
    count: row['count'] as int,
  );
}

void _clearList(Database db, int src, String kind) {
  if (kind == 'live') {
    db.execute(
        'DELETE FROM channels_fts WHERE rowid IN (SELECT rid FROM channels WHERE src = ?)',
        [src]);
    db.execute('DELETE FROM channels WHERE src = ?', [src]);
  } else {
    db.execute(
        'DELETE FROM vod_fts WHERE rowid IN (SELECT rid FROM vod WHERE src = ? AND kind = ?)',
        [src, kind]);
    db.execute('DELETE FROM vod WHERE src = ? AND kind = ?', [src, kind]);
  }
  db.execute('DELETE FROM categories WHERE src = ? AND kind = ?', [src, kind]);
  db.execute('DELETE FROM lists WHERE src = ? AND kind = ?', [src, kind]);
}

/// Liste löschen (z. B. andere Zugangsdaten).
void deleteList(Database db, String portal, String kind) {
  final src = srcOf(db, portal);
  if (src == null) return;
  _tx(db, () => _clearList(db, src, kind));
}

void _writeCats(Database db, int src, String kind, List<Category> cats) {
  final st = db.prepare(
      'INSERT INTO categories(src, kind, pos, id, name) VALUES (?, ?, ?, ?, ?)');
  try {
    for (var i = 0; i < cats.length; i++) {
      st.execute([src, kind, i, cats[i].id, cats[i].name]);
    }
  } finally {
    st.close();
  }
}

void _upsertList(Database db, int src, String kind, DateTime saved, String fp,
    String? hash, int count) {
  db.execute(
      'INSERT OR REPLACE INTO lists(src, kind, saved, fp, hash, count) VALUES (?, ?, ?, ?, ?, ?)',
      [src, kind, saved.millisecondsSinceEpoch, fp, hash, count]);
}

List<Category> _readCats(Database db, int src, String kind) => [
      for (final r in db.select(
          'SELECT id, name FROM categories WHERE src = ? AND kind = ? ORDER BY pos',
          [src, kind]))
        Category(id: r.columnAt(0) as String, name: r.columnAt(1) as String),
    ];

/// Senderliste ersetzen – alles in einer Transaktion (Abbruch → alter Stand
/// bleibt). [mask] entfernt Zugangsdaten aus Adressen/Kopfzeilen.
void writeLive(Database db, String portal,
    {required String fp,
    required String? hash,
    required DateTime saved,
    required List<Category> cats,
    required List<Channel> items,
    String Function(String)? mask,
    bool onlyIfMissing = false}) {
  final m = mask ?? (String s) => s;
  final src = srcOf(db, portal, create: true)!;
  _tx(db, () {
    // Übernahme alter Dateien: nie eine inzwischen geladene Liste ersetzen.
    if (onlyIfMissing &&
        db.select('SELECT 1 FROM lists WHERE src = ? AND kind = ?',
            [src, 'live']).isNotEmpty) {
      return;
    }
    _clearList(db, src, 'live');
    _writeCats(db, src, 'live', cats);
    final st = db.prepare('INSERT INTO channels(src, pos, id, name, norm, '
        'logo, cat, url, epg, catchup, num, cmode, csrc, headers, shift) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)');
    final fts =
        db.prepare('INSERT INTO channels_fts(rowid, norm) VALUES (?, ?)');
    try {
      for (var i = 0; i < items.length; i++) {
        final c = items[i];
        final norm = foldSearch(c.name);
        st.execute([
          src,
          i,
          c.id,
          c.name,
          norm,
          c.logoUrl,
          c.categoryId,
          m(c.streamUrl),
          c.epgId,
          c.catchupDays,
          c.number,
          c.catchupMode,
          _m(c.catchupSource, m),
          c.headers == null ? null : m(jsonEncode(c.headers)),
          c.epgShift,
        ]);
        fts.execute([db.lastInsertRowId, norm]);
      }
    } finally {
      st.close();
      fts.close();
    }
    _upsertList(db, src, 'live', saved, fp, hash, items.length);
  });
}

const _chanCols = 'id, name, logo, cat, url, epg, catchup, num, cmode, csrc, '
    'headers, shift';

Channel _channel(Row r, String Function(String) restore) {
  String rs(String s) => s.contains('\u0000') ? restore(s) : s;
  final h = _s(r.columnAt(10));
  Map<String, String>? headers;
  if (h != null) {
    final j = jsonDecode(rs(h));
    if (j is Map) {
      headers = {
        for (final e in j.entries)
          if (e.key is String && e.value is String)
            e.key as String: e.value as String,
      };
    }
  }
  final cs = _s(r.columnAt(9));
  return Channel(
    id: r.columnAt(0) as String,
    name: r.columnAt(1) as String,
    logoUrl: _s(r.columnAt(2)),
    categoryId: r.columnAt(3) as String,
    streamUrl: rs(r.columnAt(4) as String),
    epgId: _s(r.columnAt(5)),
    catchupDays: _i(r.columnAt(6)) ?? 0,
    number: _i(r.columnAt(7)) ?? 0,
    catchupMode: _s(r.columnAt(8)),
    catchupSource: cs == null ? null : rs(cs),
    headers: headers,
    epgShift: _i(r.columnAt(11)) ?? 0,
  );
}

/// Gespeicherte Senderliste oder null (keine, oder andere Zugangsdaten →
/// wird gelöscht).
DbList<Channel>? readLive(Database db, String portal,
    {required String fp, String Function(String)? restore}) {
  final info = listInfo(db, portal, 'live');
  if (info == null) return null;
  if (info.fp != fp) {
    deleteList(db, portal, 'live');
    return null;
  }
  final r = restore ?? (String s) => s;
  final src = srcOf(db, portal)!;
  return _read(db, () {
    final cats = _readCats(db, src, 'live');
    final items = [
      for (final row in db.select(
          'SELECT $_chanCols FROM channels WHERE src = ? ORDER BY pos', [src]))
        _channel(row, r),
    ];
    return DbList(cats, items, info.saved, info.hash);
  });
}

/// Filme/Serien ([kind] z. B. movies, series, embymovies) ersetzen.
void writeVod(Database db, String portal, String kind,
    {required String fp,
    required String? hash,
    required DateTime saved,
    required List<Category> cats,
    required List<VodItem> items,
    String Function(String)? mask,
    bool onlyIfMissing = false}) {
  final m = mask ?? (String s) => s;
  final src = srcOf(db, portal, create: true)!;
  _tx(db, () {
    // Übernahme alter Dateien: nie eine inzwischen geladene Liste ersetzen.
    if (onlyIfMissing &&
        db.select('SELECT 1 FROM lists WHERE src = ? AND kind = ?',
            [src, kind]).isNotEmpty) {
      return;
    }
    _clearList(db, src, kind);
    _writeCats(db, src, kind, cats);
    final st = db.prepare('INSERT INTO vod(src, kind, pos, id, name, norm, '
        'poster, backdrop, cat, url, rating, year, plot, genre, added, series, '
        'dur, actors, director, trailer, emby, spos, splayed) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)');
    final fts =
        db.prepare('INSERT INTO vod_fts(rowid, norm, people) VALUES (?, ?, ?)');
    try {
      for (var i = 0; i < items.length; i++) {
        final v = items[i];
        final norm = foldSearch(v.name);
        st.execute([
          src,
          kind,
          i,
          v.id,
          v.name,
          norm,
          v.posterUrl,
          v.backdropUrl,
          v.categoryId,
          m(v.streamUrl),
          v.rating,
          v.year,
          v.plot,
          v.genre,
          v.added?.millisecondsSinceEpoch,
          v.isSeries ? 1 : 0,
          v.duration?.inSeconds,
          v.cast,
          v.director,
          v.trailer,
          v.isEmby ? 1 : 0,
          v.serverPosition?.inSeconds,
          v.serverPlayed ? 1 : 0,
        ]);
        final people = [v.cast, v.director].whereType<String>().join(', ');
        fts.execute([
          db.lastInsertRowId,
          norm,
          people.isEmpty ? null : foldSearch(people),
        ]);
      }
    } finally {
      st.close();
      fts.close();
    }
    _upsertList(db, src, kind, saved, fp, hash, items.length);
  });
}

const _vodCols = 'id, name, poster, backdrop, cat, url, rating, year, plot, '
    'genre, added, series, dur, actors, director, trailer, emby, spos, splayed';

VodItem _vod(Row r, String Function(String) restore) {
  final url = r.columnAt(5) as String;
  final added = _i(r.columnAt(10)), dur = _i(r.columnAt(12));
  final spos = _i(r.columnAt(17));
  final rating = r.columnAt(6);
  return VodItem(
    id: r.columnAt(0) as String,
    name: r.columnAt(1) as String,
    posterUrl: _s(r.columnAt(2)),
    backdropUrl: _s(r.columnAt(3)),
    categoryId: r.columnAt(4) as String,
    streamUrl: url.contains('\u0000') ? restore(url) : url,
    rating: rating is num ? rating.toDouble() : null,
    year: _i(r.columnAt(7)),
    plot: _s(r.columnAt(8)),
    genre: _s(r.columnAt(9)),
    added: added == null ? null : DateTime.fromMillisecondsSinceEpoch(added),
    isSeries: r.columnAt(11) == 1,
    duration: dur == null ? null : Duration(seconds: dur),
    cast: _s(r.columnAt(13)),
    director: _s(r.columnAt(14)),
    trailer: _s(r.columnAt(15)),
    source: r.columnAt(16) == 1 ? VodSource.emby : VodSource.portal,
    serverPosition: spos == null ? null : Duration(seconds: spos),
    serverPlayed: r.columnAt(18) == 1,
  );
}

DbList<VodItem>? readVod(Database db, String portal, String kind,
    {required String fp, String Function(String)? restore}) {
  final info = listInfo(db, portal, kind);
  if (info == null) return null;
  if (info.fp != fp) {
    deleteList(db, portal, kind);
    return null;
  }
  final r = restore ?? (String s) => s;
  final src = srcOf(db, portal)!;
  return _read(db, () {
    final cats = _readCats(db, src, kind);
    final items = [
      for (final row in db.select(
          'SELECT $_vodCols FROM vod WHERE src = ? AND kind = ? ORDER BY pos',
          [src, kind]))
        _vod(row, r),
    ];
    return DbList(cats, items, info.saved, info.hash);
  });
}

// ---------------------------------------------------------------- Fenster

/// Anzahl Sender (optional einer Gruppe).
int countChannels(Database db, String portal, {String? category}) {
  final src = srcOf(db, portal);
  if (src == null) return 0;
  final r = category == null
      ? db.select('SELECT count(*) FROM channels WHERE src = ?', [src])
      : db.select('SELECT count(*) FROM channels WHERE src = ? AND cat = ?',
          [src, category]);
  return r.first.columnAt(0) as int;
}

/// Sender [offset] … [offset]+[limit] in Listenreihenfolge (optional einer
/// Gruppe).
List<Channel> channelWindow(Database db, String portal,
    {String? category,
    required int offset,
    required int limit,
    String Function(String)? restore}) {
  final src = srcOf(db, portal);
  if (src == null) return const [];
  final r = restore ?? (String s) => s;
  final rows = category == null
      ? db.select(
          'SELECT $_chanCols FROM channels WHERE src = ? ORDER BY pos LIMIT ? OFFSET ?',
          [
              src,
              limit,
              offset
            ])
      : db.select(
          'SELECT $_chanCols FROM channels WHERE src = ? AND cat = ? ORDER BY pos LIMIT ? OFFSET ?',
          [src, category, limit, offset]);
  return [for (final row in rows) _channel(row, r)];
}

int countVod(Database db, String portal, String kind, {String? category}) {
  final src = srcOf(db, portal);
  if (src == null) return 0;
  final r = category == null
      ? db.select(
          'SELECT count(*) FROM vod WHERE src = ? AND kind = ?', [src, kind])
      : db.select(
          'SELECT count(*) FROM vod WHERE src = ? AND kind = ? AND cat = ?',
          [src, kind, category]);
  return r.first.columnAt(0) as int;
}

List<VodItem> vodWindow(Database db, String portal, String kind,
    {String? category,
    required int offset,
    required int limit,
    String Function(String)? restore}) {
  final src = srcOf(db, portal);
  if (src == null) return const [];
  final r = restore ?? (String s) => s;
  final rows = category == null
      ? db.select(
          'SELECT $_vodCols FROM vod WHERE src = ? AND kind = ? ORDER BY pos LIMIT ? OFFSET ?',
          [
              src,
              kind,
              limit,
              offset
            ])
      : db.select(
          'SELECT $_vodCols FROM vod WHERE src = ? AND kind = ? AND cat = ? ORDER BY pos LIMIT ? OFFSET ?',
          [src, kind, category, limit, offset]);
  return [for (final row in rows) _vod(row, r)];
}

/// Ein Titel (z. B. für die Detailseite).
VodItem? vodById(Database db, String portal, String kind, String id,
    {String Function(String)? restore}) {
  final src = srcOf(db, portal);
  if (src == null) return null;
  final rows = db.select(
      'SELECT $_vodCols FROM vod WHERE src = ? AND kind = ? AND id = ? LIMIT 1',
      [src, kind, id]);
  return rows.isEmpty ? null : _vod(rows.first, restore ?? (s) => s);
}

// ---------------------------------------------------------------- Suche

/// IDs aller Sender, deren Name [q] enthält (gefaltet), in Listenreihenfolge.
List<String> searchChannelIds(Database db, String portal, String q) {
  final src = srcOf(db, portal);
  if (src == null || q.isEmpty) return const [];
  final rows = q.length >= 3
      ? db.select(
          'SELECT c.id FROM channels c WHERE c.src = ? AND c.rid IN '
          '(SELECT rowid FROM channels_fts WHERE channels_fts MATCH ?) ORDER BY c.pos',
          [src, 'norm : ${ftsPhrase(q)}'])
      : _likeChannels(db, src, q);
  return [for (final r in rows) r.columnAt(0) as String];
}

ResultSet _likeChannels(Database db, int src, String q) {
  // Unter 3 Zeichen hilft der Trigramm-Index nicht: Namen vergleichen.
  return db.select(
      "SELECT id FROM channels WHERE src = ? AND norm LIKE ? ESCAPE '\\' ORDER BY pos",
      [src, likeContains(q)]);
}

/// IDs aller Filme/Serien, deren Titel [q] enthält, in Listenreihenfolge.
List<String> searchVodIds(Database db, String portal, String kind, String q) {
  final src = srcOf(db, portal);
  if (src == null || q.isEmpty) return const [];
  if (q.length >= 3) {
    return [
      for (final r in db.select(
          'SELECT v.id FROM vod v WHERE v.src = ? AND v.kind = ? AND v.rid IN '
          '(SELECT rowid FROM vod_fts WHERE vod_fts MATCH ?) ORDER BY v.pos',
          [src, kind, 'norm : ${ftsPhrase(q)}']))
        r.columnAt(0) as String,
    ];
  }
  return [
    for (final r in db.select(
        "SELECT id FROM vod WHERE src = ? AND kind = ? AND norm LIKE ? ESCAPE '\\' ORDER BY pos",
        [src, kind, likeContains(q)]))
      r.columnAt(0) as String,
  ];
}

/// Titel, in deren Besetzung/Regie [q] vorkommt (≥ 3 Zeichen).
List<String> searchVodPeopleIds(
    Database db, String portal, String kind, String q) {
  final src = srcOf(db, portal);
  if (src == null || q.length < 3) return const [];
  return [
    for (final r in db.select(
        'SELECT v.id FROM vod v WHERE v.src = ? AND v.kind = ? AND v.rid IN '
        '(SELECT rowid FROM vod_fts WHERE vod_fts MATCH ?) ORDER BY v.pos',
        [src, kind, 'people : ${ftsPhrase(q)}']))
      r.columnAt(0) as String,
  ];
}

// ---------------------------------------------------------------- EPG

EpgDbInfo? epgInfo(Database db, String portal) {
  final src = srcOf(db, portal);
  if (src == null) return null;
  final r = db.select(
      'SELECT gen, saved, hash, lo, hi, count FROM epg_meta WHERE src = ?',
      [src]);
  if (r.isEmpty) return null;
  final row = r.first;
  final gen = row['gen'] as int;
  final chans = db.select(
      'SELECT count(*) FROM epg_chan WHERE src = ? AND gen = ?', [src, gen]);
  return EpgDbInfo(
    gen,
    DateTime.fromMillisecondsSinceEpoch(row['saved'] as int),
    _s(row['hash']),
    _i(row['lo']),
    _i(row['hi']),
    row['count'] as int,
    chans.first.columnAt(0) as int,
  );
}

({int gen, int maxdur})? _epgActive(Database db, int src) {
  final r = db.select('SELECT gen, maxdur FROM epg_meta WHERE src = ?', [src]);
  if (r.isEmpty) return null;
  return (gen: r.first.columnAt(0) as int, maxdur: r.first.columnAt(1) as int);
}

/// Alle Generationen außer [keep] löschen (Häppchenweise, eigene kurze
/// Transaktionen – Leser und andere Schreiber kommen dazwischen dran).
void _dropEpgGens(Database db, int src, int? keep) {
  final k = keep ?? -1;
  db.execute('DELETE FROM epg_stage WHERE src = ? AND gen <> ?', [src, k]);
  while (true) {
    final cids = [
      for (final r in db.select(
          'SELECT cid FROM epg_chan WHERE src = ? AND gen <> ? LIMIT 200',
          [src, k]))
        r.columnAt(0) as int,
    ];
    if (cids.isEmpty) break;
    _tx(db, () {
      final de = db.prepare('DELETE FROM epg WHERE cid = ?');
      final dc = db.prepare('DELETE FROM epg_chan WHERE cid = ?');
      try {
        for (final c in cids) {
          de.execute([c]);
          dc.execute([c]);
        }
      } finally {
        de.close();
        dc.close();
      }
    });
  }
  while (true) {
    final ids = [
      for (final r in db.select(
          'SELECT id, norm IS NOT NULL FROM epg_text WHERE src = ? AND gen <> ? LIMIT 20000',
          [src, k]))
        (r.columnAt(0) as int, r.columnAt(1) == 1),
    ];
    if (ids.isEmpty) break;
    _tx(db, () {
      final df = db.prepare('DELETE FROM epg_fts WHERE rowid = ?');
      final dt = db.prepare('DELETE FROM epg_text WHERE id = ?');
      try {
        for (final (id, title) in ids) {
          if (title) df.execute([id]);
          dt.execute([id]);
        }
      } finally {
        df.close();
        dt.close();
      }
    });
  }
}

/// EPG eines Portals ersetzen. Geschrieben wird als neue „Generation“ in
/// Häppchen à [chunk] Sendungen (je eine Transaktion); erst ganz am Ende wird
/// umgeschaltet und die alte Generation gelöscht. Abbruch ([cancelled] oder
/// Prozess-Ende) → der alte Stand bleibt gültig, Reste werden beim nächsten
/// Mal entfernt. Liefert den neuen Stand oder null (abgebrochen).
EpgDbInfo? writeEpg(Database db, String portal, Map<String, List<EpgEntry>> epg,
    {required DateTime saved,
    String? hash,
    int chunk = 50000,
    bool activate = true,
    bool Function()? cancelled}) {
  final src = srcOf(db, portal, create: true)!;
  final active = _epgActive(db, src);
  // Reste abgebrochener Läufe entfernen.
  _dropEpgGens(db, src, active?.gen);
  final maxGen = db
      .select('SELECT max(gen) FROM epg_chan WHERE src = ?', [src])
      .first
      .columnAt(0);
  final gen =
      [active?.gen ?? 0, _i(maxGen) ?? 0].reduce((a, b) => a > b ? a : b) + 1;

  var lo = -1, hi = -1, maxdur = 0, count = 0;
  final titles = <String, int>{};
  final texts = <String, int>{};

  db.execute('BEGIN IMMEDIATE');
  var open = true;
  final insChan =
      db.prepare('INSERT INTO epg_chan(src, gen, ch) VALUES (?, ?, ?)');
  final insText =
      db.prepare('INSERT INTO epg_text(src, gen, s, norm) VALUES (?, ?, ?, ?)');
  final insFts = db.prepare('INSERT INTO epg_fts(rowid, norm) VALUES (?, ?)');
  final insEpg = db.prepare('INSERT OR IGNORE INTO epg(cid, start, seq, stop, '
      'title, descr, genre, archive) VALUES (?, ?, ?, ?, ?, ?, ?, ?)');
  int title(String s) => titles[s] ??= () {
        final n = foldSearch(s);
        insText.execute([src, gen, s, n]);
        final id = db.lastInsertRowId;
        insFts.execute([id, n]);
        return id;
      }();
  int? text(String? s) {
    if (s == null) return null;
    return texts[s] ??= () {
      insText.execute([src, gen, s, null]);
      return db.lastInsertRowId;
    }();
  }

  try {
    var inChunk = 0;
    for (final e in epg.entries) {
      if (e.value.isEmpty) continue;
      insChan.execute([src, gen, e.key]);
      final cid = db.lastInsertRowId;
      var seq = 0;
      for (final p in e.value) {
        final s = p.start.millisecondsSinceEpoch ~/ 1000;
        final t = p.end.millisecondsSinceEpoch ~/ 1000;
        insEpg.execute([
          cid,
          s,
          seq++,
          t,
          title(p.title),
          text(p.description),
          text(p.genre),
          p.hasArchive ? 1 : 0,
        ]);
        if (lo < 0 || s < lo) lo = s;
        if (t > hi) hi = t;
        if (t - s > maxdur) maxdur = t - s;
        count++;
        inChunk++;
      }
      if (inChunk >= chunk) {
        db.execute('COMMIT');
        open = false;
        inChunk = 0;
        if (cancelled?.call() ?? false) return null;
        db.execute('BEGIN IMMEDIATE');
        open = true;
      }
    }
    db.execute(
        'INSERT OR REPLACE INTO epg_stage(src, gen, saved, hash, lo, hi, maxdur, count) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
        [
          src,
          gen,
          saved.millisecondsSinceEpoch,
          hash,
          lo < 0 ? null : lo,
          hi < 0 ? null : hi,
          maxdur,
          count,
        ]);
    db.execute('COMMIT');
    open = false;
  } catch (_) {
    if (open && !db.autocommit) db.execute('ROLLBACK');
    rethrow;
  } finally {
    insChan.close();
    insText.close();
    insFts.close();
    insEpg.close();
  }
  final info = EpgDbInfo(gen, saved, hash, lo < 0 ? null : lo,
      hi < 0 ? null : hi, count, epg.values.where((l) => l.isNotEmpty).length);
  if (activate) activateEpg(db, portal, gen);
  return info;
}

/// Vorbereitete Generation [gen] (aus [writeEpg] mit `activate: false`)
/// gültig machen; ältere Generationen werden gelöscht. false = gibt es
/// nicht (mehr).
bool activateEpg(Database db, String portal, int gen, {DateTime? saved}) {
  final src = srcOf(db, portal);
  if (src == null) return false;
  var ok = false;
  _tx(db, () {
    final r = db.select(
        'SELECT saved, hash, lo, hi, maxdur, count FROM epg_stage WHERE src = ? AND gen = ?',
        [src, gen]);
    if (r.isEmpty) return;
    final x = r.first;
    db.execute(
        'INSERT OR REPLACE INTO epg_meta(src, gen, saved, hash, lo, hi, maxdur, count) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
        [
          src,
          gen,
          saved?.millisecondsSinceEpoch ?? x['saved'],
          x['hash'],
          x['lo'],
          x['hi'],
          x['maxdur'],
          x['count'],
        ]);
    db.execute('DELETE FROM epg_stage WHERE src = ?', [src]);
    ok = true;
  });
  if (!ok) return false;
  // Alte Generation weg (Leser sehen schon die neue).
  try {
    _dropEpgGens(db, src, gen);
    db.execute('PRAGMA incremental_vacuum(2000)');
  } catch (_) {
    // Aufräumen holt der nächste Lauf nach.
  }
  return true;
}

/// Nur Prüfsumme/Zeitpunkt aktualisieren (Inhalt unverändert).
void touchEpg(Database db, String portal, DateTime saved) {
  final src = srcOf(db, portal);
  if (src == null) return;
  db.execute('UPDATE epg_meta SET saved = ? WHERE src = ?',
      [saved.millisecondsSinceEpoch, src]);
}

/// EPG eines Portals löschen.
void deleteEpg(Database db, String portal) {
  final src = srcOf(db, portal);
  if (src == null) return;
  _tx(db, () => db.execute('DELETE FROM epg_meta WHERE src = ?', [src]));
  _dropEpgGens(db, src, null);
}

class _Texts {
  final Database db;
  final _cache = <int, String>{};
  late final _st = db.prepare('SELECT s FROM epg_text WHERE id = ?');
  _Texts(this.db);

  String? get(Object? id) {
    if (id is! int) return null;
    final c = _cache[id];
    if (c != null) return c;
    final r = _st.select([id]);
    if (r.isEmpty) return null;
    return _cache[id] = r.first.columnAt(0) as String;
  }

  void close() => _st.close();
}

EpgEntry _entry(String key, Row r, _Texts t, int o) => EpgEntry(
      channelEpgId: key,
      start: DateTime.fromMillisecondsSinceEpoch((r.columnAt(o) as int) * 1000),
      end: DateTime.fromMillisecondsSinceEpoch(
          (r.columnAt(o + 1) as int) * 1000),
      title: t.get(r.columnAt(o + 2)) ?? '',
      description: t.get(r.columnAt(o + 3)),
      genre: t.get(r.columnAt(o + 4)),
      hasArchive: r.columnAt(o + 5) == 1,
    );

const _epgCols = 'e.start, e.stop, e.title, e.descr, e.genre, e.archive';

/// Alle Sendungen, die sich mit [from, to) überschneiden (Sekunden), je
/// EPG-Schlüssel sortiert nach Beginn.
Map<String, List<EpgEntry>> readEpgWindow(
    Database db, String portal, int from, int to) {
  final src = srcOf(db, portal);
  if (src == null) return {};
  return _read(db, () {
    final a = _epgActive(db, src);
    if (a == null) return <String, List<EpgEntry>>{};
    final t = _Texts(db);
    try {
      final out = <String, List<EpgEntry>>{};
      final st = db.prepare(
          'SELECT c.ch, $_epgCols FROM epg_chan c JOIN epg e ON e.cid = c.cid '
          'AND e.start >= ? AND e.start < ? '
          'WHERE c.src = ? AND c.gen = ? ORDER BY c.cid, e.start, e.seq');
      try {
        final rows = st.selectCursor([from - a.maxdur, to, src, a.gen]);
        String? key;
        List<EpgEntry>? list;
        while (rows.moveNext()) {
          final r = rows.current;
          if ((r.columnAt(2) as int) <= from) continue; // vorher zu Ende
          final k = r.columnAt(0) as String;
          if (k != key) {
            key = k;
            list = out[k] = <EpgEntry>[];
          }
          list!.add(_entry(k, r, t, 1));
        }
      } finally {
        st.close();
      }
      return out;
    } finally {
      t.close();
    }
  });
}

/// Programm einzelner Sender (EPG-Schlüssel) im Fenster [from, to)
/// (null = alles).
Map<String, List<EpgEntry>> readEpgChannels(
    Database db, String portal, Iterable<String> keys,
    {int? from, int? to}) {
  final src = srcOf(db, portal);
  if (src == null) return {};
  return _read(db, () {
    final a = _epgActive(db, src);
    if (a == null) return <String, List<EpgEntry>>{};
    final t = _Texts(db);
    final st = db.prepare(
        'SELECT $_epgCols FROM epg_chan c JOIN epg e ON e.cid = c.cid '
        'AND e.start >= ? AND e.start < ? '
        'WHERE c.src = ? AND c.gen = ? AND c.ch = ? ORDER BY e.start, e.seq');
    try {
      final out = <String, List<EpgEntry>>{};
      final lo = from == null ? -(1 << 62) : from - a.maxdur;
      final hi = to ?? (1 << 62);
      for (final k in keys) {
        final list = <EpgEntry>[];
        for (final r in st.select([lo, hi, src, a.gen, k])) {
          if (from != null && (r.columnAt(1) as int) <= from) continue;
          list.add(_entry(k, r, t, 0));
        }
        if (list.isNotEmpty) out[k] = list;
      }
      return out;
    } finally {
      st.close();
      t.close();
    }
  });
}

/// Sichtbare Sender für die EPG-Suche (EPG-Schlüssel → Catch-up möglich).
/// Liegt als temporäre Tabelle in dieser Verbindung (Datenbank-Isolate).
void setSearchChannels(Database db, Map<String, bool> keys) {
  db.execute('CREATE TEMP TABLE IF NOT EXISTS vis(ch TEXT PRIMARY KEY, '
      'catchup INTEGER NOT NULL) WITHOUT ROWID');
  // Nur die temporäre Tabelle: keine Schreibsperre auf der Datenbank.
  db.execute('BEGIN');
  try {
    db.execute('DELETE FROM temp.vis');
    final st = db
        .prepare('INSERT OR REPLACE INTO temp.vis(ch, catchup) VALUES (?, ?)');
    try {
      for (final e in keys.entries) {
        st.execute([e.key, e.value ? 1 : 0]);
      }
    } finally {
      st.close();
    }
    db.execute('COMMIT');
  } catch (_) {
    if (!db.autocommit) db.execute('ROLLBACK');
    rethrow;
  }
}

/// EPG-Suche wie bisher: läuft gerade → demnächst → vergangen (nur mit
/// Catch-up, neueste zuerst), nur Sendungen zwischen [from] und [to]
/// (Sekunden), nur Sender aus [setSearchChannels]. Höchstens [limit].
List<EpgHit> searchEpg(Database db, String portal, String q,
    {required int now, required int from, required int to, int limit = 60}) {
  final src = srcOf(db, portal);
  if (src == null || q.length < 2) return const [];
  final a = _epgActive(db, src);
  if (a == null) return const [];
  db.execute('CREATE TEMP TABLE IF NOT EXISTS vis(ch TEXT PRIMARY KEY, '
      'catchup INTEGER NOT NULL) WITHOUT ROWID');
  return _read(db, () {
    // Passende Titel (je Titel nur einmal gespeichert).
    final ids = q.length >= 3
        ? db.select(
            'SELECT t.id FROM epg_fts f JOIN epg_text t ON t.id = f.rowid '
            'WHERE epg_fts MATCH ? AND t.src = ? AND t.gen = ?',
            [ftsPhrase(q), src, a.gen])
        : db.select(
            "SELECT id FROM epg_text WHERE src = ? AND gen = ? AND norm IS NOT NULL "
            "AND norm LIKE ? ESCAPE '\\'",
            [src, a.gen, likeContains(q)]);
    if (ids.isEmpty) return const <EpgHit>[];
    db.execute('CREATE TEMP TABLE IF NOT EXISTS hit(id INTEGER PRIMARY KEY)');
    db.execute('DELETE FROM temp.hit');
    final ins = db.prepare('INSERT OR IGNORE INTO temp.hit(id) VALUES (?)');
    try {
      for (final r in ids) {
        ins.execute([r.columnAt(0)]);
      }
    } finally {
      ins.close();
    }
    final t = _Texts(db);
    try {
      final out = <EpgHit>[];
      // Von den passenden Titeln aus (Index title,start), nicht über alle
      // Sender; Beginn je Teil eingegrenzt (längste Sendung: maxdur).
      const base = 'SELECT c.ch, $_epgCols FROM temp.hit h '
          'CROSS JOIN epg e INDEXED BY epg_title CROSS JOIN epg_chan c '
          'CROSS JOIN temp.vis v '
          'WHERE e.title = h.id AND c.cid = e.cid AND v.ch = c.ch '
          'AND c.src = ? AND c.gen = ? ';
      final parts = [
        // läuft gerade
        (
          '${base}AND e.start > ? AND e.start <= ? AND e.stop > ? '
              'AND e.stop >= ? ORDER BY e.start, c.cid, e.seq LIMIT ?',
          [src, a.gen, now - a.maxdur - 1, now, now, from]
        ),
        // demnächst
        (
          '${base}AND e.start > ? AND e.start <= ? AND e.stop >= ? '
              'ORDER BY e.start, c.cid, e.seq LIMIT ?',
          [src, a.gen, now, to, from]
        ),
        // vergangen (nur mit Archiv), neueste zuerst
        (
          '${base}AND e.start >= ? AND e.start <= ? AND e.stop <= ? '
              'AND e.stop >= ? AND v.catchup = 1 '
              'ORDER BY e.start DESC, c.cid, e.seq LIMIT ?',
          [src, a.gen, from - a.maxdur, to, now, from]
        ),
      ];
      for (final (sql, args) in parts) {
        final left = limit - out.length;
        if (left <= 0) break;
        for (final r in db.select(sql, [...args, left])) {
          final k = r.columnAt(0) as String;
          out.add((key: k, entry: _entry(k, r, t, 1)));
        }
      }
      return out;
    } finally {
      t.close();
    }
  });
}

// ---------------------------------------------------------------- Portal

/// Alles eines Portals löschen (Listen, EPG, Suchindex).
void deletePortalData(Database db, String portal) {
  final src = srcOf(db, portal);
  if (src == null) return;
  _tx(db, () {
    for (final r
        in db.select('SELECT kind FROM lists WHERE src = ?', [src]).toList()) {
      _clearList(db, src, r.columnAt(0) as String);
    }
    // Auch Reste ohne Listen-Eintrag.
    db.execute(
        'DELETE FROM channels_fts WHERE rowid IN (SELECT rid FROM channels WHERE src = ?)',
        [src]);
    db.execute('DELETE FROM channels WHERE src = ?', [src]);
    db.execute(
        'DELETE FROM vod_fts WHERE rowid IN (SELECT rid FROM vod WHERE src = ?)',
        [src]);
    db.execute('DELETE FROM vod WHERE src = ?', [src]);
    db.execute('DELETE FROM categories WHERE src = ?', [src]);
    db.execute('DELETE FROM epg_meta WHERE src = ?', [src]);
    db.execute('DELETE FROM epg_stage WHERE src = ?', [src]);
  });
  _dropEpgGens(db, src, null);
  _tx(db, () => db.execute('DELETE FROM src WHERE sid = ?', [src]));
}

/// Alle Portal-Schlüssel mit Daten (Diagnose/Tests).
List<String> portalsWithData(Database db) => [
      for (final r in db.select('SELECT key FROM src ORDER BY sid'))
        r.columnAt(0) as String,
    ];
