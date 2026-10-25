import '../../core/audio_passthrough.dart';
import '../../core/subtitle_style.dart';
import '../../player/data_saver.dart' show DataSaverTuning;
import 'timeshift.dart' show LiveBufferPlan;

/// Setzt eine mpv-Eigenschaft (NativePlayer.setProperty; im Test ein Fake).
typedef MpvSetter = Future<void> Function(String name, String value);

/// Merkt sich je Player, was mpv schon hat, und schickt nur Änderungen –
/// beim Zappen gehen so statt ~12 meist 0–2 Eigenschaften an mpv.
class MpvProps {
  MpvProps(this._set);
  final MpvSetter _set;
  final _last = <String, String>{};

  /// Insgesamt an mpv geschickte Eigenschaften (Tests/Diagnose).
  int sent = 0;

  /// Setzt nur geänderte Werte; liefert die Zahl der gesendeten. Fehler
  /// (Option in dieser libmpv unbekannt) gelten als erledigt – sie würden
  /// sonst bei jedem Öffnen erneut versucht.
  Future<int> apply(Map<String, String> props) async {
    var n = 0;
    for (final e in props.entries) {
      if (_last[e.key] == e.value) continue;
      _last[e.key] = e.value;
      n++;
      sent++;
      try {
        await _set(e.key, e.value);
      } catch (_) {}
    }
    return n;
  }

  /// Wert von außen geändert (z. B. hwdec-Notlösung) → beim nächsten
  /// [apply] wieder senden.
  void forget(String name) => _last.remove(name);

  String? operator [](String name) => _last[name];
}

/// Einstellung „Video-Ausgabe“ (Fernseher).
enum VideoOutput {
  /// media_kit-Standard: vo=gpu, hwdec=auto-safe (bzw. Schalter
  /// „Hardware-Dekodierung“).
  standard('standard'),

  /// Dekoder zeichnet direkt auf die Fläche (vo=mediacodec_embed,
  /// hwdec=mediacodec): am sparsamsten auf schwachen TV-Boxen.
  direct('direct'),

  /// Software-Dekodierung (hwdec=no) – bei Bildfehlern/Schwarzbild.
  compat('compat');

  const VideoOutput(this.id);
  final String id;

  static const optionKey = 'videoout';

  static VideoOutput fromId(String? id) => switch (id) {
        'direct' => direct,
        'compat' => compat,
        _ => standard,
      };

  /// Darf der Player bei Bildfehlern auf Software-Dekodierung (hwdec=no)
  /// ausweichen? Nicht bei [direct]: mediacodec_embed zeigt nur Bilder des
  /// Hardware-Dekoders (sonst Schwarzbild).
  bool get allowsSoftwareFallback => this != direct;

  /// Für VideoControllerConfiguration: (vo, hwdec); null = Standard.
  (String?, String?) get controller => switch (this) {
        direct => ('mediacodec_embed', 'mediacodec'),
        compat => (null, 'no'),
        standard => (null, null),
      };
}

/// mpv-Einstellungen des Vollbild-Players.
abstract final class MpvTuning {
  /// Live ohne Live-Pause: kleiner Rückpuffer, mäßiger Vorauspuffer (ein
  /// Live-Stream kommt ohnehin nur in Echtzeit an).
  static const liveBackBytes = 6 << 20;
  static const liveForwardMin = 16 << 20;
  static const liveForwardMax = 32 << 20;

  /// Live: wie bis 1.4 (1.5.0 hatte 1 s / 2 MB – zu knapp: Tonspur oder
  /// Bildrate wurden auf manchen Streams falsch erkannt).
  static const liveAnalyze = '1.5';
  static const liveProbeSize = '5000000';

  /// Filme/Serien: wie bisher (ffmpeg-Standard für probesize).
  static const vodAnalyze = '1.5';
  static const vodProbeSize = '5000000';

  /// Vorsichtiger Start (Start-Leiter Stufe b): länger analysieren, mehr
  /// lesen, erst mit etwas Puffer anfangen. Langsamer, erkennt aber
  /// schwierige Streams (späte Tonspur, Bildrate, seltene Schlüsselbilder).
  static const carefulAnalyze = '5';
  static const carefulProbeSize = '20000000';

  /// Einmal je Player-Instanz.
  static const constant = <String, String>{
    'demuxer-lavf-o': 'fflags=+discardcorrupt',
    'cache-pause-initial': 'no',
    'network-timeout': '15',
    'stream-lavf-o': 'reconnect=1,reconnect_streamed=1,reconnect_delay_max=4',
    'cache': 'yes',
  };

  /// Puffer/Analyse je Stream. [plan] = Live-Pause aktiv (nur live).
  static Map<String, String> stream({
    required bool live,
    required LiveBufferPlan? plan,
    required int bufferBytes,
    bool careful = false,
  }) {
    final int fwd, back;
    if (live && plan != null) {
      // Live-Pause: Stream läuft im Speicher weiter, Spulen im Puffer.
      fwd = plan.forwardBytes < bufferBytes ? bufferBytes : plan.forwardBytes;
      back = plan.backBytes;
    } else if (live) {
      fwd = bufferBytes.clamp(liveForwardMin, liveForwardMax);
      back = liveBackBytes;
    } else {
      fwd = bufferBytes;
      back = bufferBytes;
    }
    return {
      'demuxer-seekable-cache': live && plan != null ? 'yes' : 'auto',
      'demuxer-max-bytes': '$fwd',
      'demuxer-max-back-bytes': '$back',
      'demuxer-lavf-analyzeduration':
          careful ? carefulAnalyze : (live ? liveAnalyze : vodAnalyze),
      'demuxer-lavf-probesize':
          careful ? carefulProbeSize : (live ? liveProbeSize : vodProbeSize),
      // ExoPlayer: konservativer LoadControl (siehe ExoEngine).
      'cache-pause-initial': careful ? 'yes' : 'no',
    };
  }

  /// Alles, was vor jedem Öffnen stimmen muss (nur Änderungen gehen raus).
  static Map<String, String> perOpen({
    required bool live,
    required LiveBufferPlan? plan,
    required int bufferBytes,
    required String userAgent,
    required String referrer,
    required SubtitleStyle subtitles,
    required bool passthrough,
    bool dataSaver = false,
    bool careful = false,
  }) =>
      {
        'user-agent': userAgent,
        'referrer': referrer,
        ...stream(
            live: live, plan: plan, bufferBytes: bufferBytes, careful: careful),
        ...subtitles.mpvProperties,
        ...AudioPassthrough.mpvProperties(passthrough),
        // Datensparmodus: niedrigste HLS-Stufe (ExoPlayer: Bitrate/720p).
        ...DataSaverTuning.mpv(dataSaver),
      };
}
