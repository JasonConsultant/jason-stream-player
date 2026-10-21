import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../l10n/strings.dart';
import 'platform_info.dart';

/// Sprachsuche über die Android-Spracheingabe (RecognizerIntent in
/// MainActivity/VoiceSearch.kt). Keine eigene Mikrofon-Berechtigung nötig –
/// die Erkennungs-App des Systems nimmt auf.
class VoiceSearch {
  VoiceSearch._();

  static const channel = MethodChannel('de.jasonstream.player/platform');

  static Future<bool>? _available;

  /// Gibt es auf dem Gerät eine Spracheingabe? Einmal geprüft, dann gemerkt.
  static Future<bool> available() => _available ??= _check();

  static Future<bool> _check() async {
    if (!PlatformInfo.isAndroid) return false;
    try {
      return await channel.invokeMethod<bool>('voiceAvailable') ?? false;
    } on Object {
      return false; // kein Android/kein Handler → kein Mikrofon
    }
  }

  /// Startet die Spracheingabe in der App-Sprache. Liefert den erkannten
  /// Text oder null (abgebrochen/nichts erkannt/Fehler).
  static Future<String?> listen() async {
    try {
      final t = await channel.invokeMethod<String>('voiceSearch', {
        'lang': L10n.lang,
        'prompt': tr('Wonach suchst du?'),
      });
      final s = t?.trim();
      return s == null || s.isEmpty ? null : s;
    } on Object {
      return null;
    }
  }

  /// Tests: gemerktes Ergebnis von [available] verwerfen.
  @visibleForTesting
  static void debugReset() => _available = null;
}
