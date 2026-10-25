import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform_info.dart';
import '../../core/orientation.dart';
import '../../core/aspect.dart';
import '../../core/audio_passthrough.dart';
import '../../core/languages.dart';
import '../../core/security.dart';
import '../../core/stream_errors.dart';
import '../../core/subtitle_style.dart';
import '../../core/theme.dart';
import '../../data/recordings/recordings.dart';
import '../../models/models.dart';
import '../../player/cast.dart';
import '../../player/data_saver.dart';
import '../../player/engine.dart';
import '../../player/engine_choice.dart';
import '../../state/channel_variants.dart';
import '../../state/playback_session.dart';
import '../../state/providers.dart';
import '../../state/shell_tab.dart';
import '../../state/profile_mode.dart'
    show guestModeProvider, visibleLiveDataProvider;
import '../../data/storage.dart';
import '../live/parental.dart';
import '../nav.dart' show replayRequest;
import '../widgets/artwork.dart';
import '../widgets/aspect_picker.dart';
import 'audio_only_badge.dart';
import 'cast_ui.dart';
import 'multiview_screen.dart';
import 'mpv_tuning.dart';
import 'next_episode.dart';
import 'stream_url.dart';
import 'subtitle_delay.dart';
import 'player_debug.dart';
import 'reconnect.dart';
import 'stream_open_headers.dart';
import 'timeshift.dart';
import 'zap_bar.dart';
import '../widgets/common.dart';
import '../widgets/focusable_tile.dart';
import '../tv/tv_focus.dart' show TvTile;
import '../widgets/a11y.dart' show playerButtonSemantics;
import '../../l10n/strings.dart';

export '../../state/playback_session.dart' show canSaveResume;

/// Vollbild-Player.
/// Live: Zappen (▲▼, Wischen, Zifferntasten), Senderliste (◀), Jetzt/Danach.
/// Film/Folge/Catch-up: Spulen (◀▶ ±10 s), Fortsetzen an letzter Stelle.
///
/// Fernbedienung live, Bedienelemente ausgeblendet:
/// * ▲▼ / CH+ CH− schalten sofort um und zeigen die Zapping-Leiste (4 s).
/// * ▶ öffnet die Leiste beim nächsten Sender (Vorschau, ohne Umschalten);
///   solange sie sichtbar ist, blättern ◀▶ durch die Nachbarsender,
///   OK schaltet auf den gezeigten Sender, Zurück/Zeitablauf schließt sie.
/// * ◀ öffnet die Senderliste, OK die Bedienelemente, Info die Leiste.
/// * 0–9 (auch Ziffernblock): Direktwahl, OK bestätigt sofort.
/// * Farbtasten: Rot = Aufnahme, Grün = Favorit, Gelb = Von Anfang,
///   Blau / Guide = TV-Guide.
/// Sichtbare Bedienelemente: erste Pfeiltaste führt hinein (wie bisher).
class PlayerScreen extends ConsumerStatefulWidget {
  final PlayRequest request;

  /// An den laufenden Stream (Mini-Player) anbinden statt neu zu öffnen.
  final bool attach;
  const PlayerScreen({super.key, required this.request, this.attach = false});

  /// Nur für Tests/Bildschirmfotos (ohne echten Player): Live-Pause mit
  /// diesem Rückstand und/oder ein Wiederverbindungs-Hinweis beim Start.
  @visibleForTesting
  static Duration? debugTimeshiftBehind;
  @visibleForTesting
  static String? debugStatus;

