import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/subtitle_style.dart';

/// Untertitel-Aussehen (Einstellungen) für die Untertitel-Anzeige von
/// media_kit. mpv zeichnet Text-Untertitel dort nicht selbst (ohne libass),
/// sondern reicht sie an Flutter – die mpv-Eigenschaften `sub-*` allein
/// wirken daher nicht.
SubtitleViewConfiguration subtitleViewConfig(SubtitleStyle s) {
  const o = 1.6;
  return SubtitleViewConfiguration(
    style: TextStyle(
      height: 1.4,
      fontSize: s.viewFontSize,
      letterSpacing: 0.0,
      wordSpacing: 0.0,
      color: Color(s.colorArgb),
      fontWeight: FontWeight.w600,
      backgroundColor: Color(s.backArgb),
      shadows: s.outline
          ? const [
              Shadow(offset: Offset(-o, -o), color: Colors.black),
              Shadow(offset: Offset(o, -o), color: Colors.black),
              Shadow(offset: Offset(-o, o), color: Colors.black),
              Shadow(offset: Offset(o, o), color: Colors.black),
              Shadow(blurRadius: 3, color: Colors.black),
            ]
          : const [],
    ),
  );
}
