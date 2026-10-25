import '../../core/stream_errors.dart';
import '../../player/engine.dart' show EngineErrorKind;

/// Was der Player nach einem Fehler/Hänger tun soll – eine Stufe der
/// Start-, Verbindungs- bzw. Wachhund-Leiter.
enum RecoveryKind {
  /// (a) Gleiche Quelle mit derselben Engine neu öffnen (nach
  /// [RecoveryStep.delay]). Live landet dabei an der Live-Kante, Filme an
  /// der letzten Position.
  retry,

  /// (b) Vorsichtiger Start: mpv größere probesize/analyzeduration,
  /// ExoPlayer konservativer LoadControl (mehr Vorpuffer).
  careful,

  /// (c) Software-Dekodierung (mpv hwdec=no / Exo Software-Decoder zuerst).
  softwareDecode,

  /// (d) Andere Engine (ExoPlayer ↔ mpv).
  otherEngine,

  /// (e) Ersatz-Adresse des Portals (Host-Failover) für denselben Stream.
  nextHost,

  /// (e) Nächste Variante des Senders (nur live).
  nextVariant,

  /// Wachhund „kein Bild“: Videoausgabe aus- und wieder einschalten.
  restartVideo,

  /// Wachhund „Ton weg“: Tonspur neu wählen.
  reselectAudio,

  /// Nur Hinweis zeigen, Wiedergabe läuft weiter (z. B. Ton bleibt weg).
  notify,

  /// Aufgeben: Fehlermeldung mit „Erneut versuchen“ zeigen.
  giveUp,
}

class RecoveryStep {
  final RecoveryKind kind;
  final Duration delay;

  /// Aufgeben, weil das Eingriffs-Budget erschöpft ist.
  final bool budgetExhausted;
  const RecoveryStep(this.kind,
      [this.delay = Duration.zero, this.budgetExhausted = false]);

  @override
  String toString() => 'RecoveryStep($kind, ${delay.inMilliseconds} ms)';

  @override
  bool operator ==(Object other) =>
      other is RecoveryStep &&
      other.kind == kind &&
      other.delay == delay &&
      other.budgetExhausted == budgetExhausted;

  @override
  int get hashCode => Object.hash(kind, delay, budgetExhausted);
}

/// Ursache einer Störung (woher sie gemeldet wird).
enum FailureKind {
  /// Fehlermeldung der Engine/des Netzwerks.
  error,

  /// Position steht (Live-Ende, Bild eingefroren ohne Puffern).
  stall,

  /// Kein erstes Bild innerhalb des Zeitbudgets nach dem Öffnen.
  startTimeout,

  /// Ton/Position läuft, aber keine neuen Videobilder.
  noVideo,

  /// Bilder laufen, aber der Ton steht bzw. die Tonspur ist weg.
  noAudio,

  /// Dauer-Puffern.
  buffering,
}

/// Fehlerart – entscheidet, welche Stufen sinnvoll sind.
enum FaultClass {
  /// Netz/Server (Zeitüberschreitung, 5xx, Abbruch, Hänger, Puffern).
  network,

  /// Anbieter bremst (HTTP 429/458): lange warten, nicht hämmern.
  rateLimited,

  /// Gleiche Adresse scheitert sicher wieder (401/403/404/451, blockiert).
  hopeless,

  /// Decoder (Hardware-Dekoder, Codec nicht initialisierbar).
  decoder,

  /// Format/Container (Analyse gescheitert, unbekanntes Format).
  format,

  /// Start ohne Bild und ohne Meldung.
  start,

  /// Wachhund: kein Bild.
  video,

  /// Wachhund: kein Ton.
  audio;

