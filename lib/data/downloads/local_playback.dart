import '../../models/models.dart';
import '../smb/smb.dart';
import 'download_models.dart';

/// Offline-Wiedergabe eines Downloads über den normalen Player: liefert
/// die lokale Datei (und mitgeladene Untertitel) und meldet nichts an
/// einen Server. Die Position merkt sich der Player wie online
/// ([DownloadItem.resumeKey]).
class LocalPlayback implements RemotePlayback {
  final DownloadItem item;
  const LocalPlayback(this.item);

  /// Pfad bzw. content:// → Adresse für die Engines.
  static String uriOf(String path) =>
      path.startsWith('content://') || path.startsWith('smb://')
          ? path
          : Uri.file(path).toString();

  @override
  Future<RemoteMedia> resolve({bool transcode = false}) async {
    final p = item.path;
    if (p == null) throw StateError('no file');
    return RemoteMedia(
      url: await resolvePath(p),
      local: true,
      subtitles: [
        for (final s in item.subs)
          if (s.path != null)
            RemoteSubtitle(await resolvePath(s.path!),
                language: s.language, title: s.title),
      ],
    );
  }

  /// Netzlaufwerk-Dateien (smb://…) laufen über den lokalen Proxy des
  /// Plugins (127.0.0.1, Spulen per Range) – mpv und ExoPlayer gleich.
  static Future<String> resolvePath(String p) async {
    if (!p.startsWith('smb://')) return uriOf(p);
    final c = Smb.current;
    final rel = c?.relOf(p);
    if (c == null || rel == null) throw const SmbException('path');
    return Smb.serve(c, rel);
  }

  @override
  Future<void> started(Duration position) async {}
  @override
  Future<void> progress(Duration position, {required bool paused}) async {}
  @override
  Future<void> stopped(Duration position) async {}
}
