import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jason_stream_player/ui/shell/ui_scale.dart';

void main() {
  testWidgets('Vergrößerte Oberfläche passt genau auf den Bildschirm', (t) async {
    t.view.physicalSize = const Size(1920, 1080);
    t.view.devicePixelRatio = 2; // 960×540 logisch
    addTearDown(t.view.reset);
    final key = GlobalKey();
    await t.pumpWidget(ProviderScope(
      overrides: [uiScaleProvider.overrideWithValue(1.2)],
      child: MaterialApp(
        builder: (c, child) => UiScale(child: child!),
        home: Container(key: key, color: Colors.red),
      ),
    ));
    // Inhalt wird mit 800×450 gebaut …
    expect(t.getSize(find.byKey(key)), const Size(800, 450));
    // … und füllt genau den Bildschirm, ohne herauszuragen.
    final r = t.getRect(find.byKey(key));
    expect(r.left, closeTo(0, 0.01));
    expect(r.top, closeTo(0, 0.01));
    expect(r.right, closeTo(960, 0.01));
    expect(r.bottom, closeTo(540, 0.01));
  });
}
