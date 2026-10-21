import 'package:flutter/services.dart';

import 'platform_info.dart';

/// Trailer öffnen: Android-Intent an die YouTube-App (TV: YouTube für
/// Android TV), sonst Browser. false = nichts gefunden (dann zeigt die
/// Oberfläche Adresse/QR-Code).
class TrailerLauncher {
  TrailerLauncher._();
  static const _channel = MethodChannel('de.jasonstream.player/platform');

  /// Für Tests: ersetzt den Plattformaufruf.
  static Future<bool> Function(String id)? debugOpen;

  static Future<bool> open(String id) async {
    final dbg = debugOpen;
    if (dbg != null) return dbg(id);
    if (!PlatformInfo.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('openTrailer', {'id': id}) ??
          false;
    } on Object {
      return false;
    }
  }

  static String webUrl(String id) => 'https://www.youtube.com/watch?v=$id';
}