  @override
  ConsumerState<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends ConsumerState<PlayerScreen> {
  /// Engine des langlebigen Streams ([PlaybackController]); null, bis die
  /// Einstellungen gelesen sind.
  PlaybackEngine? _player;
  PlaybackSession? _session;

  /// Besitzer des Streams – in initState gelesen, damit dispose ohne `ref`
  /// auskommt.
  late final PlaybackController _ctl;
  // Fängt die Tasten der Fernbedienung; nie selbst Ziel einer Pfeiltaste
  // (sonst landet ▼ aus der oberen Knopfreihe auf dem ganzen Bild statt bei
  // den Knöpfen unten).
  final _focus = FocusNode(debugLabel: "player", skipTraversal: true);
  final _subs = <StreamSubscription>[];

  /// Umschließt die Bedienelemente (nicht selbst fokussierbar).
  final _overlayNode = FocusNode(
      debugLabel: 'player overlay', canRequestFocus: false, skipTraversal: true);

  /// Fernbedienung: Ziel der ersten Pfeiltaste bei sichtbaren Bedienelementen
  /// (Live: Senderliste, Film: Pause/Abspielen).
  final _overlayMain = FocusNode(debugLabel: 'player overlay main');

  late PlayRequest _req = widget.request;
  // _open() läuft (siehe dort) – am Stream gemerkt, damit die Position auch
  // ohne Player-Seite nicht falsch gespeichert wird.
  set _opening(bool v) => _session?.opening = v;
  // „Nächste Folge in 10 s“ (Serienfolgen); neu je Folge.
  var _nextKey = GlobalKey<NextEpisodeHostState>();
  int _index = 0;
  // Vorheriger Sender (Zurück-Taste) und AFR-Zustand
  String? _curChannelId, _prevChannelId;
  double _afrFps = 0;
  bool _overlay = true;
  bool _list = false;
  bool _buffering = true;
  bool _hasVideo = false;
  String? _error;
  Timer? _hideTimer;
  Timer? _saveTimer;
  String _digits = '';
  Timer? _digitTimer;
  AspectMode _aspect = AspectMode.original;

  // Bevorzugte Sprachen (Einstellungen) und ob der Nutzer selbst gewählt hat.
  String _prefAudio = 'auto';
  String _prefSub = 'auto';
  bool _userPickedTracks = false;

  /// Untertitel-Verzögerung (mpv sub-delay); beim nächsten Sender/Film
  /// wieder 0. Ohne Stream (Einstellungen laden noch) nur Anzeige.
  SubtitleDelay? _subDelayLocal;
  SubtitleDelay? get _subDelay => _session?.subDelay ?? _subDelayLocal;

  // Schlaf-Timer
  Timer? _sleepTimer;
  Timer? _sleepTick;
  DateTime? _sleepAt;
  bool _sleepWarning = false;

  /// Handy: Video im Querformat (wie Netflix/YouTube) – auch bei Drehsperre.
  bool _landscape = true;
  bool _tv = false;
  String? _toast;
  IconData? _toastIcon;
  Timer? _toastTimer;

  // Zapping-Leiste: sichtbar? Welcher Sender wird gezeigt (Vorschau)?
  bool _bar = false;
  int _barIndex = 0;
  Timer? _barTimer;

  // ---------- Wiederverbinden / Varianten ----------
  final _recon = ReconnectPolicy();
  final _stall = StallDetector();
  Timer? _retryTimer;
  Timer? _watchTimer;
  Timer? _errorCheck;

  /// Zählt jedes Öffnen; verspätete Antworten älterer Versuche verfallen.
  int _openGen = 0;

  /// Unaufdringlicher Hinweis („Verbindung wird wiederhergestellt…“).
  String? _status;

  /// Live: Varianten des Senders in Abspielreihenfolge, gerade gespielte.
  List<Channel> _variants = const [];
  int _variantPos = 0;

  /// Software-Dekodierung als Notlösung aktiv; ursprünglicher hwdec-Wert
  /// (an der Engine-Instanz gemerkt).
  bool get _swDecode => _session?.swDecode ?? false;
  set _swDecode(bool v) => _session?.swDecode = v;
  String? get _hwdecDefault => _session?.hwdecDefault;

  /// Gewählte „Video-Ausgabe“ (Fernseher) dieser Player-Instanz.
  VideoOutput get _videoOut => _session?.videoOut ?? VideoOutput.standard;

  /// Engine-Eigenschaften dieser Instanz (nur Änderungen gehen raus).
  MpvProps? get _props => _session?.props;

  /// Einstellung „Beim Verlassen“ (Handy/Tablet).
  LeaveAction _leave = LeaveAction.mini;

  /// Beim Schließen der Seite stoppen (Ende, Schlaf-Timer, Guide) statt in
  /// den Mini-Player zu wechseln.
  bool _stopOnPop = false;

  /// Untertitel-Aussehen (Einstellungen) für die Flutter-Untertitel.
  SubtitleStyle _subStyle = const SubtitleStyle();

  /// Diagnose-Anzeige (hwdec, fps, verworfene Bilder, Puffer).
  bool _debugInfo = false;
  bool _infoLong = false;

  /// Film/Folge: Position beim Abbruch (zum Fortsetzen nach Wiederverbinden).
  Duration? _vodResumeAt;

  // Medienserver (Emby): Anfrage mit laufender Sitzung (Start gemeldet, am
  // Stream gemerkt), zuletzt geöffnete Quelle, und für welche Anfrage
  // umgewandelt wird.
  set _remoteReq(PlayRequest? r) => _session?.remoteReq = r;
  RemoteMedia? _remoteMedia;
  PlayRequest? _transcodeFor;
  Duration _lastPos = Duration.zero;

  // ---------- Live-Pause (Timeshift) ----------
  LiveBufferPlan? _bufPlan;
  int _bufferBytes = 48 << 20;
  late final TimeshiftState _ts =
      TimeshiftState(window: Duration.zero, now: DateTime.now());

  /// Vom Nutzer pausiert (dann gilt Stillstand nicht als Hänger).
  bool _userPaused = false;

  bool get _live => _req.isLive;
  bool get _replay => _req.isReplay;
  List<Channel> get _channels => _req.channels ?? const [];

  @override
  void initState() {
    super.initState();
    _ctl = ref.read(playbackProvider.notifier);
    _portraitBefore = AppOrientation.wasPortraitBefore();
    if (_req.channel != null) {
      _index = _channels.indexWhere((c) => c.id == _req.channel!.id);
      if (_index < 0) _index = 0;
    }
    final dbgShift = PlayerScreen.debugTimeshiftBehind;
    if (dbgShift != null) {
      final now = DateTime.now();
      _ts.window = const Duration(minutes: 10);
      _ts.reset(now.subtract(const Duration(minutes: 10)));
      _ts.sync(dbgShift, now);
    }
    _status = PlayerScreen.debugStatus;
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    // Fernbedienung: Fokus sicher in den Player holen, auch wenn darunter
    // liegende Listen gerade (per autofocus) Fokus anfordern.
    WidgetsBinding.instance.addPostFrameCallback((_) => _grabFocus());
    FocusManager.instance.addListener(_keepFocus);
    _init();
  }

  void _grabFocus() {
    if (mounted && !_list) _focus.requestFocus();
  }

  /// Fokus verloren (z. B. fokussierter Knopf verschwunden, Senderliste
  /// mit Zurück geschlossen) → zurück in den Player, sonst kommen die
  /// Tasten der Fernbedienung (Zappen, OK) nicht mehr an.
  void _keepFocus() {
    if (!mounted) return;
    final f = FocusManager.instance.primaryFocus;
    final route = ModalRoute.of(context);
    if (route == null || !route.isCurrent) return;
    final c = f?.context;
    final lost = f == null ||
        (f is FocusScopeNode &&
            (c == null || !c.mounted || ModalRoute.of(c) == route));
    if (!lost) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !(ModalRoute.of(context)?.isCurrent ?? false)) return;
      final now = FocusManager.instance.primaryFocus;
      if (now == null || now is FocusScopeNode) _grabFocus();
    });
  }

  /// Erste Pfeiltaste bei sichtbaren Bedienelementen: Fokus hinein (sonst
  /// sind sie mit der Fernbedienung nicht erreichbar – der Player selbst
  /// füllt den ganzen Bildschirm).
  bool _enterOverlay(LogicalKeyboardKey k) {
    if (_overlayMain.context != null && _overlayMain.canRequestFocus) {
      _overlayMain.requestFocus();
      return true;
    }
    final cands = _overlayNode.traversalDescendants
        .where((n) => n.context != null && n.canRequestFocus && !n.skipTraversal)
        .toList();
    if (cands.isEmpty) return false;
    double key(FocusNode n) => switch (k) {
          LogicalKeyboardKey.arrowDown => n.rect.top,
          LogicalKeyboardKey.arrowUp => -n.rect.bottom,
          LogicalKeyboardKey.arrowLeft => -n.rect.right,
          _ => n.rect.left,
        };
    cands.sort((a, b) => key(a).compareTo(key(b)));
    cands.first.requestFocus();
    return true;
  }

  Future<void> _init() async {
    final storage = await ref.read(storageProvider.future);
    final buffer = switch (storage.option('buffer', 'normal')) {
      'klein' => 16,
      'gross' => 128,
      _ => 48,
    };
    _bufferBytes = buffer * 1024 * 1024;
    _aspect = _resolveAspect(storage);
    _prefAudio = storage.option('alang', 'auto');
    _prefSub = storage.option('slang', 'auto');
    _tv = ref.read(isTvProvider);
    _landscape = storage.flag('playerlandscape', fallback: true);
    await _applyOrientation();
    await _planLiveBuffer();
    _subStyle = SubtitleStyle.fromOptions(storage.option);
    _debugInfo = storage.flag(PlayerDebugInfo.flagKey);
    _leave = _tv
        ? LeaveAction.stop
        : LeaveAction.fromId(storage.option(LeaveAction.optionKey, 'mini'));
    // Laufender Stream (Mini-Player) mit derselben Adresse → anbinden statt
    // neu zu öffnen.
    final existing = _ctl.session;
    final reuse = existing != null &&
        (widget.attach ||
            (existing.request.url == widget.request.url &&
                existing.request.isLive == widget.request.isLive &&
                (existing.request.channel?.id == widget.request.channel?.id)));
    final PlaybackSession session;
    if (reuse) {
      session = existing;
    } else {
      // Fernseher: „Video-Ausgabe“ (Standard / Hardware direkt / Kompatibel).
      final out = _tv
          ? VideoOutput.fromId(
              storage.option(VideoOutput.optionKey, 'standard'))
          : VideoOutput.standard;
      final (vo, hwdec) = out.controller;
      session = await _ctl.start(
        widget.request,
        videoOut: out,
        config: EngineConfig(
          engine: _engineFor(widget.request, storage).id,
          bufferBytes: buffer * 1024 * 1024,
          vo: vo,
          hwdec: hwdec,
          hardwareAcceleration: storage.flag('hwdec', fallback: true),
        ),
      );
    }
    if (!mounted) {
      if (!reuse) unawaited(_ctl.stop());
      return;
    }
    _session = session;
    _bindEngine(session.engine);
    final p = session.engine;
    _stopOnPop = false;
    _ctl.toFullscreen();
    _ctl.zapHandler = (dir) => _zapTo(_index + dir, bar: !_overlay);
    if (!reuse) {
      await _tuneForFastStart(p);
      session.hwdecDefault ??= await p.getOption('hwdec');
    }
    if (!mounted) return;
    setState(() => _player = p);
    await PlatformInfo.setAutoPip(storage.flag('autopip', fallback: true));
    if (reuse) {
      _resumeFromSession(session);
    } else {
      await _open();
    }
    // Seite inzwischen geschlossen (z. B. während auf die Länge gewartet
    // wurde) → keine Timer mehr anlegen.
    if (!mounted) return;
    _saveTimer =
        Timer.periodic(const Duration(seconds: 10), (_) => _savePosition());
    _watchTimer =
        Timer.periodic(const Duration(seconds: 1), (_) => _watch());
  }

  /// Auf Ereignisse der Engine hören (beim Start und nach einem
  /// Engine-Wechsel).
  void _bindEngine(PlaybackEngine p) {
    for (final x in _subs) {
      x.cancel();
    }
    _subs.clear();
    _subs.addAll([
      p.stream.failure.listen(_onEngineFailure),
      p.stream.buffering.listen((b) => _set(() => _buffering = b)),
      p.stream.width.listen((w) {
        final has = (w ?? 0) > 0;
        _set(() => _hasVideo = has);
        // Läuft wieder → Standort-Vermerk entfernen.
        if (has) _setUnavailable(false);
        if (has) _matchFrameRate();
      }),
      p.stream.error.listen(_onStreamError),
      p.stream.tracks.listen((_) => _applyPreferredTracks()),
      p.stream.completed.listen((done) {
        if (!done || !mounted) return;
        if (_live) {
          // Live-Stream zu Ende = Verbindung weg → still neu verbinden.
          if (_error == null && _retryTimer == null) {
            _failure(FailureKind.stall, 'eof');
          }
          return;
        }
        // Replay: nahtlos zur nächsten Sendung bzw. zurück zu Live.
        if (_replay) {
          _replayStep(1, endOfShow: true);
        } else if (!(_nextKey.currentState?.onCompleted() ?? false)) {
          _closeAndStop();
        }
      }),
    ]);
  }

  // ---------- Engine (ExoPlayer / mpv) ----------
  /// Engine-Wechsel läuft (Fehler der alten Engine nicht mehr auswerten).
  bool _switching = false;

  /// Schlüssel zum Merken der Engine für den laufenden Sender/Film.
  String? _engineKey([PlayRequest? req]) => engineMemoryKey(req ?? _req,
      portalId: ref.read(activePortalProvider).value?.id);

  /// Eingestellte Engine, außer der Inhalt lief schon einmal nur mit mpv.
  EngineKind _engineFor(PlayRequest req, Storage? st) {
    final exo = ref.read(exoAvailableProvider);
    final pref = preferredEngine(st, exoAvailable: exo);
    if (pref == EngineKind.exo &&
        ref.read(engineMemoryProvider.notifier).prefersMpv(_engineKey(req))) {
      return EngineKind.mpv;
    }
    return pref;
  }

  /// Läuft gerade ExoPlayer bzw. mpv? (null = andere/Fake-Engine)
  EngineKind? get _currentEngine => switch (_player?.id) {
        'exo' => EngineKind.exo,
        'mpv' => EngineKind.mpv,
        _ => null,
      };

  /// ExoPlayer scheitert an Decoder/Format/Container → gleiche Adresse mit
  /// mpv an derselben Stelle (Netzfehler laufen über das Wiederverbinden).
  void _onEngineFailure(EngineError e) {
    if (!mounted || _switching || !e.kind.wantsCompat) return;
    if (_currentEngine != EngineKind.exo) return;
    _errorCheck?.cancel();
    _errorCheck = null;
    unawaited(_switchEngine(EngineKind.mpv, auto: true));
  }

  /// Engine tauschen und denselben Stream an derselben Stelle neu öffnen.
  /// [auto]: Rückfall nach Fehler (Hinweis „Kompatibilitätsmodus“, Sender
  /// dauerhaft merken).
  Future<void> _switchEngine(EngineKind to, {bool auto = false}) async {
    final cur = _player;
    if (cur == null || _switching || !mounted) return;
    _switching = true;
    try {
      _openGen++;
      _errorCheck?.cancel();
      _errorCheck = null;
      _retryTimer?.cancel();
      _retryTimer = null;
      final pos = cur.state.position > _lastPos ? cur.state.position : _lastPos;
      if (!_live && pos > const Duration(seconds: 1)) _vodResumeAt = pos;
      final key = _engineKey();
      final mem = ref.read(engineMemoryProvider.notifier);
      if (to == EngineKind.mpv) {
        await mem.rememberMpv(key, persist: auto && _live);
      } else {
        await mem.forget(key);
      }
      final s = await _ctl.swapEngine(to.id);
      if (s == null || !mounted) return;
      _session = s;
      _bindEngine(s.engine);
      await _tuneForFastStart(s.engine);
      s.hwdecDefault ??= await s.engine.getOption('hwdec');
      if (!mounted) return;
      setState(() {
        _player = s.engine;
        _error = null;
      });
      _ctl.zapHandler = (dir) => _zapTo(_index + dir, bar: !_overlay);
      _showToast(
          auto
              ? tr('Kompatibilitätsmodus (mpv)')
              : trf('Player-Engine: {0}', [to.label]),
          icon: Icons.swap_horiz_rounded);
      _opening = true;
      await _open(recover: true);
    } finally {
      _switching = false;
    }
  }

  /// Vor dem Öffnen eines neuen Inhalts: passende Engine (Einstellung bzw.
  /// gemerkter Rückfall) – sonst tauschen.
  Future<void> _ensureEngine() async {
    final cur = _currentEngine;
    if (cur == null) return;
    final st = ref.read(storageProvider).value;
    final want = _engineFor(_req, st);
    if (want == cur) return;
    final s = await _ctl.swapEngine(want.id);
    if (s == null || !mounted) return;
    _session = s;
    _bindEngine(s.engine);
    await _tuneForFastStart(s.engine);
    s.hwdecDefault ??= await s.engine.getOption('hwdec');
    if (!mounted) return;
    setState(() => _player = s.engine);
    _ctl.zapHandler = (dir) => _zapTo(_index + dir, bar: !_overlay);
  }

  /// ⋮-Menü „Player-Engine wechseln“.
  VoidCallback? get _engineSwitch {
    final cur = _currentEngine;
    if (cur == null || !ref.read(exoAvailableProvider)) return null;
    return () => _switchEngine(cur.other);
  }

  /// Zurück aus dem Mini-Player: Zustand des laufenden Streams übernehmen,
  /// nichts neu öffnen.
  void _resumeFromSession(PlaybackSession s) {
    final st = s.engine.state;
    setState(() {
      _req = s.request;
      _index = s.index;
      _buffering = st.buffering;
      _hasVideo = st.hasVideo;
      _error = null;
      _userPaused = !st.playing && !st.buffering;
      _variants = const [];
      _variantPos = 0;
    });
    _curChannelId = _live && _channels.isNotEmpty ? _channels[_index].id : null;
    final sleep = _ctl.sleepAt;
    if (sleep != null) _armSleepUi(sleep);
    _grabFocus();
    _showOverlay();
  }

  /// Live-Puffer (Timeshift) nach Einstellung und freiem Arbeitsspeicher.
  Future<void> _planLiveBuffer() async {
    final minutes = ref.read(liveBufferProvider);
    MemInfo? mem;
    if (minutes > 0) mem = await PlatformInfo.memoryInfo();
    _bufPlan = planLiveBuffer(minutes, mem);
    _ts.window = _bufPlan?.window ?? Duration.zero;
  }

  /// Fehlermeldung von mpv. Nicht jede ist fatal (z. B. kurzer
  /// Verbindungsabbruch, den ffmpeg selbst überbrückt): kurz prüfen, ob die
  /// Wiedergabe weiterläuft, sonst still wiederverbinden.
  void _onStreamError(String e) {
    final msg = Redactor.redact(e);
    if (!mounted || _switching || _error != null || _retryTimer != null) return;
    if (_userPaused) return; // Hänger zeigt sich beim Weiterspielen
    final pos = _player?.state.position ?? Duration.zero;
    final gen = _openGen;
    _errorCheck?.cancel();
    _errorCheck = Timer(const Duration(milliseconds: 1500), () {
      _errorCheck = null;
      if (!mounted || gen != _openGen || _error != null) return;
      final now = _player?.state.position ?? Duration.zero;
      if (now > pos) return; // läuft weiter
      _failure(FailureKind.error, msg);
    });
  }

  /// Merkt sich (oder löscht), dass der Live-Sender am Standort gesperrt ist.
  void _setUnavailable(bool on) {
    if (!_live || _channels.isEmpty) return;
    final id = _channels[_index].id;
    final flags = ref.read(channelFlagsProvider).value;
    if (flags == null || flags.unavailable.contains(id) == on) return;
    ref.read(channelFlagsProvider.notifier).setUnavailable(id, on);
  }

  // ---------- Multiview ----------
  Future<void> _openMultiview() async {
    if (_channels.isEmpty) return;
    // Eigenen Decoder freigeben, damit die Box genug für 2–4 Bilder hat.
    await _player?.stop();
    if (!mounted) return;
    final pick = await Navigator.of(context).push<Channel>(MaterialPageRoute(
        builder: (_) => MultiviewScreen(
            channels: _channels, first: _channels[_index])));
    if (!mounted) return;
    await _applyOrientation();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    final i = pick == null ? -1 : _channels.indexWhere((c) => c.id == pick.id);
    if (i >= 0 && i != _index) {
      await _zapTo(i);
    } else {
      await _open();
    }
  }

  // ---------- Sprachen ----------
  void _applyPreferredTracks() {
    final p = _player;
    if (p == null || _userPickedTracks) return;
    final t = p.state.tracks;
    final audio = [
      for (final a in t.audio) (id: a.id, language: a.language, title: a.title)
    ];
    final ai = pickTrack(audio, _prefAudio);
    if (ai != null && ai >= 0 && t.audio[ai] != p.state.track.audio) {
      p.setAudioTrack(t.audio[ai]);
    }
    final subs = [
      for (final x in t.subtitle) (id: x.id, language: x.language, title: x.title)
    ];
    final si = pickTrack(subs, _prefSub, allowOff: true);
    if (si == -1) {
      if (!p.state.track.subtitle.isOff) {
        p.setSubtitleTrack(EngineTrack.no);
      }
    } else if (si != null && t.subtitle[si] != p.state.track.subtitle) {
      p.setSubtitleTrack(t.subtitle[si]);
    }
  }

  // ---------- Schlaf-Timer ----------
  Future<void> _pickSleep() async {
    final options = <(String, Duration?)>[
      (tr('Aus'), null),
      (tr('15 Minuten'), const Duration(minutes: 15)),
      (tr('30 Minuten'), const Duration(minutes: 30)),
      (tr('45 Minuten'), const Duration(minutes: 45)),
      (tr('1 Stunde'), const Duration(hours: 1)),
      (tr('1½ Stunden'), const Duration(minutes: 90)),
      (tr('2 Stunden'), const Duration(hours: 2)),
    ];
    final remaining = _sleepAt?.difference(DateTime.now());
    final picked = await showModalBottomSheet<int>(
      context: context,
      constraints: const BoxConstraints(maxWidth: 480),
      builder: (ctx) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          ListTile(
            title: Text(tr('Schlaf-Timer')),
            subtitle: Text(remaining == null
                ? tr('Wiedergabe stoppt automatisch nach der gewählten Zeit')
                : trf('Läuft noch {0} Min.', [remaining.inMinutes + 1])),
          ),
          for (var i = 0; i < options.length; i++)
            ListTile(
              autofocus: i == 0,
              leading: Icon(i == 0
                  ? Icons.timer_off_outlined
                  : Icons.bedtime_outlined),
              title: Text(options[i].$1),
              onTap: () => Navigator.pop(ctx, i),
            ),
        ]),
      ),
    );
    _grabFocus();
    if (picked == null) return;
    _setSleep(options[picked].$2);
  }

  void _setSleep(Duration? d) {
    _sleepTimer?.cancel();
    _sleepTick?.cancel();
    final at = d == null ? null : DateTime.now().add(d);
    setState(() {
      _sleepWarning = false;
      _sleepAt = at;
    });
    // Gilt auch im Mini-Player (stoppt dort den Stream).
    _ctl.setSleep(at);
    if (d == null) {
      _showToast(tr('Schlaf-Timer aus'));
      return;
    }
    _showToast(trf('Schlaf-Timer: {0} Min.', [d.inMinutes]));
    _armSleepUi(at!);
  }

  /// Warnung 60 s vor dem Stopp, dann Seite schließen (Stream stoppt).
  void _armSleepUi(DateTime at) {
    _sleepTimer?.cancel();
    _sleepTick?.cancel();
    _sleepAt = at;
    final warnAt = at.difference(DateTime.now()) - const Duration(seconds: 60);
    _sleepTimer = Timer(warnAt.isNegative ? Duration.zero : warnAt, () {
      _set(() => _sleepWarning = true);
      _sleepTick = Timer.periodic(const Duration(seconds: 1), (t) {
        if (_sleepAt == null) return t.cancel();
        if (DateTime.now().isAfter(_sleepAt!)) {
          t.cancel();
          _player?.pause();
          _closeAndStop();
        } else {
          _set(() {});
        }
      });
    });
  }

  /// Seite schließen und den Stream beenden (kein Mini-Player).
  void _closeAndStop() {
    if (!mounted) return;
    // Erst neu bauen (PopScope darf jetzt schließen), dann zurück.
    setState(() => _stopOnPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).maybePop();
    });
  }

  /// Nur-Ton an/aus (Video abwählen; Ton läuft weiter).
  Future<void> _toggleAudioOnly() async {
    final on = !(_session?.audioOnly ?? false);
    await _ctl.setAudioOnly(on);
    _set(() {});
    _showToast(on ? tr('Nur Ton') : tr('Video wieder an'),
        icon: on ? Icons.headphones_rounded : Icons.videocam_rounded);
  }

  bool get _audioOnly => _session?.audioOnly ?? false;

  // ---------- Ausrichtung ----------
  /// Ausrichtung beim Öffnen (für das Zurückdrehen beim Schließen).
  bool _portraitBefore = true;

  Future<void> _applyOrientation() async {
    if (_tv) return; // Fernseher ist immer quer
    await SystemChrome.setPreferredOrientations(_landscape
        ? const [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]
        : const []); // [] = frei, folgt dem Drehen des Handys
  }

  Future<void> _toggleOrientation() async {
    setState(() => _landscape = !_landscape);
    _showToast(_landscape ? tr('Querformat') : tr('Drehen frei (folgt dem Handy)'));
    await _applyOrientation();
    final st = await ref.read(storageProvider.future);
    await st.setFlag('playerlandscape', _landscape);
  }

  // ---------- Bildformat ----------
  /// Sender (live oder Replay), für den ein Format gemerkt werden kann.
  Channel? get _aspectChannel => _live
      ? (_channels.isEmpty ? null : _channels[_index])
      : _req.channel;

  AspectMode _resolveAspect(Storage st) {
    final portal = ref.read(activePortalProvider).value;
    final c = _aspectChannel;
    if (portal != null && c != null) {
      final m = st.channelAspect(portal.id, c.id);
      if (m != null) return m;
    }
    return st.defaultAspect();
  }

  Future<void> _applyAspect(AspectMode m, {required bool remember}) async {
    setState(() => _aspect = m);
    _showToast(trf('Bildformat: {0}', [m.label]));
    final st = await ref.read(storageProvider.future);
    final portal = ref.read(activePortalProvider).value;
    final c = _aspectChannel;
    if (remember && portal != null && c != null) {
      await st.setChannelAspect(portal.id, c.id, m);
    }
  }

  void _cycleAspect() =>
      _applyAspect(_aspect.next, remember: _aspectChannel != null);

  Future<void> _pickAspect() async {
    final c = _aspectChannel;
    final r = await showAspectPicker(context, _aspect,
        rememberLabel: c == null ? null : trf('Für „{0}“ merken', [c.name]));
    _grabFocus();
    if (r == null) return;
    await _applyAspect(r.$1, remember: r.$2);
  }

  void _showToast(String text, {IconData? icon}) {
    _toastTimer?.cancel();
    _set(() {
      _toast = text;
      _toastIcon = icon;
    });
    _toastTimer = Timer(const Duration(milliseconds: 1600),
        () => _set(() => _toast = null));
  }

  /// Schneller Senderstart: nicht warten, bis der Puffer voll ist, bevor
  /// das Bild kommt; feste Optionen einmal je Player-Instanz.
  Future<void> _tuneForFastStart(PlaybackEngine p) async {
    if (!p.supportsOptions) return;
    final props = _props;
    if (props == null) return;
    await props.apply(MpvTuning.constant);
  }

  void _set(VoidCallback f) {
    if (mounted) setState(f);
  }

  void _leaveForCast() {
    final route = ModalRoute.of(context);
    if (route == null) return;
    if (route.isCurrent) {
      Navigator.of(context).pop();
    } else {
      Navigator.of(context).removeRoute(route);
    }
  }

  Future<void> _toggleDebugInfo() async {
    final on = !_debugInfo;
    _set(() => _debugInfo = on);
    final st = ref.read(storageProvider).value;
    await st?.setFlag(PlayerDebugInfo.flagKey, on);
  }

  @override
  void dispose() {
    if (_afrFps > 0) PlatformInfo.setFrameRate(0);
    _savePosition();
    final s = _session;
    final ctl = _ctl;
    // Handy/Tablet: Zurück lässt den Stream im Mini-Player weiterlaufen –
    // außer bei Fehler, Ende, Schlaf-Timer, Einstellung „Stopp“/„PiP“.
    // Läuft auf einem Cast-Gerät: immer weiter (Mini-Player „Läuft auf …“).
    final keep = s != null &&
        identical(ctl.session, s) &&
        !_tv &&
        (ctl.casting ||
            (!_stopOnPop && _error == null && _leave == LeaveAction.mini));
    // Nicht mitten im Abbau des Baums am Provider drehen.
    if (keep) {
      scheduleMicrotask(ctl.toMini);
    } else if (s != null && identical(ctl.session, s)) {
      scheduleMicrotask(() => ctl.stop());
    }
    _hideTimer?.cancel();
    _saveTimer?.cancel();
    _digitTimer?.cancel();
    _barTimer?.cancel();
    _toastTimer?.cancel();
    _sleepTimer?.cancel();
    _sleepTick?.cancel();
    _retryTimer?.cancel();
    _watchTimer?.cancel();
    _subDelayLocal?.dispose();
    _errorCheck?.cancel();
    for (final x in _subs) {
      x.cancel();
    }
    FocusManager.instance.removeListener(_keepFocus);
    _focus.dispose();
    _overlayNode.dispose();
    _overlayMain.dispose();
    PlatformInfo.setAutoPip(false);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    // Außerhalb des Players wieder wie vorher (Hochformat zuerst, dann frei).
    AppOrientation.restore(portraitBefore: _portraitBefore, tv: _tv);
    super.dispose();
  }

  /// [quiet]: nach dem Zappen per Leiste nicht die Bedienelemente zeigen.
  /// [recover]: stiller Wiederverbindungsversuch (gleicher Sender, ggf.
  /// andere Variante) – kein Verlauf, keine Bedienelemente, Zähler bleiben.
  Future<void> _open({bool quiet = false, bool recover = false}) async {
    if (_player == null) return;
    var gen = ++_openGen;
    if (!recover && !_switching) {
      // Neuer Inhalt: gemerkter Rückfall (mpv) bzw. wieder die Einstellung.
      await _ensureEngine();
      if (gen != _openGen || !mounted) return;
      gen = ++_openGen;
    }
    final p = _player;
    if (p == null) return;
    // Bis der neue Stream läuft (und ggf. an die gemerkte Stelle gesprungen
    // ist), keine Position speichern – sonst landet z. B. beim Wechsel zur
    // nächsten Folge die Abspann-Position der alten unter der neuen.
    if (!recover) _opening = true;
    _errorCheck?.cancel();
    _errorCheck = null;
    if (!recover) {
      _retryTimer?.cancel();
      _retryTimer = null;
      _recon.reset();
      _vodResumeAt = null;
      _variants = _live && _channels.isNotEmpty
          ? playOrderFor(ref, _channels[_index])
          : const [];
      _variantPos = 0;
      if (_swDecode) await _setHwdec(true);
      // Vorige Medienserver-Sitzung (z. B. Folge davor) beenden.
      _endRemote();
    }
    _stall.reset();
    _ts.reset(DateTime.now());
    _userPaused = false;
    _lastPos = Duration.zero;
    setState(() {
      _error = null;
      _buffering = true;
      _hasVideo = false;
      if (!recover) _status = null;
    });
    final st = await ref.read(storageProvider.future);
    if (gen != _openGen) return;
    // Untertitel-Aussehen bei jedem Öffnen lesen (geänderte Einstellung
    // greift beim nächsten Sender).
    final sub = SubtitleStyle.fromOptions(st.option);
    _set(() {
      _aspect = _resolveAspect(st);
      _subStyle = sub;
    });
    if (!recover) {
      _userPickedTracks = false;
      // Untertitel-Verzögerung gilt nur für den vorigen Sender/Film.
      await _subDelay?.reset();
      if (gen != _openGen) return;
    }
    final playing = _playingChannel;
    var url = _live ? playing!.streamUrl : _req.url;
    // Medienserver: Abspieladresse jetzt holen (Direkt oder umgewandelt).
    final remote = _live ? null : _req.remote;
    RemoteMedia? media;
    if (remote != null) {
      try {
        media = await remote.resolve(transcode: identical(_transcodeFor, _req));
      } catch (e) {
        if (gen != _openGen) return;
        setState(() {
          _buffering = false;
          _status = null;
          _error = Redactor.friendly(e);
        });
        return;
      }
      if (gen != _openGen) return;
      url = media.url;
      _remoteMedia = media;
    }
    if (_live && !recover) {
      final cur = _channels[_index].id;
      if (_curChannelId != null && _curChannelId != cur) {
        _prevChannelId = _curChannelId;
      }
      _curChannelId = cur;
      ref.read(recentProvider.notifier).push(cur);
    }
    _afrFps = 0;
    if (_live) {
      // MAC-Portale erzeugen die Abspieladresse erst jetzt (kurzlebig);
      // Xtream/M3U brauchen dafür keinen fertigen Login.
      try {
        url = await resolveLiveUrl(
          playing!,
          portal: ref.read(activePortalProvider).value,
          current: ref.read(repositoryProvider),
          repo: () => ref.read(repositoryProvider.future),
        );
      } catch (e) {
        if (gen != _openGen) return;
        // Auch das Anfordern der Adresse kann vorübergehend scheitern.
        _failure(FailureKind.error, Redactor.friendly(e));
        return;
      }
      if (gen != _openGen) return;
    }
    if (!UrlPolicy.isStream(url)) {
      setState(() {
        _buffering = false;
        _status = null;
        _error = tr('Diese Stream-Adresse wurde aus Sicherheitsgründen blockiert.');
      });
      return;
    }
    final portal = ref.read(activePortalProvider).value;
    final headers = remote != null
        ? playerHeadersFor(null, null)
        : playerHeadersFor(portal, _live ? playing : _req.channel);
    await _applyStreamOptions(p, headers, st, sub);
    if (gen != _openGen) return;
    // Für die Übergabe an ein Cast-Gerät (Adresse bleibt im Speicher).
    if (identical(_ctl.session?.engine, p)) _ctl.noteSource(url, headers);
    await p.open(url,
        headers: headers,
        live: _live,
        // Externe Untertitel des Medienservers (ohne sie zu wählen – die
        // bevorzugte Sprache wählt [_applyPreferredTracks]).
        subtitles: [
          for (final s in media?.subtitles ?? const <RemoteSubtitle>[])
            EngineSubtitle(s.url,
                title: s.title ?? s.language ?? tr('Untertitel'),
                language: s.language),
        ]);
    if (gen != _openGen) return;
    // Nur-Ton bleibt über den Senderwechsel hinweg an.
    if (_audioOnly) await p.setVideoEnabled(false);

    final storage = await ref.read(storageProvider.future);
    if (gen != _openGen) return;
    if (_live) {
      if (portal != null && !recover) {
        await storage.setLastChannel(portal.id, _channels[_index].id);
      }
    } else if (recover && _vodResumeAt != null) {
      // Nach dem Wiederverbinden an der alten Stelle weiter.
      final at = _vodResumeAt!;
      await p.stream.duration
          .firstWhere((d) => d > Duration.zero,
              // Engine inzwischen freigegeben (Wechsel/Stopp).
              orElse: () => Duration.zero)
          .timeout(const Duration(seconds: 15), onTimeout: () => Duration.zero);
      if (gen != _openGen || !identical(_ctl.session?.engine, p)) return;
      await p.seek(at);
    } else if (_req.resumeKey != null && !recover) {
      final local = storage.resume(_req.resumeKey!);
      // Medienserver: ohne lokalen Stand die Position des Servers.
      final serverAt = media?.startAt;
      final r = local ??
          (serverAt != null && !storage.isWatched(_req.resumeKey!)
              ? (pos: serverAt.inSeconds, total: 0)
              : null);
      if (r != null && r.pos > 15) {
        // Warten, bis die Länge bekannt ist, dann springen.
        await p.stream.duration
            .firstWhere((d) => d > Duration.zero,
              // Engine inzwischen freigegeben (Wechsel/Stopp).
              orElse: () => Duration.zero)
            .timeout(const Duration(seconds: 15), onTimeout: () => Duration.zero);
        if (gen != _openGen || !identical(_ctl.session?.engine, p)) return;
        await p.seek(Duration(seconds: r.pos));
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            duration: const Duration(seconds: 4),
            content: Text(trf('Fortgesetzt bei {0}', [fmtClock(Duration(seconds: r.pos))])),
            action: SnackBarAction(
                label: tr('Von vorne'), onPressed: () => p.seek(Duration.zero)),
          ));
        }
      }
    }
    _opening = false;
    if (remote != null && !recover && gen == _openGen) {
      _remoteReq = _req;
      unawaited(remote.started(p.state.position));
    }
    if (recover) return;
    // Mit einem Cast-Gerät verbunden: neuer Inhalt läuft gleich dort.
    if (gen == _openGen) unawaited(_ctl.followCast());
    _grabFocus();
    if (!quiet) _showOverlay();
  }

  /// Live: gerade gespielte Variante (sonst der Sender selbst).
  Channel? get _playingChannel {
    if (!_live || _channels.isEmpty) return null;
    if (_variants.isEmpty) return _channels[_index];
    return _variants[_variantPos.clamp(0, _variants.length - 1)];
  }

  /// Kopfzeilen, Puffer, Untertitel und Ton für den nächsten Stream –
  /// nur was sich seit dem letzten Öffnen geändert hat, geht an mpv.
  Future<void> _applyStreamOptions(PlaybackEngine p, Map<String, String> headers,
      Storage st, SubtitleStyle sub) async {
    final props = _props;
    if (props == null) return;
    await props.apply(MpvTuning.perOpen(
      live: _live,
      plan: _live ? _bufPlan : null,
      bufferBytes: _bufferBytes,
      userAgent: headerValue(headers, 'User-Agent') ?? '',
      referrer: headerValue(headers, 'Referer') ?? '',
      subtitles: sub,
      passthrough: AudioPassthrough.enabled(st), // Dolby/DTS an Receiver
      dataSaver: ref.read(dataSaverActiveProvider),
    ));
  }

  Future<void> _setHwdec(bool hardware) async {
    final pl = _player;
    if (pl == null || !pl.supportsOptions) return;
    // „Hardware direkt“ (vo=mediacodec_embed) zeigt nur Bilder des
    // Hardware-Dekoders – Software-Dekodierung gäbe dort ein Schwarzbild.
    if (!_videoOut.allowsSoftwareFallback) return;
    try {
      await pl.setOption(
          'hwdec', hardware ? (_hwdecDefault ?? 'auto-safe') : 'no');
      _swDecode = !hardware;
    } catch (_) {}
  }

  // ---------- Wiederverbinden ----------
  void _setStatus(String? text) => _set(() {
        _status = text;
        if (text != null) {
          _error = null;
          _buffering = true;
        }
      });

  void _schedule(Duration d, Future<void> Function() f) {
    _retryTimer?.cancel();
    final gen = _openGen;
    _retryTimer = Timer(d, () {
      _retryTimer = null;
      if (!mounted || gen != _openGen) return;
      f();
    });
  }

  /// Störung: still neu verbinden, Variante wechseln, Software-Dekodierung –
  /// erst wenn nichts hilft, die Fehlermeldung zeigen.
  void _failure(FailureKind kind, String? msg) {
    final p = _player;
    if (!mounted || p == null) return;
    _errorCheck?.cancel();
    _errorCheck = null;
    _stall.reset();
    if (!_live) {
      final pos = p.state.position > _lastPos ? p.state.position : _lastPos;
      if (pos > const Duration(seconds: 1)) _vodResumeAt = pos;
    }
    final left = _live && _variants.isNotEmpty
        ? _variants.length - 1 - _variantPos
        : 0;
    final step = _recon.onFailure(
        kind: kind,
        message: msg == 'eof' ? null : msg,
        live: _live,
        variantsLeft: left);
    switch (step.kind) {
      case RecoveryKind.retry:
        _setStatus(tr('Verbindung wird wiederhergestellt …'));
        _schedule(step.delay, () => _open(recover: true));
      case RecoveryKind.nextVariant:
        _variantPos++;
        _setStatus(trf('Wechsle auf {0}', [_variants[_variantPos].name]));
        _schedule(const Duration(milliseconds: 400),
            () => _open(recover: true));
      case RecoveryKind.softwareDecode:
        _setStatus(tr('Software-Dekodierung wird versucht …'));
        _schedule(const Duration(milliseconds: 400), () async {
          await _setHwdec(false);
          await _open(recover: true);
        });
      case RecoveryKind.giveUp:
        // Medienserver: Originaldatei geht nicht → umgewandelt versuchen.
        if (!_live &&
            _req.remote != null &&
            _remoteMedia != null &&
            !_remoteMedia!.transcoding &&
            !identical(_transcodeFor, _req)) {
          _transcodeFor = _req;
          _recon.reset();
          _setStatus(tr('Wird für dieses Gerät umgewandelt …'));
          _schedule(const Duration(milliseconds: 400),
              () => _open(recover: true));
          return;
        }
        _retryTimer?.cancel();
        _retryTimer = null;
        final text = msg == null || msg == 'eof'
            ? tr('Die Verbindung zum Sender ist abgebrochen.')
            : msg;
        _set(() {
          _status = null;
          _error = text;
          _buffering = false;
        });
        if (msg != null && StreamError.classify(msg).isLocationRelated) {
          _setUnavailable(true);
        }
    }
  }

  /// Sekündlich: Hänger erkennen, gute Wiedergabe vermerken, Timeshift-
  /// Anzeige aktualisieren.
  void _watch() {
    final p = _player;
    if (p == null || !mounted) return;
    // Andere Seite (Multiview, Auswahl) im Vordergrund: nicht prüfen.
    if (!(ModalRoute.of(context)?.isCurrent ?? false)) return;
    final now = DateTime.now();
    final pos = p.state.position;
    if (pos > _lastPos) {
      _recon.markGood(now);
      if (_status != null && _retryTimer == null) _setStatus(null);
    }
    _lastPos = pos;
    final waiting =
        _error != null || _retryTimer != null || _errorCheck != null;
    if (_stall.sample(pos, now, active: !waiting && p.state.playing)) {
      _failure(FailureKind.stall, null);
      return;
    }
    if (_live && _ts.isShifted(now)) {
      _syncTimeshift();
      _set(() {});
    }
  }

  /// Medienserver-Sitzung beenden (Ende melden).
  void _endRemote() => _ctl.endRemote(_session);

  /// Position merken und Medienserver-Fortschritt melden (alle 10 s und
  /// beim Schließen) – über den Stream-Besitzer, damit es auch im
  /// Mini-Player weiter stimmt.
  void _savePosition() => _ctl.saveResume(_session);

  void _showOverlay() {
    _barTimer?.cancel();
    _set(() {
      _overlay = true;
      _bar = false;
    });
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 5), () {
      if (!_list) _set(() => _overlay = false);
    });
  }

  void _toggleOverlay() => _overlay ? _set(() => _overlay = false) : _showOverlay();

  // ---------- Vorheriger Sender ----------
  void _zapBack() {
    final id = _prevChannelId;
    final i = id == null ? -1 : _channels.indexWhere((c) => c.id == id);
    if (i < 0) {
      _showToast(tr('Kein vorheriger Sender'));
      return;
    }
    _zapTo(i);
  }

  // ---------- Bildwiederholrate (AFR) ----------
  /// TV-Boxen: Bildschirm auf die Bildrate des Senders umstellen
  /// (25/50 fps → 50 Hz, 24 → 24 Hz …), damit Bewegungen nicht ruckeln.
  Future<void> _matchFrameRate() async {
    if (!_tv) return;
    final st = await ref.read(storageProvider.future);
    if (!st.flag('afr')) return;
    // Bildrate steht erst nach ein paar Bildern sicher fest.
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    final pl = _player;
    if (pl == null || !pl.supportsOptions || !mounted) return;
    double fps = 0;
    for (final prop in ['container-fps', 'estimated-vf-fps']) {
      fps = double.tryParse(await pl.getOption(prop) ?? '') ?? 0;
      if (fps > 1) break;
    }
    if (fps <= 1 || (fps - _afrFps).abs() < 0.01) return;
    _afrFps = fps;
    await PlatformInfo.setFrameRate(fps);
  }

  // ---------- Live ----------
  /// Schaltet auf Sender [i] (zyklisch). [bar]: Zapping-Leiste statt
  /// Bedienelemente zeigen. [list]: andere Senderliste (Direktwahl-Rückfall).
  Future<void> _zapTo(int i, {bool bar = false, List<Channel>? list}) async {
    final chs = list ?? _channels;
    if (chs.isEmpty) return;
    final n = chs.length;
    final target = chs[((i % n) + n) % n];
    final flags = ref.read(channelFlagsProvider).value ?? ChannelFlags.empty;
    if (flags.locked.contains(target.id) && !await askPin(context, ref)) return;
    if (!mounted) return;
    setState(() {
      _index = chs.indexOf(target);
      _req = PlayRequest(
        title: target.name,
        url: target.streamUrl,
        isLive: true,
        channels: chs,
        channel: target,
        artworkSeed: target.name,
      );
    });
    _ctl.setRequest(_req, index: _index);
    if (bar) {
      _set(() => _overlay = false);
      _showBar();
    }
    await _open(quiet: bar);
  }

  // ---------- Zapping-Leiste ----------
  int _wrap(int i) {
    final n = _channels.length;
    return ((i % n) + n) % n;
  }

  /// Zeigt die Leiste für Sender [at] (Standard: der laufende) für 4 s.
  void _showBar([int? at]) {
    if (!_live || _channels.isEmpty) return;
    _barTimer?.cancel();
    _hideTimer?.cancel();
    final i = _wrap(at ?? _index);
    _set(() {
      _bar = true;
      _overlay = false;
      _barIndex = i;
    });
    ref.read(epgProvider.notifier).want(_channels[i]);
    _barTimer = Timer(const Duration(seconds: 4), _hideBar);
  }

  /// Leiste schließen – zurück zum laufenden Sender.
  void _hideBar() {
    _barTimer?.cancel();
    _set(() {
      _bar = false;
      _barIndex = _index;
    });
  }

  /// ◀▶: Nachbarsender in der Leiste ansehen, ohne umzuschalten.
  void _browse(int dir) => _showBar((_bar ? _barIndex : _index) + dir);

  /// OK in der Leiste: auf den gezeigten Sender umschalten.
  void _confirmBar() {
    if (_barIndex != _index) {
      _zapTo(_barIndex, bar: true);
    } else {
      _hideBar();
      _showOverlay();
    }
  }

  // ---------- Farbtasten / Aktionen ----------
  /// Sender, auf den sich Aufnahme/Favorit beziehen: der in der Leiste
  /// gezeigte, sonst der laufende.
  Channel? get _actionChannel {
    if (!_live || _channels.isEmpty) return null;
    return _channels[_bar ? _wrap(_barIndex) : _index];
  }

  Future<void> _recordNow(Channel c, EpgEntry? now) async {
    final r = await ref.read(recordingsProvider.notifier).recordNow(c, now);
    final msg = now == null
        ? tr('Aufnahme läuft (60 Min.)')
        : trf('Aufnahme bis {0}', [hm.format(now.end)]);
    const icon = Icons.fiber_manual_record_rounded;
    if (r == RecResult.duplicate) {
      _showToast(tr('Läuft bereits'), icon: icon);
    } else if (r == RecResult.inAppOnly) {
      _showToast('$msg · ${tr('App bitte geöffnet lassen')}', icon: icon);
    } else {
      _showToast(msg, icon: icon);
    }
  }

  void _recordKey() {
    final c = _actionChannel;
    if (c == null || kIsWeb) return;
    final epg = ref.read(epgProvider).value ?? const {};
    _recordNow(c, nowPlaying(epg, c));
  }

  Future<void> _toggleFavorite([Channel? channel]) async {
    final c = channel ?? _actionChannel;
    if (c == null) return;
    // Gastmodus: Favoriten unveränderbar – nicht „hinzugefügt“ melden.
    if (ref.read(guestModeProvider)) {
      _showToast(tr('Gastmodus an – Verlauf und Favoriten bleiben unberührt'),
          icon: Icons.person_outline_rounded);
      return;
    }
    final flags = ref.read(channelFlagsProvider).value ?? ChannelFlags.empty;
    final was = flags.favorites.contains(c.id);
    _showToast(
        was
            ? trf('{0} aus Favoriten entfernt', [c.name])
            : trf('{0} zu Favoriten hinzugefügt', [c.name]),
        icon: was ? Icons.star_border_rounded : Icons.star_rounded);
    await ref.read(channelFlagsProvider.notifier).toggleFavorite(c.id);
  }

  /// Gelb: laufende Sendung von Anfang (Catch-up), sonst kurzer Hinweis.
  void _startOverKey() {
    if (!_live || _channels.isEmpty) return;
    final c = _channels[_index];
    final epg = ref.read(epgProvider).value ?? const {};
    if (_bar) _hideBar();
    if (c.hasCatchup && nowPlaying(epg, c) != null) {
      _showToast(tr('Von Anfang'), icon: Icons.replay_rounded);
      _restart();
    } else {
      _showToast(tr('Von Anfang ist für diese Sendung nicht verfügbar'),
          icon: Icons.replay_rounded);
    }
  }

  /// Blau / Guide: Senderliste mit Jetzt-Programm (der TV-Guide ist ein Tab
  /// der Startseite und aus dem Player nicht direkt erreichbar).
  void _openList() {
    if (!_live) return;
    _barTimer?.cancel();
    setState(() {
      _bar = false;
      _list = true;
    });
  }

  // ---------- Replay ----------
  Channel? get _replayChannel =>
      _req.channel ?? (_channels.isEmpty ? null : _channels[_index]);

  /// Laufende Sendung von Anfang an.
  Future<void> _restart() async {
    final c = _replayChannel;
    if (c == null || !c.hasCatchup) return;
    final epg = ref.read(epgProvider).value ?? const {};
    final now = nowPlaying(epg, c);
    if (now == null) return;
    await _startReplay(c, now);
  }

  Future<void> _startReplay(Channel c, EpgEntry e) async {
    _savePosition();
    final req = await replayRequest(ref, c, e, channels: _channels);
    if (req == null || !mounted) return;
    setState(() => _req = req);
    _ctl.setRequest(_req);
    await _open();
  }

  /// Vorherige (-1) oder nächste (+1) Sendung im Replay.
  Future<void> _replayStep(int dir, {bool endOfShow = false}) async {
    final c = _replayChannel;
    final cur = _req.replayEntry;
    if (c == null || cur == null) return;
    final list = await ref.read(channelEpgProvider(c).future);
    final i = list.indexWhere((e) => e.start == cur.start);
    final j = i + dir;
    final now = DateTime.now();
    final limit = now.subtract(Duration(days: c.catchupDays));
    if (i < 0 || j < 0 || j >= list.length) {
      if (dir > 0) await _goLive();
      return;
    }
    final target = list[j];
    if (target.start.isAfter(now)) {
      await _goLive(); // Zukunft gibt es nicht – also live
      return;
    }
    if (target.start.isBefore(limit)) {
      if (!endOfShow && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(tr('Ältere Sendungen sind nicht mehr im Archiv.'))));
      }
      return;
    }
    await _startReplay(c, target);
  }

  Future<void> _goLive() async {
    final c = _replayChannel;
    if (c == null) return;
    _savePosition();
    final list = _channels.isEmpty ? [c] : _channels;
    setState(() {
      _index = list.indexWhere((x) => x.id == c.id).clamp(0, list.length - 1);
      _req = PlayRequest(
        title: c.name,
        url: c.streamUrl,
        isLive: true,
        channels: list,
        channel: c,
        artworkSeed: c.name,
      );
    });
    _ctl.setRequest(_req, index: _index);
    await _open();
  }

  // ---------- Live-Pause (Timeshift) ----------
  bool get _shifted => _live && _ts.isShifted(DateTime.now());

  /// Pause/Weiter. Live mit Puffer: pausiert zeitversetzt (der Stream läuft
  /// im Speicher weiter), Weiter spielt ab der Pausenstelle.
  void _togglePause() {
    final p = _player;
    if (p == null) return;
    final now = DateTime.now();
    if (p.state.playing) {
      p.pause();
      _userPaused = true;
      if (_live) _ts.pause(now);
    } else {
      p.play();
      _userPaused = false;
      _stall.reset();
      if (_live) _ts.resume(now);
    }
    _set(() {});
  }

  /// ◀▶ im Zeitversatz: innerhalb des Puffers spulen (nicht über Live hinaus).
  void _seekShift(Duration delta) {
    final p = _player;
    if (p == null) return;
    final now = DateTime.now();
    final eff = _ts.seek(delta, now);
    if (eff != Duration.zero) p.seek(p.state.position + eff);
    if (!_ts.isShifted(now)) _ts.goLive();
    _stall.reset();
    _set(() {});
  }

  /// „Zurück zu Live“: ans Pufferende springen, sonst neu öffnen.
  Future<void> _goLiveEdge() async {
    final p = _player;
    final now = DateTime.now();
    final behind = _ts.behind(now);
    final within = behind < _ts.available(now);
    _ts.goLive();
    _userPaused = false;
    _stall.reset();
    if (p == null) {
      _set(() {});
      return;
    }
    double? end;
    if (p.supportsOptions) {
      end = double.tryParse(await p.getOption('demuxer-cache-time') ?? '');
    }
    final pos = p.state.position.inMilliseconds / 1000;
    if (within && end != null && end - 1 > pos) {
      await p.seek(Duration(milliseconds: ((end - 1) * 1000).round()));
      await p.play();
    } else {
      // Puffer übergelaufen o. ä.: Stream frisch öffnen (= live).
      await _open(quiet: true);
    }
    _showToast(tr('Live'), icon: Icons.circle);
  }

  /// Rückstand mit mpv abgleichen: Pufferende minus Position.
  Future<void> _syncTimeshift() async {
    if (_ts.paused) return; // pausiert: Wanduhr ist genauer
    final pl = _player;
    if (pl == null || !pl.supportsOptions) return;
    try {
      final end =
          double.tryParse(await pl.getOption('demuxer-cache-time') ?? '');
      final pos = double.tryParse(await pl.getOption('time-pos') ?? '');
      if (end == null || pos == null || end <= 0) return;
      final behind = Duration(milliseconds: ((end - pos) * 1000).round());
      if (_ts.paused) return;
      if (behind < const Duration(seconds: 3)) {
        _ts.goLive();
      } else {
        _ts.sync(behind, DateTime.now());
      }
    } catch (_) {}
  }

  // ---------- Varianten ----------
  /// Etikett der laufenden Variante („FHD“, „Backup“) oder null.
  String? get _variantLabel {
    if (_variants.length < 2) return null;
    final c = _playingChannel!;
    final g = ref.read(variantIndexProvider).groupOf(c.id);
    final l = g?.labelOf(c);
    if (l == null || l == c.name) {
      return trf('Quelle {0}/{1}', [_variantPos + 1, _variants.length]);
    }
    return l;
  }

  /// „Qualität/Quelle wählen“ (Overlay): Wahl merken und umschalten.
  Future<void> _pickVariant() async {
    if (!_live || _channels.isEmpty) return;
    final c = _channels[_index];
    final playing = _playingChannel;
    final pick =
        await showVariantPicker(context, ref, c, playingId: playing?.id);
    _grabFocus();
    if (pick == null || !mounted || pick.id == playing?.id) return;
    await _open(quiet: true);
    _showToast(trf('Quelle: {0}', [pick.name]), icon: Icons.layers_rounded);
  }

  void _digit(int d) {
    _digitTimer?.cancel();
    setState(() {
      final next = '$_digits$d';
      _digits = next.length > 4 ? next.substring(1) : next;
    });
    _digitTimer = Timer(const Duration(milliseconds: 1500), _commitDigits);
  }

  /// Direktwahl ausführen: Sender mit dieser Nummer in der aktuellen Liste,
  /// sonst in der ganzen Senderliste; unbekannt → kurzer Hinweis.
  void _commitDigits() {
    _digitTimer?.cancel();
    final typed = _digits;
    final n = int.tryParse(typed) ?? -1;
    _set(() => _digits = '');
    if (typed.isEmpty) return;
    final bar = !_overlay;
    final i = _channels.indexWhere((c) => c.number == n);
    if (i >= 0) {
      if (i != _index) {
        _zapTo(i, bar: bar);
      } else if (bar) {
        _showBar();
      }
      return;
    }
    // Im Kindermodus nur freigegebene Sender.
    final all =
        ref.read(visibleLiveDataProvider).value?.channels ?? const <Channel>[];
    var j = all.indexWhere((c) => c.number == n);
    if (j < 0) {
      // Nummer einer zusammengefassten Variante → deren sichtbarer Sender.
      final raw = ref.read(liveDataProvider).value?.channels ?? const <Channel>[];
      final hidden = raw.where((c) => c.number == n).firstOrNull;
      if (hidden != null) {
        final rep =
            ref.read(variantIndexProvider).representativeOf(hidden.id);
        final k = _channels.indexWhere((c) => c.id == rep);
        if (k >= 0) {
          if (k != _index) _zapTo(k, bar: bar);
          return;
        }
        j = all.indexWhere((c) => c.id == rep);
      }
    }
    if (j >= 0) {
      _zapTo(j, bar: bar, list: all);
      return;
    }
    _showToast(trf('Sender {0} nicht gefunden', [n]),
        icon: Icons.dialpad_rounded);
  }

  // ---------- Tasten ----------
  /// Blaue Taste / Guide-Taste: Player schließen und den TV-Guide öffnen.
  void _openGuide() {
    ref.read(shellTabRequestProvider.notifier).open(ShellTab.guide);
    _stopOnPop = true;
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final k = e.logicalKey;
    final p = _player;
    if (_list) return KeyEventResult.ignored; // Senderliste hat den Fokus
    final primary = FocusManager.instance.primaryFocus;
    final onControl = primary != null && primary != _focus;
    final arrow = k == LogicalKeyboardKey.arrowUp ||
        k == LogicalKeyboardKey.arrowDown ||
        k == LogicalKeyboardKey.arrowLeft ||
        k == LogicalKeyboardKey.arrowRight;
    final ok = k == LogicalKeyboardKey.select ||
        k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.numpadEnter;

    // Schlaf-Timer-Warnung: OK = weiterschauen.
    if (_sleepWarning && ok) {
      _setSleep(null);
      return KeyEventResult.handled;
    }
    // Direktwahl läuft: OK bestätigt sofort.
    if (_live && ok && _digits.isNotEmpty) {
      _commitDigits();
      return KeyEventResult.handled;
    }
    // Zapping-Leiste: ◀▶ blättern (Vorschau), OK schaltet um, Zurück schließt.
    if (_live && _bar) {
      if (k == LogicalKeyboardKey.arrowLeft ||
          k == LogicalKeyboardKey.arrowRight) {
        _browse(k == LogicalKeyboardKey.arrowLeft ? -1 : 1);
        return KeyEventResult.handled;
      }
      if (ok) {
        _confirmBar();
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.escape || k == LogicalKeyboardKey.goBack) {
        _hideBar();
        return KeyEventResult.handled;
      }
    }
    // Farbtasten (Live) – alles auch über die Bedienelemente erreichbar.
    final color = colorOfKey(k);
    if (_live && color != null) {
      switch (color) {
        case ColorKey.red:
          _recordKey();
        case ColorKey.green:
          _toggleFavorite();
        case ColorKey.yellow:
          _startOverKey();
        case ColorKey.blue:
          _openGuide();
      }
      return KeyEventResult.handled;
    }
    if (_live && k == LogicalKeyboardKey.guide) {
      _openGuide();
      return KeyEventResult.handled;
    }
    // Info lange gedrückt: Diagnose-Anzeige an/aus.
    if (k == LogicalKeyboardKey.info && e is KeyRepeatEvent) {
      if (!_infoLong) {
        _infoLong = true;
        _toggleDebugInfo();
      }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.info) _infoLong = false;
    if (_live && k == LogicalKeyboardKey.info) {
      _bar ? _hideBar() : _showBar();
      return KeyEventResult.handled;
    }
    // Sichtbare Bedienelemente: erste Pfeiltaste holt den Fokus hinein.
    if (_overlay &&
        arrow &&
        !(primary?.ancestors.contains(_overlayNode) ?? false) &&
        _enterOverlay(k)) {
      _showOverlay();
      return KeyEventResult.handled;
    }
    // OK auf einem fokussierten Knopf (Fehler-Box, Bedienelemente) löst ihn aus.
    if (onControl && ok) {
      if (_overlay) _showOverlay();
      return KeyEventResult.ignored;
    }

    // Zifferntasten (oben und Ziffernblock)
    final di = digitOfKey(k);
    if (_live && di != null) {
      _digit(di);
      return KeyEventResult.handled;
    }

    if (_live && (k == LogicalKeyboardKey.mediaLast ||
        k == LogicalKeyboardKey.backspace)) {
      _zapBack();
      return KeyEventResult.handled;
    }
    // ▲▼ / CH± schalten sofort um; ausgeblendet mit Zapping-Leiste.
    if ((_live && k == LogicalKeyboardKey.channelUp) ||
        (_live && k == LogicalKeyboardKey.arrowUp && !_overlay)) {
      _zapTo(_index + 1, bar: !_overlay);
      return KeyEventResult.handled;
    }
    if ((_live && k == LogicalKeyboardKey.channelDown) ||
        (_live && k == LogicalKeyboardKey.arrowDown && !_overlay)) {
      _zapTo(_index - 1, bar: !_overlay);
      return KeyEventResult.handled;
    }
    // Zeitversetzt: ◀▶ spulen im Puffer.
    if (_live && !_overlay && _shifted &&
        (k == LogicalKeyboardKey.arrowLeft ||
            k == LogicalKeyboardKey.arrowRight)) {
      _seekShift(Duration(
          seconds: k == LogicalKeyboardKey.arrowLeft ? -10 : 10));
      return KeyEventResult.handled;
    }
    if (_live && k == LogicalKeyboardKey.arrowLeft && !_overlay) {
      _openList();
      return KeyEventResult.handled;
    }
    if (_live && k == LogicalKeyboardKey.arrowRight && !_overlay) {
      _browse(1);
      return KeyEventResult.handled;
    }
    if (!_live && p != null && !_overlay &&
        (k == LogicalKeyboardKey.arrowLeft ||
            k == LogicalKeyboardKey.arrowRight)) {
      final delta = Duration(
          seconds: k == LogicalKeyboardKey.arrowLeft ? -10 : 10);
      p.seek(p.state.position + delta);
      _showOverlay();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.zoomToggle ||
        k == LogicalKeyboardKey.zoomIn ||
        k == LogicalKeyboardKey.keyZ) {
      _cycleAspect();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.mediaPlayPause ||
        k == LogicalKeyboardKey.space ||
        (k == LogicalKeyboardKey.mediaPause && (p?.state.playing ?? false)) ||
        (k == LogicalKeyboardKey.mediaPlay && !(p?.state.playing ?? true))) {
      _togglePause();
      _showOverlay();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.mediaPause ||
        k == LogicalKeyboardKey.mediaPlay) {
      return KeyEventResult.handled;
    }
    // Live: ▶▶ = zurück zu Live (im Zeitversatz).
    if (_live && k == LogicalKeyboardKey.mediaFastForward) {
      if (_shifted) _goLiveEdge();
      return KeyEventResult.handled;
    }
    if (_live && _shifted && k == LogicalKeyboardKey.mediaRewind) {
      _seekShift(const Duration(seconds: -30));
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.mediaFastForward && p != null) {
      p.seek(p.state.position + const Duration(seconds: 30));
      return KeyEventResult.handled;
    }
    if (_live &&
        (k == LogicalKeyboardKey.mediaRewind ||
            k == LogicalKeyboardKey.mediaSkipBackward ||
            k == LogicalKeyboardKey.mediaTrackPrevious)) {
      _restart();
      return KeyEventResult.handled;
    }
    if (_replay &&
        (k == LogicalKeyboardKey.mediaTrackPrevious ||
            k == LogicalKeyboardKey.mediaSkipBackward ||
            k == LogicalKeyboardKey.channelDown)) {
      _replayStep(-1);
      return KeyEventResult.handled;
    }
    if (_replay &&
        (k == LogicalKeyboardKey.mediaTrackNext ||
            k == LogicalKeyboardKey.mediaSkipForward ||
            k == LogicalKeyboardKey.channelUp)) {
      _replayStep(1);
      return KeyEventResult.handled;
    }
    if (_replay && k == LogicalKeyboardKey.mediaStop) {
      _goLive();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.mediaRewind && p != null) {
      p.seek(p.state.position - const Duration(seconds: 30));
      return KeyEventResult.handled;
    }
    if (!_overlay &&
        (k == LogicalKeyboardKey.select ||
            k == LogicalKeyboardKey.enter ||
            k == LogicalKeyboardKey.info ||
            k == LogicalKeyboardKey.arrowUp ||
            k == LogicalKeyboardKey.arrowDown)) {
      _showOverlay();
      return KeyEventResult.handled;
    }
    if (_overlay) _showOverlay(); // Timer verlängern bei Bedienung
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final epg = ref.watch(epgProvider).value ?? const {};
    ref.watch(minuteTickProvider);
    // Übergabe an ein Cast-Gerät: Player-Seite schließen, der Mini-Player
    // zeigt „Läuft auf …“.
    ref.listen(playbackProvider.select((s) => s.casting), (was, now) {
      if (now && was != true && mounted) _leaveForCast();
    });
    final channel = _live && _channels.isNotEmpty ? _channels[_index] : null;
    final now = channel == null ? null : nowPlaying(epg, channel);
    final next = channel == null ? null : nextAfter(epg, channel, now);
    final flags = ref.watch(channelFlagsProvider).value ?? ChannelFlags.empty;
    final showBar = _bar && _live && !_list && _channels.isNotEmpty;
    final barChannel = showBar ? _channels[_wrap(_barIndex)] : null;
    final barNow = barChannel == null ? null : nowPlaying(epg, barChannel);
    final clock = DateTime.now();
    final shifted = _live && _ts.isShifted(clock);
    final hasVariants = _live &&
        channel != null &&
        ref.watch(variantIndexProvider).countOf(channel.id) > 1;
    final video = _player?.buildVideo(
        fit: _aspect.fit,
        aspectRatio: _aspect.ratio,
        subtitleStyle: _subStyle);

    final pipOnBack = _leave == LeaveAction.pip && !_tv && _error == null;
    return PopScope(
      canPop: !_list && !showBar && !(pipOnBack && !_stopOnPop),
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_list) {
          setState(() => _list = false);
          _focus.requestFocus();
        } else if (_bar) {
          _hideBar();
        } else if (pipOnBack) {
          // Einstellung „Bild-in-Bild“: Zurück verkleinert statt zu schließen.
          _leaveWithPip();
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Focus(
          focusNode: _focus,
          autofocus: true,
          onKeyEvent: _onKey,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _toggleOverlay,
            onDoubleTapDown: _live
                ? null
                : (d) {
                    final w = MediaQuery.sizeOf(context).width;
                    final p = _player;
                    if (p == null) return;
                    p.seek(p.state.position +
                        Duration(seconds: d.localPosition.dx < w / 2 ? -10 : 10));
                    _showOverlay();
                  },
            onVerticalDragEnd: _live
                ? (d) {
                    final v = d.primaryVelocity ?? 0;
                    if (v < -250) _zapTo(_index + 1);
                    if (v > 250) _zapTo(_index - 1);
                  }
                : null,
            onHorizontalDragEnd: _live
                ? (d) {
                    if ((d.primaryVelocity ?? 0) > 300) {
                      setState(() => _list = true);
                    }
                  }
                : null,
            child: Stack(fit: StackFit.expand, children: [
              if (video != null && !_audioOnly)
                ClipRect(
                  child: Transform.scale(
                    scale: _aspect.scale,
                    child: video,
                  ),
                ),
              // Grafik mit Senderlogo, bis das erste Bild da ist
              IgnorePointer(
                child: AnimatedOpacity(
                  opacity: _hasVideo && !_audioOnly ? 0 : 1,
                  duration: const Duration(milliseconds: 300),
                  child: _LoadingArt(req: _req, channel: channel, now: now),
                ),
              ),
              if (_audioOnly)
                const IgnorePointer(child: AudioOnlyBadge()),
              if (_debugInfo && _player != null)
                Positioned(
                  // Rechts unter der oberen Leiste: Titel, Knöpfe und
                  // Senderwahl bleiben frei.
                  right: 16,
                  top: 84,
                  child: IgnorePointer(
                    child: PlayerDebugInfo(
                        engine: _player!,
                        sent: () => _props?.sent ?? 0,
                        dataSaver: ref.watch(dataSaverActiveProvider)),
                  ),
                ),
              if (_buffering && _error == null && !_audioOnly)
                const Center(
                  child: SizedBox(
                    width: 44,
                    height: 44,
                    child: CircularProgressIndicator(strokeWidth: 3),
                  ),
                ),
              if (_error != null)
                _ErrorBox(
                  message: _error!,
                  onRetry: _open,
                  onNextChannel:
                      _live && _channels.length > 1 ? () => _zapTo(_index + 1) : null,
                ),
              AnimatedOpacity(
                opacity: _overlay ? 1 : 0,
                duration: const Duration(milliseconds: 200),
                child: IgnorePointer(
                  ignoring: !_overlay,
                  // Ausgeblendet: Knöpfe auch nicht per D-Pad erreichbar.
                  child: Focus(
                    focusNode: _overlayNode,
                    canRequestFocus: false,
                    skipTraversal: true,
                    child: ExcludeFocus(
                  excluding: !_overlay || _list,
                  child: _live
                      ? _LiveOverlay(
                          mainFocus: _overlayMain,
                          channel: channel!,
                          now: now,
                          next: next,
                          onBack: _back,
                          onTracks: _showTracks,
                          onSubtitleDelay: _showSubtitleDelay,
                          onAudioOnly: _tv ? null : _toggleAudioOnly,
                          audioOnly: _audioOnly,
                          onEngine: _engineSwitch,
                          engineLabel: _currentEngine?.label,
                          onList: () => setState(() => _list = true),
                          onPip: _pip,
                          onPrev: () => _zapTo(_index - 1),
                          onNext: () => _zapTo(_index + 1),
                          onAspect: _pickAspect,
                          onSleep: _pickSleep,
                          onRotate: _tv ? null : _toggleOrientation,
                          touch: !_tv,
                          onMultiview: _openMultiview,
                          onZapBack: _prevChannelId == null ? null : _zapBack,
                          onRecord: () => _recordNow(channel, now),
                          favorite: flags.favorites.contains(channel.id),
                          onFavorite: ref.watch(guestModeProvider)
                              ? null
                              : () => _toggleFavorite(channel),
                          onRestart: channel.hasCatchup && now != null
                              ? _restart
                              : null,
                          paused: _userPaused,
                          onPlayPause: _ts.enabled ? _togglePause : null,
                          onGoLive: shifted ? _goLiveEdge : null,
                          shiftText: shifted
                              ? trf('{0} zeitversetzt',
                                  [fmtBehind(_ts.behind(clock))])
                              : null,
                          onVariants: hasVariants ? _pickVariant : null,
                          variantLabel: hasVariants ? _variantLabel : null,
                        )
                      : _VodOverlay(
                          mainFocus: _overlayMain,
                          req: _req,
                          player: _player,
                          onBack: _back,
                          onTracks: _showTracks,
                          onSubtitleDelay: _showSubtitleDelay,
                          onAudioOnly: _tv ? null : _toggleAudioOnly,
                          audioOnly: _audioOnly,
                          onEngine: _engineSwitch,
                          engineLabel: _currentEngine?.label,
                          onPip: _pip,
                          onInteract: _showOverlay,
                          onPlayPause: _togglePause,
                          onAspect: _pickAspect,
                          onSleep: _pickSleep,
                          onRotate: _tv ? null : _toggleOrientation,
                          showControls: _error == null,
                          replay: _replay
                              ? _ReplayBar(
                                  channel: _replayChannel!,
                                  entry: _req.replayEntry!,
                                  onPrev: () => _replayStep(-1),
                                  onNext: () => _replayStep(1),
                                  onLive: _goLive,
                                )
                              : null,
                        ),
                    ),
                  ),
                ),
              ),
              if (barChannel != null)
                ZapBar(
                  channel: barChannel,
                  now: barNow,
                  next: nextAfter(epg, barChannel, barNow),
                  preview: _wrap(_barIndex) != _index,
                  favorite: flags.favorites.contains(barChannel.id),
                  tv: _tv,
                ),
              if (_status != null && _error == null)
                Positioned(
                  // Mit Bedienelementen oben unter der Knopfreihe, sonst
                  // verdeckt der Hinweis die Sendungsinfo unten.
                  top: _overlay ? 104 : null,
                  bottom: _overlay ? null : 48,
                  left: 0,
                  right: 0,
                  child: IgnorePointer(
                    child: Center(
                      child: _StatusPill(
                          key: const ValueKey('player-status'),
                          text: _status!,
                          busy: true),
                    ),
                  ),
                ),
              if (shifted && !_overlay && _error == null)
                Positioned(
                  top: 32,
                  left: 40,
                  child: IgnorePointer(
                    child: _StatusPill(
                      key: const ValueKey('timeshift-status'),
                      icon: _userPaused
                          ? Icons.pause_rounded
                          : Icons.history_rounded,
                      text: trf('{0} zeitversetzt',
                          [fmtBehind(_ts.behind(clock))]),
                    ),
                  ),
                ),
              if (_sleepWarning && _sleepAt != null)
                Positioned(
                  bottom: 140,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(20, 14, 14, 14),
                      decoration: BoxDecoration(
                        color: AppColors.surface.withValues(alpha: 0.95),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(Icons.bedtime_rounded, color: AppColors.gold),
                        const SizedBox(width: 12),
                        Text(
                            trf('Schlaf-Timer: Stopp in {0} s', [_sleepAt!.difference(DateTime.now()).inSeconds.clamp(0, 60)]),
                            style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700)),
                        const SizedBox(width: 16),
                        FilledButton(
                          autofocus: true,
                          onPressed: () => _setSleep(null),
                          child: Text(tr('Weiterschauen')),
                        ),
                      ]),
                    ),
                  ),
                ),
              if (_toast != null)
                Positioned(
                  top: 90,
                  left: 0,
                  right: 0,
                  child: IgnorePointer(
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 18, vertical: 10),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.72),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(_toastIcon ?? _aspect.icon,
                              color: AppColors.accent, size: 20),
                          const SizedBox(width: 10),
                          Text(_toast!,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700)),
                        ]),
                      ),
                    ),
                  ),
                ),
              if (_digits.isNotEmpty)
                Positioned(
                  top: 32,
                  right: 40,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 22, vertical: 10),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.7),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: AppColors.accent, width: 2),
                    ),
                    child: Text(_digits,
                        style: const TextStyle(
                            fontFamily: 'InterDisplay',
                            fontSize: 44,
                            fontWeight: FontWeight.w800,
                            color: Colors.white)),
                  ),
                ),
              if (!_live && _req.nextUp != null && _player != null)
                NextEpisodeHost(
                  key: _nextKey,
                  request: _req,
                  position: _player!.stream.position,
                  duration: _player!.stream.duration,
                  returnFocus: _focus,
                  onExit: _closeAndStop,
                  onPlay: (next) {
                    setState(() {
                      _req = next;
                      _nextKey = GlobalKey<NextEpisodeHostState>();
                    });
                    _ctl.setRequest(_req);
                    // Der Knopf der Karte verschwindet – Fokus gleich zurück
                    // in den Player (nicht erst nach dem Öffnen).
                    _grabFocus();
                    _open();
                  },
                ),
              if (_list && _live)
                _ChannelDrawer(
                  channels: _channels,
                  current: _index,
                  epg: epg,
                  onPick: (i) {
                    setState(() => _list = false);
                    _focus.requestFocus();
                    if (i != _index) _zapTo(i);
                  },
                  onClose: () {
                    setState(() => _list = false);
                    _focus.requestFocus();
                  },
                ),
            ]),
          ),
        ),
      ),
    );
  }

  /// Blatt „Untertitel-Verzögerung“ (auch per langem OK auf dem
  /// Untertitel-Knopf). Ohne Player: nur Anzeige, nichts wird gesetzt.
  Future<void> _showSubtitleDelay() async {
    final d = _subDelay ?? (_subDelayLocal ??= SubtitleDelay((_, __) async {}));
    await SubtitleDelaySheet.show(context, d);
    _focus.requestFocus();
  }

  /// Zurück-Knopf der Bedienelemente. Bei Einstellung „Bild-in-Bild“
  /// schließt er den Player (die Zurück-Taste verkleinert).
  void _back() {
    if (_leave == LeaveAction.pip && !_tv) {
      _closeAndStop();
      return;
    }
    Navigator.maybePop(context);
  }

  /// Einstellung „Bild-in-Bild beim Verlassen“: statt zu schließen
  /// verkleinern; geht das nicht, Seite schließen und stoppen.
  Future<void> _leaveWithPip() async {
    final ok = await PlatformInfo.enterPip();
    if (ok) {
      _set(() => _overlay = false);
      return;
    }
    _closeAndStop();
  }

  Future<void> _pip() async {
    final ok = await PlatformInfo.enterPip();
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(tr('Bild-in-Bild wird auf diesem Gerät nicht unterstützt.'))));
    } else {
      _set(() => _overlay = false);
    }
  }

  Future<void> _showTracks() async {
    final p = _player;
    if (p == null) return;
    final tracks = p.state.tracks;
    final cur = p.state.track;
    String label(String? title, String? lang, String id) {
      if (id == 'auto') return tr('Automatisch');
      if (id == 'no') return tr('Aus');
      return TrackLanguage.describe(lang, title, trf('Spur {0}', [id]));
    }

    await showModalBottomSheet<void>(
      context: context,
      constraints: const BoxConstraints(maxWidth: 560),
      builder: (ctx) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          ListTile(title: Text(tr('Tonspur'))),
          for (final a in tracks.audio)
            ListTile(
              // Fernbedienung: Start auf der aktuellen Tonspur.
              autofocus: a == cur.audio,
              leading: Icon(a == cur.audio
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked),
              title: Text(label(a.title, a.language, a.id)),
              onTap: () {
                _userPickedTracks = true;
                p.setAudioTrack(a);
                Navigator.pop(ctx);
              },
            ),
          const Divider(),
          ListTile(title: Text(tr('Untertitel'))),
          for (final s in tracks.subtitle)
            ListTile(
              leading: Icon(s == cur.subtitle
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked),
              title: Text(label(s.title, s.language, s.id)),
              onTap: () {
                _userPickedTracks = true;
                p.setSubtitleTrack(s);
                Navigator.pop(ctx);
              },
            ),
          const Divider(),
          ListTile(
            key: const ValueKey('track-subdelay'),
            leading: const Icon(Icons.timer_outlined),
            title: Text(tr('Untertitel-Verzögerung')),
            trailing: Text(_subDelay?.label ?? tr('Keine Verzögerung'),
                style: const TextStyle(color: AppColors.textDim)),
            onTap: () {
              Navigator.pop(ctx);
              _showSubtitleDelay();
            },
          ),
          if (_engineSwitch != null) ...[
            const Divider(),
            ListTile(
              key: const ValueKey('track-engine'),
              leading: const Icon(Icons.swap_horiz_rounded),
              title: Text(tr('Player-Engine wechseln')),
              subtitle: Text(trf('Aktuell: {0}', [_currentEngine!.label])),
              onTap: () {
                Navigator.pop(ctx);
                _engineSwitch?.call();
              },
            ),
          ],
        ]),
      ),
    );
    _focus.requestFocus();
  }
}


