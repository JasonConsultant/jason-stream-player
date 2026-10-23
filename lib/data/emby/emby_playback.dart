import 'dart:async';

import '../../models/models.dart';
import 'emby_client.dart';
import 'emby_mapper.dart';

/// Wiedergabe eines Emby-Titels: holt beim Öffnen die Medienquelle
/// (PlaybackInfo), wählt Direktwiedergabe oder Umwandlung und meldet
/// Start/Fortschritt/Ende an den Server – im Gastmodus nichts.
class EmbyPlayback implements RemotePlayback {
  /// App-ID (`emby_…`) oder Server-ID.
  final String itemId;
  final Future<EmbyClient?> Function() client;

  /// Max. Streaming-Bitrate (null = automatisch), beim Öffnen gelesen.
  final int? Function() maxBitrate;

  /// Bevorzugte Tonspur ('auto', 'de', …).
  final String Function() audioPref;

  /// false = Gastmodus: nichts an den Server melden.
  final bool Function() reportAllowed;

  /// Stand des Servers beim Öffnen der Liste/Details.
  final Duration? serverPosition;

  /// Nach dem Ende (z. B. „Weiterschauen“ neu laden).
  final void Function()? onStopped;

  EmbyPlayback({
    required this.itemId,
    required this.client,
    required this.maxBitrate,
    required this.audioPref,
    required this.reportAllowed,
    this.serverPosition,
    this.onStopped,
  });

  EmbyClient? _c;
  EmbyStreamChoice? _choice;
  bool _started = false;

  /// Zuletzt gewählter Weg (Tests/Anzeige).
  EmbyStreamChoice? get choice => _choice;

  String get _raw => embyRaw(itemId);

  @override
  Future<RemoteMedia> resolve({bool transcode = false}) async {
    final c = _c = await client();
    if (c == null) {
      throw const EmbyException(EmbyErrorKind.wrongCredentials);
    }
    final rate = maxBitrate();
    final info = await c.playbackInfo(_raw, maxBitrate: rate);
    final ch = _choice = chooseEmbyStream(c, _raw, info,
        maxBitrate: rate, forceTranscode: transcode, audioPref: audioPref());
    return RemoteMedia(
      url: ch.url,
      transcoding: ch.transcoding,
      startAt: serverPosition,
      subtitles: ch.subtitles,
    );
  }

  Future<void> _safe(Future<void> Function(EmbyClient c, EmbyStreamChoice ch) f) async {
    final c = _c, ch = _choice;
    if (c == null || ch == null || !reportAllowed()) return;
    try {
      await f(c, ch);
    } catch (_) {
      // Fortschritt melden ist Nebensache – Wiedergabe nie stören.
    }
  }

  @override
  Future<void> started(Duration position) {
    _started = true;
    return _safe((c, ch) => c.reportStart(
        itemId: _raw,
        position: position,
        mediaSourceId: ch.mediaSourceId,
        playSessionId: ch.playSessionId,
        playMethod: ch.playMethod));
  }

  @override
  Future<void> progress(Duration position, {required bool paused}) {
    if (!_started) return Future.value();
    return _safe((c, ch) => c.reportProgress(
        itemId: _raw,
        position: position,
        paused: paused,
        mediaSourceId: ch.mediaSourceId,
        playSessionId: ch.playSessionId,
        playMethod: ch.playMethod));
  }

  @override
  Future<void> stopped(Duration position) async {
    if (!_started) return;
    _started = false;
    await _safe((c, ch) => c.reportStopped(
        itemId: _raw,
        position: position,
        mediaSourceId: ch.mediaSourceId,
        playSessionId: ch.playSessionId));
    onStopped?.call();
  }
}
