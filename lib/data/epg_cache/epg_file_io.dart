import 'dart:typed_data';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

Future<File> _file(String name) async {
  final dir = await getApplicationSupportDirectory();
  return File('${dir.path}/$name');
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