class _LoadingArt extends StatelessWidget {
  final PlayRequest req;
  final Channel? channel;
  final EpgEntry? now;
  const _LoadingArt({required this.req, this.channel, this.now});

  @override
  Widget build(BuildContext context) {
    return Stack(fit: StackFit.expand, children: [
      NetworkArt(
          url: req.artworkUrl, seed: now?.title ?? req.artworkSeed ?? req.title),
      Container(color: Colors.black.withValues(alpha: 0.35)),
      if (channel != null)
        Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ChannelLogo(name: channel!.name, url: channel!.logoUrl, size: 64),
            const SizedBox(height: 90),
          ]),
        ),
    ]);
  }
}

class _ErrorBox extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  final VoidCallback? onNextChannel;
  const _ErrorBox(
      {required this.message, required this.onRetry, this.onNextChannel});

  @override
  Widget build(BuildContext context) {
    final err = StreamError.classify(message);
    final t = Theme.of(context).textTheme;
    final geo = err.isLocationRelated;
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 480),
        margin: const EdgeInsets.all(24),
        padding: const EdgeInsets.all(26),
        decoration: BoxDecoration(
          color: AppColors.surface.withValues(alpha: 0.94),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(err.icon,
              size: 42, color: geo ? AppColors.gold : AppColors.live),
          const SizedBox(height: 12),
          Text(err.title, textAlign: TextAlign.center, style: t.titleLarge),
          const SizedBox(height: 8),
          Text(err.message,
              textAlign: TextAlign.center,
              style: t.bodyMedium?.copyWith(height: 1.45)),
          if (err.kind == StreamErrorKind.other) ...[
            const SizedBox(height: 8),
            Text(message, // bereits ohne Zugangsdaten
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: t.bodySmall?.copyWith(color: AppColors.textFaint)),
          ],
          const SizedBox(height: 20),
          // Eigener Bereich: Autofokus greift, obwohl der Player den Fokus
          // hat → OK = „Erneut versuchen“ bzw. „Nächster Sender“.
          FocusScope(
            child: Wrap(spacing: 10, runSpacing: 10, alignment: WrapAlignment.center,
              children: [
            if (geo && onNextChannel != null)
              FilledButton.icon(
                  autofocus: true,
                  onPressed: onNextChannel,
                  icon: const Icon(Icons.skip_next_rounded),
                  label: Text(tr('Nächster Sender'))),
            if (geo && onNextChannel != null)
              OutlinedButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh_rounded),
                  label: Text(tr('Erneut versuchen')))
            else
              FilledButton.icon(
                  autofocus: true,
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh_rounded),
                  label: Text(tr('Erneut versuchen'))),
          ]),
          ),
        ]),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  final Widget title;
  final VoidCallback onBack, onTracks, onPip, onAspect, onSleep;
  final VoidCallback? onRotate;

  /// Untertitel-Verzögerung: langes OK/Drücken auf dem Untertitel-Knopf
  /// und Eintrag im „⋮“-Menü.
  final VoidCallback? onSubtitleDelay;

  /// Nur-Ton an/aus (Handy/Tablet; „⋮“-Menü bzw. Knopf).
  final VoidCallback? onAudioOnly;

  /// „Player-Engine wechseln“ (ExoPlayer ↔ mpv); null = nicht anbieten.
  final VoidCallback? onEngine;
  final String? engineLabel;
  final bool audioOnly;
  final List<Widget> extra;
  const _TopBar({
    required this.title,
    required this.onBack,
    required this.onTracks,
    required this.onPip,
    required this.onAspect,
    required this.onSleep,
    this.onRotate,
    this.onSubtitleDelay,
    this.onAudioOnly,
    this.onEngine,
    this.engineLabel,
    this.audioOnly = false,
    this.extra = const [],
  });

  /// Schmale Bildschirme (< 800 dp, auch Handy quer): selten genutzte
  /// Funktionen im „⋮“-Menü.
  Future<void> _more(BuildContext context) async {
    final pick = await showModalBottomSheet<int>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          ListTile(
              leading: const Icon(Icons.aspect_ratio_rounded),
              title: Text(tr('Bildformat')),
              onTap: () => Navigator.pop(ctx, 0)),
          ListTile(
              leading: const Icon(Icons.subtitles_outlined),
              title: Text(tr('Tonspur & Untertitel')),
              onTap: () => Navigator.pop(ctx, 1)),
          if (onSubtitleDelay != null)
            ListTile(
                leading: const Icon(Icons.timer_outlined),
                title: Text(tr('Untertitel-Verzögerung')),
                onTap: () => Navigator.pop(ctx, 4)),
          if (onAudioOnly != null)
            ListTile(
                key: const ValueKey('menu-audio-only'),
                leading: Icon(audioOnly
                    ? Icons.videocam_rounded
                    : Icons.headphones_rounded),
                title: Text(audioOnly ? tr('Video wieder an') : tr('Nur Ton')),
                subtitle: audioOnly
                    ? null
                    : Text(tr('Bild aus, Ton läuft weiter – spart Akku und Daten')),
                onTap: () => Navigator.pop(ctx, 5)),
          if (onEngine != null)
            ListTile(
                key: const ValueKey('menu-engine'),
                leading: const Icon(Icons.swap_horiz_rounded),
                title: Text(tr('Player-Engine wechseln')),
                subtitle: engineLabel == null
                    ? null
                    : Text(trf('Aktuell: {0}', [engineLabel!])),
                onTap: () => Navigator.pop(ctx, 6)),
          // Handy hochkant mit Cast-Knopf: „Bild drehen“ hier statt oben.
          if (onRotate != null && _rotateInMenu(context))
            ListTile(
                key: const ValueKey('menu-rotate'),
                leading: const Icon(Icons.screen_rotation_rounded),
                title: Text(tr('Bild drehen')),
                onTap: () => Navigator.pop(ctx, 7)),
          ListTile(
              leading: const Icon(Icons.picture_in_picture_alt_rounded),
              title: Text(tr('Bild-in-Bild')),
              onTap: () => Navigator.pop(ctx, 2)),
          ListTile(
              leading: const Icon(Icons.bedtime_outlined),
              title: Text(tr('Schlaf-Timer')),
              onTap: () => Navigator.pop(ctx, 3)),
        ]),
      ),
    );
    switch (pick) {
      case 0:
        onAspect();
      case 1:
        onTracks();
      case 2:
        onPip();
      case 3:
        onSleep();
      case 4:
        onSubtitleDelay?.call();
      case 5:
        onAudioOnly?.call();
      case 6:
        onEngine?.call();
      case 7:
        onRotate?.call();
    }
  }

  /// Sehr schmal und ein Cast-Gerät in Reichweite: „Bild drehen“ wandert ins
  /// „⋮“-Menü, damit der Cast-Knopf Platz hat.
  static bool _rotateInMenu(BuildContext context) =>
      MediaQuery.sizeOf(context).width < 420 &&
      ProviderScope.containerOf(context, listen: false)
          .read(castProvider)
          .available &&
      ProviderScope.containerOf(context, listen: false)
          .read(castSupportedProvider);

  @override
  Widget build(BuildContext context) => Consumer(builder: (context, ref, _) {
        // Cast-Knopf sichtbar? (entscheidet, wo „Bild drehen“ liegt)
        ref.watch(castProvider.select((c) => c.available));
        return _bar(context);
      });

  Widget _bar(BuildContext context) => Container(
        padding: EdgeInsets.fromLTRB(
            12, MediaQuery.paddingOf(context).top + 12, 16, 40),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xCC000000), Color(0x00000000)],
          ),
        ),
        child: Row(children: [
          _RoundBtn(icon: Icons.arrow_back_rounded, onTap: onBack),
          const SizedBox(width: 12),
          // Sehr schmal (Handy hochkant mit vielen Knöpfen): Titel weglassen
          // statt überlaufen.
          Expanded(
              child: LayoutBuilder(
                  builder: (_, box) =>
                      box.maxWidth < 110 ? const SizedBox.shrink() : title)),
          ...extra,
          // Datensparmodus aktiv / Cast (nur Handy/Tablet, nur mit Gerät).
          Consumer(
              builder: (_, ref, __) => ref.watch(dataSaverActiveProvider)
                  ? const DataSaverBadge()
                  : const SizedBox.shrink()),
          const CastButton(),
          if (onRotate != null && !_rotateInMenu(context)) ...[
            _RoundBtn(icon: Icons.screen_rotation_rounded, onTap: onRotate!),
            const SizedBox(width: 8),
          ],
          if (MediaQuery.sizeOf(context).width < 800)
            _RoundBtn(icon: Icons.more_vert_rounded, onTap: () => _more(context))
          else ...[
            _RoundBtn(icon: Icons.aspect_ratio_rounded, onTap: onAspect),
            const SizedBox(width: 8),
            _RoundBtn(
                icon: Icons.subtitles_outlined,
                onTap: onTracks,
                onLongPress: onSubtitleDelay),
            const SizedBox(width: 8),
            if (onAudioOnly != null) ...[
              _RoundBtn(
                  key: const ValueKey('audio-only-btn'),
                  icon: audioOnly
                      ? Icons.videocam_rounded
                      : Icons.headphones_rounded,
                  onTap: onAudioOnly!),
              const SizedBox(width: 8),
            ],
            _RoundBtn(icon: Icons.picture_in_picture_alt_rounded, onTap: onPip),
            const SizedBox(width: 8),
            _RoundBtn(icon: Icons.bedtime_outlined, onTap: onSleep),
          ],
        ]),
      );
}

