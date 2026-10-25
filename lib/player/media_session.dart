import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';

import '../core/security.dart';

/// Was die Benachrichtigung / der Sperrbildschirm anzeigen soll.
class MediaInfo {
  final String title;
  final String? subtitle;

  /// Logo/Poster (nur eine unbedenkliche Adresse ohne Zugangsdaten).
  final String? artUrl;
  final bool live;
  final bool playing;
  final bool buffering;

  /// Live mit Senderliste: CH+/CH− anbieten.
  final bool canZap;
  final Duration position;
  final Duration duration;
  const MediaInfo({
    required this.title,
    this.subtitle,
    this.artUrl,
    this.live = false,
    this.playing = false,
    this.buffering = false,
    this.canZap = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
  });

  /// Nur Adressen ohne Zugangsdaten/Parameter in die Benachrichtigung –
  /// Stream-Adressen und Portal-Logins dürfen dort nie landen.
  static String? safeArt(String? url) {
    if (url == null || !UrlPolicy.isWeb(url)) return null;
    final u = Uri.tryParse(url.trim());
    if (u == null || u.userInfo.isNotEmpty || u.hasQuery) return null;
    return u.toString();
  }
}

/// Reaktionen auf Tasten der Benachrichtigung, Kopfhörer, Audio-Fokus.
class MediaSessionCallbacks {
  final Future<void> Function() onPlay;
  final Future<void> Function() onPause;
  final Future<void> Function() onStop;
  final Future<void> Function(int dir)? onZap;
  final Future<void> Function(Duration pos)? onSeek;

  /// Audio-Fokus: Ducking an/aus (Lautstärke senken) bzw. Unterbrechung
  /// (Anruf → Pause, danach ggf. weiter).
  final Future<void> Function(bool on) onDuck;
  final Future<void> Function() onInterrupt;
  final Future<void> Function() onInterruptEnd;
  const MediaSessionCallbacks({
    required this.onPlay,
    required this.onPause,
    required this.onStop,
    this.onZap,
    this.onSeek,
    required this.onDuck,
    required this.onInterrupt,
    required this.onInterruptEnd,
  });
}

/// Brücke zu Systemsteuerung (Benachrichtigung, Sperrbildschirm, Kopfhörer-
/// Tasten, Audio-Fokus). In der App: audio_service + audio_session; im Test
/// und auf dem Fernseher: [NoopMediaSession].
abstract class MediaSessionBridge {
  /// Aktive Brücke (von [AudioServiceBridge.init] gesetzt).
  static MediaSessionBridge? instance;

  void attach(MediaSessionCallbacks callbacks);
  void detach();

  /// Anzeige aktualisieren (Titel, Zustand).
  Future<void> update(MediaInfo info);

  /// Nichts läuft mehr – Benachrichtigung weg, Audio-Fokus abgeben.
  Future<void> idle();
}

/// Ohne Systemanbindung (Test, Web, Fernseher).
class NoopMediaSession implements MediaSessionBridge {
  final updates = <MediaInfo>[];
  int idles = 0;
  MediaSessionCallbacks? callbacks;

  @override
  void attach(MediaSessionCallbacks c) => callbacks = c;
  @override
  void detach() => callbacks = null;
  @override
  Future<void> update(MediaInfo info) async => updates.add(info);
  @override
  Future<void> idle() async => idles++;
}

/// audio_service-Handler: Benachrichtigung mit Titel/Sender, Play/Pause,
/// Stopp, bei Live CH+/CH−; Kopfhörer-Tasten; Audio-Fokus über
/// audio_session (Pause bei Anruf, Ducking).
class AudioServiceBridge extends BaseAudioHandler implements MediaSessionBridge {
  MediaSessionCallbacks? _cb;
  AudioSession? _session;
  bool _active = false;
  bool _pausedByInterrupt = false;
  final _subs = <StreamSubscription>[];

  AudioServiceBridge._();

