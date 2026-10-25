import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:jsp_exoplayer/jsp_exoplayer.dart';

import '../core/subtitle_style.dart';
import '../ui/player/subtitle_view.dart';
import 'engine.dart';

/// Ein Untertitel-Element von Media3 (Text oder Bild, z. B. DVB/PGS).
@immutable
class ExoCue {
  final String? text;
  final Uint8List? png;

  /// Bild: Position/Größe als Anteil der Bildfläche (null = unbekannt).
  final double? x, y, w;

  /// Text: Zeile als Anteil der Höhe (null = unten).
  final double? line;
  const ExoCue({this.text, this.png, this.x, this.y, this.w, this.line});

  static ExoCue? fromMap(Map<Object?, Object?> m) {
    final t = m['text'] as String?;
    final p = m['png'];
    double? d(Object? v) => v is num ? v.toDouble() : null;
    if (t != null && t.trim().isNotEmpty) {
      return ExoCue(text: t, line: d(m['line']));
    }
    if (p is Uint8List && p.isNotEmpty) {
      return ExoCue(png: p, x: d(m['x']), y: d(m['y']), w: d(m['w']));
    }
    return null;
  }
}

/// Media3/ExoPlayer-Engine (Android): Bild über eine Flutter-Textur,
/// Untertitel zeichnet Flutter (Stil und Verzögerung wie bisher).
///
/// mpv-Optionen der Player-Seite werden auf Media3 abgebildet:
/// - user-agent/referrer → HTTP-Kopfzeilen (falls nicht schon gesetzt)
/// - demuxer-max-bytes / -max-back-bytes / -seekable-cache → LoadControl
///   (Vorpuffer, Rückpuffer für die Live-Pause)
/// - hwdec „no“ → Software-Videodekoder zuerst, sonst Gerät (Hardware)
/// - audio-spdif → Dolby/DTS durchreichen (Media3-Audio-Fähigkeiten)
/// - sub-delay → Verzögerung der Flutter-Untertitel (nur positiv, s. u.)
/// - Lesen: hwdec, hwdec-current, current-vo, video-codec, video-params/w|h,
///   container-fps, frame-drop-count, demuxer-cache-duration,
///   demuxer-cache-time, time-pos → aus der Exo-Statistik
/// - sub-*-Stil, analyzeduration/probesize, Netz-Optionen → ignoriert.
///
/// Untertitel-Verzögerung: positiv wird durch Zurückhalten der Cues
/// umgesetzt. Negativ (früher) geht mit Media3 nicht – der TextRenderer
/// liefert Cues erst zu ihrem Zeitpunkt (und ist nicht erweiterbar); die
/// Untertitel erscheinen dann zum Original-Zeitpunkt.
class ExoEngine implements PlaybackEngine, EngineDiagnostics {
  final JspExoPlayer _p;
  final EngineConfig config;
  late final StreamSubscription _sub;

  ExoEngine._(this._p, this.config) {
    _softwareVideo = config.hwdec == 'no' || !config.hardwareAcceleration;
    _sub = _p.events.listen(_onEvent, onError: (Object e) {
      final msg = e is PlatformException ? (e.message ?? e.code) : '$e';
      _fail(EngineError(EngineErrorKind.other, msg));
    });
  }

  /// Legt den nativen Player samt Textur an.
  static Future<PlaybackEngine> create(EngineConfig c) async =>
      ExoEngine._(await JspExoPlayer.create(), c);

  /// Für Tests (gemockter Kanal).
  @visibleForTesting
  static Future<ExoEngine> createForTest(EngineConfig c) async =>
      ExoEngine._(await JspExoPlayer.create(), c);

  // ---------- Zustand ----------
  EngineState _state = const EngineState();
  EngineSelection _selection = const EngineSelection();
  double _par = 1;
  Duration _buffered = Duration.zero;
  double? _fps;
  bool _disposed = false;

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

