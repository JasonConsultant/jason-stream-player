/// Media3 ExoPlayer (nur Android) über Plattformkanäle: ein Player je
/// [JspExoPlayer], Videobild als Flutter-Textur ([textureId]).
library;

import 'dart:async';

import 'package:flutter/services.dart';

/// Kanalnamen (auch für Tests mit gemocktem Kanal).
abstract final class JspExoChannels {
  static const method = MethodChannel('de.jasonstream/exoplayer');
  static String events(int id) => 'de.jasonstream/exoplayer/events/$id';
}

/// Externer Untertitel, der beim Öffnen mitgeladen wird.
class JspExoSubtitle {
  final String url;
  final String? language;
  final String? label;
  final String? codec;
  const JspExoSubtitle(this.url, {this.language, this.label, this.codec});

  Map<String, Object?> toMap() =>
      {'url': url, 'language': language, 'label': label, 'codec': codec};
}

/// Aufbau-Einstellungen; eine Änderung baut den Player neu (die Textur bleibt).
class JspExoBuild {
  /// Vorpuffer in Byte (Einstellung Puffer).
  final int bufferBytes;

  /// Live-Pause: Rückpuffer/Vorpuffer in Byte (0 = aus).
  final int backBytes;
  final int forwardBytes;

  /// Software-Videodekoder zuerst (mpv hwdec=no).
  final bool softwareVideo;

  /// Dolby/DTS an den Receiver durchreichen.
  final bool passthrough;

  /// Datensparmodus: höchste Video-Bitrate (bit/s) bzw. Bildhöhe der
  /// HLS/DASH-Stufe; 0 = offen. Gilt je Quelle (kein Neuaufbau).
  final int maxVideoBitrate;
  final int maxVideoHeight;
  const JspExoBuild({
    this.bufferBytes = 48 << 20,
    this.backBytes = 0,
    this.forwardBytes = 0,
    this.softwareVideo = false,
    this.passthrough = false,
    this.maxVideoBitrate = 0,
    this.maxVideoHeight = 0,
  });

  Map<String, Object?> toMap() => {
        'bufferBytes': bufferBytes,
        'backBytes': backBytes,
        'forwardBytes': forwardBytes,
        'softwareVideo': softwareVideo,
        'passthrough': passthrough,
        'maxVideoBitrate': maxVideoBitrate,
        'maxVideoHeight': maxVideoHeight,
      };
}

/// Ein nativer Player. Ereignisse kommen als Maps mit Schlüssel `e`
/// (state, pos, tracks, size, cues, error, fps, firstFrame).
class JspExoPlayer {
  final int id;
  final int textureId;
  final Stream<Map<Object?, Object?>> events;
  bool _disposed = false;

  JspExoPlayer._(this.id, this.textureId)
      : events = EventChannel(JspExoChannels.events(id))
            .receiveBroadcastStream()
            .where((e) => e is Map)
            .cast<Map<Object?, Object?>>()
            .asBroadcastStream();

  static const _m = JspExoChannels.method;

  static Future<JspExoPlayer> create() async {
    final r = await _m.invokeMapMethod<String, Object?>('create');
    if (r == null) throw PlatformException(code: 'exo', message: 'create');
    return JspExoPlayer._((r['id'] as num).toInt(), (r['textureId'] as num).toInt());
  }

  Future<void> _call(String method, [Map<String, Object?> args = const {}]) async {
    if (_disposed) return;
    await _m.invokeMethod<void>(method, {'id': id, ...args});
  }

  Future<void> open(
    String url, {
    Map<String, String> headers = const {},
    bool live = false,
    bool play = true,
    Duration start = Duration.zero,
    List<JspExoSubtitle> subtitles = const [],
    JspExoBuild build = const JspExoBuild(),
  }) =>
      _call('open', {
        'url': url,
        'headers': headers,
        'live': live,
        'play': play,
        'startMs': start.inMilliseconds,
        'subtitles': [for (final s in subtitles) s.toMap()],
        ...build.toMap(),
      });

  Future<void> play() => _call('play');
  Future<void> pause() => _call('pause');
  Future<void> stop() => _call('stop');
  Future<void> seek(Duration d) => _call('seek', {'ms': d.inMilliseconds});

  /// 0 … 1.
  Future<void> setVolume(double v) => _call('setVolume', {'volume': v});
  Future<void> setVideoEnabled(bool on) =>
      _call('setVideoEnabled', {'enabled': on});

  /// [type]: audio | text | video; [track]: auto | no | Kennung aus `tracks`.
  Future<void> selectTrack(String type, String track) =>
      _call('selectTrack', {'type': type, 'track': track});

  /// Statistik (Decoder, Auflösung, fps, verworfene Bilder, Puffer …).
  Future<Map<String, Object?>> stats() async {
    if (_disposed) return const {};
    final r = await _m.invokeMapMethod<String, Object?>('stats', {'id': id});
    return r ?? const {};
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _m.invokeMethod<void>('dispose', {'id': id});
  }
}
