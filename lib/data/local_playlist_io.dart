import 'dart:io';
import 'dart:typed_data';

/// Lokale Playlist (vom Gerät importiert) lesen – nur aus dem App-Ordner.
Future<Uint8List> readLocalPlaylist(String fileUrl) async {
  final path = Uri.parse(fileUrl).toFilePath();
  if (!path.contains('/playlists/') || path.contains('..')) {
    throw const FileSystemException('Ungültiger Pfad');
  }
  return File(path).readAsBytes();
}