  /// Untertitel, die gerade zu sehen sind (nach Verzögerung).
  final cues = ValueNotifier<List<ExoCue>>(const []);
  final _pendingCues = <Timer>[];

  /// Seitenverhältnis des Bildes (Breite/Höhe inkl. Pixel-Seitenverhältnis).
  double? get videoAspect {
    final w = _state.width ?? 0, h = _state.height ?? 0;
    if (w <= 0 || h <= 0) return null;
    return w * _par / h;
  }

  @override
  String get id => 'exo';
  @override
  EngineState get state => _state;
  @override
  EngineStreams get stream => _streams;

  int get textureId => _p.textureId;

  // ---------- Abgebildete mpv-Optionen ----------
  final _options = <String, String>{};
  String? _userAgent, _referrer;
  int _forwardBytes = 0, _backBytes = 0;
  bool _seekable = false;
  bool _passthrough = false;
  late bool _softwareVideo;
  double _subDelay = 0;

  /// Nicht abbildbare Optionen (Diagnose/Tests).
  final ignored = <String>{};

  /// Aufbau-Einstellungen für den nächsten [open].
  @visibleForTesting
  JspExoBuild get build => JspExoBuild(
        bufferBytes: config.bufferBytes,
        backBytes: _seekable ? _backBytes : 0,
        forwardBytes: _seekable ? _forwardBytes : 0,
        softwareVideo: _softwareVideo,
        passthrough: _passthrough,
      );

  double get subtitleDelay => _subDelay;

  void _emit<T>(StreamController<T> c, T v) {
    if (!c.isClosed) c.add(v);
  }

  void _set(EngineState s) => _state = s;

  // ---------- Ereignisse ----------
  void _onEvent(Map<Object?, Object?> e) {
    if (_disposed) return;
    switch (e['e']) {
      case 'state':
        final st = e['state'] as String? ?? 'idle';
        final ended = st == 'ended';
        final playing = (e['playing'] as bool? ?? false) && !ended;
        final buffering = st == 'buffering';
        if (playing != _state.playing) {
          _set(_state.copyWith(playing: playing));
          _emit(_playing, playing);
        }
        if (buffering != _state.buffering) {
          _set(_state.copyWith(buffering: buffering));
          _emit(_buffering, buffering);
        }
        if (ended != _state.completed) {
          _set(_state.copyWith(completed: ended));
          _emit(_completed, ended);
        }
      case 'pos':
        final pos = Duration(milliseconds: (e['pos'] as num? ?? 0).toInt());
        final dur = Duration(milliseconds: (e['dur'] as num? ?? 0).toInt());
        _buffered = Duration(milliseconds: (e['buf'] as num? ?? 0).toInt());
        if (pos != _state.position) {
          _set(_state.copyWith(position: pos));
          _emit(_position, pos);
        }
        if (dur != _state.duration) {
          _set(_state.copyWith(duration: dur));
          _emit(_duration, dur);
        }
      case 'size':
        final w = (e['width'] as num? ?? 0).toInt();
        final h = (e['height'] as num? ?? 0).toInt();
        _par = (e['par'] as num? ?? 1).toDouble();
        if (_par <= 0) _par = 1;
        if (w <= 0 || h <= 0) return;
        _set(_state.copyWith(width: w, height: h));
        _emit(_width, w);
      case 'tracks':
        final t = parseTracks(e['tracks']);
        _set(_state.copyWith(tracks: t));
        _emit(_tracks, t);
      case 'cues':
        final list = <ExoCue>[];
        final raw = e['cues'];
        if (raw is List) {
          for (final c in raw) {
            if (c is Map) {
              final cue = ExoCue.fromMap(c);
              if (cue != null) list.add(cue);
            }
          }
        }
        _showCues(list, clear: e['pos'] == null);
      case 'fps':
        _fps = (e['fps'] as num?)?.toDouble();
      case 'error':
        _fail(EngineError(
          EngineErrorKind.fromId(e['category'] as String?),
          e['message'] as String? ?? 'error',
          code: (e['code'] as num?)?.toInt(),
        ));
    }
  }

