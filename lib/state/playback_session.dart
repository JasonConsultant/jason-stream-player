import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/app_messages.dart';
import '../core/platform_info.dart';
import '../core/security.dart';
import '../data/reminders/reminders.dart' show NativeReminders;
import '../l10n/strings.dart';
import '../models/models.dart';
import '../player/cast.dart';
import '../player/data_saver.dart';
import '../player/engine.dart';
import '../player/exo_engine.dart';
import '../player/media_session.dart';
import '../player/mpv_engine.dart';
import '../player/zap_guard.dart';
import '../ui/player/mpv_tuning.dart';
import '../ui/player/reconnect.dart' show StartMemory;
import '../ui/player/stream_open_headers.dart';
import '../ui/player/stream_url.dart';
import '../ui/player/subtitle_delay.dart';
import 'providers.dart';

/// Legt die Engine nach [EngineConfig.engine] an: „exo“ = Media3/ExoPlayer
/// (Android-Standard), sonst mpv (media_kit). Tests überschreiben mit einer
/// Fake-Engine.
final playbackEngineProvider = Provider<EngineFactory>(
    (_) => (c) => c.engine == 'exo' ? ExoEngine.create(c) : MpvEngine.create(c));

/// Zuletzt erfolgreiche Start-Stufe je Sender/Film (nur diese Sitzung;
/// die Engine-Wahl merkt sich [EngineMemory] dauerhaft).
final startMemoryProvider = Provider<StartMemory>((_) => StartMemory());

/// Systemanbindung (Benachrichtigung, Kopfhörer, Audio-Fokus).
final mediaSessionProvider = Provider<MediaSessionBridge>(
    (_) => MediaSessionBridge.instance ?? NoopMediaSession());

/// Einstellung „Beim Verlassen des Players“ (Zurück-Taste, nur Handy/Tablet).
enum LeaveAction {
  mini('mini'),
  pip('pip'),
  stop('stop');

  const LeaveAction(this.id);
  final String id;
  static const optionKey = 'leaveplayer';
  static LeaveAction fromId(String? id) => switch (id) {
        'pip' => pip,
        'stop' => stop,
        _ => mini,
      };
}

/// Wo der laufende Stream gerade zu sehen ist.
enum PlayerSurface {
  /// Kein Stream.
  none,

  /// Player-Seite offen (oder gerade im Öffnen).
  fullscreen,

  /// Mini-Player über der Shell.
  mini,
}

/// Darf die Wiedergabestelle gemerkt werden? Nicht bei Live, nicht in den
/// ersten Sekunden und nicht, solange ein neuer Stream geöffnet wird (die
/// Stelle gehört dann noch zum vorigen – etwa beim Wechsel zur nächsten
/// Folge).
bool canSaveResume(
        {required bool live,
        required bool opening,
        required int pos,
        required int total}) =>
    !live && !opening && pos >= 5 && total > 0;

/// Ein laufender Stream: Engine samt allem, was an die Engine-Instanz
/// gebunden ist. Überlebt die Player-Seite (Mini-Player, Nur-Ton).
class PlaybackSession {
  final PlaybackEngine engine;

  /// Fortlaufende Nummer (Tests: dieselbe Instanz nach dem Zurückkehren?).
  final int serial;
  PlayRequest request;

  /// Live: Position des laufenden Senders in [PlayRequest.channels].
  int index;

  /// Engine-Eigenschaften, die diese Instanz schon hat (nur Änderungen
  /// gehen raus).
  final MpvProps props;

  /// Untertitel-Verzögerung (Reset bei neuem Inhalt durch den Player).
  final SubtitleDelay subDelay;

  /// hwdec-Ausgangswert und ob Software-Dekodierung als Notlösung läuft.
  String? hwdecDefault;
  bool swDecode = false;
  final VideoOutput videoOut;
  final int bufferBytes;

  /// Konfiguration, mit der die Engine angelegt wurde (Engine-Wechsel).
  final EngineConfig config;