class _RoundBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  /// Langes Drücken bzw. OK gedrückt halten (Fernbedienung, über [TvTile]).
  final VoidCallback? onLongPress;
  final double size;
  final FocusNode? focusNode;
  const _RoundBtn(
      {super.key,
      required this.icon,
      required this.onTap,
      this.onLongPress,
      this.size = 44,
      this.focusNode});

  @override
  Widget build(BuildContext context) {
    final child = Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.12),
        shape: BoxShape.circle,
      ),
      child: Icon(icon, color: Colors.white, size: size * 0.5),
    );
    final label = playerButtonSemantics(icon); // TalkBack
    return SizedBox(
      width: size,
      height: size,
      child: onLongPress != null
          ? TvTile(
              radius: BorderRadius.circular(size),
              onTap: onTap,
              onLongPress: onLongPress,
              semanticLabel: label,
              child: child,
            )
          : FocusableTile(
              focusNode: focusNode,
              radius: BorderRadius.circular(size),
              onTap: onTap,
              semanticLabel: label,
              child: child,
            ),
    );
  }
}

class _LiveOverlay extends StatelessWidget {
  final Channel channel;
  final EpgEntry? now, next;
  final VoidCallback onBack, onTracks, onList, onPip, onPrev, onNext, onAspect, onSleep;
  final VoidCallback? onRotate;
  final VoidCallback? onSubtitleDelay;
  final VoidCallback? onAudioOnly;