  void _fail(EngineError err) {
    if (_state.buffering) {
      _set(_state.copyWith(buffering: false));
      _emit(_buffering, false);
    }
    _emit(_failure, err);
    _emit(_error, err.message);
  }

  /// Spuren aus dem Ereignis: wie bei mpv mit „auto“/„no“ vorn.
  @visibleForTesting
  static EngineTracks parseTracks(Object? raw) {
    final audio = <EngineTrack>[EngineTrack.auto, EngineTrack.no];
    final subs = <EngineTrack>[EngineTrack.auto, EngineTrack.no];
    if (raw is List) {
      for (final t in raw) {
        if (t is! Map) continue;
        if (t['supported'] == false) continue;
        final id = t['id'] as String?;
        if (id == null) continue;
        final label = t['label'] as String?;
        final codec = _codecName(t['mime'] as String?);
        final ch = (t['channels'] as num?)?.toInt();
        final title = [
          if (label != null && label.isNotEmpty) label,
          if (t['type'] == 'audio' && codec != null)
            ch != null && ch > 0 ? '$codec ${_channels(ch)}' : codec,
        ].join(' · ');
        final track = EngineTrack(id,
            title: title.isEmpty ? null : title,
            language: t['language'] as String?);
        switch (t['type']) {
          case 'audio':
            audio.add(track);
          case 'text':
            subs.add(track);
        }
      }
    }
    return EngineTracks(audio: audio, subtitle: subs);
  }

  static String _channels(int ch) => switch (ch) {
        1 => 'Mono',
        2 => 'Stereo',
        6 => '5.1',
        8 => '7.1',
        _ => '${ch}ch',
      };

  static String? _codecName(String? mime) {
    if (mime == null) return null;
    final m = mime.toLowerCase();
    return switch (m) {
      'audio/ac3' => 'AC3',
      'audio/eac3' || 'audio/eac3-joc' => 'E-AC3',
      'audio/vnd.dts' || 'audio/vnd.dts.hd' || 'audio/vnd.dts.uhd' => 'DTS',
      'audio/true-hd' => 'TrueHD',
      'audio/mp4a-latm' => 'AAC',
      'audio/mpeg' => 'MP3',
      'audio/mpeg-l2' => 'MP2',
      'audio/opus' => 'Opus',
      'audio/vorbis' => 'Vorbis',
      'audio/flac' => 'FLAC',
      _ => m.contains('/') ? m.split('/').last.toUpperCase() : m,
    };
  }

  // ---------- Untertitel (Flutter) ----------
  void _clearPendingCues() {
    for (final t in _pendingCues) {
      t.cancel();
    }
    _pendingCues.clear();
  }

  void _showCues(List<ExoCue> list, {bool clear = false}) {
    if (clear) {
      // Sprung/neue Quelle: sofort leeren, Zurückgehaltenes verwerfen.
      _clearPendingCues();
      cues.value = list;
      return;
    }
    final d = _subDelay;
    if (d <= 0) {
      cues.value = list;
      return;
    }
    late final Timer t;
    t = Timer(Duration(milliseconds: (d * 1000).round()), () {
      _pendingCues.remove(t);
      if (!_disposed) cues.value = list;
    });
    _pendingCues.add(t);
  }

  // ---------- Bedienung ----------
  @override
  Future<void> open(String url,
      {Map<String, String> headers = const {},
      bool play = true,
      bool live = false,
      List<EngineSubtitle> subtitles = const []}) async {
    final h = {...headers};
    bool has(String n) => h.keys.any((k) => k.toLowerCase() == n.toLowerCase());
    if (!has('User-Agent') && (_userAgent ?? '').isNotEmpty) {
      h['User-Agent'] = _userAgent!;
    }
    if (!has('Referer') && (_referrer ?? '').isNotEmpty) {
      h['Referer'] = _referrer!;
    }
    _clearPendingCues();
    cues.value = const [];
    _fps = null;
    _selection = const EngineSelection();
    _set(_state.copyWith(
      completed: false,
      buffering: true,
      playing: play,
      position: Duration.zero,
      duration: Duration.zero,
      clearSize: true,
      tracks: const EngineTracks(),
      track: _selection,
    ));
    _emit(_completed, false);
    _emit(_buffering, true);
    _emit(_playing, play);
    _emit(_position, Duration.zero);
    _emit(_width, null);
    _emit(_track, _selection);
    await _p.open(
      url,
      headers: h,
      live: live,
      play: play,
      subtitles: [
        for (final s in subtitles)
          JspExoSubtitle(s.url, language: s.language, label: s.title),
      ],
      build: build,
    );
  }