  static FaultClass of(FailureKind kind,
      {String? message, EngineErrorKind? engineKind}) {
    switch (kind) {
      case FailureKind.startTimeout:
        return start;
      case FailureKind.noVideo:
        return video;
      case FailureKind.noAudio:
        return audio;
      case FailureKind.stall:
      case FailureKind.buffering:
        return network;
      case FailureKind.error:
        break;
    }
    final m = message ?? '';
    if (m.isNotEmpty && ReconnectPolicy.isRateLimited(m)) return rateLimited;
    if (m.isNotEmpty && !ReconnectPolicy.worthRetrying(m)) return hopeless;
    if (engineKind == EngineErrorKind.decoder) return decoder;
    if (engineKind == EngineErrorKind.format ||
        engineKind == EngineErrorKind.container) {
      return format;
    }
    if (engineKind == EngineErrorKind.network) return network;
    if (m.isNotEmpty && ReconnectPolicy.isDecoderError(m)) return decoder;
    if (m.isNotEmpty && ReconnectPolicy.isFormatError(m)) return format;
    return network;
  }
}

/// Was in der aktuellen Lage möglich ist (vom Player gefüllt).
class RecoveryOptions {
  final bool live;

  /// Weitere, noch nicht probierte Varianten (live).
  final int variantsLeft;

  /// Weitere, noch nicht probierte Ersatz-Adressen des Portals.
  final int hostsLeft;

  /// Software-Dekodierung möglich (nicht „Hardware direkt“, noch nicht an).
  final bool canSoftware;

  /// Andere Engine verfügbar.
  final bool canSwitchEngine;

  /// Die Engine probiert bei Decoder-Fehlern selbst weitere (auch
  /// Software-)Dekoder (ExoPlayer: DecoderFallback) – dann bringt
  /// „Software-Dekodierung“ nach einem Decoder-Fehler nichts Neues.
  final bool engineHasDecoderFallback;

  /// Bringt „vorsichtiger Start“ bei Format-/Containerfehlern etwas? (mpv:
  /// längere Analyse; ExoPlayer ändert nur den Puffer – dann gleich die
  /// andere Engine.)
  final bool carefulHelpsFormat;
  const RecoveryOptions({
    required this.live,
    this.variantsLeft = 0,
    this.hostsLeft = 0,
    this.canSoftware = true,
    this.canSwitchEngine = false,
    this.engineHasDecoderFallback = false,
    this.carefulHelpsFormat = true,
  });
}

/// Begrenzt automatische Eingriffe: höchstens [max] Störungs-Episoden je
/// [window]. Danach bleibt die Fehlermeldung stehen statt einer Endlos-
/// schleife aus „läuft kurz – hängt – neu öffnen“.
class InterventionBudget {
  final int max;
  final Duration window;
  InterventionBudget(
      {this.max = 3, this.window = const Duration(minutes: 5)});

  final _used = <DateTime>[];

  /// Eingriffe im aktuellen Fenster.
  int count(DateTime now) {
    _used.removeWhere((t) => now.difference(t) >= window);
    return _used.length;
  }

  /// Einen Eingriff verbuchen; false = Budget erschöpft.
  bool tryUse(DateTime now) {
    if (count(now) >= max) return false;
    _used.add(now);
    return true;
  }

  void reset() => _used.clear();
}

/// Start-, Verbindungs- und Wachhund-Leiter in einem – reine Logik, ohne
/// Player (Uhr kommt von außen).
///
/// Je Störung (Fehlerart → sinnvolle Stufen):
/// - Netz/Hänger/Puffern: Wiederholen mit 0,5/1/2/4/8 s → Ersatz-Adresse
///   (je 1 Versuch) → nächste Variante (live, je 1 Versuch) → aufgeben.
/// - HTTP 429/458 (Anbieter bremst): 8/20/45 s warten, keine weiteren
///   Adressen/Varianten (gleicher Anbieter = gleiche Sperre) → aufgeben.
/// - 401/403/404/451: nicht wiederholen → Ersatz-Adresse → Variante → aufgeben.
/// - Decoder: Software-Dekodierung (nicht bei ExoPlayer, der probiert selbst
///   weiter) → andere Engine → Variante → aufgeben.
/// - Format/Container: vorsichtiger Start (nur mpv: längere Analyse) →
///   andere Engine → Variante → aufgeben.
/// - Start ohne Bild (Zeitbudget): einmal wiederholen → vorsichtiger Start →
///   andere Engine → Ersatz-Adresse → Variante → aufgeben.
/// - Kein Bild: Videoausgabe neu → neu öffnen → Software → andere Engine →
///   aufgeben.
/// - Kein Ton: Tonspur neu wählen → neu öffnen → nur Hinweis.
///
/// Nach [healthyAfter] störungsfreier Wiedergabe beginnt die Leiter von
/// vorn; jede neue Störungs-Episode verbraucht einen Eingriff aus dem
/// [budget] (3 je 5 min) – ist es leer, wird aufgegeben.
class ReconnectPolicy {
  static const backoff = [
    Duration(milliseconds: 500),
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
  ];

