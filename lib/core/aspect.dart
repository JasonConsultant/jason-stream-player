import 'package:flutter/material.dart';

import '../l10n/strings.dart';

/// Bildformate im Player.
///
/// - [fit] steuert, wie das Bild in den Bildschirm passt.
/// - [ratio] erzwingt ein Seitenverhältnis (z. B. 4:3 für alte Sendungen,
///   die fälschlich als 16:9 gesendet werden – oder umgekehrt).
/// - [scale] vergrößert das Bild und schneidet die Ränder ab (z. B. um
///   schwarze Balken bei Kinofilmen in 16:9-Sendungen loszuwerden).
enum AspectMode {
  original('original', 'Original', 'Unverzerrt, ggf. mit Rändern',
      Icons.crop_original_rounded, BoxFit.contain, null, 1.0),
  fill('cover', 'Füllen', 'Ganzer Bildschirm, Ränder werden abgeschnitten',
      Icons.fit_screen_rounded, BoxFit.cover, null, 1.0),
  stretch('stretch', 'Strecken', 'Ganzer Bildschirm, Bild wird verzerrt',
      Icons.open_in_full_rounded, BoxFit.fill, null, 1.0),
  r16x9('16x9', '16:9', 'Breitbild erzwingen',
      Icons.crop_16_9_rounded, BoxFit.contain, 16 / 9, 1.0),
  r4x3('4x3', '4:3', 'Für ältere Sender und Sendungen',
      Icons.crop_5_4_rounded, BoxFit.contain, 4 / 3, 1.0),
  cinema('cinema', 'Kino 21:9', 'Entfernt schwarze Balken oben und unten',
      Icons.theaters_rounded, BoxFit.contain, null, (21 / 9) / (16 / 9)),
  zoom('zoom', 'Zoom 115 %', 'Leicht vergrößert, z. B. gegen Senderränder',
      Icons.zoom_in_rounded, BoxFit.contain, null, 1.15);

  final String id;
  final String _label;
  final String _hint;

  /// Übersetzte Bezeichnung und Erklärung.
  String get label => tr(_label);
  String get hint => tr(_hint);
  final IconData icon;
  final BoxFit fit;
  final double? ratio;
  final double scale;

  const AspectMode(this.id, this._label, this._hint, this.icon, this.fit,
      this.ratio, this.scale);

  /// Liest auch die Werte älterer Versionen (contain/cover/fill).
  static AspectMode fromId(String? id) => switch (id) {
        'contain' || null => AspectMode.original,
        'fill' => AspectMode.stretch, // alter Wert für „Strecken“
        _ => AspectMode.values.firstWhere((m) => m.id == id,
            orElse: () => AspectMode.original),
      };

  AspectMode get next => AspectMode.values[(index + 1) % AspectMode.values.length];
}
