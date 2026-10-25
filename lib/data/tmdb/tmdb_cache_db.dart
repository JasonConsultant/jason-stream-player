import '../db/catalog.dart';
import 'tmdb.dart';

/// TMDB-Antworten in der Katalog-Datenbank (Tabelle `meta_cache`, ab
/// Schema 2). Ohne Datenbank (Web-Vorschau, Tests ohne Ordner) im Speicher.
class DbTmdbCache implements TmdbCache {
  final _mem = MemoryTmdbCache();

  @override
  Future<String?> get(String key, Duration ttl) async {
    if (!Catalog.supported) return _mem.get(key, ttl);
    final minSaved = DateTime.now().subtract(ttl).millisecondsSinceEpoch;
    final v = await Catalog.kvGet(key, minSaved);
    return v ?? await _mem.get(key, ttl);
  }

  @override
  Future<void> put(String key, String value) async {
    await _mem.put(key, value);
    if (!Catalog.supported) return;
    await Catalog.kvPut(key, value, DateTime.now().millisecondsSinceEpoch);
  }
}