  /// „Player-Engine wechseln“ (ExoPlayer ↔ mpv); null = nicht anbieten.
  final VoidCallback? onEngine;
  final String? engineLabel;
  final bool audioOnly;
  final VoidCallback? onRestart;
  final VoidCallback? onMultiview;
  final VoidCallback? onRecord;
  final VoidCallback? onZapBack;
  final VoidCallback? onFavorite;
  final bool favorite;

  /// Live-Pause: Pause/Weiter (null = Live-Puffer aus), zurück zu Live
  /// (nur im Zeitversatz) und Anzeige „−1:23 zeitversetzt“.
  final bool paused;
  final VoidCallback? onPlayPause;
  final VoidCallback? onGoLive;
  final String? shiftText;

  /// Sender-Varianten: Auswahl öffnen, Etikett der laufenden („FHD“).
  final VoidCallback? onVariants;
  final String? variantLabel;

  /// Handy/Tablet (Touch) statt Fernbedienung → Wisch-Hinweise.
  final bool touch;
  final FocusNode? mainFocus;
  const _LiveOverlay({
    this.mainFocus,
    this.paused = false,
    this.onPlayPause,
    this.onGoLive,
    this.shiftText,
    this.onVariants,
    this.variantLabel,
    this.onFavorite,
    this.favorite = false,
    this.onZapBack,
    this.onMultiview,
    this.onRecord,
    required this.onSleep,
    this.touch = false,
    this.onRestart,
    this.onRotate,
    this.onSubtitleDelay,
    this.onAudioOnly,
    this.onEngine,
    this.engineLabel,
    this.audioOnly = false,
    required this.onAspect,
    required this.channel,
    required this.now,
    required this.next,
    required this.onBack,
    required this.onTracks,
    required this.onList,
    required this.onPip,
    required this.onPrev,
    required this.onNext,
  });

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < 800;
    final t = Theme.of(context).textTheme;
    final c = channel;
    return Column(children: [
      _TopBar(
        onBack: onBack,
        onTracks: onTracks,
        onPip: onPip,
        onAspect: onAspect,
        onSleep: onSleep,
        onRotate: onRotate,
        onSubtitleDelay: onSubtitleDelay,
        onAudioOnly: onAudioOnly,
        audioOnly: audioOnly,
        onEngine: onEngine,
        engineLabel: engineLabel,
        title: Row(children: [
          const LiveBadge(),
          const SizedBox(width: 10),
          Flexible(
            child: Text(c.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: t.titleMedium?.copyWith(color: Colors.white)),
          ),
          if (variantLabel != null) ...[
            const SizedBox(width: 8),
            Tag(variantLabel!, color: Colors.white70),
          ],
        ]),
        extra: [
          if (!narrow) ...[
            LiveClock(style: t.titleMedium?.copyWith(color: Colors.white70)),
            const SizedBox(width: 16),
          ],
          if (onVariants != null) ...[
            _RoundBtn(
                key: const ValueKey('variant-btn'),
                icon: Icons.layers_rounded,
                onTap: onVariants!),
            const SizedBox(width: 8),
          ],
          if (onRestart != null) ...[
            narrow
                ? _RoundBtn(icon: Icons.replay_rounded, onTap: onRestart!)
                : _PillBtn(
                    icon: Icons.replay_rounded,
                    label: tr('Von Anfang'),
                    color: AppColors.catchup,
                    onTap: onRestart!),
            const SizedBox(width: 8),
          ],
          if (onZapBack != null) ...[
            _RoundBtn(icon: Icons.swap_horiz_rounded, onTap: onZapBack!),
            const SizedBox(width: 8),
          ],
          // Schmal (Handy hochkant): kein Platz – Favorit dort über das
          // Sendermenü bzw. die grüne Taste.
          if (onFavorite != null && !narrow) ...[
            _RoundBtn(
                icon: favorite ? Icons.star_rounded : Icons.star_border_rounded,
                onTap: onFavorite!),
            const SizedBox(width: 8),
          ],
          if (onRecord != null && !kIsWeb) ...[
            _RoundBtn(icon: Icons.fiber_manual_record_rounded, onTap: onRecord!),
            const SizedBox(width: 8),
          ],
          if (onMultiview != null) ...[
            _RoundBtn(icon: Icons.grid_view_rounded, onTap: onMultiview!),
            const SizedBox(width: 8),
          ],
          _RoundBtn(
              icon: Icons.format_list_bulleted_rounded,
              onTap: onList,
              focusNode: mainFocus),
          const SizedBox(width: 8),
        ],
      ),
      const Spacer(),
      Container(
        padding: const EdgeInsets.fromLTRB(32, 60, 32, 28),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [Color(0xEE000000), Color(0x00000000)],
          ),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Column(children: [
            _RoundBtn(icon: Icons.keyboard_arrow_up_rounded, onTap: onNext, size: 40),
            const SizedBox(height: 8),
            Text('${c.number}',
                style: const TextStyle(
                    fontFamily: 'InterDisplay',
                    fontSize: 30,
                    fontWeight: FontWeight.w800,
                    color: Colors.white)),
            const SizedBox(height: 8),
            _RoundBtn(icon: Icons.keyboard_arrow_down_rounded, onTap: onPrev, size: 40),
          ]),
          if (onPlayPause != null) ...[
            const SizedBox(width: 18),
            Padding(
              padding: const EdgeInsets.only(bottom: 34),
              child: _RoundBtn(
                  key: const ValueKey('live-pause'),
                  icon: paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
                  size: 52,
                  onTap: onPlayPause!),
            ),
          ],
          const SizedBox(width: 22),
          ChannelLogo(name: c.name, url: c.logoUrl, size: 56),
          const SizedBox(width: 22),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (shiftText != null) ...[
                  Row(children: [
                    Text(shiftText!,
                        style: t.labelLarge?.copyWith(color: AppColors.gold)),
                    if (onGoLive != null) ...[
                      const SizedBox(width: 14),
                      _PillBtn(
                          key: const ValueKey('go-live'),
                          icon: Icons.circle,
                          label: tr('Zurück zu Live'),
                          color: AppColors.live,
                          filled: true,
                          onTap: onGoLive!),
                    ],
                  ]),
                  const SizedBox(height: 8),
                ],
                if (now != null) ...[
                  Row(children: [
                    Text(tr('JETZT'),
                        style: t.labelSmall?.copyWith(color: AppColors.accent)),
                    const SizedBox(width: 10),
                    Text('${hm.format(now!.start)} – ${hm.format(now!.end)}',
                        style: t.bodySmall?.copyWith(color: Colors.white70)),
                  ]),
                  const SizedBox(height: 4),
                  Text(now!.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.headlineSmall?.copyWith(
                          color: Colors.white, fontFamily: 'InterDisplay')),
                  const SizedBox(height: 10),
                  ThinProgress(value: now!.progressAt(DateTime.now()), height: 4),
                  if (next != null) ...[
                    const SizedBox(height: 10),
                    Text(trf('DANACH  {0}  {1}', [hm.format(next!.start), next!.title]),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: t.bodySmall?.copyWith(color: Colors.white60)),
                  ],
                ] else
                  Text(tr('Keine Programminfo'),
                      style: t.titleMedium?.copyWith(color: Colors.white70)),
                const SizedBox(height: 12),
                Text(
                    touch
                        ? tr('Wischen ↕ Sender wechseln · → Senderliste')
                        : onRestart != null
                            ? tr('▲▼ Umschalten   ◀ Senderliste   0–9 Direktwahl   ◀◀ Von Anfang')
                            : tr('▲▼ Umschalten   ◀ Senderliste   0–9 Direktwahl'),
                    style: t.bodySmall?.copyWith(color: Colors.white38)),
              ],
            ),
          ),
        ]),
      ),
    ]);
  }
}