  /// Wartezeiten bei HTTP 429/458 (Anbieter-Sperre wegen zu vieler Anfragen).
  static const rateLimitWaits = [
    Duration(seconds: 8),
    Duration(seconds: 20),
    Duration(seconds: 45),
  ];
  static const healthyAfter = Duration(seconds: 60);

  /// Wartezeit vor einem Wechsel (Variante, Adresse, Engine, Dekoder).
  static const switchDelay = Duration(milliseconds: 400);

  /// Wiederholungen derselben Quelle nach einem Wechsel auf eine weitere
  /// Variante/Adresse (die erste bekommt alle [backoff]-Stufen).
  static const retriesPerExtraSource = 1;

  /// Kompatibel zum bisherigen Namen.
  static const retriesPerExtraVariant = retriesPerExtraSource;

  ReconnectPolicy({InterventionBudget? budget})
      : budget = budget ?? InterventionBudget();

  final InterventionBudget budget;

  int _retries = 0;
  int _variantSwitches = 0;
  int _hostSwitches = 0;
  int _rateWaits = 0;
  bool _triedSoftware = false;
  bool _triedCareful = false;
  bool _triedEngine = false;
  bool _restartedVideo = false;
  bool _reopenedForVideo = false;
  bool _reselectedAudio = false;
  bool _reopenedForAudio = false;
  bool _startRetried = false;
  bool _episode = false;
  DateTime? _goodSince;

  /// Zuletzt gewählte Stufe der laufenden Episode (für „erfolgreiche Stufe
  /// merken“); null = keine Störung.
  RecoveryKind? lastStep;

  /// Eingriffe dieser Sitzung (Stream-Info).
  int interventions = 0;

  int get retries => _retries;
  int get variantSwitches => _variantSwitches;
  int get hostSwitches => _hostSwitches;
  bool get triedSoftware => _triedSoftware;
  bool get triedCareful => _triedCareful;
  bool get triedEngine => _triedEngine;

  /// Läuft gerade ein Wiederherstellungsversuch (seit der letzten Störung
  /// noch nicht [healthyAfter] gut gelaufen)?
  bool get recovering => _episode;

  void _clearLadder() {
    _retries = 0;
    _variantSwitches = 0;
    _hostSwitches = 0;
    _rateWaits = 0;
    _triedSoftware = false;
    _triedCareful = false;
    _triedEngine = false;
    _restartedVideo = false;
    _reopenedForVideo = false;
    _reselectedAudio = false;
    _reopenedForAudio = false;
    _startRetried = false;
    _episode = false;
    lastStep = null;
  }

  /// Alles zurücksetzen (Nutzer schaltet um / „Erneut versuchen“) – auch
  /// das Eingriffs-Budget.
  void reset() {
    _clearLadder();
    _goodSince = null;
    budget.reset();
  }

  /// Wiedergabe läuft (neue Bilder/Position). Nach [healthyAfter] am Stück
  /// beginnt die Leiter wieder von vorn (das Budget bleibt).
  void markGood(DateTime now) {
    _goodSince ??= now;
    if (_episode && now.difference(_goodSince!) >= healthyAfter) {
      _clearLadder();
    }
  }