  /// Medienserver (Emby): Anfrage mit laufender Sitzung (Start gemeldet).
  PlayRequest? remoteReq;

  /// Nur-Ton (Video abgewählt).
  bool audioOnly = false;

  /// Der Player öffnet gerade einen neuen Stream (Position nicht speichern).
  bool opening = false;

  /// Zuletzt geöffnete Adresse samt Kopfzeilen (Übergabe an ein
  /// Cast-Gerät und Rückgabe). Enthält ggf. Zugangsdaten – nie loggen.
  String? sourceUrl;
  Map<String, String> sourceHeaders = const {};

  PlaybackSession({
    required this.engine,
    required this.serial,
    required this.request,
    required this.index,
    required this.videoOut,
    required this.bufferBytes,
    this.config = const EngineConfig(),
  })  : props = MpvProps(engine.setOption),
        subDelay = SubtitleDelay(engine.setOption);

  bool get live => request.isLive;
  List<Channel> get channels => request.channels ?? const [];
  Channel? get channel =>
      live && channels.isNotEmpty ? channels[index.clamp(0, channels.length - 1)] : request.channel;
}

/// Was die Oberfläche (Mini-Player) vom laufenden Stream wissen muss.
@immutable
class PlaybackSnapshot {
  final PlayerSurface surface;
  final int serial;
  final String title;
  final String? subtitle;
  final String? artUrl;
  final bool live;
  final bool playing;
  final bool buffering;
  final bool hasVideo;
  final bool audioOnly;
  final bool canZap;

  /// Läuft auf einem Cast-Gerät (Name), sonst null.
  final String? castDevice;
  const PlaybackSnapshot({
    this.surface = PlayerSurface.none,
    this.serial = 0,
    this.title = '',
    this.subtitle,
    this.artUrl,
    this.live = false,
    this.playing = false,
    this.buffering = false,
    this.hasVideo = false,
    this.audioOnly = false,
    this.canZap = false,
    this.castDevice,
  });

  static const none = PlaybackSnapshot();

  bool get active => surface != PlayerSurface.none;
  bool get showMini => surface == PlayerSurface.mini;
  bool get casting => castDevice != null;

  @override
  bool operator ==(Object other) =>
      other is PlaybackSnapshot &&
      other.surface == surface &&
      other.serial == serial &&
      other.title == title &&
      other.subtitle == subtitle &&
      other.artUrl == artUrl &&
      other.live == live &&
      other.playing == playing &&
      other.buffering == buffering &&
      other.hasVideo == hasVideo &&
      other.audioOnly == audioOnly &&
      other.canZap == canZap &&
      other.castDevice == castDevice;

  @override
  int get hashCode => Object.hash(surface, serial, title, subtitle, artUrl,
      live, playing, buffering, hasVideo, audioOnly, canZap, castDevice);
}

/// Langlebiger Besitzer der Player-Instanz (überlebt den Navigator). Die
/// Player-Seite bindet sich daran; Mini-Player und Benachrichtigung bedienen
/// ihn direkt.
class PlaybackController extends Notifier<PlaybackSnapshot> {
  PlaybackSession? session;
  final _subs = <StreamSubscription>[];
  int _serial = 0;
  Timer? _sleep;
  Timer? _tick;
  DateTime? sleepAt;
  static const _volume = 100.0;

  /// Player-Seite angebunden: Zappen (Benachrichtigung) geht über sie.
  Future<void> Function(int dir)? zapHandler;

  /// Zapping-Schutz ohne Player-Seite (Benachrichtigung/Mini-Player).
  final _zapGuard = ZapGuard();
  Timer? _zapTimer;

  bool _disposed = false;

