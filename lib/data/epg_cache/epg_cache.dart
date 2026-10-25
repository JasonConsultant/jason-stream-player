import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../../models/models.dart';
import '../db/catalog.dart';
import '../db/catalog_sync.dart' as dbs;
import '../epg_window.dart';
import 'epg_file_stub.dart' if (dart.library.io) 'epg_file_io.dart';

/// Wohin das Parse-Isolate das EPG gleich schreibt (siehe
/// [XmltvParser.loadSources]): Datenbank, Portal und Prüfsumme des
/// angezeigten Programms (gleich → nichts schreiben).
class EpgStoreSpec {
  final String path;
  final String portal;
  final String? prevHash;
  const EpgStoreSpec(this.path, this.portal, this.prevHash);
}

/// EPG-Zwischenspeicher auf dem Gerät: Die App startet sofort mit Programm
/// (auch offline) und lädt nur nach, wenn es fällig ist.
///
/// Ab 2.0 liegt das Programm in der Katalog-Datenbank (lib/data/db). Im
/// Speicher hält die App nur noch ein Fenster um „jetzt“
/// ([memoryBack]/[memoryForward]); Archiv, andere Tage des TV-Guides und
/// die Sendungssuche lesen bei Bedarf aus der Datenbank.
///
/// Bis 1.9 war es eine Binärdatei (`epg_<id>.bin`, "JEPG" · Version ·
/// Text-Tabelle · Zahlen je Sendung). Sie wird beim ersten Laden einmalig
/// übernommen und gelöscht; das Format bleibt für die Prüfsumme
/// ([hashEpg] = md5 dieser Bytes) und die Übernahme erhalten.
class EpgCache {
  static const _magic = 0x4A455047; // "JEPG"
  static const _version = 2;