  /// Nächster Schritt nach einer Störung.
  RecoveryStep onFailure({
    required FailureKind kind,
    String? message,
    EngineErrorKind? engineKind,
    required bool live,
    int variantsLeft = 0,
    int hostsLeft = 0,
    bool canSoftware = true,
    bool canSwitchEngine = false,
    bool engineHasDecoderFallback = false,
    bool carefulHelpsFormat = true,
    DateTime? now,
  }) =>
      next(
        kind,
        RecoveryOptions(
          live: live,
          variantsLeft: variantsLeft,
          hostsLeft: hostsLeft,
          canSoftware: canSoftware,
          canSwitchEngine: canSwitchEngine,
          engineHasDecoderFallback: engineHasDecoderFallback,
          carefulHelpsFormat: carefulHelpsFormat,
        ),
        message: message,
        engineKind: engineKind,
        now: now,
      );

  /// Wie [onFailure], mit gebündelten Möglichkeiten.
  RecoveryStep next(
    FailureKind kind,
    RecoveryOptions o, {
    String? message,
    EngineErrorKind? engineKind,
    DateTime? now,
  }) {
    _goodSince = null;
    final t = now ?? DateTime.now();
    if (!_episode) {
      // Neue Störungs-Episode: verbraucht einen Eingriff.
      if (!budget.tryUse(t)) {
        return const RecoveryStep(RecoveryKind.giveUp, Duration.zero, true);
      }
      _episode = true;
    }
    final cls = FaultClass.of(kind, message: message, engineKind: engineKind);
    final step = _step(cls, o);
    lastStep = step.kind;
    if (step.kind != RecoveryKind.giveUp) interventions++;
    return step;
  }

  RecoveryStep _step(FaultClass cls, RecoveryOptions o) {
    switch (cls) {
      case FaultClass.rateLimited:
        if (_rateWaits < rateLimitWaits.length) {
          return RecoveryStep(RecoveryKind.retry, rateLimitWaits[_rateWaits++]);
        }
        return const RecoveryStep(RecoveryKind.giveUp);
      case FaultClass.hopeless:
        return _alternate(o) ?? const RecoveryStep(RecoveryKind.giveUp);
      case FaultClass.network:
        return _retry() ??
            _alternate(o) ??
            const RecoveryStep(RecoveryKind.giveUp);
      case FaultClass.decoder:
        if (!o.engineHasDecoderFallback && o.canSoftware && !_triedSoftware) {
          _triedSoftware = true;
          return const RecoveryStep(RecoveryKind.softwareDecode, switchDelay);
        }
        return _engine(o) ??
            _variant(o) ??
            const RecoveryStep(RecoveryKind.giveUp);
      case FaultClass.format:
        if (o.carefulHelpsFormat && !_triedCareful) {
          _triedCareful = true;
          return const RecoveryStep(RecoveryKind.careful, switchDelay);
        }
        return _engine(o) ??
            _variant(o) ??
            const RecoveryStep(RecoveryKind.giveUp);
      case FaultClass.start:
        if (!_startRetried) {
          _startRetried = true;
          return RecoveryStep(RecoveryKind.retry, backoff.first);
        }
        if (!_triedCareful) {
          _triedCareful = true;
          return const RecoveryStep(RecoveryKind.careful, switchDelay);
        }
        return _engine(o) ??
            _alternate(o) ??
            const RecoveryStep(RecoveryKind.giveUp);
      case FaultClass.video:
        if (!_restartedVideo) {
          _restartedVideo = true;
          return const RecoveryStep(RecoveryKind.restartVideo);
        }
        if (!_reopenedForVideo) {
          _reopenedForVideo = true;
          return RecoveryStep(RecoveryKind.retry, backoff.first);
        }
        if (o.canSoftware && !_triedSoftware) {
          _triedSoftware = true;
          return const RecoveryStep(RecoveryKind.softwareDecode, switchDelay);
        }
        return _engine(o) ?? const RecoveryStep(RecoveryKind.giveUp);
      case FaultClass.audio:
        if (!_reselectedAudio) {
          _reselectedAudio = true;
          return const RecoveryStep(RecoveryKind.reselectAudio);
        }
        if (!_reopenedForAudio) {
          _reopenedForAudio = true;
          return RecoveryStep(RecoveryKind.retry, backoff.first);
        }
        return const RecoveryStep(RecoveryKind.notify);
    }
  }