  @override
  Future<void> play() async {
    _set(_state.copyWith(playing: true));
    _emit(_playing, true);
    await _p.play();
  }

  @override
  Future<void> pause() async {
    _set(_state.copyWith(playing: false));
    _emit(_playing, false);
    await _p.pause();
  }

  @override
  Future<void> playOrPause() => _state.playing ? pause() : play();

  @override
  Future<void> stop() async {
    _clearPendingCues();
    cues.value = const [];
    _set(_state.copyWith(playing: false, buffering: false));
    _emit(_playing, false);
    _emit(_buffering, false);
    await _p.stop();
  }

  @override
  Future<void> seek(Duration position) async {
    _clearPendingCues();
    cues.value = const [];
    _set(_state.copyWith(position: position));
    _emit(_position, position);
    await _p.seek(position);
  }

  @override
  Future<void> setVolume(double volume) =>
      _p.setVolume((volume / 100).clamp(0.0, 1.0));

  @override
  Future<void> setAudioTrack(EngineTrack track) async {
    _selection = EngineSelection(audio: track, subtitle: _selection.subtitle);
    _set(_state.copyWith(track: _selection));
    _emit(_track, _selection);
    await _p.selectTrack('audio', track.id);
  }

  @override
  Future<void> setSubtitleTrack(EngineTrack track) async {
    _selection = EngineSelection(audio: _selection.audio, subtitle: track);
    _set(_state.copyWith(track: _selection));
    _emit(_track, _selection);
    _clearPendingCues();
    cues.value = const [];
    await _p.selectTrack('text', track.id);
  }

  /// Nur-Ton: Videospur über TrackSelectionParameters abwählen.
  @override
  Future<void> setVideoEnabled(bool enabled) => _p.setVideoEnabled(enabled);

  @override
  bool get supportsOptions => true;

  @override
  Future<void> setOption(String name, String value) async {
    _options[name] = value;
    switch (name) {
      case 'user-agent':
        _userAgent = value;
      case 'referrer':
        _referrer = value;
      case 'demuxer-max-bytes':
        _forwardBytes = int.tryParse(value) ?? 0;
      case 'demuxer-max-back-bytes':
        _backBytes = int.tryParse(value) ?? 0;
      case 'demuxer-seekable-cache':
        _seekable = value == 'yes';
      case 'audio-spdif':
        _passthrough = value.trim().isNotEmpty;
      case 'hwdec':
        _softwareVideo = value == 'no';
      case 'sub-delay':
        _subDelay = double.tryParse(value) ?? 0;
        if (_subDelay <= 0) _clearPendingCues();
      default:
        ignored.add(name);
    }
  }

  Map<String, Object?> _stats = const {};
  DateTime _statsAt = DateTime.fromMillisecondsSinceEpoch(0);

  Future<Map<String, Object?>> stats({bool fresh = false}) async {
    final now = DateTime.now();
    if (!fresh && now.difference(_statsAt) < const Duration(milliseconds: 300)) {
      return _stats;
    }
    try {
      _stats = await _p.stats();
    } catch (_) {
      _stats = const {};
    }
    _statsAt = now;
    return _stats;
  }