class _VodOverlay extends StatelessWidget {
  final PlayRequest req;
  final PlaybackEngine? player;
  final VoidCallback onBack, onTracks, onPip, onInteract, onAspect, onSleep;
  final VoidCallback? onRotate;
  final VoidCallback? onSubtitleDelay;
  final VoidCallback? onAudioOnly;

  /// „Player-Engine wechseln“ (ExoPlayer ↔ mpv); null = nicht anbieten.
  final VoidCallback? onEngine;
  final String? engineLabel;
  final bool audioOnly;

  /// Pause/Weiter über den Player-Zustand (merkt „vom Nutzer pausiert“).
  final VoidCallback? onPlayPause;
  final bool showControls;
  final Widget? replay;
  final FocusNode? mainFocus;
  const _VodOverlay({
    this.mainFocus,
    this.onPlayPause,
    required this.onSleep,
    this.replay,
    this.onRotate,
    this.onSubtitleDelay,
    this.onAudioOnly,
    this.onEngine,
    this.engineLabel,
    this.audioOnly = false,
    required this.onAspect,
    required this.req,
    required this.player,
    this.showControls = true,
    required this.onBack,
    required this.onTracks,
    required this.onPip,
    required this.onInteract,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final p = player;
    return Column(children: [
      _TopBar(
        onBack: onBack,
        onTracks: onTracks,
        onPip: onPip,
        onAspect: onAspect,
        onSleep: onSleep,
        onRotate: onRotate,
        onSubtitleDelay: onSubtitleDelay,
        onAudioOnly: onAudioOnly,
        audioOnly: audioOnly,
        onEngine: onEngine,
        engineLabel: engineLabel,
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(req.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: t.titleMedium?.copyWith(color: Colors.white)),
          if (req.subtitle != null && req.subtitle!.isNotEmpty)
            Text(req.subtitle!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: t.bodySmall?.copyWith(color: Colors.white70)),
        ]),
      ),
      Expanded(
        child: p == null || !showControls
            ? const SizedBox.shrink()
            : Center(
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  _RoundBtn(
                      icon: Icons.replay_10_rounded,
                      size: 56,
                      onTap: () {
                        p.seek(p.state.position - const Duration(seconds: 10));
                        onInteract();
                      }),
                  const SizedBox(width: 36),
                  StreamBuilder<bool>(
                    stream: p.stream.playing,
                    initialData: p.state.playing,
                    builder: (_, s) => _RoundBtn(
                      focusNode: mainFocus,
                      icon: s.data == true
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      size: 76,
                      onTap: () {
                        onPlayPause != null ? onPlayPause!() : p.playOrPause();
                        onInteract();
                      },
                    ),
                  ),
                  const SizedBox(width: 36),
                  _RoundBtn(
                      icon: Icons.forward_10_rounded,
                      size: 56,
                      onTap: () {
                        p.seek(p.state.position + const Duration(seconds: 10));
                        onInteract();
                      }),
                ]),
              ),
      ),
      if (p != null)
        Container(
          padding: const EdgeInsets.fromLTRB(32, 40, 32, 28),
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [Color(0xDD000000), Color(0x00000000)],
            ),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (replay != null) ...[replay!, const SizedBox(height: 14)],
            _SeekBar(player: p, onInteract: onInteract),
          ]),
        ),
    ]);
  }
}

