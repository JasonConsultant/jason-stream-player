import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:media_kit/media_kit.dart';

import 'app.dart';
import 'core/platform_info.dart';
import 'data/epg_window.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await initializeDateFormatting();
  Intl.defaultLocale = 'de';
  runApp(const ProviderScope(child: JasonStreamApp()));
  // Schwache TV-Boxen (1–2 GB RAM): EPG-Obergrenze anpassen.
  PlatformInfo.memoryInfo().then((m) {
    if (m != null) {
      EpgWindow.tuneForDevice(totalBytes: m.total, lowRam: m.lowRam);
    }
  });
}
