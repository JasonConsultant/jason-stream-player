import 'dart:async';

import 'package:flutter/material.dart';

import '../../player/engine.dart';

/// Versteckte Diagnose-Anzeige im Player (Einstellungen: 5× OK auf der
/// Versionszeile; im Player: Info-Taste lange drücken). Zeigt, was auf dem
/// Gerät wirklich läuft: Dekoder (hwdec-current), Ausgabe (vo), Bildrate,
/// verworfene Bilder und Pufferstand – bei ExoPlayer dessen Statistik
/// ([EngineDiagnostics]).
class PlayerDebugInfo extends StatefulWidget {
  /// Einstellung `set_playerdebug`.
  static const flagKey = 'playerdebug';

  /// Abgefragte mpv-Eigenschaften (Name → Anzeige).
  static const props = <String, String>{
    'hwdec-current': 'hwdec',
    'current-vo': 'vo',
    'video-codec': 'codec',
    'video-params/w': 'w',
    'video-params/h': 'h',
    'container-fps': 'fps',
    'estimated-vf-fps': 'vf-fps',
    'frame-drop-count': 'drop',
    'decoder-frame-drop-count': 'dec-drop',
    'vo-delayed-frame-count': 'delayed',
    'demuxer-cache-duration': 'cache s',
    'cache-buffering-state': 'buf %',
  };

  final PlaybackEngine engine;

  /// Bisher an mpv geschickte Eigenschaften (MpvProps.sent).
  final int Function()? sent;
  const PlayerDebugInfo({super.key, required this.engine, this.sent});

  /// Zeilen aus abgefragten Werten (rein, für Tests).
  static List<String> format(Map<String, String> v, {int? sent}) {
    String g(String k) {
      final x = v[k];
      if (x == null || x.isEmpty) return '–';
      final d = double.tryParse(x);
      if (d != null && x.contains('.')) return d.toStringAsFixed(1);
      return x;
    }

    return [
      'hwdec ${g('hwdec-current')} · vo ${g('current-vo')}',
      '${g('video-codec')} ${g('video-params/w')}×${g('video-params/h')}',
      'fps ${g('container-fps')} (vf ${g('estimated-vf-fps')})',
      'drop ${g('frame-drop-count')} · dec-drop ${g('decoder-frame-drop-count')}'
          ' · delayed ${g('vo-delayed-frame-count')}',
      'cache ${g('demuxer-cache-duration')} s · buf ${g('cache-buffering-state')} %',
      if (sent != null) 'mpv props sent $sent',
    ];
  }

  @override
  State<PlayerDebugInfo> createState() => _PlayerDebugInfoState();
}

class _PlayerDebugInfoState extends State<PlayerDebugInfo> {
  Timer? _timer;
  List<String> _lines = const [];

  @override
  void initState() {
    super.initState();
    _poll();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _poll());
  }

  Future<void> _poll() async {
    final e = widget.engine;
    // ExoPlayer: eigene Statistik (Decoder HW/SW, Auflösung, fps, Puffer …).
    if (e is EngineDiagnostics) {
      final lines = await (e as EngineDiagnostics).diagnostics();
      if (!mounted) return;
      setState(() => _lines = lines);
      return;
    }
    final v = <String, String>{};
    if (e.supportsOptions) {
      for (final k in PlayerDebugInfo.props.keys) {
        final x = await e.getOption(k);
        if (x != null) v[k] = x;
      }
    }
    if (!mounted) return;
    setState(
        () => _lines = PlayerDebugInfo.format(v, sent: widget.sent?.call()));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PlayerDebugPanel(lines: _lines);
}

/// Darstellung der Diagnose-Zeilen (ohne Player – auch für Vorschaubilder).
class PlayerDebugPanel extends StatelessWidget {
  final List<String> lines;
  const PlayerDebugPanel({super.key, required this.lines});

  @override
  Widget build(BuildContext context) => Container(
        key: const ValueKey('player-debug-info'),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final l in lines)
              Text(l,
                  style: const TextStyle(
                      // App-Schrift mit gleich breiten Ziffern (überall
                      // vorhanden, auch in Bildschirmfoto-Tests).
                      fontFamily: 'Inter',
                      fontFeatures: [FontFeature.tabularFigures()],
                      fontSize: 12,
                      color: Colors.white)),
          ],
        ),
      );
}
