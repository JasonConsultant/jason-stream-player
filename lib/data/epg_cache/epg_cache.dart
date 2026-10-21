import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../../models/models.dart';
import '../epg_window.dart';
import 'epg_file_stub.dart' if (dart.library.io) 'epg_file_io.dart';

/// EPG-Zwischenspeicher auf dem Gerät: Die App startet sofort mit Programm
/// (auch offline) und lädt nur nach, wenn es fällig ist.
///
/// Binärformat (statt JSON) – 5–10× schneller zu lesen:
///   "JEPG" · Version · Text-Tabelle (jeder Text nur einmal) · je Sender die
///   Sendungen als Zahlen (Start, Dauer, Text-Indizes).
class EpgCache {
  static const _magic = 0x4A455047; // "JEPG"
  static const _version = 2;

  static String _name(String portalId) =>
      'epg_${portalId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')}.bin';

  /// Rohdaten lesen (einmal), dann in zwei Stufen dekodieren:
  /// [decodeNear] für den schnellen Start, [decodeFull] fürs Archiv.
  static Future<Uint8List?> loadBytes(String portalId) async {
    try {
      return await readCacheBytes(_name(portalId));
    } catch (_) {
      return null;
    }
  }

  /// Nur „jetzt und demnächst“ (−3 h … +30 h) – sehr schnell, für Live-Liste
  /// und TV-Guide direkt beim Start.
  static Future<Map<String, List<EpgEntry>>?> decodeNear(Uint8List raw) {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return _safe(raw, now - 3 * 3600, now + 30 * 3600);
  }

  /// Alles inkl. 7 Tage Archiv (für Catch-up) und 7 Tage voraus.
  static Future<Map<String, List<EpgEntry>>?> decodeFull(Uint8List raw) {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return _safe(raw, now - EpgWindow.back.inSeconds, now + EpgWindow.forward.inSeconds);
  }

  static Future<Map<String, List<EpgEntry>>?> _safe(
      Uint8List raw, int from, int to) async {
    try {
      return await compute(_decodeWindow, (raw, from, to));
    } catch (_) {
      return null; // beschädigt → einfach neu laden
    }
  }

  static Future<Map<String, List<EpgEntry>>?> load(String portalId) async {
    final raw = await loadBytes(portalId);
    return raw == null ? null : decodeFull(raw);
  }

  static Future<void> save(
      String portalId, Map<String, List<EpgEntry>> epg) async {
    try {
      final raw = await compute(_encode, epg);
      await writeCacheBytes(_name(portalId), raw);
    } catch (_) {
      // Zwischenspeicher ist optional.
    }
  }

  static Future<void> clear(String portalId) =>
      deleteCacheFile(_name(portalId));

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
        : (raw, now - EpgWindow.back.inSeconds, now + EpgWindow.forward.inSeconds))!;
  }

  // ---------------------------------------------------------------- Format
  static Uint8List _encode(Map<String, List<EpgEntry>> epg) {
    final index = <String, int>{};
    final strings = <String>[];
    int idx(String? s) {
      if (s == null) return -1;
      return index[s] ??= (strings..add(s)).length - 1;
    }

    final ints = <int>[];
    var entries = 0;
    for (final e in epg.entries) {
      ints
        ..add(idx(e.key))
        ..add(e.value.length);
      for (final p in e.value) {
        ints
          ..add(p.start.millisecondsSinceEpoch ~/ 1000)
          ..add(p.end.difference(p.start).inSeconds)
          ..add(idx(p.title))
          ..add(idx(p.description))
          ..add(idx(p.genre))
          ..add(p.hasArchive ? 1 : 0);
        entries++;
      }
    }

    final out = BytesBuilder(copy: false);
    final head = ByteData(16)
      ..setUint32(0, _magic)
      ..setUint32(4, _version)
      ..setUint32(8, strings.length)
      ..setUint32(12, epg.length);
    out.add(head.buffer.asUint8List());
    // Texte: Länge (uint32) + UTF-8
    for (final s in strings) {
      final b = utf8.encode(s);
      out.add((ByteData(4)..setUint32(0, b.length)).buffer.asUint8List());
      out.add(b);
    }
    final body = ByteData(ints.length * 4);
    for (var i = 0; i < ints.length; i++) {
      body.setInt32(i * 4, ints[i]);
    }
    out.add(body.buffer.asUint8List());
    assert(entries >= 0);
    return out.takeBytes();
  }

  static Map<String, List<EpgEntry>>? _decodeWindow(
      (Uint8List, int, int) job) {
    final (raw, from, to) = job;
    final bd = ByteData.sublistView(raw);
    if (raw.length < 16 || bd.getUint32(0) != _magic) return null;
    if (bd.getUint32(4) != _version) return null;
    final nStrings = bd.getUint32(8);
    final nChannels = bd.getUint32(12);
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
