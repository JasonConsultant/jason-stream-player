import 'dart:async';
import 'dart:isolate';

import 'package:sqlite3/sqlite3.dart';

import '../../models/models.dart';
import '../epg_cache/epg_file_io.dart' as files;
import 'db_io.dart' as dbi;
import 'db_types.dart';

export 'db_types.dart';

/// Zugriff auf die Katalog-Datenbank (siehe db_io.dart).
///
/// - **Abgleich** (Listen/EPG schreiben, Startlisten lesen) läuft in den
///   bestehenden Hintergrund-Isolates mit eigener Verbindung
///   ([withCatalog], synchron).
/// - **Abfragen** aus der Oberfläche (Suche, Fenster, Archiv, Tagesansicht)
///   laufen in einem eigenen, langlebigen Datenbank-Isolate ([Catalog.run]) –
///   der UI-Thread wartet nie auf SQLite.
class Catalog {
  Catalog._();

  static const fileName = 'databases/catalog.db';

  /// Pfad der Datenbank im App-Ordner (null = kein Dateisystem, z. B.
  /// Tests ohne Verzeichnis).
  static Future<String?> path() => files.cacheFilePath(fileName);

  /// Datenbank verfügbar (Plattform mit Dateisystem)?
  static const supported = true;

  static _Worker? _worker;

  /// [job] im Datenbank-Isolate ausführen. null = keine Datenbank / Fehler.
  /// [job] darf nur sendbare Werte einfangen und liefern.
  static Future<T?> run<T>(T Function(Database db) job) async {
    final p = await path();
    if (p == null) return null;
    try {
      var w = _worker;
      if (w == null || w.path != p) {
        w?.close();
        w = _worker = _Worker(p);
      }
      return await w.run(job);
    } catch (_) {
      return null;
    }
  }

  /// Datenbank-Isolate beenden (Tests, Verzeichniswechsel).
  static void closeWorker() {
    _worker?.close();
    _worker = null;
  }

  // ------------------------------------------------------------ Abfragen
  /// Schlüssel-Wert-Zwischenspeicher (TMDB).
  static Future<String?> kvGet(String key, int minSaved) =>
      run<String?>((db) => dbi.kvGet(db, key, minSaved));
  static Future<void> kvPut(String key, String value, int now) =>
      run((db) => dbi.kvPut(db, key, value, now));

  static Future<bool> hasList(String portal, String kind) async =>
      await run((db) => dbi.hasList(db, portal, kind)) ?? false;

  static Future<List<String>> searchChannelIds(String portal, String q) async =>
      await run((db) => dbi.searchChannelIds(db, portal, q)) ?? const [];

  static Future<List<String>> searchVodIds(
          String portal, String kind, String q) async =>
      await run((db) => dbi.searchVodIds(db, portal, kind, q)) ?? const [];

  static Future<List<String>> searchVodPeopleIds(
          String portal, String kind, String q) async =>
      await run((db) => dbi.searchVodPeopleIds(db, portal, kind, q)) ??
      const [];

  static Future<bool> setSearchChannels(Map<String, bool> keys) async =>
      await run((db) {
        dbi.setSearchChannels(db, keys);
        return true;
      }) ??
      false;

  static Future<List<EpgHit>?> searchEpg(String portal, String q,
          {required int now,
          required int from,
          required int to,
          int limit = 60}) =>
      run((db) => dbi.searchEpg(db, portal, q,
          now: now, from: from, to: to, limit: limit));

  static Future<EpgDbInfo?> epgInfo(String portal) =>
      run<EpgDbInfo?>((db) => dbi.epgInfo(db, portal));

  static Future<Map<String, List<EpgEntry>>?> epgChannels(
          String portal, List<String> keys,
          {int? from, int? to}) =>
      run((db) => dbi.readEpgChannels(db, portal, keys, from: from, to: to));

  static Future<Map<String, List<EpgEntry>>?> epgWindow(
          String portal, int from, int to) =>
      run((db) => dbi.readEpgWindow(db, portal, from, to));

