import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Echte Schriften für Widget-Tests: Inter, InterDisplay (wie pubspec.yaml)
/// und die Material-Symbole aus dem Flutter-SDK – sonst rechnet der Test mit
/// der Ersatzschrift (Ahem) und Bildschirmfotos zeigen nur Kästchen.
Future<void> loadAppFonts() async {
  Future<void> family(String name, List<String> files) async {
    final l = FontLoader(name);
    for (final f in files) {
      l.addFont(Future.value(ByteData.sublistView(File(f).readAsBytesSync())));
    }
    await l.load();
  }

  const d = 'assets/fonts';
  await family('Inter', [
    '$d/Inter-Regular.otf',
    '$d/Inter-Medium.otf',
    '$d/Inter-SemiBold.otf',
    '$d/Inter-Bold.otf',
    '$d/Inter-ExtraBold.otf',
  ]);
  await family('InterDisplay', [
    '$d/InterDisplay-SemiBold.otf',
    '$d/InterDisplay-Bold.otf',
    '$d/InterDisplay-ExtraBold.otf',
  ]);
  final sdk = Platform.environment['FLUTTER_ROOT'] ??
      File(Platform.resolvedExecutable)
          .parent.parent.parent.parent.parent.parent.path;
  final icons =
      File('$sdk/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
  if (icons.existsSync()) await family('MaterialIcons', [icons.path]);
}

/// Bildschirmfoto von [boundary] als `<TV_SHOTS>/<name>.png` – nur, wenn die
/// Umgebungsvariable `TV_SHOTS` gesetzt ist (sonst schreibt kein Test).
Future<void> writeShot(
    WidgetTester tester, GlobalKey boundary, String name) async {
  final dir = Platform.environment['TV_SHOTS'];
  if (dir == null) return;
  await tester.runAsync(() async {
    final b =
        boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final img = await b.toImage(pixelRatio: tester.view.devicePixelRatio);
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    File('$dir/$name.png').writeAsBytesSync(data!.buffer.asUint8List());
  });
}
