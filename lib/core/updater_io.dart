import 'dart:io';
import 'dart:typed_data';

Future<void> writeUpdateFile(String path, Uint8List bytes) async {
  final f = File(path);
  if (await f.exists()) await f.delete();
  await f.writeAsBytes(bytes, flush: true);
}
