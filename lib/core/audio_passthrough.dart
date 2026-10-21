import 'package:media_kit/media_kit.dart';

import '../data/storage.dart';

/// Dolby/DTS-Durchreichung (Bitstream über HDMI an AV-Receiver/Soundbar).
/// Standard: aus – ohne passendes Gerät gäbe es sonst keinen Ton.
class AudioPassthrough {
  /// Einstellung `set_passthrough`.
  static const flagKey = 'passthrough';

  /// Codecs, die mpv unverändert durchreicht (mpv-Eigenschaft `audio-spdif`).
  static const codecs = 'ac3,eac3,dts,dts-hd,truehd';

  static bool enabled(Storage st) => st.flag(flagKey);

  /// mpv-Eigenschaften für den Schalter (leer = dekodieren wie bisher).
  static Map<String, String> mpvProperties(bool on) =>
      {'audio-spdif': on ? codecs : ''};

  /// Setzt die Eigenschaften über [setProperty]; Fehler (z. B. ältere
  /// libmpv) werden ignoriert.
  static Future<void> apply(
      Future<void> Function(String key, String value) setProperty,
      bool on) async {
    for (final e in mpvProperties(on).entries) {
      try {
        await setProperty(e.key, e.value);
      } catch (_) {}
    }
  }

  /// Für den Player: vor jedem Öffnen aufrufen, damit ein geänderter
  /// Schalter (auch während nichts läuft) beim nächsten Stream greift.
  static Future<void> applyTo(Player p, Storage st) async {
    final pl = p.platform;
    if (pl is! NativePlayer) return;
    await apply(pl.setProperty, enabled(st));
  }
}