  /// Einmal beim Start (vor runApp). Auf Web/Test nichts tun.
  static Future<void> init() async {
    if (kIsWeb || MediaSessionBridge.instance != null) return;
    try {
      final h = await AudioService.init(
        builder: AudioServiceBridge._,
        config: const AudioServiceConfig(
          androidNotificationChannelId: 'de.jasonstream.player.playback',
          androidNotificationChannelName: 'Wiedergabe',
          androidNotificationOngoing: true,
          androidStopForegroundOnPause: true,
          androidNotificationIcon: 'mipmap/ic_launcher',
        ),
      );
      MediaSessionBridge.instance = h;
    } catch (e) {
      // Ohne Benachrichtigung weiterarbeiten (z. B. Dienst nicht eingetragen).
      debugPrint('media session unavailable: ${Redactor.redact('$e')}');
    }
  }

  Future<AudioSession> _ensureSession() async {
    final s = _session ??= await AudioSession.instance;
    if (_subs.isEmpty) {
      await s.configure(const AudioSessionConfiguration.music());
      _subs.add(s.interruptionEventStream.listen((e) async {
        final cb = _cb;
        if (cb == null) return;
        if (e.begin) {
          switch (e.type) {
            case AudioInterruptionType.duck:
              await cb.onDuck(true);
            case AudioInterruptionType.pause:
            case AudioInterruptionType.unknown:
              if (playbackState.value.playing) {
                _pausedByInterrupt = true;
                await cb.onInterrupt();
              }
          }
        } else {
          switch (e.type) {
            case AudioInterruptionType.duck:
              await cb.onDuck(false);
            case AudioInterruptionType.pause:
              if (_pausedByInterrupt) {
                _pausedByInterrupt = false;
                await cb.onInterruptEnd();
              }
            case AudioInterruptionType.unknown:
              _pausedByInterrupt = false;
          }
        }
      }));
      // Kopfhörer abgezogen → Pause.
      _subs.add(s.becomingNoisyEventStream.listen((_) => _cb?.onPause()));
    }
    return s;
  }

  @override
  void attach(MediaSessionCallbacks callbacks) => _cb = callbacks;

  @override
  void detach() => _cb = null;

  @override
  Future<void> update(MediaInfo info) async {
    final s = await _ensureSession();
    if (!_active && info.playing) {
      _active = await s.setActive(true);
    }
    final cur = mediaItem.value;
    final art = MediaInfo.safeArt(info.artUrl);
    if (cur == null ||
        cur.title != info.title ||
        cur.artist != info.subtitle ||
        cur.artUri?.toString() != art ||
        cur.duration != (info.live ? null : info.duration)) {
      mediaItem.add(MediaItem(
        // Nie die Stream-Adresse als Kennung.
        id: 'jsp:${info.title.hashCode}',
        title: info.title,
        artist: info.subtitle,
        artUri: art == null ? null : Uri.tryParse(art),
        duration: info.live || info.duration == Duration.zero
            ? null
            : info.duration,
      ));
    }
    playbackState.add(playbackState.value.copyWith(
      controls: [
        if (info.canZap) MediaControl.skipToPrevious,
        info.playing ? MediaControl.pause : MediaControl.play,
        MediaControl.stop,
        if (info.canZap) MediaControl.skipToNext,
      ],
      systemActions: {
        if (!info.live) MediaAction.seek,
      },
      androidCompactActionIndices: info.canZap ? const [0, 1, 3] : const [0, 1],
      processingState: info.buffering
          ? AudioProcessingState.buffering
          : AudioProcessingState.ready,
      playing: info.playing,
      updatePosition: info.position,
    ));
  }

  @override
  Future<void> idle() async {
    playbackState.add(playbackState.value.copyWith(
      controls: const [],
      processingState: AudioProcessingState.idle,
      playing: false,
    ));
    if (_active) {
      _active = false;
      try {
        await _session?.setActive(false);
      } catch (_) {}
    }
  }

  // ---- Tasten (Benachrichtigung, Kopfhörer, Sperrbildschirm) ----
  @override
  Future<void> play() async => _cb?.onPlay();
  @override
  Future<void> pause() async => _cb?.onPause();
  @override
  Future<void> stop() async {
    await _cb?.onStop();
    await idle();
  }

  @override
  Future<void> skipToNext() async => _cb?.onZap?.call(1);
  @override
  Future<void> skipToPrevious() async => _cb?.onZap?.call(-1);
  @override
  Future<void> seek(Duration position) async => _cb?.onSeek?.call(position);

  /// Benachrichtigung weggewischt → Wiedergabe beenden.
  @override
  Future<void> onTaskRemoved() => stop();
}
