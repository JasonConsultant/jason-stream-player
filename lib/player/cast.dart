import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:jsp_exoplayer/jsp_cast.dart';

import '../core/platform_info.dart';
import '../state/providers.dart';

/// Ein Cast-Gerät im Heimnetz.
@immutable
class CastDevice {
  final String id;
  final String name;
  const CastDevice(this.id, this.name);

  @override
  bool operator ==(Object other) =>
      other is CastDevice && other.id == id && other.name == name;
  @override
  int get hashCode => Object.hash(id, name);
}

enum CastPhase { idle, connecting, connected }

/// Zustand der Fernwiedergabe auf dem Cast-Gerät.
enum CastPlayer { idle, buffering, playing, paused }

@immutable
class CastState {
  final List<CastDevice> devices;
  final CastPhase phase;

  /// Name des verbundenen Geräts.
  final String? device;
  final CastPlayer player;
  final Duration position;
  const CastState({
    this.devices = const [],
    this.phase = CastPhase.idle,
    this.device,
    this.player = CastPlayer.idle,
    this.position = Duration.zero,
  });

  static const none = CastState();

  bool get connected => phase == CastPhase.connected;

  /// Cast-Knopf zeigen? Nur, wenn ein Gerät gefunden wurde (oder schon
  /// eine Verbindung besteht).
  bool get available => devices.isNotEmpty || phase != CastPhase.idle;

  CastState copyWith({
    List<CastDevice>? devices,
    CastPhase? phase,
    String? device,
    bool clearDevice = false,
    CastPlayer? player,
    Duration? position,
  }) =>
      CastState(
        devices: devices ?? this.devices,
        phase: phase ?? this.phase,
        device: clearDevice ? null : (device ?? this.device),
        player: player ?? this.player,
        position: position ?? this.position,
      );

  @override
  bool operator ==(Object other) =>
      other is CastState &&
      other.phase == phase &&
      other.device == device &&
      other.player == player &&
      other.position == position &&
      _sameDevices(other.devices, devices);

  static bool _sameDevices(List<CastDevice> a, List<CastDevice> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode =>
      Object.hash(phase, device, player, position, Object.hashAll(devices));
}

/// Was an das Cast-Gerät geht: Adresse und MIME-Typ.
@immutable
class CastSource {
  final String url;
  final String mime;
  const CastSource(this.url, this.mime);
  @override
  bool operator ==(Object other) =>
      other is CastSource && other.url == url && other.mime == mime;
  @override
  int get hashCode => Object.hash(url, mime);
  @override
  String toString() => 'CastSource($mime)'; // nie die Adresse (Zugangsdaten)
}

/// MIME-Typen, die der Default Media Receiver kennt.
abstract final class CastMime {
  static const hls = 'application/x-mpegURL';
  static const dash = 'application/dash+xml';
  static const mp4 = 'video/mp4';
  static const ts = 'video/mp2t';
  static const mkv = 'video/x-matroska';
  static const webm = 'video/webm';
  static const mp3 = 'audio/mpeg';
  static const aac = 'audio/aac';

  static String? _byExt(String ext) => switch (ext) {
        'm3u8' || 'm3u' => hls,
        'mpd' => dash,
        'mp4' || 'm4v' || 'mov' => mp4,
        'ts' || 'mpegts' || 'm2ts' => ts,
        'mkv' => mkv,
        'webm' => webm,
        'mp3' => mp3,
        'aac' || 'm4a' => aac,
        _ => null,
      };

  /// MIME-Typ nach Dateiendung bzw. Hinweisen in der Adresse; Live ohne
  /// Endung = MPEG-TS (typisch IPTV), Filme ohne Endung = MP4.
  static String of(String url, {required bool live}) {
    final u = Uri.tryParse(url);
    final path = (u?.path ?? url).toLowerCase();
    final dot = path.lastIndexOf('.');
    final slash = path.lastIndexOf('/');
    if (dot > slash && dot >= 0) {
      final m = _byExt(path.substring(dot + 1));
      if (m != null) return m;
    }
    final q = u?.queryParameters ?? const {};
    for (final k in const ['container', 'Container', 'extension', 'output']) {
      final m = _byExt((q[k] ?? '').toLowerCase());
      if (m != null) return m;
    }
    if (url.toLowerCase().contains('m3u8')) return hls;
    return live ? ts : mp4;
  }
}

/// Reihenfolge der Versuche: Xtream-Live-Adressen (`/live/u/p/1.ts`) gibt
/// es meist auch als HLS (`.m3u8`) – das kann der Receiver, rohes MPEG-TS
/// meist nicht. Danach die Originaladresse.
List<CastSource> castCandidates(String url, {required bool live}) {
  final out = <CastSource>[];
  final u = Uri.tryParse(url);
  if (live && u != null) {
    final seg = u.pathSegments;
    final last = seg.isEmpty ? '' : seg.last.toLowerCase();
    if (seg.length >= 4 && seg.contains('live') && last.endsWith('.ts')) {
      final hlsSeg = [...seg]..last =
          '${seg.last.substring(0, seg.last.length - 3)}.m3u8';
      out.add(CastSource(
          u.replace(pathSegments: hlsSeg).toString(), CastMime.hls));
    }
  }
  out.add(CastSource(url, CastMime.of(url, live: live)));
  return out;
}

/// Plattformanbindung (Tests: gemockter Kanal oder eigenes Objekt).
final castApiProvider = Provider<JspCast>((_) => const JspCast());

/// Gibt es Cast auf diesem Gerät? (Android-Handy/Tablet; TV nie.)
final castSupportedProvider = Provider<bool>(
    (ref) => PlatformInfo.isAndroid && !ref.watch(isTvProvider));

/// Gerätesuche und Sitzung. Die Übergabe des laufenden Streams macht der
/// PlaybackController (er hört auf diesen Zustand).
class CastController extends Notifier<CastState> {
  StreamSubscription? _sub;
  AppLifecycleListener? _life;
  final _errors = StreamController<String>.broadcast();

