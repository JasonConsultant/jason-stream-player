import 'dart:typed_data';

// Web-Vorschau: kein Dateisystem → kein Zwischenspeicher.
String? cacheDirOverride;
Future<String?> cacheFilePath(String name) async => null;
Future<String?> readCacheFile(String name) async => null;
Future<void> writeCacheFile(String name, String content) async {}
Future<void> deleteCacheFile(String name) async {}
Future<Uint8List?> readCacheBytes(String name) async => null;
Future<void> writeCacheBytes(String name, Uint8List bytes) async {}
void writeFileAtomicSync(String path, Object content) {}
String? readFileSync(String path) => null;
Uint8List? readBytesSync(String path) => null;
void deleteFileSync(String path) {}
Future<bool> cacheFileExists(String name) async => false;