  static String _name(String portalId) =>
      'epg_${portalId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')}.bin';

  /// Fenster im Speicher, wenn die Datenbank das ganze Programm hält:
  /// gestern bis übermorgen (TV-Guide „Heute“, Jetzt/Danach, Catch-up der
  /// letzten Stunden). Ohne Datenbank (Web) bleibt alles im Speicher.
  static const memoryBack = Duration(days: 1);
  static const memoryForward = Duration(days: 2);

  /// Kommt das Programm aus der Datenbank? (Dann ist die Map im Speicher
  /// nur ein Fenster und Archiv/Tage/Suche fragen die Datenbank.)
  static final dbBacked = <String, bool>{};

  /// Stand des Programms in der Datenbank (Zeitraum, Anzahl) je Portal.
  static final info = <String, EpgDbInfo>{};

  static (int, int) _range(DateTime now, {bool near = false, bool db = true}) {
    final t = now.millisecondsSinceEpoch ~/ 1000;
    if (near) return (t - 3 * 3600, t + 30 * 3600);
    if (db) return (t - memoryBack.inSeconds, t + memoryForward.inSeconds);
    return (t - EpgWindow.back.inSeconds, t + EpgWindow.forward.inSeconds);
  }

  /// Nur das Speicherfenster (gestern … übermorgen) eines vollständigen EPG.
  static Map<String, List<EpgEntry>> memoryWindow(
      Map<String, List<EpgEntry>> epg,
      {DateTime? now}) {
    final n = now ?? DateTime.now();
    final lo = n.subtract(memoryBack), hi = n.add(memoryForward);
    final out = <String, List<EpgEntry>>{};
    for (final e in epg.entries) {
      final l = e.value;
      // Listen sind nach Beginn sortiert.
      var a = 0;
      while (a < l.length && !l[a].end.isAfter(lo)) {
        a++;
      }
      var b = a;
      while (b < l.length && l[b].start.isBefore(hi)) {
        b++;
      }
      if (b > a) out[e.key] = a == 0 && b == l.length ? l : l.sublist(a, b);
    }
    return out;
  }

  /// Nur „jetzt und demnächst“ (−3 h … +30 h) aus alten Rohdaten (Tests).
  static Future<Map<String, List<EpgEntry>>?> decodeNear(Uint8List raw) {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return _safe(raw, now - 3 * 3600, now + 30 * 3600);
  }

  /// Alles inkl. 7 Tage Archiv aus alten Rohdaten (Tests).
  static Future<Map<String, List<EpgEntry>>?> decodeFull(Uint8List raw) {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return _safe(
        raw, now - EpgWindow.back.inSeconds, now + EpgWindow.forward.inSeconds);
  }

  static Future<Map<String, List<EpgEntry>>?> _safe(
      Uint8List raw, int from, int to) async {
    try {
      return await compute(_decodeWindow, (raw, from, to));
    } catch (_) {
      return null; // beschädigt → einfach neu laden
    }
  }

  static Future<Map<String, List<EpgEntry>>?> load(String portalId) =>
      loadWindow(portalId);

  /// Programm im Hintergrund lesen (Datenbank; alte Datei wird dabei
  /// einmalig übernommen). [near]: nur −3 h … +30 h (Schnellstart), sonst
  /// das Speicherfenster (mit Datenbank) bzw. alles (ohne). Die Prüfsumme
  /// hängt am Ergebnis ([hashOf]). Nichts gespeichert/beschädigt → null.
  static Future<Map<String, List<EpgEntry>>?> loadWindow(String portalId,
      {bool near = false}) async {
    try {
      final db = await Catalog.path();
      final legacy = await cacheFilePath(_name(portalId));
      if (db == null && legacy == null) return null;
      final r = await Isolate.run(
          _loadTask(db, legacy, portalId, DateTime.now(), near, !near));
      if (r == null) return null;
      final (map, hash, inDb, meta) = r;
      dbBacked[portalId] = inDb;
      if (meta != null) info[portalId] = meta;
      if (hash != null) _attached[map] = (null, hash, null);
      return map;
    } catch (_) {
      return null;
    }
  }

  static _LoadResult? Function() _loadTask(String? db, String? legacy,
          String portal, DateTime now, bool near, bool withHash) =>
      () => _loadJob(db, legacy, portal, now, near, withHash);

  static _LoadResult? _loadJob(String? db, String? legacy, String portal,
      DateTime now, bool near, bool withHash) {
    var dbOk = false;
    if (db != null) {
      try {
        var meta = dbs.syncEpgInfo(db, portal);
        dbOk = true;
        if (meta == null && legacy != null) {
          // Einmalige Übernahme der alten Datei (bis 1.9).
          final raw = readBytesSync(legacy);
          if (raw != null) {
            Map<String, List<EpgEntry>>? all;
            try {
              all = _decodeWindow((raw, -(1 << 40), 1 << 40));
            } catch (_) {
              all = null;
            }
            if (all == null) {
              deleteFileSync(legacy); // beschädigt → neu laden
              return null;
            }
            meta = dbs.syncWriteEpg(db, portal, all,
                saved: now, hash: hashBytes(raw));
            deleteFileSync(legacy);
          }
        } else if (legacy != null) {
          deleteFileSync(legacy); // Rest (Abbruch beim Löschen)
        }
        if (meta == null) return null;
        final (from, to) = _range(now, near: near);
        final map = dbs.syncReadEpgWindow(db, portal, from, to);
        return (map, withHash ? meta.hash : null, true, meta);
      } catch (_) {
        if (dbOk) return null;
        // Datenbank nicht nutzbar → alte Datei wie bisher.
      }
    }
    if (legacy == null) return null;
    final raw = readBytesSync(legacy);
    if (raw == null) return null;
    final (from, to) = _range(now, near: near, db: false);
    Map<String, List<EpgEntry>>? map;
    try {
      map = _decodeWindow((raw, from, to));
    } catch (_) {
      map = null;
    }
    if (map == null) {
      deleteFileSync(legacy); // beschädigt → wie nicht vorhanden
      return null;
    }
    return (map, withHash ? hashBytes(raw) : null, false, null);
  }

  // ---------- Fertig gespeichertes EPG (aus dem Parse-Isolate) ----------
  /// Zum EPG-Objekt gehörende Prüfsumme und – falls das Parse-Isolate es
  /// schon in die Datenbank geschrieben hat – die vorbereitete Generation
  /// ([save] schaltet sie dann nur noch um, ohne das große EPG zu kopieren).
  static final _attached = Expando<(Uint8List?, String, int?)>('epgEncoded');

  /// Prüfsumme (und optional vorbereitete Generation [staged]) anheften.
  static void attach(
          Map<String, List<EpgEntry>> epg, Uint8List? bytes, String hash,
          {int? staged}) =>
      _attached[epg] = (bytes, hash, staged);

  /// Verbindung lösen (das EPG wurde nachträglich verändert).
  static void detach(Map<String, List<EpgEntry>> epg) => _attached[epg] = null;

  /// Prüfsumme des Inhalts, falls bekannt (geladen oder fertig kodiert).
  static String? hashOf(Map<String, List<EpgEntry>> epg) => _attached[epg]?.$2;

  static String hashBytes(Uint8List b) => md5.convert(b).toString();

  /// Kodieren + Prüfsumme (im Hintergrund-Isolate aufzurufen).
  static (Uint8List, String) encodeWithHash(Map<String, List<EpgEntry>> epg) {
    final b = _encode(epg);
    return (b, hashBytes(b));
  }

  /// Prüfsumme wie `hashBytes(encode(epg))`, aber ohne die Bytes im
  /// Speicher zu sammeln (stückweise in md5).
  static String hashEpg(Map<String, List<EpgEntry>> epg) {
    final out = _DigestSink();
    final sink = md5.startChunkedConversion(out);
    _encodeTo(epg, sink.add);
    sink.close();
    return out.value.toString();
  }

  /// Programm speichern: hat das Parse-Isolate schon geschrieben, wird nur
  /// umgeschaltet; sonst im Hintergrund in die Datenbank geschrieben.
  static Future<void> save(
      String portalId, Map<String, List<EpgEntry>> epg) async {
    try {
      final db = await Catalog.path();
      if (db == null) return;
      final a = _attached[epg];
      final staged = a?.$3;
      final now = DateTime.now();
      final hash = a?.$2;
      if (staged != null) {
        final ok =
            await Isolate.run(_activateTask(db, portalId, staged, now));
        if (ok) {
          dbBacked[portalId] = true;
          _attached[epg] = (null, hash!, null);
          final m = await Catalog.epgInfo(portalId);
          if (m != null) info[portalId] = m;
          return;
        }
      }
      final meta = await Isolate.run(_writeTask(db, portalId, epg, now, hash));
      if (meta != null) {
        info[portalId] = meta;
        dbBacked[portalId] = true;
      }
    } catch (_) {
      // Zwischenspeicher ist optional.
    }
  }

  // Eigene Funktionen: die Closures dürfen nur ihre Argumente einfangen
  // (sonst ginge das ganze EPG mit ins Isolate).
  static bool Function() _activateTask(
          String db, String portal, int gen, DateTime now) =>
      () => dbs.syncActivateEpg(db, portal, gen, now);

  static EpgDbInfo? Function() _writeTask(String db, String portal,
          Map<String, List<EpgEntry>> epg, DateTime now, String? hash) =>
      () => dbs.syncWriteEpg(db, portal, epg,
          saved: now, hash: hash ?? hashEpg(epg));

  /// Programm eines Portals löschen (Datenbank und alte Dateien).
  static Future<void> clear(String portalId) async {
    dbBacked.remove(portalId);
    info.remove(portalId);
    try {
      await deleteCacheFile(_name(portalId));
      await deleteCacheFile(_namesFile(portalId));
    } catch (_) {}
    await Catalog.deleteEpg(portalId);
  }

  // ---------- Senderliste der EPG-Quellen (Kennung → Anzeigename) ----------
  static String _namesFile(String portalId) =>
      'epgnames_${portalId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')}.json';

  static Future<Map<String, String>> loadNames(String portalId) async {
    try {
      final raw = await readCacheFile(_namesFile(portalId));
      if (raw == null || raw.isEmpty) return const {};
      return (jsonDecode(raw) as Map).cast<String, String>();
    } catch (_) {
      return const {};
    }
  }

  static Future<void> saveNames(
      String portalId, Map<String, String> names) async {
    try {
      if (names.isEmpty) return;
      await writeCacheFile(_namesFile(portalId), jsonEncode(names));
    } catch (_) {
      // optional
    }
  }

  static Uint8List debugEncode(Map<String, List<EpgEntry>> e) => _encode(e);
  static Map<String, List<EpgEntry>> debugDecode(Uint8List raw,
      {bool near = false}) {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return _decodeWindow(near
        ? (raw, now - 3 * 3600, now + 30 * 3600)
        : (
            raw,
            now - EpgWindow.back.inSeconds,
            now + EpgWindow.forward.inSeconds
          ))!;
  }

  // ---------------------------------------------------------------- Format
  static Uint8List _encode(Map<String, List<EpgEntry>> epg) {
    final out = BytesBuilder(copy: false);
    _encodeTo(epg, out.add);
    return out.takeBytes();
  }

  /// Binärformat stückweise an [add] (Kopf, Texte, Zahlen).
  static void _encodeTo(
      Map<String, List<EpgEntry>> epg, void Function(Uint8List) add) {
    final index = <String, int>{};
    final strings = <String>[];
    int idx(String? s) {
      if (s == null) return -1;
      return index[s] ??= (strings..add(s)).length - 1;
    }

    // 1. Durchgang: Texttabelle (Reihenfolge wie beim Schreiben).
    for (final e in epg.entries) {
      idx(e.key);
      for (final p in e.value) {
        idx(p.title);
        idx(p.description);
        idx(p.genre);
      }
    }
    final head = ByteData(16)
      ..setUint32(0, _magic)
      ..setUint32(4, _version)
      ..setUint32(8, strings.length)
      ..setUint32(12, epg.length);
    add(head.buffer.asUint8List());
    // Texte: Länge (uint32) + UTF-8
    for (final s in strings) {
      final b = utf8.encode(s);
      add((ByteData(4)..setUint32(0, b.length)).buffer.asUint8List());
      add(b);
    }
    // 2. Durchgang: Zahlen in Blöcken.
    const block = 8192;
    var buf = ByteData(block * 4);
    var n = 0;
    void put(int v) {
      buf.setInt32(n * 4, v);
      if (++n == block) {
        add(buf.buffer.asUint8List());
        buf = ByteData(block * 4);
        n = 0;
      }
    }

    for (final e in epg.entries) {
      put(index[e.key]!);
      put(e.value.length);
      for (final p in e.value) {
        put(p.start.millisecondsSinceEpoch ~/ 1000);
        put(p.end.difference(p.start).inSeconds);
        put(idx(p.title));
        put(idx(p.description));
        put(idx(p.genre));
        put(p.hasArchive ? 1 : 0);
      }
    }
    if (n > 0) add(buf.buffer.asUint8List(0, n * 4));
  }

  static Map<String, List<EpgEntry>>? _decodeWindow((Uint8List, int, int) job) {
    final (raw, from, to) = job;
    final bd = ByteData.sublistView(raw);
    if (raw.length < 16 || bd.getUint32(0) != _magic) return null;
    if (bd.getUint32(4) != _version) return null;
    final nStrings = bd.getUint32(8);
    final nChannels = bd.getUint32(12);
    // Unplausible Kopfdaten (beschädigt) → nicht riesig Speicher anfordern.
    if (nStrings * 4 > raw.length || nChannels * 8 > raw.length) return null;
    var pos = 16;
    // Texte erst bei Bedarf dekodieren (beim Schnellstart werden die meisten
    // Beschreibungen gar nicht gebraucht).
    final offsets = Int32List(nStrings);
    for (var i = 0; i < nStrings; i++) {
      offsets[i] = pos;
      pos += 4 + bd.getUint32(pos);
    }
    final strings = List<String?>.filled(nStrings, null);
    const dec = Utf8Decoder(allowMalformed: true);
    String? str(int i) {
      if (i < 0) return null;
      final o = offsets[i];
      return strings[i] ??= dec.convert(raw, o + 4, o + 4 + bd.getUint32(o));
    }

    int next() {
      final v = bd.getInt32(pos);
      pos += 4;
      return v;
    }

    final result = <String, List<EpgEntry>>{};
    for (var c = 0; c < nChannels; c++) {
      final ch = str(next())!;
      final n = next();
      final list = <EpgEntry>[];
      for (var i = 0; i < n; i++) {
        final start = next();
        final dur = next();
        final t = next(), d = next(), g = next(), a = next();
        if (start + dur < from || start > to) continue; // außerhalb Fenster
        list.add(EpgEntry(
          channelEpgId: ch,
          start: DateTime.fromMillisecondsSinceEpoch(start * 1000),
          end: DateTime.fromMillisecondsSinceEpoch((start + dur) * 1000),
          title: str(t) ?? '',
          description: str(d),
          genre: str(g),
          hasArchive: a == 1,
        ));
      }
      if (list.isNotEmpty) result[ch] = list;
    }
    return result;
  }
}

typedef _LoadResult = (
  Map<String, List<EpgEntry>>,
  String?,
  bool,
  EpgDbInfo?,
);

class _DigestSink implements Sink<Digest> {
  late Digest value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}
