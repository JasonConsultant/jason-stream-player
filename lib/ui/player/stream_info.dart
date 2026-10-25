import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../l10n/strings.dart';
import '../../player/engine.dart';
import '../widgets/action_sheet.dart';

/// Was die Player-Seite zur Stream-Info beiträgt (ohne Engine-Messwerte).
class StreamInfoContext {
  /// „ExoPlayer“ / „mpv“.
  final String engine;

  /// Software-Dekodierung als Notlösung/vom Nutzer gewählt.
  final bool softwareForced;

  /// Vorsichtiger Start aktiv.
  final bool careful;
  final bool live;

  /// Gespielte Quelle (Variante „FHD“, „Ersatz-Server 2“), null = Standard.
  final String? source;

  /// Automatische Eingriffe dieser Sitzung und ihr Verlauf.
  final int interventions;
  final List<(DateTime, String)> events;
  const StreamInfoContext({
    required this.engine,
    this.softwareForced = false,
    this.careful = false,
    this.live = false,
    this.source,
    this.interventions = 0,
    this.events = const [],
  });
}

/// Verständliche Zeilen der Stream-Info (rein, für Tests).
abstract final class StreamInfo {
  static String _num(double v, [int digits = 1]) {
    final s = v.toStringAsFixed(digits);
    return L10n.lang == 'en' ? s : s.replaceAll('.', ',');
  }

  /// „Full HD“, „4K“ … nach Bildhöhe.
  static String quality(int w, int h) {
    final x = h > w ? w : h; // Hochkant-Videos
    if (x >= 2000) return '4K';
    if (x >= 1400) return 'QHD';
    if (x >= 1000) return 'Full HD';
    if (x >= 700) return 'HD';
    return 'SD';
  }

  static String videoCodec(String c) => switch (c.toLowerCase()) {
        'h264' || 'avc' || 'avc1' => 'H.264 (AVC)',
        'hevc' || 'h265' || 'hvc1' => 'H.265 (HEVC)',
        'mpeg2video' || 'mpeg2' => 'MPEG-2',
        'av1' => 'AV1',
        'vp9' => 'VP9',
        'vp8' => 'VP8',
        'mpeg4' => 'MPEG-4',
        _ => c.toUpperCase(),
      };

  static String audioCodec(String c) => switch (c.toLowerCase()) {
        'aac' || 'mp4a' => 'AAC',
        'ac3' => 'Dolby Digital (AC3)',
        'e-ac3' || 'eac3' => 'Dolby Digital Plus (E-AC3)',
        'mp2' => 'MP2',
        'mp3' => 'MP3',
        'opus' => 'Opus',
        'dts' => 'DTS',
        'truehd' => 'Dolby TrueHD',
        _ => c.toUpperCase() == c ? c : c.toUpperCase(),
      };

  static String channels(int ch) => switch (ch) {
        1 => 'Mono',
        2 => 'Stereo',
        6 => '5.1',
        8 => '7.1',
        _ => trf('{0} Kanäle', [ch]),
      };

  static String bitrate(int bps) => bps >= 1000000
      ? '${_num(bps / 1e6)} Mbit/s'
      : '${(bps / 1000).round()} kbit/s';

  /// (Bezeichnung, Wert) – fehlende Werte als „–“.
  static List<(String, String)> rows(EngineHealth h, StreamInfoContext c) {
    const dash = '–';
    final w = h.width ?? 0, hh = h.height ?? 0;
    final fps = h.fps ?? h.outputFps;
    final audio = [
      if (h.audioCodec != null) audioCodec(h.audioCodec!),
      if ((h.audioChannels ?? 0) > 0) channels(h.audioChannels!),
      if ((h.sampleRate ?? 0) > 0) '${_num(h.sampleRate! / 1000, 1)} kHz',
    ].join(' · ');
    final rate = [
      if ((h.videoBitrate ?? 0) > 0) bitrate(h.videoBitrate!),
      if ((h.audioBitrate ?? 0) > 0)
        trf('Ton {0}', [bitrate(h.audioBitrate!)]),
    ].join(' · ');
    final String decoder;
    if (h.hardwareDecoder == null) {
      decoder = c.softwareForced ? tr('Software') : dash;
    } else {
      final kind = h.hardwareDecoder! ? tr('Hardware') : tr('Software');
      final name = h.videoDecoder;
      decoder = name == null || name == 'ffmpeg' || name == 'no'
          ? kind
          : '$kind ($name)';
    }
    return [
      (
        tr('Player-Engine'),
        c.careful ? '${c.engine} · ${tr('vorsichtiger Start')}' : c.engine
      ),
      (
        tr('Auflösung'),
        w > 0 && hh > 0 ? '$w × $hh (${quality(w, hh)})' : dash
      ),
      (
        tr('Bildrate'),
        fps == null || fps <= 0 ? dash : '${_num(fps, fps % 1 == 0 ? 0 : 2)} fps'
      ),
      (
        tr('Video'),
        h.videoCodec == null
            ? (h.hasVideoTrack == false ? tr('Kein Bild (nur Ton)') : dash)
            : videoCodec(h.videoCodec!)
      ),
      (tr('Ton'), audio.isEmpty ? dash : audio),
      (tr('Bitrate'), rate.isEmpty ? dash : rate),
      if ((h.bandwidth ?? 0) > 0)
        (tr('Verbindung'), '≈ ${bitrate(h.bandwidth!)}'),
      (
        tr('Puffer'),
        h.bufferSeconds == null ? dash : '${_num(h.bufferSeconds!)} s'
      ),
      (tr('Dekoder'), decoder),
      (
        tr('Verworfene Bilder'),
        h.droppedFrames == null ? dash : '${h.droppedFrames}'
      ),
      if (c.source != null) (tr('Quelle'), c.source!),
      (
        tr('Automatische Eingriffe'),
        c.interventions == 0 ? tr('keine') : '${c.interventions}'
      ),
    ];
  }
}

