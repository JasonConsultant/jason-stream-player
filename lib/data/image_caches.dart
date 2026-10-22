import 'package:flutter/painting.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import 'image_trim_stub.dart' if (dart.library.io) 'image_trim_io.dart';

/// Bild-Zwischenspeicher der App.
///
/// - **Arbeitsspeicher** (dekodierte Bilder, [PaintingBinding.imageCache]):
///   Obergrenze nach Geräte-RAM – ≤ 2,5 GB (Mi Box & Co.) 48 MB, sonst 96 MB.
///   Flutters Vorgabe (100 MB, 1000 Bilder) ist für 2-GB-Boxen zu viel.
/// - **Datenträger**: Senderlogos sind klein, aber zahlreich (große Anbieter:
///   Zehntausende Sender) – eigener Speicher für bis zu 5 000 Logos / 60 MB.
///   Poster/Hintergründe in einem eigenen, kleineren Speicher, damit sie die
///   Logos nicht verdrängen (vorher teilten sich alle 200 Plätze).
class ImageCaches {
  ImageCaches._();

  static const logoKey = 'jsp_logos_v1';
  static const logoMaxFiles = 5000;
  static const logoMaxBytes = 60 << 20;

  static const artKey = 'jsp_art_v1';
  static const artMaxFiles = 600;
  static const artMaxBytes = 120 << 20;

  static CacheManager? _logos, _art;

  /// Senderlogos (klein, viele, lange gültig).
  static CacheManager get logos => _logos ??= CacheManager(Config(logoKey,
      stalePeriod: const Duration(days: 60),
      maxNrOfCacheObjects: logoMaxFiles));

  /// Poster, Hintergründe, Episodenbilder.
  static CacheManager get art => _art ??= CacheManager(Config(artKey,
      stalePeriod: const Duration(days: 21), maxNrOfCacheObjects: artMaxFiles));

  /// Grenzen für dekodierte Bilder im Arbeitsspeicher.
  static ({int bytes, int count}) memoryLimits(int? totalRamBytes) {
    final small = totalRamBytes == null || totalRamBytes <= 2560 << 20;
    return small
        ? (bytes: 48 << 20, count: 500)
        : (bytes: 96 << 20, count: 1000);
  }

  /// [totalRamBytes] null = unbekannt → vorsichtig (kleine Grenze).
  static void configureMemory(int? totalRamBytes) {
    final l = memoryLimits(totalRamBytes);
    PaintingBinding.instance.imageCache
      ..maximumSizeBytes = l.bytes
      ..maximumSize = l.count;
  }

  /// Datenträger-Speicher auf ihre Byte-Grenzen kürzen (älteste Dateien
  /// zuerst). Die Cache-Bibliothek begrenzt nur die Anzahl; fehlt eine
  /// Datei, lädt sie das Bild einfach neu.
  static Future<void> trimDisk() async {
    try {
      await trimCacheDir(logoKey, logoMaxBytes);
      await trimCacheDir(artKey, artMaxBytes);
    } catch (_) {
      // optional
    }
  }
}
