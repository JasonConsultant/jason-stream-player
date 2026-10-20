import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show compute;

import '../models/models.dart';
import 'epg_cache/epg_file_stub.dart' if (dart.library.io) 'epg_cache/epg_file_io.dart';

/// Zwischenspeicher für Senderliste, Filme und Serien.
///
/// Stream-Adressen enthalten bei Xtream Benutzername und Passwort
/// (`…/live/USER/PASS/123.ts`). Vor dem Speichern werden diese durch
/// Platzhalter ersetzt – die Datei enthält **keine Zugangsdaten**. Beim Laden
/// werden sie aus dem verschlüsselten Speicher wieder eingesetzt.
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
    final q = Uri.tryParse(p.url)?.queryParameters ?? const {};
    for (final k in ['username', 'user', 'password', 'pass', 'token', 'key']) {
      add(q[k]);
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

  static Future<({List<Category> categories, List<Channel> channels, DateTime saved})?>
      loadLive(Portal p) async {
    final raw = await _read('live', p);
    if (raw == null) return null;
    return compute(_decodeLive, raw);
  }

  static Future<void> saveLive(
          Portal p, List<Category> cats, List<Channel> chans) =>
      _write('live', p, {
        'cats': [for (final c in cats) [c.id, c.name]],
        'ch': [
          for (final c in chans)
            [c.id, c.name, c.logoUrl, c.categoryId, c.streamUrl, c.epgId,
             c.catchupDays, c.number, c.catchupMode, c.catchupSource]
        ],
      });

  static Future<({List<Category> categories, List<VodItem> items, DateTime saved})?>
      loadVod(String kind, Portal p) async {
    final raw = await _read(kind, p);
    if (raw == null) return null;
    return compute(_decodeVod, raw);
  }

  static Future<void> saveVod(
          String kind, Portal p, List<Category> cats, List<VodItem> items) =>
      _write(kind, p, {
        'cats': [for (final c in cats) [c.id, c.name]],
        'items': [
          for (final m in items)
            [m.id, m.name, m.posterUrl, m.backdropUrl, m.categoryId, m.streamUrl,
             m.rating, m.year, m.plot, m.genre, m.added?.millisecondsSinceEpoch,
             m.isSeries ? 1 : 0, m.duration?.inSeconds]
        ],
      });

  static Future<void> clear(Portal p) async {
    for (final k in ['live', 'movies', 'series']) {
      await deleteCacheFile(_file(k, p.id));
    }
  }

  /// Nur für Tests: Maskieren/Wiederherstellen ohne Datei.
  static String debugMask(String json, Portal p) => _mask((json, _secrets(p)));
  static String? debugRestore(String raw, Portal p) {
    final secrets = _secrets(p);
    return _restore((raw, secrets, _fingerprint(secrets)));
  }

  static String fingerprintFor(Portal p) => _fingerprint(_secrets(p));

  // ---------- intern ----------
  static Future<String?> _read(String kind, Portal p) async {
    try {
      final raw = await readCacheFile(_file(kind, p.id));
      if (raw == null) return null;
      final secrets = _secrets(p);
      return await compute(_restore, (raw, secrets, _fingerprint(secrets)));
    } catch (_) {
      return null;
    }
  }

  static Future<void> _write(
      String kind, Portal p, Map<String, Object?> body) async {
    try {
      final secrets = _secrets(p);
      final raw = await compute(_mask, (
        jsonEncode({
          'v': 1,
          'saved': DateTime.now().millisecondsSinceEpoch,
          'fp': _fingerprint(secrets),
          ...body
        }),
        secrets
      ));
      await writeCacheFile(_file(kind, p.id), raw);
    } catch (_) {
      // Zwischenspeicher ist optional.
    }
  }

  static String _mask((String, List<String>) job) {
    var s = job.$1;
    for (var i = 0; i < job.$2.length; i++) {
      s = s.replaceAll(job.$2[i], '\u0000S$i\u0000');
    }
    return s;
  }

  /// Platzhalter zurück → null, wenn sich die Zugangsdaten geändert haben.
  static String? _restore((String, List<String>, String) job) {
    final (raw, secrets, fp) = job;
    final fpAt = raw.indexOf('"fp":"');
    if (fpAt < 0 || raw.substring(fpAt + 6, fpAt + 6 + 64) != fp) return null;
    var s = raw;
    for (var i = 0; i < secrets.length; i++) {
      s = s.replaceAll('\u0000S$i\u0000', secrets[i]);
    }
    return s;
  }

  static ({List<Category> categories, List<Channel> channels, DateTime saved})?
      _decodeLive(String? raw) {
    if (raw == null) return null;
    final j = jsonDecode(raw) as Map<String, dynamic>;
    return (
      saved: DateTime.fromMillisecondsSinceEpoch(j['saved'] as int),
      categories: [
        for (final c in (j['cats'] as List).cast<List>())
          Category(id: c[0] as String, name: c[1] as String)
      ],
      channels: [
        for (final c in (j['ch'] as List).cast<List>())
          Channel(
            id: c[0] as String,
            name: c[1] as String,
            logoUrl: c[2] as String?,
            categoryId: c[3] as String,
            streamUrl: c[4] as String,
            epgId: c[5] as String?,
            catchupDays: c[6] as int,
            number: c[7] as int,
            catchupMode: c[8] as String?,
            catchupSource: c[9] as String?,
          )
      ],
    );
  }

  static ({List<Category> categories, List<VodItem> items, DateTime saved})?
      _decodeVod(String? raw) {
    if (raw == null) return null;
    final j = jsonDecode(raw) as Map<String, dynamic>;
    return (
      saved: DateTime.fromMillisecondsSinceEpoch(j['saved'] as int),
      categories: [
        for (final c in (j['cats'] as List).cast<List>())
          Category(id: c[0] as String, name: c[1] as String)
      ],
      items: [
        for (final m in (j['items'] as List).cast<List>())
          VodItem(
            id: m[0] as String,
            name: m[1] as String,
            posterUrl: m[2] as String?,
            backdropUrl: m[3] as String?,
            categoryId: m[4] as String,
            streamUrl: m[5] as String,
            rating: (m[6] as num?)?.toDouble(),
            year: m[7] as int?,
            plot: m[8] as String?,
            genre: m[9] as String?,
            added: m[10] == null
                ? null
                : DateTime.fromMillisecondsSinceEpoch(m[10] as int),
            isSeries: m[11] == 1,
            duration: m[12] == null ? null : Duration(seconds: m[12] as int),
          )
      ],
    );
  }
}
