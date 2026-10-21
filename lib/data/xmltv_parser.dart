import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/models.dart';
import 'epg_matcher.dart';
import 'gzip_stub.dart' if (dart.library.io) 'gzip_io.dart';
import 'net.dart';
import 'epg_window.dart';
import 'xmltv_scanner.dart';

/// Lädt und parst XMLTV-EPG. Ergebnis: Map epgId → Einträge (sortiert).
///
/// Schnell und sparsam auch bei sehr großen EPGs (100 MB+):
/// - **Streaming**: die Datei wird stückweise (1 MB) entpackt, dekodiert und
///   gelesen – nie als Ganzes im Speicher aufgebaut.
/// - **Filter**: nur Sendungen für Sender, die es im Portal gibt
///   ([channelIds]), und nur im Zeitfenster −7 bis +7 Tage (siehe epg_window.dart).
/// - Läuft in einem Hintergrund-Isolate; die Oberfläche bleibt flüssig.
class XmltvParser {
  /// [headers]: User-Agent/Referer des Portals. [offsetMinutes]:
  /// Zeitversatz dieser Quelle (wird beim Lesen angewendet).
  static Future<Map<String, List<EpgEntry>>> load(Uri url,
      {Set<String>? channelIds,
      List<Channel>? channels,
      Map<String, String>? headers,
      int offsetMinutes = 0,
      void Function(int received, int? total)? onProgress,
      VoidCallback? onParsing}) async {
    final bytes = await Net.get(url,
            maxBytes: 300 * 1024 * 1024,
            timeout: const Duration(seconds: 90),
            headers: headers,
            onProgress: onProgress)
        // Manche Server erzeugen xmltv.php sehr langsam – nie ewig warten.
        .timeout(const Duration(minutes: 6));
    onParsing?.call();
    // Obergrenze schon im Hintergrund anwenden: sonst würde das volle EPG
    // ins Haupt-Isolate kopiert (doppelter Speicher auf 2-GB-Boxen).
    final limit = EpgWindow.maxTotal;
    final (map, names) = channels != null
        ? await compute(_matchJob, (bytes, channels, offsetMinutes, limit))
        : await compute(
            _parseBytesJob, (bytes, channelIds, offsetMinutes, limit));
    // Sendernamen der Quelle für die manuelle EPG-Zuordnung merken.
    EpgChannelNames.addAll(names);
    return map;
  }

  static Future<(Map<String, List<EpgEntry>>, Map<String, String>)>
      _parseBytesJob((Uint8List, Set<String>?, int, int) job) async {
    final names = <String, String>{};
    final map = await parseBytes(job.$1,
        channelIds: job.$2, namesOut: names, offsetMinutes: job.$3);
    return (EpgWindow.cap(map, total: job.$4), names);
  }

  /// Mit Zuordnung über Kennung und Namen (siehe [EpgMatcher]).
  static Future<(Map<String, List<EpgEntry>>, Map<String, String>)> _matchJob(
      (Uint8List, List<Channel>, int, int) job) async {
    final m = EpgMatcher(job.$2);
    final names = <String, String>{};
    final parsed = await parseBytes(job.$1,
        wants: m.wants, namesOut: names, offsetMinutes: job.$3);
    return (EpgWindow.cap(m.assign(parsed), total: job.$4), names);
  }

  /// Bytes (gzip oder unkomprimiert) stückweise parsen – komplett synchron:
  /// entpacken → UTF-8 → Scanner, je 1 MB. Im Speicher liegt nie mehr als
  /// ein Stück plus das Ergebnis. [namesOut]: XMLTV-Kennung → Anzeigename.
  static Future<Map<String, List<EpgEntry>>> parseBytes(Uint8List bytes,
      {Set<String>? channelIds,
      bool Function(String)? wants,
      Map<String, String>? namesOut,
      int offsetMinutes = 0}) async {
    final scanner = XmltvScanner(channelIds, parseTime, wants)
      ..shift = Duration(minutes: offsetMinutes);
    final text = const Utf8Decoder(allowMalformed: true)
        .startChunkedConversion(StringConversionSink.fromStringSink(scanner));
    final gz = bytes.length > 2 && bytes[0] == 0x1f && bytes[1] == 0x8b;
    final Sink<List<int>> input = gz ? gunzipSink(text) : text;
    const step = 1024 * 1024;
    for (var i = 0; i < bytes.length; i += step) {
      input.add(Uint8List.sublistView(
          bytes, i, i + step > bytes.length ? bytes.length : i + step));
    }
    input.close();
    final out = scanner.finish();
    namesOut?.addAll(scanner.channelNames);
    return out;
  }

  /// Für Tests/kleine Dateien: kompletter Text.
  static Future<Map<String, List<EpgEntry>>> parse(String xml,
          {Set<String>? channelIds, int offsetMinutes = 0}) async =>
      (XmltvScanner(channelIds, parseTime)
            ..shift = Duration(minutes: offsetMinutes)
            ..write(xml))
          .finish();

  /// XMLTV-Zeit: 20260101120000 +0100
  static DateTime? parseTime(String? s) {
    if (s == null || s.length < 14) return null;
    try {
      var dt = DateTime.utc(
        int.parse(s.substring(0, 4)),
        int.parse(s.substring(4, 6)),
        int.parse(s.substring(6, 8)),
        int.parse(s.substring(8, 10)),
        int.parse(s.substring(10, 12)),
        int.parse(s.substring(12, 14)),
      );
      final tz = RegExp(r'([+-])(\d{2})(\d{2})').firstMatch(s.substring(14));
      if (tz != null) {
        final sign = tz.group(1) == '+' ? 1 : -1;
        final off = Duration(
            hours: int.parse(tz.group(2)!), minutes: int.parse(tz.group(3)!));
        dt = dt.subtract(off * sign);
      }
      return dt.toLocal();
    } catch (_) {
      return null;
    }
  }
}
