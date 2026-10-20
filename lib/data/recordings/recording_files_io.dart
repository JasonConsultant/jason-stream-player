import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Ordner für Aufnahmen: `Android/data/<app>/files/Aufnahmen`
/// (per USB/Dateimanager erreichbar, wird bei Deinstallation entfernt).
Future<String> recordingsDir() async {
  final base = await getExternalStorageDirectory() ??
      await getApplicationDocumentsDirectory();
  final dir = Directory('${base.path}/Aufnahmen');
  if (!await dir.exists()) await dir.create(recursive: true);
  return dir.path;
}

Future<List<({String path, int bytes, DateTime modified})>> listRecordings() async {
  final dir = Directory(await recordingsDir());
  final out = <({String path, int bytes, DateTime modified})>[];
  await for (final f in dir.list()) {
    if (f is File && (f.path.endsWith('.ts') || f.path.endsWith('.mkv'))) {
      final st = await f.stat();
      out.add((path: f.path, bytes: st.size, modified: st.modified));
    }
  }
  out.sort((a, b) => b.modified.compareTo(a.modified));
  return out;
}

Future<void> deleteRecording(String path) async {
  final dir = await recordingsDir();
  // Nur Dateien im eigenen Aufnahme-Ordner löschen.
  if (!File(path).absolute.path.startsWith(dir)) return;
  final f = File(path);
  if (await f.exists()) await f.delete();
}

Future<bool> isInRecordingsDir(String path) async =>
    File(path).absolute.path.startsWith(await recordingsDir());
