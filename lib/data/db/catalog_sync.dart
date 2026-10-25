/// Synchrone Katalog-Aufrufe für Hintergrund-Isolates (siehe catalog_sync_io.dart).
library;

export 'catalog_sync_stub.dart' if (dart.library.io) 'catalog_sync_io.dart';
