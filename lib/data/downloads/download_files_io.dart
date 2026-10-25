
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'download_transfer.dart';

/// Nur für Tests: anderer Basisordner.
String? downloadsDirOverride;

/// Ordner für Downloads: `Android/data/<app>/files/Downloads` – mit
/// `.nomedia`, damit Filme nicht in der Galerie auftauchen. Wird bei der
/// Deinstallation entfernt.
Future<String> downloadsDir() async {
  final String base;
  if (downloadsDirOverride != null) {
    base = downloadsDirOverride!;
  } else {
    base = (await getExternalStorageDirectory() ??
            await getApplicationDocumentsDirectory())
        .path;
  }
  final dir = Directory('$base/Downloads');
  if (!await dir.exists()) await dir.create(recursive: true);
  final nomedia = File('${dir.path}/.nomedia');
  if (!await nomedia.exists()) {
    try {
      await nomedia.create();
    } catch (_) {}
  }
  return dir.path;
}

/// Liegt [path] im eigenen Download-Ordner?
Future<bool> isInDownloadsDir(String path) async {
  final dir = await downloadsDir();
  final abs = File(path).absolute.path;
  return abs.startsWith('$dir/') && !abs.contains('/../');
}

Future<bool> localFileExists(String path) => File(path).exists();

Future<void> deleteLocalFile(String path) async {
  if (!await isInDownloadsDir(path)) return;
  final f = File(path);
  if (await f.exists()) await f.delete();
}

/// Gespeicherte Download-Liste (ohne Zugangsdaten, siehe UrlVault).
Future<String?> readDownloadList() async {
  try {
    final f = File('${await _stateDir()}/downloads.json');
    if (!await f.exists()) return null;
    return await f.readAsString();
  } catch (_) {
    return null;
  }
}

Future<void> writeDownloadList(String json) async {
  final dir = await _stateDir();
  final tmp = File('$dir/downloads.json.tmp');
  await tmp.writeAsString(json, flush: true);
  await tmp.rename('$dir/downloads.json');
}

Future<String> _stateDir() async {
  if (downloadsDirOverride != null) return downloadsDirOverride!;
  return (await getApplicationSupportDirectory()).path;
}

/// Datei im App-Ordner, anhängend oder neu.
class FileSink implements DownloadSink {
  final String path;
  RandomAccessFile? _raf;
  FileSink(this.path);

  @override
  Future<int> length() async {
    final f = File(path);
    return await f.exists() ? await f.length() : 0;
  }

  @override
  Future<void> open({required bool append}) async {
    final f = File(path);
    await f.parent.create(recursive: true);
    _raf = await f.open(mode: append ? FileMode.append : FileMode.write);
  }

  @override
  Future<void> write(Uint8List data) async {
    await _raf!.writeFrom(data);
  }

  @override
  Future<void> close() async {
    final r = _raf;
    _raf = null;
    if (r != null) {
      await r.flush();
      await r.close();
    }
  }

  @override
  Future<void> delete() async {
    final f = File(path);
    if (await f.exists()) await f.delete();
  }
}

