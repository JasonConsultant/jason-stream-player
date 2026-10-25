import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:jason_stream_player/core/subtitle_style.dart';
import 'package:jason_stream_player/player/engine.dart';

/// Fake-Engine für Tests: merkt sich Aufrufe, liefert Zustand über Streams,
/// zeichnet eine farbige Fläche statt Video.
class FakeEngine implements PlaybackEngine {
  final calls = <String>[];
  final options = <String, String>{};
  bool disposed = false;
  bool videoEnabled = true;
  EngineState _state = const EngineState();

  final _playing = StreamController<bool>.broadcast();
  final _buffering = StreamController<bool>.broadcast();
  final _completed = StreamController<bool>.broadcast();
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _width = StreamController<int?>.broadcast();
  final _tracks = StreamController<EngineTracks>.broadcast();
  final _track = StreamController<EngineSelection>.broadcast();
  final _error = StreamController<String>.broadcast();
  final _failure = StreamController<EngineError>.broadcast();

  /// Kennung wie die echte Engine („exo“/„mpv“ aus [EngineConfig.engine]).
  @override
  final String id;

  /// Konfiguration, mit der die Engine angelegt wurde.
  final EngineConfig config;
  FakeEngine({this.id = 'fake', this.config = const EngineConfig()});

  /// Zuletzt beim Öffnen übergebene Untertitel.
  List<EngineSubtitle> lastSubtitles = const [];

  late final EngineStreams _streams = EngineStreams(
    playing: _playing.stream,
    buffering: _buffering.stream,
    completed: _completed.stream,
    position: _position.stream,
    duration: _duration.stream,
    width: _width.stream,
    tracks: _tracks.stream,
    track: _track.stream,
    error: _error.stream,
    failure: _failure.stream,
  );

  /// Angelegte Engines (Reihenfolge) – für `playbackEngineProvider`.
  static final created = <FakeEngine>[];
  static Future<PlaybackEngine> factory(EngineConfig c) async {
    final e = FakeEngine(id: c.engine, config: c);
    created.add(e);
    return e;
  }

  /// Zustand von außen setzen (als käme er vom Player).
  void emit({
    bool? playing,
    bool? buffering,
    bool? completed,
    Duration? position,
    Duration? duration,
    int? width,
    EngineTracks? tracks,
  }) {
    _state = _state.copyWith(
        playing: playing,
        buffering: buffering,
        completed: completed,
        position: position,
        duration: duration,
        width: width,
        height: width == null ? null : (width * 9 ~/ 16),
        tracks: tracks);
    if (playing != null) _playing.add(playing);
    if (buffering != null) _buffering.add(buffering);
    if (completed != null) _completed.add(completed);
    if (position != null) _position.add(position);
    if (duration != null) _duration.add(duration);
    if (width != null) _width.add(width);
    if (tracks != null) _tracks.add(tracks);
  }

  void fail(String message) => _error.add(message);

  /// Eingeordneter Fehler (wie ExoEngine: erst [EngineError], dann Text).
  void failWith(EngineErrorKind kind, String message) {
    _failure.add(EngineError(kind, message));
    _error.add(message);
  }
  @override
  EngineState get state => _state;
  @override
  EngineStreams get stream => _streams;

  @override
  Future<void> open(String url,
      {Map<String, String> headers = const {},
      bool play = true,
      bool live = false,
      List<EngineSubtitle> subtitles = const []}) async {
    calls.add('open $url');
    lastSubtitles = subtitles;
    emit(playing: play, buffering: true, completed: false, position: Duration.zero);
  }

  @override
  Future<void> play() async {
    calls.add('play');
    emit(playing: true);
  }

  @override
  Future<void> pause() async {
    calls.add('pause');
    emit(playing: false);
  }

  @override
  Future<void> playOrPause() => _state.playing ? pause() : play();

  @override
  Future<void> stop() async {
    calls.add('stop');
    emit(playing: false);
  }

  @override
  Future<void> seek(Duration position) async {
    calls.add('seek ${position.inSeconds}');
    emit(position: position);
  }

  @override
  Future<void> setVolume(double volume) async => calls.add('volume $volume');

  @override
  Future<void> setAudioTrack(EngineTrack track) async {
    calls.add('audio ${track.id}');
    _state = _state.copyWith(
        track: EngineSelection(audio: track, subtitle: _state.track.subtitle));
    _track.add(_state.track);
  }

  @override
  Future<void> setSubtitleTrack(EngineTrack track) async {
    calls.add('subtitle ${track.id}');
    _state = _state.copyWith(
        track: EngineSelection(audio: _state.track.audio, subtitle: track));
    _track.add(_state.track);
  }

  @override
  Future<void> setVideoEnabled(bool enabled) async {
    calls.add('video ${enabled ? 'on' : 'off'}');
    videoEnabled = enabled;
  }

  @override
  bool get supportsOptions => true;

  @override
  Future<void> setOption(String name, String value) async {
    calls.add('set $name=$value');
    options[name] = value;
  }

  @override
  Future<String?> getOption(String name) async => options[name];

  @override
  Future<void> command(List<String> args) async =>
      calls.add('cmd ${args.join(' ')}');

  @override
  bool get hasVideoSurface => true;

  @override
  Widget? buildVideo(
          {required BoxFit fit,
          double? aspectRatio,
          SubtitleStyle subtitleStyle = const SubtitleStyle()}) =>
      Container(
          key: const ValueKey('fake-video'),
          color: const Color(0xFF1B3A5C));

  @override
  Future<void> dispose() async {
    calls.add('dispose');
    disposed = true;
    for (final c in [
      _playing,
      _buffering,
      _completed,
      _position,
      _duration,
      _width,
      _tracks,
      _track,
      _error,
      _failure
    ]) {
      await c.close();
    }
  }
}
