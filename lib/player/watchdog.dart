/// Wachhunde während der Wiedergabe – reine Logik mit Uhr von außen, für
/// beide Engines (ExoPlayer, mpv). Der Player ruft [PlaybackWatchdog.sample]
/// etwa einmal je Sekunde mit dem Zustand und der Statistik der Engine
/// ([EngineHealth]) auf und reagiert auf den gemeldeten [WatchAlarm].
library;

/// Was der Wachhund bemerkt hat.
enum WatchAlarm {
  /// Nach dem Öffnen innerhalb des Zeitbudgets kein erstes Bild (bzw. bei
  /// reinem Ton keine laufende Position).
  startTimeout,

  /// Ton/Position läuft, aber es kommen keine Videobilder.
  noVideo,

  /// Position steht bei „spielt“ ohne Puffern – Bild eingefroren.
  frozen,

  /// Bilder laufen, aber der Ton steht bzw. die Tonspur ist weg.
  noAudio,

  /// Puffert ununterbrochen zu lange.
  buffering,

  /// Viele verworfene Bilder über längere Zeit (Ruckeln).
  stutter,
}

/// Ein Messpunkt (Zustand + Statistik der Engine).
class WatchSample {
  /// Soll gerade abgespielt werden? false bei Pause durch den Nutzer,
  /// Fehlermeldung, laufendem Wiederherstellungsversuch, Cast, verdeckter
  /// Player-Seite – dann wird nichts gezählt.
  final bool active;
  final bool playing;
  final bool buffering;
  final Duration position;

  /// Wird ein Bild erwartet und gezeichnet? false bei Nur-Ton, App im
  /// Hintergrund/Bild-in-Bild, Radiosendern ohne Videospur.
  final bool videoExpected;

  /// Gibt es eine gewählte Tonspur? (false = stumm gewollt/keine Spur)
  final bool audioExpected;

  /// Erstes Bild ist da (Bildgröße bekannt).
  final bool hasFirstFrame;

  /// Zähler gezeigter Bilder; null = unbekannt.
  final int? videoFrames;

  /// Gemessene Bildrate der Ausgabe (mpv estimated-vf-fps); null = unbekannt.
  final double? outputFps;

  /// Ton-Fortschritt (mpv audio-pts in ms, ExoPlayer verarbeitete
  /// Tonpuffer); null = unbekannt.
  final int? audioTicks;

  /// Verworfene Bilder (gesamt); null = unbekannt.
  final int? droppedFrames;

  /// Nominale Bildrate (für die Ruckel-Schwelle).
  final double? fps;
  const WatchSample({
    required this.active,
    required this.playing,
    required this.buffering,
    required this.position,
    this.videoExpected = true,
    this.audioExpected = true,
    this.hasFirstFrame = false,
    this.videoFrames,
    this.outputFps,
    this.audioTicks,
    this.droppedFrames,
    this.fps,
  });
}

/// Grenzen der Wachhunde.
class WatchLimits {
  /// Zeitbudget bis zum ersten Bild.
  final Duration startLive, startVod;

  /// Kein Bild, obwohl Ton/Position läuft.
  final Duration noVideo;

  /// Position steht bei „spielt“ ohne Puffern.
  final Duration frozen;

  /// Ton steht, obwohl Bilder laufen.
  final Duration noAudio;

  /// Dauer-Puffern.
  final Duration buffering;

  /// Ruckeln: Fenster und Anteil verworfener Bilder darin.
  final Duration stutterWindow;
  final double stutterRatio;

  /// Mindestzahl verworfener Bilder im Fenster (kleine Ausreißer zählen nicht).
  final int stutterMinDrops;

  /// Nach einem Ruckel-Hinweis so lange keinen weiteren (Hysterese).
  final Duration stutterCooldown;

  /// Höchstens so viele Ruckel-Hinweise je Sitzung.
  final int stutterMaxHints;
  const WatchLimits({
    this.startLive = const Duration(seconds: 8),
    this.startVod = const Duration(seconds: 12),
    this.noVideo = const Duration(seconds: 6),
    this.frozen = const Duration(seconds: 7),
    this.noAudio = const Duration(seconds: 5),
    this.buffering = const Duration(seconds: 15),
    this.stutterWindow = const Duration(seconds: 30),
    this.stutterRatio = 0.15,
    this.stutterMinDrops = 40,
    this.stutterCooldown = const Duration(minutes: 10),
    this.stutterMaxHints = 2,
  });
}

