/// Katalog-Datenbank: SQLite auf Geräten mit Dateisystem, sonst (Web)
/// ein Platzhalter ohne Datenbank.
library;

export 'catalog_stub.dart' if (dart.library.io) 'catalog_io.dart';
