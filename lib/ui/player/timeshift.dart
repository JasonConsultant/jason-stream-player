/// Live-Pause (Timeshift) über den Demuxer-Puffer von mpv – reine Logik.
library;

/// Speicherinfo des Geräts (siehe PlatformInfo.memoryInfo).
typedef MemInfo = ({int avail, int total, bool lowRam});

/// Puffergrößen für mpv (`demuxer-max-bytes` / `demuxer-max-back-bytes`).
class LiveBufferPlan {
  /// Vorauspuffer: hier sammelt sich der Stream, während pausiert ist.
  final int forwardBytes;

  /// Rückwärtspuffer: bereits Gesehenes, zum Zurückspulen.
  final int backBytes;

  /// Wie weit (ungefähr) zeitversetzt geschaut werden kann.
  final Duration window;

  const LiveBufferPlan(this.forwardBytes, this.backBytes, this.window);

  @override
  String toString() =>
      'LiveBufferPlan(${forwardBytes >> 20} MB vor, ${backBytes >> 20} MB zurück, '
      '${window.inMinutes} min)';
}

/// Typische IPTV-Bitrate (HD, H.264): ~5 Mbit/s.
const liveBytesPerSecond = 625000;

/// Obergrenzen für den Puffer im Arbeitsspeicher.
const _capUnknown = 160 << 20; // Speicher unbekannt: vorsichtig
const _capLowRam = 48 << 20; // „Low-RAM“-Geräte (viele günstige TV-Boxen)
const _capMax = 768 << 20;
const _capSmallBox = 160 << 20; // ≤ 2,5 GB RAM (z. B. Mi Box S: 2 GB)

/// Plant den Live-Puffer für [minutes] Minuten (0 = aus → null).
/// Begrenzt durch den freien Arbeitsspeicher: höchstens 30 % des freien und
/// 15 % des gesamten RAMs, auf Boxen mit ≤ 2,5 GB höchstens 160 MB; ohne
/// Speicherinfo [_capUnknown].
LiveBufferPlan? planLiveBuffer(int minutes, MemInfo? mem) {
  if (minutes <= 0) return null;
  final want = minutes * 60 * liveBytesPerSecond;
  int cap;
  if (mem == null) {
    cap = _capUnknown;
  } else if (mem.lowRam) {
    cap = _capLowRam;
  } else {
    cap = [
      mem.avail * 3 ~/ 10,
      mem.total * 15 ~/ 100,
      mem.total <= (2560 << 20) ? _capSmallBox : _capMax,
    ].reduce((a, b) => a < b ? a : b);
  }
  final budget = want < cap ? want : cap;
  if (budget < (16 << 20)) return null; // zu wenig für sinnvolles Pausieren
  final forward = budget * 2 ~/ 3;
  final back = budget - forward;
  return LiveBufferPlan(
      forward, back, Duration(seconds: forward ~/ liveBytesPerSecond));
}

/// Zustand der Live-Pause. Zeitbasiert (Wanduhr); der Player kann den
/// Rückstand mit den Werten von mpv abgleichen ([sync]).
class TimeshiftState {
  /// Höchster möglicher Rückstand (Puffergröße), 0 = Live-Pause aus.
  Duration window;

  DateTime _openedAt;
  DateTime? _pausedAt;
  Duration _behind = Duration.zero;

  TimeshiftState({required this.window, required DateTime now})
      : _openedAt = now;

  bool get enabled => window > Duration.zero;
  bool get paused => _pausedAt != null;

  /// Neuer Sender/Stream: Puffer ist leer.
  void reset(DateTime now) {
    _openedAt = now;
    _pausedAt = null;
    _behind = Duration.zero;
  }

  /// Wie weit maximal zurück (seit dem Öffnen gepuffert, höchstens [window]).
  Duration available(DateTime now) {
    final since = now.difference(_openedAt);
    return since < window ? since : window;
  }

  Duration _clamp(Duration d, DateTime now) {
    if (d < Duration.zero) return Duration.zero;
    final max = window;
    return d > max ? max : d;
  }

  /// Rückstand zu Live.
  Duration behind(DateTime now) {
    var b = _behind;
    if (_pausedAt != null) b += now.difference(_pausedAt!);
    return _clamp(b, now);
  }

  /// Zeitversetzt (oder pausiert)?
  bool isShifted(DateTime now) =>
      paused || behind(now) >= const Duration(seconds: 2);

  void pause(DateTime now) {
    if (!enabled) return;
    _pausedAt ??= now;
  }

  void resume(DateTime now) {
    if (_pausedAt == null) return;
    _behind = behind(now);
    _pausedAt = null;
  }

  /// Spulen um [delta] (negativ = zurück). Liefert die tatsächlich mögliche
  /// Verschiebung (nicht vor den Pufferanfang, nicht über Live hinaus).
  Duration seek(Duration delta, DateTime now) {
    final cur = behind(now);
    var target = cur - delta;
    if (target < Duration.zero) target = Duration.zero;
    final avail = available(now) > cur ? available(now) : cur;
    if (target > avail) target = avail;
    if (_pausedAt != null) _pausedAt = now;
    _behind = target;
    return cur - target;
  }

  /// Zurück zu Live.
  void goLive() {
    _behind = Duration.zero;
    _pausedAt = null;
  }

  /// Rückstand von mpv übernehmen (Puffer-Ende minus Position).
  void sync(Duration behind, DateTime now) {
    if (_pausedAt != null) _pausedAt = now;
    _behind = _clamp(behind, now);
  }
}

/// „−12:34“ (Minuten:Sekunden, ab 1 h „−1:02:03“).
String fmtBehind(Duration d) {
  final s = d.inSeconds;
  final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return h > 0 ? '−$h:${two(m)}:${two(sec)}' : '−$m:${two(sec)}';
}
