import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:media_kit/media_kit.dart';

import 'app.dart';
import 'core/platform_info.dart';
import 'data/epg_window.dart';
import 'data/image_caches.dart';
import 'l10n/strings.dart' show L10n;
import 'player/media_session.dart';
import 'core/licenses.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  // Nur die App-Sprachen (de/en/tr) statt aller ~400 Gebietsschemata.
  await Future.wait(
      [for (final l in L10n.supported) initializeDateFormatting(l)]);
  Intl.defaultLocale = 'de';
  // Bilder im Arbeitsspeicher: erst vorsichtig, nach RAM-Abfrage ggf. mehr.
  ImageCaches.configureMemory(null);
  // Sperrbildschirm/Benachrichtigung, Kopfhörer-Tasten, Audio-Fokus
  // (Handy/Tablet; der Fernseher nutzt es nicht).
  if (PlatformInfo.isAndroid || PlatformInfo.isIos) {
    await AudioServiceBridge.init();
  }
  registerNativeLicenses();
  runApp(const ProviderScope(child: JasonStreamApp()));
  // Schwache TV-Boxen (1–2 GB RAM): EPG-Obergrenze und Bild-Cache anpassen.
  PlatformInfo.memoryInfo().then((m) {
    if (m != null) {
      EpgWindow.tuneForDevice(totalBytes: m.total, lowRam: m.lowRam);
      ImageCaches.configureMemory(m.lowRam ? 0 : m.total);
    }
  });
  // Logo-/Poster-Speicher auf ihre Byte-Grenzen kürzen – lange nach dem Start.
  Timer(const Duration(seconds: 90), ImageCaches.trimDisk);
}