  /// Letzte Position vom Gerät (auch nach dem Trennen noch gültig).
  Duration lastPosition = Duration.zero;

  /// Fehlercodes/Abbrüche des Geräts (Ladefehler, Wiedergabefehler).
  Stream<String> get errors => _errors.stream;

  JspCast get api => ref.read(castApiProvider);

  @override
  CastState build() {
    final api = this.api;
    final supported = ref.watch(castSupportedProvider);
    ref.onDispose(() {
      _sub?.cancel();
      _sub = null;
      _life?.dispose();
      _life = null;
      if (supported) unawaited(api.stopDiscovery());
    });
    if (!supported) return CastState.none;
    _sub = api.events().listen(_onEvent, onError: (Object _) {});
    unawaited(api.startDiscovery());
    try {
      // Suche nur im Vordergrund (Akku).
      _life = AppLifecycleListener(
        onResume: () => unawaited(api.startDiscovery()),
        onPause: () {
          if (!state.connected) unawaited(api.stopDiscovery());
        },
      );
    } catch (_) {
      _life = null;
    }
    return CastState.none;
  }

  void _onEvent(Map<Object?, Object?> e) {
    switch (e['e']) {
      case 'devices':
        final list = <CastDevice>[
          for (final d in (e['devices'] as List? ?? const []))
            if (d is Map && d['id'] is String)
              CastDevice(d['id'] as String, '${d['name'] ?? ''}'),
        ];
        state = state.copyWith(devices: list);
      case 'session':
        switch (e['state']) {
          case 'connected':
            state = state.copyWith(
                phase: CastPhase.connected, device: e['device'] as String?);
          case 'connecting':
            state = state.copyWith(phase: CastPhase.connecting);
          case 'failed':
            state = state.copyWith(
                phase: CastPhase.idle,
                clearDevice: true,
                player: CastPlayer.idle);
            _errors.add('connect');
          default: // idle, ended
            state = state.copyWith(
                phase: CastPhase.idle,
                clearDevice: true,
                player: CastPlayer.idle);
        }
      case 'status':
        final p = switch (e['state']) {
          'playing' => CastPlayer.playing,
          'paused' => CastPlayer.paused,
          'buffering' => CastPlayer.buffering,
          _ => CastPlayer.idle,
        };
        final ms = (e['ms'] as num?)?.toInt();
        if (ms != null && ms > 0) lastPosition = Duration(milliseconds: ms);
        state = state.copyWith(player: p, position: lastPosition);
        final idle = e['idle'];
        if (p == CastPlayer.idle && (idle == 'error' || idle == 'finished')) {
          _errors.add(idle as String);
        }
      case 'pos':
        final ms = (e['ms'] as num?)?.toInt() ?? 0;
        if (ms > 0) {
          lastPosition = Duration(milliseconds: ms);
          state = state.copyWith(position: lastPosition);
        }
      case 'unavailable':
        state = CastState.none;
    }
  }

  Future<bool> connect(CastDevice d) async {
    state = state.copyWith(phase: CastPhase.connecting, device: d.name);
    final ok = await api.connect(d.id);
    if (!ok && state.phase == CastPhase.connecting) {
      state = state.copyWith(phase: CastPhase.idle, clearDevice: true);
    }
    return ok;
  }

  Future<void> disconnect() => api.disconnect();
}

final castProvider =
    NotifierProvider<CastController, CastState>(CastController.new);

/// Einmaliger Hinweis vor dem ersten Cast (Zugangsdaten in der Adresse).
const castNoticeFlag = 'castNoticeOk';
