import '../../models/models.dart';
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
      path.startsWith('content://') ? path : Uri.file(path).toString();

  @override
  Future<RemoteMedia> resolve({bool transcode = false}) async {
    final p = item.path;
    if (p == null) throw StateError('no file');
    return RemoteMedia(
      url: uriOf(p),
      local: true,
      subtitles: [
        for (final s in item.subs)
          if (s.path != null)
            RemoteSubtitle(uriOf(s.path!), language: s.language, title: s.title),
      ],
    );
  }

  @override
  Future<void> started(Duration position) async {}
  @override
  Future<void> progress(Duration position, {required bool paused}) async {}
  @override
  Future<void> stopped(Duration position) async {}
}
