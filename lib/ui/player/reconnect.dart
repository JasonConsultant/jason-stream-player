import '../../core/stream_errors.dart';

/// Was der Player nach einem Fehler/Hänger tun soll.
enum RecoveryKind {
  /// Gleiche Quelle neu öffnen (nach [RecoveryStep.delay]).
  retry,

  /// Auf die nächste Sender-Variante wechseln.
  nextVariant,

  /// Einmal mit Software-Dekodierung (hwdec=no) versuchen.
  softwareDecode,

  /// Aufgeben: Fehlermeldung mit „Erneut versuchen“ zeigen.
  giveUp,
}

class RecoveryStep {
  final RecoveryKind kind;
  final Duration delay;
  const RecoveryStep(this.kind, [this.delay = Duration.zero]);

  @override
  String toString() => 'RecoveryStep($kind, ${delay.inMilliseconds} ms)';

  @override
  bool operator ==(Object other) =>
      other is RecoveryStep && other.kind == kind && other.delay == delay;

  @override
  int get hashCode => Object.hash(kind, delay);
}

/// Ursache einer Störung.
enum FailureKind {
  /// Fehlermeldung von mpv/Netzwerk.
  error,

  /// Live: keine neuen Bilder mehr / Ende des Streams.
  stall,
}

/// Automatisches Wiederverbinden – reine Logik, ohne Player.
///
/// Ablauf je Störung:
/// 1. bis zu 3 Wiederholungen derselben Quelle (1 s, 2 s, 4 s),
/// 2. nächste Variante des Senders (nur live; je Variante noch 1 Versuch),
/// 3. bei Decoder-Fehlern einmal Software-Dekodierung,
/// 4. aufgeben (Fehlermeldung).
///
/// Nach 60 s störungsfreier Wiedergabe beginnt alles von vorn.
/// Fehler, bei denen Wiederholen nichts bringt (403/404/451/401, von der App
/// blockiert), überspringen die Wiederholungen.
class ReconnectPolicy {
  static const backoff = [
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 4),
  ];
  static const healthyAfter = Duration(seconds: 60);

  /// Wiederholungen derselben Quelle, wenn auf eine weitere Variante
  /// gewechselt wurde (die erste bekommt alle [backoff]-Stufen).
  static const retriesPerExtraVariant = 1;

  int _retries = 0;
  int _variantSwitches = 0;
  bool _triedSoftware = false;
  DateTime? _goodSince;

  int get retries => _retries;
  int get variantSwitches => _variantSwitches;
  bool get triedSoftware => _triedSoftware;

  /// Läuft gerade ein Wiederherstellungsversuch (seit der letzten Störung
  /// noch nicht 60 s gut gelaufen)?
  bool get recovering =>
      _retries > 0 || _variantSwitches > 0 || _triedSoftware;

  /// Alles zurücksetzen (Nutzer schaltet um / „Erneut versuchen“).
  void reset() {
    _retries = 0;
    _variantSwitches = 0;
    _triedSoftware = false;
    _goodSince = null;
  }

  /// Wiedergabe läuft (neue Bilder/Position). Nach [healthyAfter] am Stück
  /// werden die Zähler zurückgesetzt.
  void markGood(DateTime now) {
    _goodSince ??= now;
    if (recovering && now.difference(_goodSince!) >= healthyAfter) {
      _retries = 0;
      _variantSwitches = 0;
      _triedSoftware = false;
    }
  }

  /// Nächster Schritt nach einer Störung.
  /// [variantsLeft]: weitere, noch nicht probierte Varianten (live).
  RecoveryStep onFailure({
    required FailureKind kind,
    String? message,
    required bool live,
    int variantsLeft = 0,
  }) {
    _goodSince = null;
    final hopeless = kind == FailureKind.error &&
        message != null &&
        !_worthRetrying(message);
    final maxRetries = _variantSwitches == 0
        ? backoff.length
        : retriesPerExtraVariant;
    if (!hopeless && _retries < maxRetries) {
      final d = backoff[_retries.clamp(0, backoff.length - 1)];
      _retries++;
      return RecoveryStep(RecoveryKind.retry, d);
    }
    if (live && variantsLeft > 0) {
      _variantSwitches++;
      _retries = 0;
      return const RecoveryStep(RecoveryKind.nextVariant);
    }
    if (!_triedSoftware && message != null && isDecoderError(message)) {
      _triedSoftware = true;
      _retries = 0;
      return const RecoveryStep(RecoveryKind.softwareDecode);
    }
    return const RecoveryStep(RecoveryKind.giveUp);
  }

  /// Fehler, bei denen dieselbe Quelle sofort wieder scheitert.
  static bool _worthRetrying(String message) {
    final k = StreamError.classify(message).kind;
    return switch (k) {
      StreamErrorKind.geoBlocked ||
      StreamErrorKind.forbidden ||
      StreamErrorKind.unauthorized ||
      StreamErrorKind.notFound ||
      StreamErrorKind.blockedByApp =>
        false,
      _ => true,
    };
  }

  /// Sieht der Fehler nach einem Decoder-Problem aus (Hardware-Dekoder)?
  static bool isDecoderError(String message) {
    final m = message.toLowerCase();
    return m.contains('decod') ||
        m.contains('codec') ||
        m.contains('hwdec') ||
        m.contains('mediacodec') ||
        m.contains('video output') ||
        m.contains('vo:') ||
        m.contains('could not initialize');
  }
}

/// Hänger-Erkennung: Position bewegt sich nicht mehr, obwohl abgespielt
/// werden soll. Reine Logik; der Player ruft [sample] regelmäßig auf.
class StallDetector {
  /// So lange darf die Position stehen, bevor es als Hänger gilt.
  final Duration limit;

  /// Nach dem Öffnen mehr Zeit lassen (Verbindungsaufbau, Puffern).
  final Duration startupLimit;

  StallDetector({
    this.limit = const Duration(seconds: 12),
    this.startupLimit = const Duration(seconds: 25),
  });

  Duration? _lastPos;
  DateTime? _since;
  bool _started = false;

  void reset() {
    _lastPos = null;
    _since = null;
    _started = false;
  }

  /// [active]: Wiedergabe soll laufen (nicht pausiert, kein Fehler).
  /// Liefert true, sobald ein Hänger erkannt ist (danach [reset] nötig).
  bool sample(Duration pos, DateTime now, {required bool active}) {
    if (!active) {
      _since = null;
      _lastPos = pos;
      return false;
    }
    if (_lastPos == null || pos != _lastPos) {
      if (_lastPos != null && pos > _lastPos!) _started = true;
      _lastPos = pos;
      _since = now;
      return false;
    }
    _since ??= now;
    final lim = _started ? limit : startupLimit;
    return now.difference(_since!) >= lim;
  }
}
