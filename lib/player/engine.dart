import 'dart:async';

import 'package:flutter/widgets.dart';

import '../core/subtitle_style.dart';

/// Abstrakte Wiedergabe-Engine. Player-Seite, Mini-Player, Nur-Ton und die
/// Medien-Benachrichtigung sprechen nur über diese Schnittstelle – die
/// konkrete Engine (mpv über media_kit, später Media3/ExoPlayer) liegt
/// dahinter. Engine-spezifische Optionen gehen über [setOption] /
/// [getOption] / [command]; eine Engine, die sie nicht kennt, ignoriert sie.
abstract class PlaybackEngine {
  /// Kennung der Engine („mpv“, „exo“).
  String get id;

  /// Momentaufnahme des Zustands.
  EngineState get state;

  /// Zustandsänderungen als Streams.
  EngineStreams get stream;

  /// Öffnet eine Adresse (mit HTTP-Kopfzeilen) und startet die Wiedergabe.
  Future<void> open(String url,
      {Map<String, String> headers = const {}, bool play = true});

  Future<void> play();
  Future<void> pause();
  Future<void> playOrPause();

  /// Wiedergabe beenden (Engine bleibt nutzbar).
  Future<void> stop();
  Future<void> seek(Duration position);

  /// Lautstärke 0–100 (Ducking bei Benachrichtigungstönen).
  Future<void> setVolume(double volume);

  Future<void> setAudioTrack(EngineTrack track);
  Future<void> setSubtitleTrack(EngineTrack track);

  /// Nur-Ton: Video abwählen (spart Akku/Daten) bzw. wieder einschalten.
  Future<void> setVideoEnabled(bool enabled);

  /// Kennt die Engine Optionen/Befehle ([setOption], [getOption], [command])?
  bool get supportsOptions;

  /// Engine-Option setzen (mpv: Eigenschaft). Unbekannt → wirft oder
  /// ignoriert – Aufrufer behandeln beides.
  Future<void> setOption(String name, String value);

  /// Engine-Option lesen; null, wenn unbekannt/nicht unterstützt.
  Future<String?> getOption(String name);

  /// Engine-Befehl (mpv: z. B. `sub-add`).
  Future<void> command(List<String> args);

  /// Videofläche. null, wenn die Engine kein Bild liefern kann (Test/Web).
  Widget? buildVideo({
    required BoxFit fit,
    double? aspectRatio,
    SubtitleStyle subtitleStyle = const SubtitleStyle(),
  });

  /// Kann die Videofläche gezeichnet werden?
  bool get hasVideoSurface;

  Future<void> dispose();
}

/// Konfiguration beim Anlegen einer Engine.
class EngineConfig {
  /// Puffer in Byte.
  final int bufferBytes;

  /// Hardware-Dekodierung erlaubt?
  final bool hardwareAcceleration;

  /// mpv: Video-Ausgabe (vo) und hwdec, null = Standard.
  final String? vo;
  final String? hwdec;
  const EngineConfig({
    this.bufferBytes = 48 << 20,
    this.hardwareAcceleration = true,
    this.vo,
    this.hwdec,
  });
}

/// Eine Ton- oder Untertitelspur.
class EngineTrack {
  final String id;
  final String? title;
  final String? language;
  const EngineTrack(this.id, {this.title, this.language});

  /// Automatisch (Engine wählt).
  static const auto = EngineTrack('auto');

  /// Keine Spur (Untertitel aus).
  static const no = EngineTrack('no');

  bool get isAuto => id == 'auto';
  bool get isOff => id == 'no';

  @override
  bool operator ==(Object other) =>
      other is EngineTrack &&
      other.id == id &&
      other.title == title &&
      other.language == language;

  @override
  int get hashCode => Object.hash(id, title, language);

  @override
  String toString() => 'EngineTrack($id, $language, $title)';
}

/// Verfügbare Spuren.
class EngineTracks {
  final List<EngineTrack> audio;
  final List<EngineTrack> subtitle;
  const EngineTracks({this.audio = const [], this.subtitle = const []});
}

/// Gewählte Spuren.
class EngineSelection {
  final EngineTrack audio;
  final EngineTrack subtitle;
  const EngineSelection(
      {this.audio = EngineTrack.auto, this.subtitle = EngineTrack.auto});
}

/// Momentaufnahme des Engine-Zustands.
class EngineState {
  final bool playing;
  final bool buffering;
  final bool completed;
  final Duration position;
  final Duration duration;

  /// Bildgröße (0/null = noch kein Bild).
  final int? width;
  final int? height;
  final EngineTracks tracks;
  final EngineSelection track;
  const EngineState({
    this.playing = false,
    this.buffering = false,
    this.completed = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.width,
    this.height,
    this.tracks = const EngineTracks(),
    this.track = const EngineSelection(),
  });

  bool get hasVideo => (width ?? 0) > 0;

  EngineState copyWith({
    bool? playing,
    bool? buffering,
    bool? completed,
    Duration? position,
    Duration? duration,
    int? width,
    int? height,
    EngineTracks? tracks,
    EngineSelection? track,
    bool clearSize = false,
  }) =>
      EngineState(
        playing: playing ?? this.playing,
        buffering: buffering ?? this.buffering,
        completed: completed ?? this.completed,
        position: position ?? this.position,
        duration: duration ?? this.duration,
        width: clearSize ? null : (width ?? this.width),
        height: clearSize ? null : (height ?? this.height),
        tracks: tracks ?? this.tracks,
        track: track ?? this.track,
      );
}

/// Zustands-Streams einer Engine.
class EngineStreams {
  final Stream<bool> playing;
  final Stream<bool> buffering;
  final Stream<bool> completed;
  final Stream<Duration> position;
  final Stream<Duration> duration;
  final Stream<int?> width;
  final Stream<EngineTracks> tracks;
  final Stream<EngineSelection> track;

  /// Fehlermeldungen (bereits ohne Zugangsdaten zu behandeln – der
  /// Aufrufer schwärzt mit dem Redactor).
  final Stream<String> error;
  const EngineStreams({
    required this.playing,
    required this.buffering,
    required this.completed,
    required this.position,
    required this.duration,
    required this.width,
    required this.tracks,
    required this.track,
    required this.error,
  });
}

/// Legt eine Engine an (echte Engine in der App, Fake im Test).
typedef EngineFactory = Future<PlaybackEngine> Function(EngineConfig config);
