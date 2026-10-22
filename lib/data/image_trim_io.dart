import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Ordner `<temp>/<key>` (wie flutter_cache_manager) auf [maxBytes] kürzen,
/// älteste Dateien zuerst. Liefert die Zahl gelöschter Dateien.
Future<int> trimCacheDir(String key, int maxBytes, {String? baseDir}) async {
  final base = baseDir ?? (await getTemporaryDirectory()).path;
  final dir = Directory('$base/$key');
  if (!await dir.exists()) return 0;
  final files = <(File, int, DateTime)>[];
  var total = 0;
  await for (final e in dir.list(recursive: true, followLinks: false)) {
    if (e is! File) continue;
    final st = await e.stat();
    files.add((e, st.size, st.modified));
    total += st.size;
  }
  if (total <= maxBytes) return 0;
  files.sort((a, b) => a.$3.compareTo(b.$3));
  var removed = 0;
  for (final f in files) {
    if (total <= maxBytes) break;
    try {
      await f.$1.delete();
      total -= f.$2;
      removed++;
    } catch (_) {}
  }
  return removed;
}