  static Future<int> countChannels(String portal, {String? category}) async =>
      await run((db) => dbi.countChannels(db, portal, category: category)) ?? 0;

  static Future<List<Channel>> channelWindow(String portal,
          {String? category,
          required int offset,
          required int limit,
          String Function(String)? restore}) async =>
      await run((db) => dbi.channelWindow(db, portal,
          category: category,
          offset: offset,
          limit: limit,
          restore: restore)) ??
      const [];

  static Future<int> countVod(String portal, String kind,
          {String? category}) async =>
      await run((db) => dbi.countVod(db, portal, kind, category: category)) ??
      0;

  static Future<List<VodItem>> vodWindow(String portal, String kind,
          {String? category,
          required int offset,
          required int limit,
          String Function(String)? restore}) async =>
      await run((db) => dbi.vodWindow(db, portal, kind,
          category: category,
          offset: offset,
          limit: limit,
          restore: restore)) ??
      const [];

  /// Programm eines Portals löschen.
  static Future<bool> deleteEpg(String portal) async =>
      await run((db) {
        dbi.deleteEpg(db, portal);
        return true;
      }) ??
      false;

  /// Alle Daten eines Portals löschen (Listen, EPG, Suchindex).
  static Future<bool> deletePortal(String portal) async =>
      await run((db) {
        dbi.deletePortalData(db, portal);
        return true;
      }) ??
      false;

  static Future<List<String>> portalsWithData() async =>
      await run(dbi.portalsWithData) ?? const [];
}

/// Verbindung im aktuellen (Hintergrund-)Isolate öffnen, [job] ausführen,
/// schließen. Für Abgleich/Laden in den Listen- und EPG-Isolates.
T withCatalog<T>(String path, T Function(Database db) job) {
  final db = dbi.openCatalog(path);
  try {
    return job(db);
  } finally {
    db.close();
  }
}

// ---------------------------------------------------------------- Isolat

class _Worker {
  final String path;
  final _ready = Completer<SendPort>();
  final _rp = ReceivePort();
  final _pending = <int, Completer<Object?>>{};
  var _seq = 0;
  Isolate? _iso;
  bool _closed = false;

  _Worker(this.path) {
    _rp.listen((m) {
      if (m is SendPort) {
        if (!_ready.isCompleted) _ready.complete(m);
        return;
      }
      if (m is (int, bool, Object?)) {
        final c = _pending.remove(m.$1);
        if (c == null) return;
        m.$2 ? c.complete(m.$3) : c.completeError(m.$3 ?? 'Fehler');
      }
    });
    Isolate.spawn(_main, (_rp.sendPort, path), debugName: 'catalog-db').then(
        (i) {
      _iso = i;
      if (_closed) i.kill(priority: Isolate.immediate);
    }, onError: (Object e) {
      if (!_ready.isCompleted) _ready.completeError(e);
    });
  }

  Future<T> run<T>(T Function(Database db) job) async {
    final port = await _ready.future;
    final id = _seq++;
    final c = _pending[id] = Completer<Object?>();
    port.send((id, job));
    return (await c.future) as T;
  }

  void close() {
    _closed = true;
    _iso?.kill(priority: Isolate.immediate);
    _rp.close();
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(StateError('geschlossen'));
    }
    _pending.clear();
  }

  static void _main((SendPort, String) a) {
    final (out, path) = a;
    final rp = ReceivePort();
    out.send(rp.sendPort);
    Database? db;
    rp.listen((m) {
      final (int id, Object? Function(Database) job) =
          m as (int, Object? Function(Database));
      try {
        db ??= dbi.openCatalog(path);
        out.send((id, true, job(db!)));
      } catch (e) {
        // Verbindung bei Fehlern neu öffnen (z. B. Datei ersetzt).
        try {
          db?.close();
        } catch (_) {}
        db = null;
        out.send((id, false, '$e'));
      }
    });
  }
}
