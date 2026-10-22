import 'dart:typed_data';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Nur für Tests: Verzeichnis statt path_provider.
String? cacheDirOverride;

Future<String> _dir() async =>
    cacheDirOverride ?? (await getApplicationSupportDirectory()).path;

Future<File> _file(String name) async => File('${await _dir()}/$name');

/// Vollständiger Pfad einer Zwischenspeicher-Datei – damit ein
/// Hintergrund-Isolate (ohne Plattform-Kanäle) direkt schreiben kann.
/// null = kein Dateisystem verfügbar.
Future<String?> cacheFilePath(String name) async {
  try {
    return '${await _dir()}/$name';
  } catch (_) {
    return null;
  }
}

Future<String?> readCacheFile(String name) async {
  final f = await _file(name);
  return await f.exists() ? f.readAsString() : null;
}

Future<void> writeCacheFile(String name, String content) async {
  final f = await _file(name);
  final tmp = File('${f.path}.tmp');
  await tmp.writeAsString(content, flush: true);
  await tmp.rename(f.path); // atomar: nie eine halb geschriebene Datei
}

Future<void> deleteCacheFile(String name) async {
  final f = await _file(name);
  if (await f.exists()) await f.delete();
}

Future<Uint8List?> readCacheBytes(String name) async {
  final f = await _file(name);
  return await f.exists() ? f.readAsBytes() : null;
}

Future<void> writeCacheBytes(String name, Uint8List bytes) async {
  final f = await _file(name);
  final tmp = File('${f.path}.tmp');
  await tmp.writeAsBytes(bytes, flush: true);
  await tmp.rename(f.path);
}

/// Synchron und atomar schreiben (für Hintergrund-Isolates, [path] aus
/// [cacheFilePath]). Text wird als UTF-8 gespeichert.
void writeFileAtomicSync(String path, Object content) {
  final tmp = File('$path.tmp');
  if (content is String) {
    tmp.writeAsStringSync(content, flush: true);
  } else {
    tmp.writeAsBytesSync(content as List<int>, flush: true);
  }
  tmp.renameSync(path);
}

/// Synchron lesen (Hintergrund-Isolate). null = nicht vorhanden.
String? readFileSync(String path) {
  final f = File(path);
  if (!f.existsSync()) return null;
  return f.readAsStringSync();
}

Uint8List? readBytesSync(String path) {
  final f = File(path);
  if (!f.existsSync()) return null;
  return f.readAsBytesSync();
}

void deleteFileSync(String path) {
  try {
    final f = File(path);
    if (f.existsSync()) f.deleteSync();
  } catch (_) {}
}

Future<bool> cacheFileExists(String name) async {
  try {
    return await (await _file(name)).exists();
  } catch (_) {
    return false;
  }
}
