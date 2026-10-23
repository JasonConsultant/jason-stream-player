import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/services.dart';

/// Bildschirmausrichtung außerhalb von Player/Multiview.
///
/// Problem: Nach einer erzwungenen Querformat-Sperre bleibt Android bei
/// „frei“ (`[]`) im Querformat stehen, wenn am Handy „Automatisch drehen“
/// aus ist – die App dreht dann nicht mehr zurück. Darum beim Verlassen
/// zuerst die vorherige Ausrichtung (meist Hochformat) setzen und erst kurz
/// danach wieder freigeben (folgt dann dem Drehen, wenn das Handy es erlaubt).
abstract final class AppOrientation {
  /// War das Gerät vor dem Player im Hochformat? (Vor dem Sperren merken.)
  static bool wasPortraitBefore() {
    final views = PlatformDispatcher.instance.views;
    if (views.isEmpty) return true;
    final s = views.first.physicalSize;
    return s.height >= s.width;
  }

  static Timer? _release;

  /// Ausrichtung nach dem Player wiederherstellen. [tv]: nichts tun.
  static Future<void> restore(
      {required bool portraitBefore, bool tv = false}) async {
    if (tv) return;
    _release?.cancel();
    if (portraitBefore) {
      await SystemChrome.setPreferredOrientations(
          const [DeviceOrientation.portraitUp]);
      // Kurz warten, bis Android gedreht hat, dann wieder frei drehen lassen.
      _release = Timer(const Duration(milliseconds: 600), () {
        SystemChrome.setPreferredOrientations(const []);
      });
    } else {
      await SystemChrome.setPreferredOrientations(const []);
    }
  }
}
