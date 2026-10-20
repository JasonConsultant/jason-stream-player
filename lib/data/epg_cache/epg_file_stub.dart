import 'dart:typed_data';

// Web-Vorschau: kein Dateisystem → kein Zwischenspeicher.
Future<String?> readCacheFile(String name) async => null;
Future<void> writeCacheFile(String name, String content) async {}
Future<void> deleteCacheFile(String name) async {}
Future<Uint8List?> readCacheBytes(String name) async => null;
Future<void> writeCacheBytes(String name, Uint8List bytes) async {}