class _SeekBar extends StatefulWidget {
  final PlaybackEngine player;
  final VoidCallback onInteract;
  const _SeekBar({required this.player, required this.onInteract});

  @override
  State<_SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<_SeekBar> {
  double? _drag;

  @override
  Widget build(BuildContext context) {
    final p = widget.player;
    return StreamBuilder<Duration>(
      stream: p.stream.position,
      initialData: p.state.position,
      builder: (_, snap) {
        final total = p.state.duration;
        final pos = snap.data ?? Duration.zero;
        final max = total.inMilliseconds.toDouble().clamp(1, double.infinity);
        final value = _drag ?? pos.inMilliseconds.toDouble().clamp(0, max);
        final style = const TextStyle(
            color: Colors.white70,
            fontSize: 13,
            fontFeatures: [FontFeature.tabularFigures()]);
        return Row(children: [
          Text(fmtClock(Duration(milliseconds: value.toInt())), style: style),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 4,
                activeTrackColor: AppColors.accent,
                inactiveTrackColor: Colors.white24,
                thumbColor: Colors.white,
                overlayShape: SliderComponentShape.noOverlay,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                // Fernbedienung: nur ◀▶ spulen; ▲▼ verlassen den Regler
                // (sonst spulen auch sie und man kommt nicht mehr weg).
                child: MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(navigationMode: NavigationMode.directional),
                  child: Slider(
                  value: value.toDouble(),
                  max: max.toDouble(),
                  onChanged: (v) {
                    widget.onInteract();
                    setState(() => _drag = v);
                  },
                  onChangeEnd: (v) {
                    p.seek(Duration(milliseconds: v.toInt()));
                    setState(() => _drag = null);
                  },
                ),
                ),
              ),
            ),
          ),
          Text(
              total == Duration.zero
                  ? '--:--'
                  : '-${fmtClock(total - Duration(milliseconds: value.toInt()))}',
              style: style),
        ]);
      },
    );
  }
}