class PlaybackWatchdog {
  final WatchLimits limits;
  PlaybackWatchdog({this.limits = const WatchLimits()});

  bool _live = true;
  Duration _startBudget = const Duration(seconds: 8);

  // Start
  bool _started = false;
  bool _startAlarmed = false;
  Duration _startElapsed = Duration.zero;
  Duration? _firstPos;

  DateTime? _lastAt;
  Duration? _lastPos;
  int? _lastFrames;
  int? _lastAudio;

  // Laufzeiten der einzelnen Zustände (nur aktive Zeit).
  Duration _frozenFor = Duration.zero;
  Duration _bufferFor = Duration.zero;
  Duration _noVideoFor = Duration.zero;
  Duration _noAudioFor = Duration.zero;

  /// Zeitpunkt der letzten Positionsänderung (für „Position läuft“).
  DateTime? _posMovedAt;

  // Ruckeln
  final _drops = <(DateTime, int)>[];
  DateTime? _stutterSince;
  DateTime? _lastStutterHint;
  int _stutterHints = 0;

  bool get started => _started;

  /// Ruckel-Hinweise dieser Sitzung.
  int get stutterHints => _stutterHints;

  /// Neues Öffnen: Start-Zeitbudget beginnt. [budgetFactor] > 1 bei
  /// vorsichtigem Start (mehr Analyse/Vorpuffer braucht länger).
  /// [now]: Zeitpunkt des Öffnens (Beginn der Frist).
  void reset({required bool live, double budgetFactor = 1, DateTime? now}) {
    _live = live;
    final base = live ? limits.startLive : limits.startVod;
    _startBudget = base * budgetFactor;
    _started = false;
    _startAlarmed = false;
    _startElapsed = Duration.zero;
    _firstPos = null;
    _lastAt = now;
    _lastPos = null;
    _lastFrames = null;
    _lastAudio = null;
    _posMovedAt = null;
    _clearRun();
    _drops.clear();
    _stutterSince = null;
  }

  /// Nach einem Eingriff ohne Neuöffnen (Videoausgabe/Tonspur neu): die
  /// laufenden Zähler beginnen von vorn, der Start bleibt erledigt.
  void rearm() {
    _clearRun();
    _lastFrames = null;
    _lastAudio = null;
  }

  /// Ruckel-Hinweise dieser Sitzung zurücksetzen (Nutzer schaltet um).
  void resetSession() {
    _stutterHints = 0;
    _lastStutterHint = null;
  }

  void _clearRun() {
    _frozenFor = Duration.zero;
    _bufferFor = Duration.zero;
    _noVideoFor = Duration.zero;
    _noAudioFor = Duration.zero;
  }