/// Stream-Info öffnen (⋮ bzw. Spuren-Blatt). [onToggleDecoder]: Hardware ↔
/// Software wechseln (null = nicht möglich).
Future<void> showStreamInfo(
  BuildContext context, {
  required PlaybackEngine engine,
  required StreamInfoContext Function() info,
  VoidCallback? onToggleDecoder,
}) =>
    showActionSheet<void>(
      context: context,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 560),
      builder: (ctx) => SafeArea(
        child: StreamInfoSheet(
          engine: engine,
          info: info,
          onToggleDecoder: onToggleDecoder == null
              ? null
              : () {
                  Navigator.pop(ctx);
                  onToggleDecoder();
                },
        ),
      ),
    );

/// Inhalt der Stream-Info: Messwerte 1×/s aus der Engine.
class StreamInfoSheet extends StatefulWidget {
  final PlaybackEngine? engine;
  final StreamInfoContext Function() info;
  final VoidCallback? onToggleDecoder;

  /// Feste Messwerte (Vorschaubilder/Tests ohne Engine).
  final EngineHealth? health;
  const StreamInfoSheet({
    super.key,
    this.engine,
    required this.info,
    this.onToggleDecoder,
    this.health,
  });

  @override
  State<StreamInfoSheet> createState() => _StreamInfoSheetState();
}

class _StreamInfoSheetState extends State<StreamInfoSheet> {
  Timer? _timer;
  late EngineHealth _h = widget.health ?? EngineHealth.unknown;

  @override
  void initState() {
    super.initState();
    if (widget.health == null) {
      _poll();
      _timer = Timer.periodic(const Duration(seconds: 1), (_) => _poll());
    }
  }

  Future<void> _poll() async {
    final e = widget.engine;
    if (e is! EngineHealthSource) return;
    try {
      final h = await (e as EngineHealthSource).health(full: true);
      if (mounted) setState(() => _h = h);
    } catch (_) {}
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.info();
    final t = Theme.of(context).textTheme;
    final rows = StreamInfo.rows(_h, c);
    final events = c.events.reversed.take(5).toList();
    String hms(DateTime d) =>
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}:'
        '${d.second.toString().padLeft(2, '0')}';
    return ListView(
      key: const ValueKey('stream-info'),
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(children: [
            Icon(Icons.info_outline_rounded, color: AppColors.accent),
            const SizedBox(width: 10),
            Text(tr('Stream-Info'), style: t.titleLarge),
          ]),
        ),
        for (final (label, value) in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 170,
                  child: Text(label,
                      style: t.bodyMedium?.copyWith(color: AppColors.textDim)),
                ),
                Expanded(
                  child: Text(value,
                      style: t.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          fontFeatures: const [FontFeature.tabularFigures()])),
                ),
              ],
            ),
          ),
        if (events.isNotEmpty) ...[
          const Divider(height: 24),
          Text(tr('Letzte Eingriffe'),
              style: t.titleSmall?.copyWith(color: AppColors.textDim)),
          const SizedBox(height: 6),
          for (final (at, text) in events)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Text('${hms(at)}  $text', style: t.bodySmall),
            ),
        ],
        if (widget.onToggleDecoder != null) ...[
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              key: const ValueKey('stream-info-decoder'),
              autofocus: true,
              onPressed: widget.onToggleDecoder,
              icon: const Icon(Icons.memory_rounded),
              label: Text(c.softwareForced
                  ? tr('Hardware-Dekodierung versuchen')
                  : tr('Software-Dekodierung versuchen')),
            ),
          ),
        ],
      ],
    );
  }
}
