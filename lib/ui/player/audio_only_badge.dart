import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../l10n/strings.dart';

/// Anzeige „Nur Ton“ im Vollbild-Player (Video abgewählt, Ton läuft).
class AudioOnlyBadge extends StatelessWidget {
  const AudioOnlyBadge({super.key});

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.topCenter,
        child: Padding(
          // Unter der oberen Knopfreihe (Mitte: Spulknöpfe, unten: Info).
          padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top + 66),
          child: Container(
            key: const ValueKey('audio-only-badge'),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(22),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.headphones_rounded, color: AppColors.accent, size: 20),
              const SizedBox(width: 8),
              Text(tr('Nur Ton'),
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w700)),
              const SizedBox(width: 10),
              Flexible(
                child: Text(tr('Bild aus, Ton läuft weiter – spart Akku und Daten'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white70, fontSize: 12.5)),
              ),
            ]),
          ),
        ),
      );
}
