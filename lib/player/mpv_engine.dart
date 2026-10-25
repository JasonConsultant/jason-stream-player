import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../core/subtitle_style.dart';
import '../ui/player/subtitle_view.dart';
import 'engine.dart';

/// mpv-Engine (media_kit). Kapselt [Player] und [VideoController]; alles
/// mpv-Spezifische (Eigenschaften, Befehle) läuft über [setOption],
/// [getOption] und [command].
class MpvEngine implements PlaybackEngine {
  final Player player;
  final VideoController? controller;
  late final EngineStreams _streams;

  MpvEngine._(this.player, this.controller) {
    final s = player.stream;
    _streams = EngineStreams(
      playing: s.playing,
      buffering: s.buffering,
      completed: s.completed,
      position: s.position,
      duration: s.duration,
      width: s.width,
      tracks: s.tracks.map(_tracks),
      track: s.track.map(_selection),
      error: s.error,
    );
  }

  /// Legt Player und Videofläche an.
  static Future<PlaybackEngine> create(EngineConfig c) async {
    final p = Player(
        configuration: PlayerConfiguration(bufferSize: c.bufferBytes));
    final v = VideoController(
      p,
      configuration: VideoControllerConfiguration(
        vo: c.vo,
        hwdec: c.hwdec,
        enableHardwareAcceleration: c.hardwareAcceleration,
      ),
    );
    return MpvEngine._(p, v);
  }

  /// Für Tests mit eigenem [Player] (ohne Videofläche).
  @visibleForTesting
  MpvEngine.wrap(this.player) : controller = null {
    final s = player.stream;
    _streams = EngineStreams(
      playing: s.playing,
      buffering: s.buffering,
      completed: s.completed,
      position: s.position,
      duration: s.duration,
      width: s.width,
      tracks: s.tracks.map(_tracks),
      track: s.track.map(_selection),
      error: s.error,
    );
  }

  static EngineTrack _a(AudioTrack t) =>
      EngineTrack(t.id, title: t.title, language: t.language);
  static EngineTrack _s(SubtitleTrack t) =>
      EngineTrack(t.id, title: t.title, language: t.language);

  static EngineTracks _tracks(Tracks t) => EngineTracks(
        audio: [for (final a in t.audio) _a(a)],
        subtitle: [for (final x in t.subtitle) _s(x)],
      );

  static EngineSelection _selection(Track t) =>
      EngineSelection(audio: _a(t.audio), subtitle: _s(t.subtitle));

  NativePlayer? get _native {
    final pl = player.platform;
    return pl is NativePlayer ? pl : null;
  }

  @override
  String get id => 'mpv';

  @override
  EngineState get state {
    final s = player.state;
    return EngineState(
      playing: s.playing,
      buffering: s.buffering,
      completed: s.completed,
      position: s.position,
      duration: s.duration,
      width: s.width,
      height: s.height,
      tracks: _tracks(s.tracks),
      track: _selection(s.track),
    );
  }

  @override
  EngineStreams get stream => _streams;

  @override
  Future<void> open(String url,
          {Map<String, String> headers = const {}, bool play = true}) =>
      player.open(Media(url, httpHeaders: headers), play: play);

  @override
  Future<void> play() => player.play();
  @override
  Future<void> pause() => player.pause();
  @override
  Future<void> playOrPause() => player.playOrPause();
  @override
  Future<void> stop() => player.stop();
  @override
  Future<void> seek(Duration position) => player.seek(position);
  @override
  Future<void> setVolume(double volume) => player.setVolume(volume);

  @override
  Future<void> setAudioTrack(EngineTrack t) {
    if (t.isAuto) return player.setAudioTrack(AudioTrack.auto());
    if (t.isOff) return player.setAudioTrack(AudioTrack.no());
    final found = player.state.tracks.audio.where((a) => a.id == t.id);
    return player.setAudioTrack(found.isEmpty
        ? AudioTrack(t.id, t.title, t.language)
        : found.first);
  }

  @override
  Future<void> setSubtitleTrack(EngineTrack t) {
    if (t.isAuto) return player.setSubtitleTrack(SubtitleTrack.auto());
    if (t.isOff) return player.setSubtitleTrack(SubtitleTrack.no());
    final found = player.state.tracks.subtitle.where((a) => a.id == t.id);
    return player.setSubtitleTrack(found.isEmpty
        ? SubtitleTrack(t.id, t.title, t.language)
        : found.first);
  }

  @override
  Future<void> setVideoEnabled(bool enabled) =>
      player.setVideoTrack(enabled ? VideoTrack.auto() : VideoTrack.no());

  @override
  bool get supportsOptions => _native != null;

  @override
  Future<void> setOption(String name, String value) async {
    final n = _native;
    if (n == null) return;
    await n.setProperty(name, value);
  }

  @override
  Future<String?> getOption(String name) async {
    final n = _native;
    if (n == null) return null;
    try {
      return await n.getProperty(name);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> command(List<String> args) async {
    final n = _native;
    if (n == null) return;
    await n.command(args);
  }

  @override
  bool get hasVideoSurface => controller != null;

  @override
  Widget? buildVideo({
    required BoxFit fit,
    double? aspectRatio,
    SubtitleStyle subtitleStyle = const SubtitleStyle(),
  }) {
    final c = controller;
    if (c == null) return null;
    return Video(
      controller: c,
      controls: NoVideoControls,
      fit: fit,
      aspectRatio: aspectRatio,
      // Untertitel zeichnet Flutter – Aussehen hier setzen.
      subtitleViewConfiguration: subtitleViewConfig(subtitleStyle),
    );
  }

  @override
  Future<void> dispose() => player.dispose();
}