  /// Wiederholen derselben Quelle mit wachsender Wartezeit.
  RecoveryStep? _retry() {
    final max = _variantSwitches == 0 && _hostSwitches == 0
        ? backoff.length
        : retriesPerExtraSource;
    if (_retries >= max) return null;
    final d = backoff[_retries.clamp(0, backoff.length - 1)];
    _retries++;
    return RecoveryStep(RecoveryKind.retry, d);
  }

  /// Ersatz-Adresse, sonst Ersatz-Variante.
  RecoveryStep? _alternate(RecoveryOptions o) => _host(o) ?? _variant(o);

  RecoveryStep? _host(RecoveryOptions o) {
    if (o.hostsLeft <= 0) return null;
    _hostSwitches++;
    _retries = 0;
    return const RecoveryStep(RecoveryKind.nextHost, switchDelay);
  }

  RecoveryStep? _variant(RecoveryOptions o) {
    if (!o.live || o.variantsLeft <= 0) return null;
    _variantSwitches++;
    _retries = 0;
    return const RecoveryStep(RecoveryKind.nextVariant, switchDelay);
  }

  RecoveryStep? _engine(RecoveryOptions o) {
    if (!o.canSwitchEngine || _triedEngine) return null;
    _triedEngine = true;
    _retries = 0;
    return const RecoveryStep(RecoveryKind.otherEngine, switchDelay);
  }

  /// Fehler, bei denen dieselbe Quelle sofort wieder scheitert.
  static bool worthRetrying(String message) {
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

  /// HTTP 429/458: der Anbieter bremst wegen zu vieler Anfragen.
  static bool isRateLimited(String message) =>
      StreamError.classify(message).kind == StreamErrorKind.rateLimited;

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

  /// Format/Container nicht erkannt (Analyse zu kurz, unbekanntes Format).
  static bool isFormatError(String message) {
    final m = message.toLowerCase();
    return m.contains('unrecognized file format') ||
        m.contains('invalid data found') ||
        m.contains('unsupported format') ||
        m.contains('container error') ||
        m.contains('could not find codec parameters') ||
        m.contains('no video or audio streams') ||
        m.contains('failed to recognize file format');
  }
}

/// Erfolgreiche Start-Einstellungen je Sender/Film (nur für die Sitzung –
/// die Engine-Wahl merkt sich [EngineMemory] dauerhaft).
class StartProfile {
  /// Vorsichtiger Start (größere Analyse/konservativer Puffer).
  final bool careful;

  /// Software-Dekodierung.
  final bool software;

  /// Gelaufene Variante (Sender-ID), null = die gewählte.
  final String? variantId;

  /// Gelaufene Ersatz-Adresse des Portals (Index), null = die bevorzugte.
  final int? hostIndex;
  const StartProfile({
    this.careful = false,
    this.software = false,
    this.variantId,
    this.hostIndex,
  });

  bool get isDefault =>
      !careful && !software && variantId == null && hostIndex == null;

  @override
  bool operator ==(Object other) =>
      other is StartProfile &&
      other.careful == careful &&
      other.software == software &&
      other.variantId == variantId &&
      other.hostIndex == hostIndex;

  @override
  int get hashCode => Object.hash(careful, software, variantId, hostIndex);

  @override
  String toString() =>
      'StartProfile(careful: $careful, software: $software, '
      'variant: $variantId, host: $hostIndex)';
}

/// Merkt die zuletzt erfolgreiche Start-Stufe je Inhalt (Sitzung).
class StartMemory {
  final _m = <String, StartProfile>{};

  StartProfile of(String? key) =>
      key == null ? const StartProfile() : (_m[key] ?? const StartProfile());

  void remember(String? key, StartProfile p) {
    if (key == null) return;
    if (p.isDefault) {
      _m.remove(key);
    } else {
      _m[key] = p;
    }
  }

  void forget(String? key) {
    if (key != null) _m.remove(key);
  }

  int get length => _m.length;
}
