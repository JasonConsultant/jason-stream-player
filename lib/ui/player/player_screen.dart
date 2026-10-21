import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/platform_info.dart';
import '../../core/aspect.dart';
import '../../core/languages.dart';
import '../../core/security.dart';
import '../../core/stream_errors.dart';
import '../../core/subtitle_style.dart';
import '../../core/theme.dart';
import '../../data/recordings/recordings.dart';
import '../../models/models.dart';
import '../../state/providers.dart';
import '../../state/shell_tab.dart';
import '../../state/profile_mode.dart'
    show guestModeProvider, visibleLiveDataProvider;
import '../../data/storage.dart';
import '../live/parental.dart';
import '../nav.dart' show replayRequest;
import '../widgets/artwork.dart';
import '../widgets/aspect_picker.dart';
import 'multiview_screen.dart';
import 'zap_bar.dart';
import '../widgets/common.dart';
import '../widgets/focusable_tile.dart';
import '../../l10n/strings.dart';

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
  const PlayerScreen({super.key, required this.request});

  @override
  ConsumerState<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends ConsumerState<PlayerScreen> {
  Player? _player;
  VideoController? _video;
  final _focus = FocusNode();
  final _subs = <StreamSubscription>[];

  /// Umschließt die Bedienelemente (nicht selbst fokussierbar).
  final _overlayNode = FocusNode(
      debugLabel: 'player overlay', canRequestFocus: false, skipTraversal: true);

  /// Fernbedienung: Ziel der ersten Pfeiltaste bei sichtbaren Bedienelementen
  /// (Live: Senderliste, Film: Pause/Abspielen).
  final _overlayMain = FocusNode(debugLabel: 'player overlay main');

  late PlayRequest _req = widget.request;
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

  bool get _live => _req.isLive;
  bool get _replay => _req.isReplay;
  List<Channel> get _channels => _req.channels ?? const [];

  @override
  void initState() {
    super.initState();
    if (_req.channel != null) {
      _index = _channels.indexWhere((c) => c.id == _req.channel!.id);
      if (_index < 0) _index = 0;
    }
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
    _aspect = _resolveAspect(storage);
    _prefAudio = storage.option('alang', 'auto');
    _prefSub = storage.option('slang', 'auto');
    _tv = ref.read(isTvProvider);
    _landscape = storage.flag('playerlandscape', fallback: true);
    await _applyOrientation();
    final p = Player(
      configuration: PlayerConfiguration(bufferSize: buffer * 1024 * 1024),
    );
    final v = VideoController(
      p,
      configuration: VideoControllerConfiguration(
        enableHardwareAcceleration: storage.flag('hwdec', fallback: true),
      ),
    );
    _subs.addAll([
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
        if (!done || _live || !mounted) return;
        // Replay: nahtlos zur nächsten Sendung bzw. zurück zu Live.
        if (_replay) {
          _replayStep(1, endOfShow: true);
        } else {
          Navigator.of(context).maybePop();
        }
      }),
    ]);
    if (!mounted) {
      p.dispose();
      return;
    }
    await _tuneForFastStart(p);
    setState(() {
      _player = p;
      _video = v;
    });
    await PlatformInfo.setAutoPip(storage.flag('autopip', fallback: true));
    await _open();
    _saveTimer =
        Timer.periodic(const Duration(seconds: 10), (_) => _savePosition());
  }

  void _onStreamError(String e) {
    final msg = Redactor.redact(e);
    _set(() {
      _error = msg;
      _buffering = false;
    });
    if (StreamError.classify(msg).isLocationRelated) _setUnavailable(true);
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
      if (p.state.track.subtitle != SubtitleTrack.no()) {
        p.setSubtitleTrack(SubtitleTrack.no());
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
    setState(() {
      _sleepWarning = false;
      _sleepAt = d == null ? null : DateTime.now().add(d);
    });
    if (d == null) {
      _showToast(tr('Schlaf-Timer aus'));
      return;
    }
    _showToast(trf('Schlaf-Timer: {0} Min.', [d.inMinutes]));
    // 60 s vorher warnen, dann stoppen.
    final warnAt = d - const Duration(seconds: 60);
    _sleepTimer = Timer(warnAt.isNegative ? Duration.zero : warnAt, () {
      _set(() => _sleepWarning = true);
      _sleepTick = Timer.periodic(const Duration(seconds: 1), (t) {
        if (_sleepAt == null) return t.cancel();
        if (DateTime.now().isAfter(_sleepAt!)) {
          t.cancel();
          _player?.pause();
          if (mounted) Navigator.of(context).maybePop();
        } else {
          _set(() {});
        }
      });
    });
  }

  // ---------- Ausrichtung ----------
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

  /// Schneller Senderstart: nicht 5 s lang den Stream analysieren und nicht
  /// warten, bis der Puffer voll ist, bevor das Bild kommt.
  Future<void> _tuneForFastStart(Player p) async {
    final pl = p.platform;
    if (pl is! NativePlayer) return;
    const props = {
      'demuxer-lavf-analyzeduration': '1.5', // Standard: bis zu 5 s
      'demuxer-lavf-o': 'fflags=+discardcorrupt',
      'cache-pause-initial': 'no',
      'network-timeout': '15',
      'stream-lavf-o': 'reconnect=1,reconnect_streamed=1,reconnect_delay_max=4',
    };
    for (final e in props.entries) {
      try {
        await pl.setProperty(e.key, e.value);
      } catch (_) {
        // Option wird von dieser libmpv-Version nicht unterstützt – egal.
      }
    }
  }

  /// Untertitel-Aussehen (Einstellungen → mpv). Wird bei jedem Öffnen
  /// gelesen, damit geänderte Einstellungen beim nächsten Sender greifen.
  Future<void> _applySubtitleStyle(Player p, Storage st) async {
    final pl = p.platform;
    if (pl is! NativePlayer) return;
    final style = SubtitleStyle.fromOptions(st.option);
    for (final e in style.mpvProperties.entries) {
      try {
        await pl.setProperty(e.key, e.value);
      } catch (_) {
        // Von dieser libmpv-Version nicht unterstützt – egal.
      }
    }
  }

  void _set(VoidCallback f) {
    if (mounted) setState(f);
  }

  @override
  void dispose() {
    if (_afrFps > 0) PlatformInfo.setFrameRate(0);
    _savePosition();
    _hideTimer?.cancel();
    _saveTimer?.cancel();
    _digitTimer?.cancel();
    _barTimer?.cancel();
    _toastTimer?.cancel();
    _sleepTimer?.cancel();
    _sleepTick?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    _player?.dispose();
    FocusManager.instance.removeListener(_keepFocus);
    _focus.dispose();
    _overlayNode.dispose();
    _overlayMain.dispose();
    PlatformInfo.setAutoPip(false);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    // Außerhalb des Players wieder frei drehen (folgt dem Gerät).
    SystemChrome.setPreferredOrientations(const []);
    super.dispose();
  }

  /// [quiet]: nach dem Zappen per Leiste nicht die Bedienelemente zeigen.
  Future<void> _open({bool quiet = false}) async {
    final p = _player;
    if (p == null) return;
    setState(() {
      _error = null;
      _buffering = true;
      _hasVideo = false;
    });
    final st = await ref.read(storageProvider.future);
    _set(() => _aspect = _resolveAspect(st));
    await _applySubtitleStyle(p, st);
    _userPickedTracks = false;
    var url = _live ? _channels[_index].streamUrl : _req.url;
    if (_live) {
      final cur = _channels[_index].id;
      if (_curChannelId != null && _curChannelId != cur) {
        _prevChannelId = _curChannelId;
      }
      _curChannelId = cur;
      ref.read(recentProvider.notifier).push(cur);
    }
    _afrFps = 0;
    if (_live) {
      // MAC-Portale erzeugen die Abspieladresse erst jetzt (kurzlebig).
      try {
        final repo = await ref.read(repositoryProvider.future);
        if (repo != null) url = await repo.resolveStreamUrl(_channels[_index]);
      } catch (e) {
        _set(() {
          _buffering = false;
          _error = Redactor.friendly(e);
        });
        return;
      }
    }
    if (!UrlPolicy.isStream(url)) {
      setState(() {
        _buffering = false;
        _error = tr('Diese Stream-Adresse wurde aus Sicherheitsgründen blockiert.');
      });
      return;
    }
    await p.open(Media(url, httpHeaders: const {
      'User-Agent': 'JasonStreamPlayer/0.4',
    }));

    final storage = await ref.read(storageProvider.future);
    if (_live) {
      final portal = ref.read(activePortalProvider).value;
      if (portal != null) {
        await storage.setLastChannel(portal.id, _channels[_index].id);
      }
    } else if (_req.resumeKey != null) {
      final r = storage.resume(_req.resumeKey!);
      if (r != null && r.pos > 15) {
        // Warten, bis die Länge bekannt ist, dann springen.
        await p.stream.duration
            .firstWhere((d) => d > Duration.zero)
            .timeout(const Duration(seconds: 15), onTimeout: () => Duration.zero);
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
    _grabFocus();
    if (!quiet) _showOverlay();
  }

  void _savePosition() {
    final p = _player;
    final key = _req.resumeKey;
    if (p == null || key == null || _live) return;
    final pos = p.state.position.inSeconds;
    final total = p.state.duration.inSeconds;
    if (pos < 5 || total <= 0) return;
    ref.read(storageProvider).value?.setResume(key, pos, total);
  }

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
    final pl = _player?.platform;
    if (pl is! NativePlayer || !mounted) return;
    double fps = 0;
    for (final prop in ['container-fps', 'estimated-vf-fps']) {
      try {
        fps = double.tryParse(await pl.getProperty(prop)) ?? 0;
      } catch (_) {}
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
    await _open();
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
    final j = all.indexWhere((c) => c.number == n);
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
        k == LogicalKeyboardKey.space) {
      p?.playOrPause();
      _showOverlay();
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
    final channel = _live && _channels.isNotEmpty ? _channels[_index] : null;
    final now = channel == null ? null : nowPlaying(epg, channel);
    final next = channel == null ? null : nextAfter(epg, channel, now);
    final flags = ref.watch(channelFlagsProvider).value ?? ChannelFlags.empty;
    final showBar = _bar && _live && !_list && _channels.isNotEmpty;
    final barChannel = showBar ? _channels[_wrap(_barIndex)] : null;
    final barNow = barChannel == null ? null : nowPlaying(epg, barChannel);

    return PopScope(
      canPop: !_list && !showBar,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_list) {
          setState(() => _list = false);
          _focus.requestFocus();
        } else if (_bar) {
          _hideBar();
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
              if (_video != null)
                ClipRect(
                  child: Transform.scale(
                    scale: _aspect.scale,
                    child: Video(
                      controller: _video!,
                      controls: NoVideoControls,
                      fit: _aspect.fit,
                      aspectRatio: _aspect.ratio,
                    ),
                  ),
                ),
              // Grafik mit Senderlogo, bis das erste Bild da ist
              IgnorePointer(
                child: AnimatedOpacity(
                  opacity: _hasVideo ? 0 : 1,
                  duration: const Duration(milliseconds: 300),
                  child: _LoadingArt(req: _req, channel: channel, now: now),
                ),
              ),
              if (_buffering && _error == null)
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
                          onBack: () => Navigator.maybePop(context),
                          onTracks: _showTracks,
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
                        )
                      : _VodOverlay(
                          mainFocus: _overlayMain,
                          req: _req,
                          player: _player,
                          onBack: () => Navigator.maybePop(context),
                          onTracks: _showTracks,
                          onPip: _pip,
                          onInteract: _showOverlay,
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
  final List<Widget> extra;
  const _TopBar({
    required this.title,
    required this.onBack,
    required this.onTracks,
    required this.onPip,
    required this.onAspect,
    required this.onSleep,
    this.onRotate,
    this.extra = const [],
  });

  /// Schmale Bildschirme: selten genutzte Funktionen im „⋮“-Menü.
  Future<void> _more(BuildContext context) async {
    final pick = await showModalBottomSheet<int>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
              leading: const Icon(Icons.aspect_ratio_rounded),
              title: Text(tr('Bildformat')),
              onTap: () => Navigator.pop(ctx, 0)),
          ListTile(
              leading: const Icon(Icons.subtitles_outlined),
              title: Text(tr('Tonspur & Untertitel')),
              onTap: () => Navigator.pop(ctx, 1)),
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
    }
  }

  @override
  Widget build(BuildContext context) => Container(
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
          Expanded(child: title),
          ...extra,
          if (onRotate != null) ...[
            _RoundBtn(icon: Icons.screen_rotation_rounded, onTap: onRotate!),
            const SizedBox(width: 8),
          ],
          if (MediaQuery.sizeOf(context).width < 700)
            _RoundBtn(icon: Icons.more_vert_rounded, onTap: () => _more(context))
          else ...[
            _RoundBtn(icon: Icons.aspect_ratio_rounded, onTap: onAspect),
            const SizedBox(width: 8),
            _RoundBtn(icon: Icons.subtitles_outlined, onTap: onTracks),
            const SizedBox(width: 8),
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
  final double size;
  final FocusNode? focusNode;
  const _RoundBtn(
      {required this.icon, required this.onTap, this.size = 44, this.focusNode});

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size,
        child: FocusableTile(
          focusNode: focusNode,
          radius: BorderRadius.circular(size),
          onTap: onTap,
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: Colors.white, size: size * 0.5),
          ),
        ),
      );
}

class _LiveOverlay extends StatelessWidget {
  final Channel channel;
  final EpgEntry? now, next;
  final VoidCallback onBack, onTracks, onList, onPip, onPrev, onNext, onAspect, onSleep;
  final VoidCallback? onRotate;
  final VoidCallback? onRestart;
  final VoidCallback? onMultiview;
  final VoidCallback? onRecord;
  final VoidCallback? onZapBack;
  final VoidCallback? onFavorite;
  final bool favorite;

  /// Handy/Tablet (Touch) statt Fernbedienung → Wisch-Hinweise.
  final bool touch;
  final FocusNode? mainFocus;
  const _LiveOverlay({
    this.mainFocus,
    this.onFavorite,
    this.favorite = false,
    this.onZapBack,
    this.onMultiview,
    this.onRecord,
    required this.onSleep,
    this.touch = false,
    this.onRestart,
    this.onRotate,
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
    final narrow = MediaQuery.sizeOf(context).width < 700;
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
        title: Row(children: [
          const LiveBadge(),
          const SizedBox(width: 10),
          Flexible(
            child: Text(c.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: t.titleMedium?.copyWith(color: Colors.white)),
          ),
        ]),
        extra: [
          if (!narrow) ...[
            LiveClock(style: t.titleMedium?.copyWith(color: Colors.white70)),
            const SizedBox(width: 16),
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
          const SizedBox(width: 22),
          ChannelLogo(name: c.name, url: c.logoUrl, size: 56),
          const SizedBox(width: 22),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
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
  final Player? player;
  final VoidCallback onBack, onTracks, onPip, onInteract, onAspect, onSleep;
  final VoidCallback? onRotate;
  final bool showControls;
  final Widget? replay;
  final FocusNode? mainFocus;
  const _VodOverlay({
    this.mainFocus,
    required this.onSleep,
    this.replay,
    this.onRotate,
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
                        p.playOrPause();
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
  final Player player;
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
                                Text(c.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600,
                                        color: AppColors.text)),
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
                            const Icon(Icons.graphic_eq_rounded,
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
