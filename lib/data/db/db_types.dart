import '../../models/models.dart';

/// Gemeinsame Typen der Katalog-Datenbank (ohne SQLite-Abhängigkeit, damit
/// auch die Web-Variante übersetzt).

/// Aktuelle Schema-Version der Katalog-Datenbank.
const catalogSchemaVersion = 2;

/// Gelesene Liste (Kategorien + Einträge) mit Stand und Prüfsumme.
class DbList<T> {
  final List<Category> categories;
  final List<T> items;
  final DateTime saved;
  final String? hash;
  const DbList(this.categories, this.items, this.saved, this.hash);
}

/// Stand des gespeicherten EPG eines Portals.
class EpgDbInfo {
  final int gen;
  final DateTime saved;
  final String? hash;

  /// Früheste/späteste Sendung (Sekunden seit 1970), null = leer.
  final int? lo, hi;
  final int count;

  /// Sender mit Programm.
  final int channels;
  const EpgDbInfo(this.gen, this.saved, this.hash, this.lo, this.hi, this.count,
      [this.channels = 0]);

  DateTime? get first =>
      lo == null ? null : DateTime.fromMillisecondsSinceEpoch(lo! * 1000);
  DateTime? get last =>
      hi == null ? null : DateTime.fromMillisecondsSinceEpoch(hi! * 1000);
}

/// Treffer der EPG-Suche: EPG-Schlüssel des Senders + Sendung.
typedef EpgHit = ({String key, EpgEntry entry});