  @override
  Future<String?> getOption(String name) async {
    switch (name) {
      case 'hwdec':
        return _softwareVideo ? 'no' : 'auto';
      case 'sub-delay':
        return _subDelay.toStringAsFixed(1);
      case 'current-vo':
        return 'exo-texture';
      case 'time-pos':
        return (_state.position.inMilliseconds / 1000).toStringAsFixed(3);
    }
    final s = await stats();
    String? n(String k) => s[k] == null ? null : '${s[k]}';
    switch (name) {
      case 'hwdec-current':
        if (s['videoDecoder'] == null) return null;
        return s['videoHw'] == true ? 'mediacodec' : 'no';
      case 'video-codec':
        return _codecShort(s['videoMime'] as String?);
      case 'video-params/w':
        return n('width');
      case 'video-params/h':
        return n('height');
      case 'container-fps':
        final f = (s['fps'] as num?)?.toDouble() ?? _fps;
        return f?.toStringAsFixed(3);
      case 'frame-drop-count':
        return n('dropped');
      case 'demuxer-cache-duration':
        final ms = (s['bufferedMs'] as num?)?.toInt();
        return ms == null ? null : (ms / 1000).toStringAsFixed(1);
      case 'demuxer-cache-time':
        final ms = (s['bufferedPositionMs'] as num?)?.toInt() ??
            _buffered.inMilliseconds;
        return (ms / 1000).toStringAsFixed(3);
    }
    return null;
  }

  static String? _codecShort(String? mime) {
    if (mime == null) return null;
    return switch (mime) {
      'video/avc' => 'h264',
      'video/hevc' => 'hevc',
      'video/mpeg2' => 'mpeg2video',
      'video/av01' => 'av1',
      'video/x-vnd.on2.vp9' => 'vp9',
      _ => mime.split('/').last,
    };
  }

  /// mpv-Befehle: `sub-add` übernimmt [open] (Untertitel beim Öffnen),
  /// alles andere ist ohne Entsprechung.
  @override
  Future<void> command(List<String> args) async {
    if (args.isNotEmpty) ignored.add('cmd:${args.first}');
  }

  @override
  Future<List<String>> diagnostics() async =>
      formatStats(await stats(fresh: true), subDelay: _subDelay);

  /// Zeilen der Diagnose-Anzeige aus der Exo-Statistik (rein, für Tests).
  static List<String> formatStats(Map<String, Object?> s, {double subDelay = 0}) {
    String hw(Object? v) => v == true ? 'HW' : (v == false ? 'SW' : '–');
    String g(Object? v) => v == null ? '–' : '$v';
    final fps = (s['fps'] as num?)?.toDouble();
    final br = (s['bitrate'] as num?)?.toDouble();
    final net = (s['bandwidth'] as num?)?.toDouble();
    final buf = (s['bufferedMs'] as num?)?.toDouble();
    final ch = (s['audioChannels'] as num?)?.toInt();
    final audio = _codecName(s['audioMime'] as String?);
    return [
      'ExoPlayer${s['softwarePreferred'] == true ? ' · SW zuerst' : ''}'
          '${s['passthrough'] == true ? ' · passthrough' : ''}',
      'dec ${g(s['videoDecoder'])} (${hw(s['videoHw'])})',
      'audio ${g(s['audioDecoder'])} (${hw(s['audioHw'])})'
          '${audio == null ? '' : ' $audio'}${ch == null ? '' : ' ${_channels(ch)}'}',
      '${_codecShort(s['videoMime'] as String?) ?? '–'} '
          '${g(s['width'])}×${g(s['height'])} · '
          'fps ${fps == null ? '–' : fps.toStringAsFixed(2)}',
      'drop ${g(s['dropped'])}',
      'bitrate ${br == null ? '–' : '${(br / 1e6).toStringAsFixed(1)} Mbit/s'}'
          ' · net ${net == null ? '–' : (net / 1e6).toStringAsFixed(1)}',
      'buffer ${buf == null ? '–' : (buf / 1000).toStringAsFixed(1)} s'
          '${subDelay != 0 ? ' · sub-delay ${subDelay.toStringAsFixed(1)} s' : ''}',
    ];
  }