  /// Messpunkt auswerten; liefert höchstens einen Alarm.
  WatchAlarm? sample(WatchSample s, DateTime now) {
    final last = _lastAt;
    _lastAt = now;
    // Abstand zum letzten Messpunkt (gedeckelt: nach Pausen/Hintergrund
    // keine großen Sprünge).
    var dt = last == null ? Duration.zero : now.difference(last);
    if (dt.isNegative) dt = Duration.zero;
    if (dt > const Duration(seconds: 2)) dt = const Duration(seconds: 2);

    final posMoved = _lastPos != null && s.position != _lastPos;
    _lastPos = s.position;
    if (posMoved) _posMovedAt = now;
    final framesMoved = s.videoFrames != null &&
        _lastFrames != null &&
        s.videoFrames != _lastFrames;
    final framesKnown = s.videoFrames != null && _lastFrames != null;
    _lastFrames = s.videoFrames;
    final audioMoved =
        s.audioTicks != null && _lastAudio != null && s.audioTicks != _lastAudio;
    final audioKnown = s.audioTicks != null && _lastAudio != null;
    _lastAudio = s.audioTicks;

    if (!s.active) {
      // Pause/Hintergrund/Cast: nichts zählen, Laufzeiten verfallen.
      _clearRun();
      _stutterSince = null;
      _drops.clear();
      return null;
    }

    // ---------- Start ----------
    if (!_started) {
      _firstPos ??= s.position;
      final ran = s.position - _firstPos! >= const Duration(milliseconds: 800);
      if (s.hasFirstFrame || (ran && s.playing)) {
        _started = true;
        _clearRun();
      } else {
        _startElapsed += dt;
        if (!_startAlarmed && _startElapsed >= _startBudget) {
          _startAlarmed = true;
          return WatchAlarm.startTimeout;
        }
        return null;
      }
    }

    // ---------- Dauer-Puffern ----------
    if (s.buffering) {
      _bufferFor += dt;
      _frozenFor = Duration.zero;
      _noVideoFor = Duration.zero;
      _noAudioFor = Duration.zero;
      if (_bufferFor >= limits.buffering) {
        _bufferFor = Duration.zero;
        return WatchAlarm.buffering;
      }
      return null;
    }
    _bufferFor = Duration.zero;
    if (!s.playing) {
      _clearRun();
      return null;
    }

    // ---------- Eingefroren ----------
    if (posMoved) {
      _frozenFor = Duration.zero;
    } else {
      _frozenFor += dt;
      if (_frozenFor >= limits.frozen) {
        _clearRun();
        return WatchAlarm.frozen;
      }
    }

    // Position lief in den letzten 2 s (Ton/Uhr läuft).
    final running = _posMovedAt != null &&
        now.difference(_posMovedAt!) <= const Duration(seconds: 2);

    // ---------- Kein Bild ----------
    if (s.videoExpected && running) {
      final noFrames = !s.hasFirstFrame ||
          (framesKnown && !framesMoved) ||
          (s.videoFrames == null && s.outputFps != null && s.outputFps! < 0.5);
      if (noFrames) {
        _noVideoFor += dt;
        if (_noVideoFor >= limits.noVideo) {
          _noVideoFor = Duration.zero;
          return WatchAlarm.noVideo;
        }
      } else {
        _noVideoFor = Duration.zero;
      }
    } else {
      _noVideoFor = Duration.zero;
    }

    // ---------- Kein Ton ----------
    final picture = framesMoved || (!framesKnown && running);
    if (s.audioExpected && audioKnown && picture) {
      if (!audioMoved) {
        _noAudioFor += dt;
        if (_noAudioFor >= limits.noAudio) {
          _noAudioFor = Duration.zero;
          return WatchAlarm.noAudio;
        }
      } else {
        _noAudioFor = Duration.zero;
      }
    } else {
      _noAudioFor = Duration.zero;
    }

    // ---------- Ruckeln ----------
    if (_stutter(s, now)) return WatchAlarm.stutter;
    return null;
  }

  /// Verworfene Bilder über [WatchLimits.stutterWindow]: Anteil an den
  /// erwarteten Bildern über der Schwelle – und das ein ganzes Fenster lang
  /// (kurze Ausreißer beim Senderwechsel zählen nicht). Hysterese: danach
  /// [WatchLimits.stutterCooldown] Ruhe, höchstens
  /// [WatchLimits.stutterMaxHints] je Sitzung.
  bool _stutter(WatchSample s, DateTime now) {
    final d = s.droppedFrames;
    if (d == null || !s.videoExpected) return false;
    _drops.add((now, d));
    final w = limits.stutterWindow;
    while (_drops.length > 1 && now.difference(_drops.first.$1) > w) {
      _drops.removeAt(0);
    }
    final span = now.difference(_drops.first.$1);
    if (span < w * 0.9) return false;
    final dropped = d - _drops.first.$2;
    final fps = (s.fps ?? 0) > 1 ? s.fps! : 25.0;
    final expected = fps * span.inMilliseconds / 1000;
    final bad = dropped >= limits.stutterMinDrops &&
        dropped >= expected * limits.stutterRatio;
    if (!bad) {
      _stutterSince = null;
      return false;
    }
    _stutterSince ??= now;
    if (now.difference(_stutterSince!) < w) return false;
    if (_stutterHints >= limits.stutterMaxHints) return false;
    if (_lastStutterHint != null &&
        now.difference(_lastStutterHint!) < limits.stutterCooldown) {
      return false;
    }
    _lastStutterHint = now;
    _stutterHints++;
    _stutterSince = null;
    return true;
  }

  /// Live oder Film (für Tests/Anzeige).
  bool get live => _live;
  Duration get startBudget => _startBudget;
}
