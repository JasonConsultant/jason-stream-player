import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jason_stream_player/l10n/strings.dart';
import 'package:jason_stream_player/ui/portals/pair_screen.dart';

void main() {
  // Fernseher 1080p mit vergrößerter Oberfläche ≈ 800×450 logische Punkte.
  testWidgets('QR-Seite passt auf den Fernseher (Querformat)', (t) async {
    t.view.physicalSize = const Size(1600, 900);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    L10n.lang = 'de';
    await t.pumpWidget(const ProviderScope(
        child: MaterialApp(home: PairScreen())));
    await t.pump(const Duration(milliseconds: 500));
    expect(t.takeException(), isNull);
    // Anleitung steht neben dem Code, nicht darunter.
    final title = t.getTopLeft(find.textContaining('Zugang vom Handy'));
    expect(title.dy, lessThan(450));
  });
}