  @override
  PlaybackSnapshot build() {
    ref.listen(castProvider, _onCast);
    final castErrors =
        ref.read(castProvider.notifier).errors.listen(_onCastError);
    ref.onDispose(() {
      _disposed = true;
      _zapTimer?.cancel();
      castErrors.cancel();
      _cancel();
      _sleep?.cancel();
      _tick?.cancel();
      final s = session;
      session = null;
      if (s != null) unawaited(s.engine.dispose());
    });
    return PlaybackSnapshot.none;
  }

  /// Fernseher: keine Benachrichtigung/Audio-Fokus (Verhalten unverändert).
  final _noop = NoopMediaSession();
  MediaSessionBridge get _media =>
      ref.read(isTvProvider) ? _noop : ref.read(mediaSessionProvider);

  void _cancel() {
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
  }

  /// Neuen Stream beginnen: alte Instanz weg, neue Engine anlegen.
  Future<PlaybackSession> start(PlayRequest req,
      {required EngineConfig config,
      VideoOutput videoOut = VideoOutput.standard}) async {
    await stop(keepSleep: true);
    final engine = await ref.read(playbackEngineProvider)(config);
    var index = 0;
    if (req.channel != null && req.channels != null) {
      index = req.channels!.indexWhere((c) => c.id == req.channel!.id);
      if (index < 0) index = 0;
    }
    final s = session = PlaybackSession(
      engine: engine,
      serial: ++_serial,
      request: req,
      index: index,
      videoOut: videoOut,
      bufferBytes: config.bufferBytes,
      config: config,
    );
    _bind(s);
    _media.attach(MediaSessionCallbacks(
      onPlay: () => setPaused(false),
      onPause: () => setPaused(true),
      onStop: () => stop(),
      onZap: (d) => zap(d),
      onSeek: (p) async => casting
          ? ref.read(castApiProvider).seek(p)
          : session?.engine.seek(p),
      // Anruf/Benachrichtigungston betreffen das Handy, nicht den Fernseher.
      onDuck: (on) async {
        if (!casting) await _duck(on);
      },
      onInterrupt: () async {
        if (!casting) await setPaused(true);
      },
      onInterruptEnd: () async {
        if (!casting) await setPaused(false);
      },
    ));
    _surface = PlayerSurface.fullscreen;
    _publish();
    // Auch ohne Player-Seite (Mini-Player): Position merken, Benachrichtigung
    // (Spulbalken) nachführen.
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 10), (_) {
      saveResume();
      _publish();
    });
    unawaited(_askNotifications());
    return s;
  }

  void _bind(PlaybackSession s) {
    final engine = s.engine;
    _subs.addAll([
      engine.stream.playing.listen((_) => _publish()),
      engine.stream.buffering.listen((_) => _publish()),
      engine.stream.width.listen((_) => _publish()),
      engine.stream.completed.listen((done) {
        // Ohne Player-Seite (Mini-Player): Film zu Ende → aufräumen.
        if (done && state.surface == PlayerSurface.mini && !s.live) stop();
      }),
    ]);
  }

  /// Engine des laufenden Streams tauschen (Rückfall ExoPlayer → mpv oder
  /// „Engine wechseln“): gleiche Anfrage, Medienserver-Sitzung und Nur-Ton
  /// bleiben, die alte Engine wird freigegeben. Öffnen macht die
  /// Player-Seite.
  Future<PlaybackSession?> swapEngine(String engineId) async {
    final old = session;
    if (old == null) return null;
    final config = old.config.withEngine(engineId);
    final engine = await ref.read(playbackEngineProvider)(config);
    if (_disposed || session != old) {
      unawaited(engine.dispose());
      return null;
    }
    _cancel();
    final s = session = PlaybackSession(
      engine: engine,
      serial: ++_serial,
      request: old.request,
      index: old.index,
      videoOut: old.videoOut,
      bufferBytes: old.bufferBytes,
      config: config,
    )
      ..remoteReq = old.remoteReq
      ..audioOnly = old.audioOnly
      ..sourceUrl = old.sourceUrl
      ..sourceHeaders = old.sourceHeaders;
    _bind(s);
    _publish();
    try {
      await old.engine.dispose();
    } catch (_) {}
    // Untertitel-Verzögerung gilt weiter (neue Engine bekommt den Wert).
    if (!old.subDelay.isZero) await s.subDelay.setSeconds(old.subDelay.seconds);
    return s;
  }

  /// Android 13+: Benachrichtigungen einmalig erlauben lassen (für die
  /// Medien-Steuerung auf dem Sperrbildschirm). Nur Handy/Tablet, einmal.
  static const _notifyKey = 'mediaNotifyAsked';
  Future<void> _askNotifications() async {
    if (!PlatformInfo.isAndroid || ref.read(isTvProvider) || _disposed) return;
    final st = ref.read(storageProvider).value;
    if (st == null || st.flag(_notifyKey)) return;
    await st.setFlag(_notifyKey, true);
    await NativeReminders().requestNotify();
  }

  PlayerSurface _surface = PlayerSurface.none;

  /// Player-Seite zeigt den Stream (Mini-Player weg).
  void toFullscreen() {
    if (session == null) return;
    _surface = PlayerSurface.fullscreen;
    _publish();
  }

  /// Player-Seite verlassen, Stream läuft im Mini-Player weiter.
  void toMini() {
    if (session == null) return;
    _surface = PlayerSurface.mini;
    zapHandler = null;
    _publish();
  }

  /// Anfrage geändert (Zappen, nächste Folge, Replay) → Anzeige anpassen.
  void setRequest(PlayRequest req, {int? index}) {
    final s = session;
    if (s == null) return;
    s.request = req;
    if (index != null) {
      s.index = index;
    } else if (req.channel != null && req.channels != null) {
      final i = req.channels!.indexWhere((c) => c.id == req.channel!.id);
      if (i >= 0) s.index = i;
    }
    _publish();
  }

  /// Position merken, Medienserver-Sitzung beenden, Engine freigeben.
  Future<void> stop({bool keepSleep = false}) async {
    final s = session;
    if (!keepSleep) _clearSleep();
    if (s == null) return;
    // Läuft auf dem Fernseher: dort ebenfalls anhalten (Verbindung bleibt).
    if (_castRun != null) {
      _castRun = null;
      unawaited(ref.read(castApiProvider).stop());
    }
    session = null;
    zapHandler = null;
    _zapTimer?.cancel();
    _zapTimer = null;
    _cancel();
    _tick?.cancel();
    _tick = null;
    saveResume(s);
    endRemote(s);
    _surface = PlayerSurface.none;
    _publish();
    if (!_disposed) {
      _media.detach();
      unawaited(_media.idle());
    }
    try {
      await s.engine.dispose();
    } catch (_) {}
  }

  /// Wiedergabestelle (Filme/Folgen) merken und ggf. an den Medienserver
  /// melden – vom Player alle 10 s und beim Verlassen/Schließen.
  void saveResume([PlaybackSession? which]) {
    final s = which ?? session;
    if (s == null) return;
    final key = s.request.resumeKey;
    if (key == null) return;
    final st = s.engine.state;
    final r = s.remoteReq;
    final casting = _castRun != null && identical(s, session);
    final position = casting ? _castPosition : st.position;
    if (r != null && identical(r, s.request) && !s.opening) {
      unawaited(r.remote?.progress(position,
          paused: casting ? !state.playing : !st.playing));
    }
    final pos = position.inSeconds;
    final total = st.duration.inSeconds;
    if (!canSaveResume(
        live: s.live, opening: s.opening, pos: pos, total: total)) {
      return;
    }
    if (_disposed) return;
    ref.read(storageProvider).value?.setResume(key, pos, total);
  }

  /// Medienserver-Sitzung beenden (Ende melden).
  void endRemote([PlaybackSession? which]) {
    final s = which ?? session;
    final r = s?.remoteReq;
    if (s == null || r == null) return;
    s.remoteReq = null;
    unawaited(r.remote?.stopped(s.engine.state.position));
  }

  // ---------- Bedienung (Mini-Player, Benachrichtigung) ----------
  Future<void> setPaused(bool paused) async {
    final s = session;
    if (s == null) return;
    if (casting) {
      final api = ref.read(castApiProvider);
      await (paused ? api.pause() : api.play());
      return;
    }
    if (paused) {
      await s.engine.pause();
    } else {
      await s.engine.play();
    }
    _publish();
  }

  Future<void> playPause() => setPaused(casting
      ? state.playing
      : (session?.engine.state.playing ?? false));

  Future<void> _duck(bool on) async {
    final s = session;
    if (s == null) return;
    try {
      await s.engine.setVolume(on ? _volume * 0.25 : _volume);
    } catch (_) {}
  }

  /// Nur-Ton: Video abwählen (Akku/Daten), Ton läuft weiter.
  Future<void> setAudioOnly(bool on) async {
    final s = session;
    if (s == null || s.audioOnly == on) return;
    s.audioOnly = on;
    _publish();
    try {
      await s.engine.setVideoEnabled(!on);
    } catch (_) {}
  }

  /// Live: Sender wechseln (Benachrichtigung CH+/CH−, Mini-Player). Mit
  /// Player-Seite über deren Zapping (Verlauf, Varianten, Leiste); ohne sie
  /// vereinfacht direkt über die Engine.
  Future<void> zap(int dir) async {
    final s = session;
    if (s == null || !s.live || s.channels.length < 2) return;
    final h = zapHandler;
    if (h != null) return h(dir);
    final n = s.channels.length;
    final i = (((s.index + dir) % n) + n) % n;
    final target = s.channels[i];
    final flags = ref.read(channelFlagsProvider).value;
    if (flags != null && flags.locked.contains(target.id)) return; // PIN nötig
    setRequest(
        PlayRequest(
          title: target.name,
          url: target.streamUrl,
          isLive: true,
          channels: s.channels,
          channel: target,
          artworkSeed: target.name,
        ),
        index: i);
    // Zapping-Schutz: schnelle Folge → Anzeige sofort, Öffnen nach Ruhe.
    final wait = _zapGuard.press(clock.now());
    _zapTimer?.cancel();
    _zapTimer = null;
    if (wait == Duration.zero) return _zapOpen(s, target);
    _zapTimer = Timer(wait, () {
      _zapTimer = null;
      if (identical(session, s)) unawaited(_zapOpen(s, target));
    });
  }

  /// Stream des Senders [target] ohne Player-Seite öffnen.
  Future<void> _zapOpen(PlaybackSession s, Channel target) async {
    s.opening = true;
    try {
      final portal = ref.read(activePortalProvider).value;
      final url = await resolveLiveUrl(
        target,
        portal: portal,
        current: ref.read(repositoryProvider),
        repo: () => ref.read(repositoryProvider.future),
      );
      if (!UrlPolicy.isStream(url) || session != s) return;
      final headers = playerHeadersFor(portal, target);
      s
        ..sourceUrl = url
        ..sourceHeaders = headers;
      if (_castRun != null) {
        // Läuft auf dem Fernseher: dort umschalten, lokal bleibt still.
        await _castStartRun(s, live: true, start: Duration.zero);
      } else {
        await s.props.apply({
          'user-agent': headerValue(headers, 'User-Agent') ?? '',
          'referrer': headerValue(headers, 'Referer') ?? '',
          ...DataSaverTuning.mpv(ref.read(dataSaverActiveProvider)),
        });
        await s.engine.open(url, headers: headers, live: true);
      }
      ref.read(recentProvider.notifier).push(target.id);
      if (portal != null) {
        ref.read(storageProvider).value?.setLastChannel(portal.id, target.id);
      }
    } catch (_) {
      // Fehler zeigt die Player-Seite beim nächsten Öffnen.
    } finally {
      s.opening = false;
    }
  }

  // ---------- Chromecast ----------
  _CastRun? _castRun;

  /// Läuft der Stream gerade auf einem Cast-Gerät?
  bool get casting => _castRun != null;

  Duration get _castPosition => ref.read(castProvider.notifier).lastPosition;

  /// Player-Seite: Stream ist geöffnet ([url] mit [headers]) – merken für
  /// die Übergabe. Besteht schon eine Cast-Verbindung, geht der neue Inhalt
  /// gleich auf das Gerät.
  /// [url] null = nichts übergebbar (z. B. heruntergeladene Datei).
  void noteSource(String? url, Map<String, String> headers) {
    final s = session;
    if (s == null) return;
    s
      ..sourceUrl = url
      ..sourceHeaders = headers;
  }

  /// Nach dem Öffnen auf der Player-Seite: verbunden → auf das Gerät.
  Future<void> followCast() async {
    if (casting || !ref.read(castProvider).connected) return;
    await castCurrent();
  }

  void _onCast(CastState? prev, CastState next) {
    final was = prev?.connected ?? false;
    if (next.connected && !was) {
      // Frisch verbunden: laufenden Inhalt übergeben.
      if (session != null && !casting) unawaited(castCurrent());
    } else if (was && !next.connected && casting) {
      // Getrennt (auch vom Fernseher aus): lokal an der Stelle weiter.
      unawaited(_castBack());
    } else if (casting) {
      _publish();
    }
  }

  /// Laufenden Inhalt an das verbundene Gerät übergeben (Live ab
  /// Live-Kante, Filme/Folgen ab der aktuellen Stelle). Lokal: Live stoppt,
  /// Filme pausieren. Die Player-Seite schließt sich (Mini-Player).
  Future<bool> castCurrent() async {
    final s = session;
    if (s == null || s.sourceUrl == null || !ref.read(castProvider).connected) {
      return false;
    }
    final start = s.live ? Duration.zero : s.engine.state.position;
    ref.read(castProvider.notifier).lastPosition = start;
    _surface = PlayerSurface.mini;
    zapHandler = null;
    try {
      if (s.live) {
        await s.engine.stop();
      } else {
        await s.engine.pause();
      }
    } catch (_) {}
    if (session != s) return false;
    return _castStartRun(s, live: s.live, start: start);
  }

  Future<bool> _castStartRun(PlaybackSession s,
      {required bool live, required Duration start}) async {
    final run = _castRun =
        _CastRun(castCandidates(s.sourceUrl!, live: live), live, start);
    _publish();
    return _castLoad(s, run);
  }

  /// Kandidaten der Reihe nach laden (HLS-Variante zuerst).
  Future<bool> _castLoad(PlaybackSession s, _CastRun run) async {
    final api = ref.read(castApiProvider);
    while (run.index < run.candidates.length) {
      final c = run.candidates[run.index];
      run.loaded = false;
      final r = await api.load(
        url: c.url,
        mime: c.mime,
        live: run.live,
        position: run.start,
        title: state.title,
        subtitle: s.live ? null : s.request.subtitle,
        image: UrlPolicy.isWeb(state.artUrl) ? state.artUrl : null,
      );
      if (_disposed || _castRun != run || session != s) return false;
      if (r.ok) {
        run.loaded = true;
        return true;
      }
      run.index++;
    }
    await _castFailed(s);
    return false;
  }

  /// Gerät meldet Wiedergabefehler bzw. Ende.
  void _onCastError(String what) {
    if (_disposed) return;
    if (what == 'connect') {
      AppMessages.show(tr('Verbindung zum Cast-Gerät fehlgeschlagen'));
      return;
    }
    final run = _castRun;
    final s = session;
    if (run == null || s == null) return;
    if (what == 'finished') {
      if (!run.live) stop();
      return;
    }
    if (what == 'error' && run.loaded) {
      // Geladen, aber nicht abspielbar → nächste Variante bzw. aufgeben.
      run.loaded = false;
      run.index++;
      if (run.index < run.candidates.length) {
        unawaited(_castLoad(s, run));
      } else {
        unawaited(_castFailed(s));
      }
    }
  }

  Future<void> _castFailed(PlaybackSession s) async {
    AppMessages.show(s.live
        ? tr('Dieser Sender kann nicht gestreamt werden')
        : tr('Dieser Inhalt kann nicht gestreamt werden'));
    await _castBack();
  }

  /// Zurück aufs Handy: Filme an der Stelle des Geräts, Live neu öffnen.
  Future<void> _castBack() async {
    final run = _castRun;
    _castRun = null;
    final s = session;
    if (run == null || s == null) return;
    final pos = _castPosition;
    _publish();
    try {
      if (s.live) {
        final url = s.sourceUrl;
        if (url != null) {
          await s.engine.open(url, headers: s.sourceHeaders, live: true);
        }
      } else {
        if (pos > Duration.zero) await s.engine.seek(pos);
        await s.engine.play();
      }
    } catch (_) {}
    _publish();
  }

  /// Verbindung trennen (Wiedergabe kommt aufs Handy zurück).
  Future<void> disconnectCast() => ref.read(castProvider.notifier).disconnect();

  // ---------- Schlaf-Timer ----------
  /// Stoppt die Wiedergabe zum Zeitpunkt [at] (null = aus). Gilt auch im
  /// Mini-Player.
  void setSleep(DateTime? at) {
    _clearSleep();
    sleepAt = at;
    if (at == null) return;
    final d = at.difference(DateTime.now());
    _sleep = Timer(d.isNegative ? Duration.zero : d, () {
      sleepAt = null;
      stop();
    });
  }

  void _clearSleep() {
    _sleep?.cancel();
    _sleep = null;
    sleepAt = null;
  }

  // ---------- Anzeige ----------
  void _publish() {
    if (_disposed) return;
    final s = session;
    if (s == null) {
      state = PlaybackSnapshot.none;
      return;
    }
    final st = s.engine.state;
    final c = s.live ? s.channel : null;
    final req = s.request;
    final title = s.live ? (c?.name ?? req.title) : req.title;
    final cast = _castRun != null ? ref.read(castProvider) : null;
    final device = cast == null ? null : (cast.device ?? tr('Fernseher'));
    // Auf dem Cast-Gerät: „Läuft auf …“ statt Untertitel, Zustand vom Gerät.
    final sub = device != null
        ? trf('Läuft auf {0}', [device])
        : (s.live ? null : req.subtitle);
    final playing = cast != null
        ? cast.player == CastPlayer.playing ||
            cast.player == CastPlayer.buffering
        : st.playing;
    final buffering =
        cast != null ? cast.player == CastPlayer.buffering : st.buffering;
    state = PlaybackSnapshot(
      surface: _surface,
      serial: s.serial,
      title: title,
      subtitle: sub,
      artUrl: s.live ? c?.logoUrl : req.artworkUrl,
      live: s.live,
      playing: playing,
      buffering: buffering,
      hasVideo: cast == null && st.hasVideo,
      audioOnly: s.audioOnly,
      canZap: s.live && s.channels.length > 1,
      castDevice: device,
    );
    unawaited(_media.update(MediaInfo(
      title: title,
      subtitle: sub,
      artUrl: state.artUrl,
      live: s.live,
      playing: playing,
      buffering: buffering,
      canZap: state.canZap,
      position: cast != null ? _castPosition : st.position,
      duration: st.duration,
    )));
  }
}

final playbackProvider =
    NotifierProvider<PlaybackController, PlaybackSnapshot>(
        PlaybackController.new);

/// Ein Cast-Versuch: Kandidaten-Adressen und wo wir stehen.
class _CastRun {
  final List<CastSource> candidates;
  final bool live;
  final Duration start;
  int index = 0;

  /// Gerät hat die aktuelle Adresse angenommen.
  bool loaded = false;
  _CastRun(this.candidates, this.live, this.start);
}