  // ---------- Bild ----------
  @override
  bool get hasVideoSurface => true;

  @override
  Widget? buildVideo({
    required BoxFit fit,
    double? aspectRatio,
    SubtitleStyle subtitleStyle = const SubtitleStyle(),
  }) =>
      ExoVideo(
          engine: this,
          fit: fit,
          aspectRatio: aspectRatio,
          subtitleStyle: subtitleStyle);

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _clearPendingCues();
    await _sub.cancel();
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
    try {
      await _p.dispose();
    } catch (_) {}
    cues.dispose();
  }
}

/// Videofläche (Textur) mit Flutter-Untertiteln.
class ExoVideo extends StatelessWidget {
  final ExoEngine engine;
  final BoxFit fit;
  final double? aspectRatio;
  final SubtitleStyle subtitleStyle;
  const ExoVideo({
    super.key,
    required this.engine,
    required this.fit,
    this.aspectRatio,
    this.subtitleStyle = const SubtitleStyle(),
  });

  @override
  Widget build(BuildContext context) => StreamBuilder<int?>(
        stream: engine.stream.width,
        builder: (context, _) {
          final ar = aspectRatio ?? engine.videoAspect ?? 16 / 9;
          final w = engine.state.width ?? 0;
          return Stack(fit: StackFit.expand, children: [
            ColoredBox(
              color: Colors.black,
              child: ClipRect(
                child: w <= 0
                    ? const SizedBox.expand()
                    : FittedBox(
                        fit: fit,
                        child: SizedBox(
                          width: 1000 * ar,
                          height: 1000,
                          child: Texture(
                              key: const ValueKey('exo-texture'),
                              textureId: engine.textureId,
                              filterQuality: FilterQuality.medium),
                        ),
                      ),
              ),
            ),
            ExoSubtitles(cues: engine.cues, style: subtitleStyle),
          ]);
        },
      );
}

/// Untertitel von Media3 in Flutter gezeichnet (Aussehen aus den
/// Einstellungen, wie bei mpv/media_kit).
class ExoSubtitles extends StatelessWidget {
  final ValueListenable<List<ExoCue>> cues;
  final SubtitleStyle style;
  const ExoSubtitles({super.key, required this.cues, required this.style});

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: ValueListenableBuilder<List<ExoCue>>(
          valueListenable: cues,
          builder: (context, list, _) {
            if (list.isEmpty) return const SizedBox.shrink();
            final text = [
              for (final c in list)
                if (c.text != null) c.text!
            ].join('\n');
            final images = [
              for (final c in list)
                if (c.png != null) c
            ];
            final ts = subtitleViewConfig(style).style;
            return LayoutBuilder(builder: (context, box) {
              return Stack(children: [
                for (final c in images)
                  Positioned(
                    left: (c.x ?? 0.5) * box.maxWidth -
                        ((c.w ?? 0.6) * box.maxWidth) / 2,
                    width: (c.w ?? 0.6) * box.maxWidth,
                    top: c.y == null ? null : c.y! * box.maxHeight,
                    bottom: c.y == null ? box.maxHeight * 0.06 : null,
                    child: Image.memory(c.png!,
                        key: const ValueKey('exo-cue-image'),
                        fit: BoxFit.contain,
                        gaplessPlayback: true),
                  ),
                if (text.isNotEmpty)
                  // Wie media_kit: Abstand unten 24, Größe nach Fläche
                  // (Bezug 1920×1080, höchstens 1).
                  Positioned(
                    left: 16,
                    right: 16,
                    bottom: 24,
                    child: Text(
                      text,
                      key: const ValueKey('exo-cue-text'),
                      textAlign: TextAlign.center,
                      style: ts,
                      textScaler: TextScaler.linear(math.sqrt(
                          (box.maxWidth * box.maxHeight / (1920 * 1080))
                              .clamp(0.0, 1.0))),
                    ),
                  ),
              ]);
            });
          },
        ),
      );
}
