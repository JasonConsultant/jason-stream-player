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
class MpvEngine implements PlaybackEngine, EngineHealthSource {
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
      {Map<String, String> headers = const {},
      bool play = true,
      bool live = false,
      List<EngineSubtitle> subtitles = const []}) async {
    await player.open(Media(url, httpHeaders: headers), play: play);
    // Externe Untertitel dazuladen (ohne sie zu wählen – die bevorzugte
    // Sprache wählt der Player).
    for (final s in subtitles) {
      try {
        await command(
            ['sub-add', s.url, 'auto', s.title ?? s.language ?? '', s.language ?? '']);
      } catch (_) {}
    }
  }

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

  // ---------- Wachhunde / Stream-Info ----------
  /// mpv-Eigenschaften für die Wachhunde (etwa 1×/s).
  static const watchProps = [
    'estimated-frame-number',
    'estimated-vf-fps',
    'audio-pts',
    'frame-drop-count',
    'decoder-frame-drop-count',
    'demuxer-cache-duration',
    'vid',
    'aid',
  ];

  /// Zusätzlich für die Stream-Info.
  static const infoProps = [
    'hwdec-current',
    'video-format',
    'audio-codec-name',
    'video-params/w',
    'video-params/h',
    'container-fps',
    'video-bitrate',
    'audio-bitrate',
    'audio-params/channel-count',
    'audio-params/samplerate',
  ];

  @override
  bool get hasDecoderFallback => false;

  @override
  Future<EngineHealth> health({bool full = false}) async {
    if (!supportsOptions) return EngineHealth.unknown;
    final v = <String, String>{};
    for (final k in [...watchProps, if (full) ...infoProps]) {
      final x = await getOption(k);
      if (x != null && x.isNotEmpty) v[k] = x;
    }
    return healthFrom(v, position: player.state.position);
  }

  /// Messwerte aus mpv-Eigenschaften (rein, für Tests).
  @visibleForTesting
  static EngineHealth healthFrom(Map<String, String> v, {Duration? position}) {
    int? i(String k) {
      final x = v[k];
      if (x == null) return null;
      return int.tryParse(x) ?? double.tryParse(x)?.round();
    }

    double? d(String k) => v[k] == null ? null : double.tryParse(v[k]!);
    bool? track(String k) {
      final x = v[k];
      if (x == null) return null;
      return x != 'no' && x != 'false';
    }

    final drop = i('frame-drop-count');
    final dec = i('decoder-frame-drop-count');
    final pts = d('audio-pts');
    final hw = v['hwdec-current'];
    return EngineHealth(
      position: position,
      videoFrames: i('estimated-frame-number'),
      outputFps: d('estimated-vf-fps'),
      audioTicks: pts == null ? null : (pts * 1000).round(),
      droppedFrames: drop == null && dec == null ? null : (drop ?? 0) + (dec ?? 0),
      bufferSeconds: d('demuxer-cache-duration'),
      hasVideoTrack: track('vid'),
      hasAudioTrack: track('aid'),
      hardwareDecoder: hw == null ? null : hw != 'no',
      videoDecoder: hw == null ? null : (hw == 'no' ? 'ffmpeg' : hw),
      videoCodec: v['video-format'],
      audioCodec: v['audio-codec-name'],
      width: i('video-params/w'),
      height: i('video-params/h'),
      fps: d('container-fps'),
      videoBitrate: i('video-bitrate'),
      audioBitrate: i('audio-bitrate'),
      audioChannels: i('audio-params/channel-count'),
      sampleRate: i('audio-params/samplerate'),
    );
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