/// Senderliste von links im Player, ohne die Wiedergabe zu stoppen.
class _ChannelDrawer extends StatefulWidget {
  final List<Channel> channels;
  final int current;
  final Map<String, List<EpgEntry>> epg;
  final ValueChanged<int> onPick;
  final VoidCallback onClose;
  const _ChannelDrawer({
    required this.channels,
    required this.current,
    required this.epg,
    required this.onPick,
    required this.onClose,
  });

  @override
  State<_ChannelDrawer> createState() => _ChannelDrawerState();
}

class _ChannelDrawerState extends State<_ChannelDrawer> {
  // Einmal anlegen: ein neuer Controller bei jedem Neuaufbau (z. B. EPG-
  // Minutentakt) würde die Liste zurückspringen lassen.
  late final _controller = ScrollController(
      initialScrollOffset:
          (widget.current - 3).clamp(0, widget.channels.length) * 68.0);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final channels = widget.channels;
    final current = widget.current;
    final epg = widget.epg;
    // Eigener Fokusbereich: Autofokus auf den laufenden Sender greift,
    // obwohl der Player gerade den Fokus hat.
    return FocusScope(
      child: Stack(children: [
      GestureDetector(
          onTap: widget.onClose, child: Container(color: Colors.black38)),
      Positioned(
        left: 0,
        top: 0,
        bottom: 0,
        width: 400,
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.bg.withValues(alpha: 0.94),
            border: const Border(right: BorderSide(color: AppColors.line)),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 28, 20, 12),
              child: Text(tr('Sender'),
                  style: Theme.of(context).textTheme.titleLarge),
            ),
            Expanded(
              child: ListView.builder(
                controller: _controller,
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 20),
                itemExtent: 68,
                itemCount: channels.length,
                itemBuilder: (_, i) {
                  final c = channels[i];
                  final now = nowPlaying(epg, c);
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: FocusableTile(
                      autofocus: i == current,
                      selected: i == current,
                      onTap: () => widget.onPick(i),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        child: Row(children: [
                          SizedBox(
                            width: 28,
                            child: Text('${c.number}',
                                style: const TextStyle(
                                    fontSize: 12, color: AppColors.textFaint)),
                          ),
                          ChannelLogo(name: c.name, url: c.logoUrl, size: 34),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(children: [
                                  Flexible(
                                    child: Text(c.name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                            fontSize: 14,
                                            fontWeight: FontWeight.w600,
                                            color: AppColors.text)),
                                  ),
                                  VariantCountBadge(channelId: c.id),
                                ]),
                                if (now != null)
                                  Text(now.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          fontSize: 12,
                                          color: AppColors.textDim)),
                              ],
                            ),
                          ),
                          if (i == current)
                            Icon(Icons.graphic_eq_rounded,
                                color: AppColors.accent, size: 18),
                        ]),
                      ),
                    ),
                  );
                },
              ),
            ),
          ]),
        ),
      ),
    ]),
    );
  }
}

/// Kleine Pille mit Icon und Text (z. B. „Von Anfang“, „LIVE“).
class _PillBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  final bool filled;
  const _PillBtn({
    super.key,
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
    this.filled = false,
  });

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 44,
        child: FocusableTile(
          radius: BorderRadius.circular(22),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: filled ? color : Colors.white.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(22),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, size: 20, color: filled ? Colors.white : color),
              const SizedBox(width: 8),
              Text(label,
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: filled ? Colors.white : Colors.white)),
            ]),
          ),
        ),
      );
}

/// Replay-Leiste: Sender, Sendezeit, vorherige/nächste Sendung, zurück zu Live.
class _ReplayBar extends StatelessWidget {
  final Channel channel;
  final EpgEntry entry;
  final VoidCallback onPrev, onNext, onLive;
  const _ReplayBar({
    required this.channel,
    required this.entry,
    required this.onPrev,
    required this.onNext,
    required this.onLive,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final running = entry.isNowAt(DateTime.now());
    return Row(children: [
      ChannelLogo(name: channel.name, url: channel.logoUrl, size: 38),
      const SizedBox(width: 14),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Tag('REPLAY', color: AppColors.catchup, filled: true),
            const SizedBox(width: 10),
            Text(
              '${hm.format(entry.start)} – ${hm.format(entry.end)}'
              '${running ? '  ·  ${tr('läuft gerade')}' : ''}',
              style: t.bodySmall?.copyWith(color: Colors.white70),
            ),
          ]),
          const SizedBox(height: 4),
          Text(entry.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: t.titleLarge?.copyWith(
                  color: Colors.white, fontFamily: 'InterDisplay')),
        ]),
      ),
      _PillBtn(
          icon: Icons.skip_previous_rounded,
          label: tr('Vorherige'),
          color: Colors.white,
          onTap: onPrev),
      const SizedBox(width: 8),
      _PillBtn(
          icon: Icons.skip_next_rounded,
          label: tr('Nächste'),
          color: Colors.white,
          onTap: onNext),
      const SizedBox(width: 8),
      _PillBtn(
          icon: Icons.circle,
          label: 'LIVE',
          color: AppColors.live,
          filled: true,
          onTap: onLive),
    ]);
  }
}

/// Kleiner, unaufdringlicher Hinweis (Wiederverbinden, Zeitversatz).
class _StatusPill extends StatelessWidget {
  final String text;
  final IconData? icon;
  final bool busy;
  const _StatusPill(
      {super.key, required this.text, this.icon, this.busy = false});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.66),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (busy)
            const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2))
          else if (icon != null)
            Icon(icon, size: 16, color: AppColors.gold),
          const SizedBox(width: 8),
          Text(text,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600)),
        ]),
      );
}
