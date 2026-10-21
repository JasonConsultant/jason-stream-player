import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme.dart';
import '../../l10n/strings.dart';
import '../../models/models.dart';
import '../widgets/a11y.dart';
import '../widgets/artwork.dart';
import '../widgets/common.dart';

/// Ziffer einer Zifferntaste (oben oder Ziffernblock), sonst null.
int? digitOfKey(LogicalKeyboardKey k) {
  const top = [
    LogicalKeyboardKey.digit0,
    LogicalKeyboardKey.digit1,
    LogicalKeyboardKey.digit2,
    LogicalKeyboardKey.digit3,
    LogicalKeyboardKey.digit4,
    LogicalKeyboardKey.digit5,
    LogicalKeyboardKey.digit6,
    LogicalKeyboardKey.digit7,
    LogicalKeyboardKey.digit8,
    LogicalKeyboardKey.digit9,
  ];
  const pad = [
    LogicalKeyboardKey.numpad0,
    LogicalKeyboardKey.numpad1,
    LogicalKeyboardKey.numpad2,
    LogicalKeyboardKey.numpad3,
    LogicalKeyboardKey.numpad4,
    LogicalKeyboardKey.numpad5,
    LogicalKeyboardKey.numpad6,
    LogicalKeyboardKey.numpad7,
    LogicalKeyboardKey.numpad8,
    LogicalKeyboardKey.numpad9,
  ];
  final i = top.indexOf(k);
  if (i >= 0) return i;
  final j = pad.indexOf(k);
  return j >= 0 ? j : null;
}

/// Farbtasten der Fernbedienung (Android PROG_RED … PROG_BLUE → colorF0 … F3).
enum ColorKey { red, green, yellow, blue }

ColorKey? colorOfKey(LogicalKeyboardKey k) => switch (k) {
      LogicalKeyboardKey.colorF0Red => ColorKey.red,
      LogicalKeyboardKey.colorF1Green => ColorKey.green,
      LogicalKeyboardKey.colorF2Yellow => ColorKey.yellow,
      LogicalKeyboardKey.colorF3Blue => ColorKey.blue,
      _ => null,
    };

/// Kompakte Info-Leiste beim Zappen (wie Swisscom blue TV / MagentaTV):
/// Nummer, Logo, Name, laufende Sendung mit Fortschritt und „Danach“.
/// [preview] = geblätterter Sender, der (noch) nicht läuft.
class ZapBar extends StatelessWidget {
  final Channel channel;
  final EpgEntry? now, next;
  final bool preview;
  final bool favorite;
  final bool tv;
  const ZapBar({
    super.key,
    required this.channel,
    required this.now,
    required this.next,
    this.preview = false,
    this.favorite = false,
    this.tv = false,
  });

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.paddingOf(context);
    // TV: sichere Ränder (≥ 48 dp seitlich, ≥ 27 dp unten).
    final side = tv ? 56.0 : 12.0 + pad.left;
    final bottom = tv ? 32.0 : 12.0 + pad.bottom;
    final c = channel;
    final n = now;
    const dim = TextStyle(fontSize: 15, color: Colors.white70);
    return Positioned(
      left: side,
      right: tv ? 56.0 : 12.0 + pad.right,
      bottom: bottom,
      child: IgnorePointer(
        // TalkBack: Leiste als ein Eintrag, Änderungen werden angesagt.
        child: Semantics(
          container: true,
          liveRegion: true,
          label: preview
              ? '${channelSemantics(c, n)}. ${tr('Vorschau · OK schaltet um')}'
              : channelSemantics(c, n),
          excludeSemantics: true,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 980),
              child: Container(
                padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
                decoration: BoxDecoration(
                  color: AppColors.bg.withValues(alpha: 0.9),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                      color: preview ? AppColors.accent : AppColors.line,
                      width: preview ? 2 : 1),
                ),
                child: Row(children: [
                  if (tv)
                    const Icon(Icons.chevron_left_rounded,
                        color: Colors.white38, size: 22),
                  SizedBox(
                    width: 52,
                    child: Text('${c.number}',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            fontFamily: 'InterDisplay',
                            fontSize: 24,
                            fontWeight: FontWeight.w800,
                            color: Colors.white)),
                  ),
                  const SizedBox(width: 10),
                  ChannelLogo(name: c.name, url: c.logoUrl, size: 44),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          Flexible(
                            child: Text(c.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w700,
                                    color: Colors.white70)),
                          ),
                          if (favorite) ...[
                            const SizedBox(width: 6),
                            const Icon(Icons.star_rounded,
                                size: 16, color: AppColors.gold),
                          ],
                          if (preview) ...[
                            const SizedBox(width: 10),
                            Text(tr('Vorschau · OK schaltet um'),
                                style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                    color: AppColors.accent)),
                          ],
                        ]),
                        const SizedBox(height: 2),
                        Text(n?.title ?? tr('Keine Programminfo'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                                color: Colors.white)),
                        if (n != null) ...[
                          const SizedBox(height: 6),
                          Row(children: [
                            Text('${hm.format(n.start)} – ${hm.format(n.end)}',
                                style: dim),
                            const SizedBox(width: 12),
                            Expanded(
                              child: ThinProgress(
                                  value: n.progressAt(DateTime.now()),
                                  height: 4),
                            ),
                          ]),
                        ],
                        if (next != null) ...[
                          const SizedBox(height: 4),
                          Text(
                              trf('Danach: {0}',
                                  ['${hm.format(next!.start)} ${next!.title}']),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 15, color: Colors.white60)),
                        ],
                      ],
                    ),
                  ),
                  if (tv)
                    const Icon(Icons.chevron_right_rounded,
                        color: Colors.white38, size: 22),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
