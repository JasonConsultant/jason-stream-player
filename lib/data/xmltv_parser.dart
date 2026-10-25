import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import '../l10n/strings.dart' show L10n;
import '../models/models.dart';
import 'db/catalog_sync.dart' as dbs;
import 'epg_cache/epg_cache.dart';
import 'epg_matcher.dart';
import 'gzip_stub.dart' if (dart.library.io) 'gzip_io.dart';
import 'net.dart';
import 'repository.dart' show RepositoryException;
import 'epg_window.dart';
import 'xmltv_scanner.dart';

/// Lädt und parst XMLTV-EPG. Ergebnis: Map epgId → Einträge (sortiert).
///
/// Schnell und sparsam auch bei sehr großen EPGs (100 MB+):
/// - **Ein Hintergrund-Isolate** für alle Quellen: Herunterladen, Entpacken,
///   Dekodieren, Parsen, Zusammenführen, Obergrenze, tvg-shift und das
///   Kodieren für den Zwischenspeicher. Das Haupt-Isolate bekommt nur das
///   fertige Ergebnis (per `Isolate.exit`, ohne Kopie) plus die fertigen
///   Cache-Bytes ([EpgCache.attach]).
/// - **Streaming**: die Datei wird nie als Ganzes im Speicher gehalten –
///   jedes Stück aus dem Netz wird sofort entpackt und gelesen.
/// - **Filter**: nur Sendungen für Sender, die es im Portal gibt
///   ([channelIds]), und nur im Zeitfenster −7 bis +7 Tage (siehe epg_window.dart).
class XmltvParser {
  /// Eine Quelle laden (siehe [loadSources]).
  static Future<Map<String, List<EpgEntry>>> load(Uri url,
      {Set<String>? channelIds,
      List<Channel>? channels,
      Map<String, String>? headers,
      int offsetMinutes = 0,
      void Function(int received, int? total)? onProgress,
      VoidCallback? onParsing}) {
    return loadSources([(url.toString(), offsetMinutes)],
        channelIds: channelIds,
        channels: channels,
        headers: headers,
        onProgress: onProgress == null ? null : (_, b, t) => onProgress(b, t),
        onParsing: onParsing == null ? null : (_) => onParsing(),
        encode: false);
  }

  /// Alle [sources] (Adresse, Zeitversatz in Minuten) nacheinander laden
  /// und zusammenführen – frühere Quellen haben Vorrang. Wirft den ersten
  /// Fehler nur, wenn gar nichts geladen werden konnte.
  /// [shifts]: EPG-Schlüssel → Minuten (tvg-shift der Playlist), nach der
  /// Obergrenze angewendet. [encode]: Cache-Bytes gleich mit erzeugen.
  static Future<Map<String, List<EpgEntry>>> loadSources(
      List<(String, int)> sources,
      {Set<String>? channelIds,
      List<Channel>? channels,
      Map<String, String>? headers,
      Map<String, int>? shifts,
      bool encode = true,
      EpgStoreSpec? store,
      void Function(int index, int received, int? total)? onProgress,
      void Function(int index)? onParsing}) async {
    if (sources.isEmpty) return {};
    final rp = ReceivePort();
    // Im Test-Modus (MockClient) kann das Isolate nicht selbst laden –
    // dann lädt das Haupt-Isolate und reicht die Stücke durch.
    final forward = Net.hasCustomClient;
    final job = XmltvJob(
      sources: sources,
      headers: headers,
      channelIds: channels == null ? channelIds : null,
      packedChannels: channels == null ? null : _pack(channels),
      limit: EpgWindow.maxTotal,
      shifts: shifts,
      encode: encode,
      store: store,
      port: rp.sendPort,
      download: !forward,
      lang: L10n.lang,
    );
    SendPort? ctl;
    final forwards = <Future<void>>[];
    final sub = rp.listen((m) {
      if (m is SendPort) {
        ctl = m;
      } else if (m is (String, int, int, int?)) {
        onProgress?.call(m.$2, m.$3, m.$4);
      } else if (m is (String, int)) {
        if (m.$1 == 'parsing') onParsing?.call(m.$2);
        if (m.$1 == 'want' && ctl != null) {
          forwards.add(_forward(ctl!, sources[m.$2].$1, m.$2, headers,
              (b, t) => onProgress?.call(m.$2, b, t)));
        }
      }
    });
    try {
      final r = await Isolate.run(_task(job));
      EpgChannelNames.addAll(r.names);
      if (r.hash != null) {
        EpgCache.attach(r.epg, null, r.hash!, staged: r.staged);
      }
      return r.epg;
    } finally {
      ctl?.send(null); // Isolate beendet sich ohnehin; nur aufräumen
      await sub.cancel();
      rp.close();
      await Future.wait(forwards).catchError((_) => const <void>[]);
    }
  }

  /// Sender für die Zuordnung kompakt übergeben (ein String statt 50 000
  /// Objekten – das Senden ins Isolate ist dann nur ein Speicherkopieren).
  static String _pack(List<Channel> channels) {
    final b = StringBuffer();
    for (final c in channels) {
      b
        ..write(c.id)
        ..write('\u0001')
        ..write(c.name)
        ..write('\u0001')
        ..write(c.epgId ?? '\u0002')
        ..write('\u0000');
    }
    return b.toString();
  }

  static List<Channel> _unpack(String s) {
    final out = <Channel>[];
    var pos = 0;
    while (pos < s.length) {
      var end = s.indexOf('\u0000', pos);
      if (end < 0) end = s.length;
      final parts = s.substring(pos, end).split('\u0001');
      pos = end + 1;
      if (parts.length < 3) continue;
      out.add(Channel(
          id: parts[0],
          name: parts[1],
          epgId: parts[2] == '\u0002' ? null : parts[2],
          categoryId: '',
          streamUrl: ''));
    }
    return out;
  }

  /// Test-Modus: im Haupt-Isolate laden, Stücke ans Isolate weiterreichen.
  static Future<void> _forward(SendPort ctl, String url, int i,
      Map<String, String>? headers, void Function(int, int?) progress) async {
    try {
      final (stream, total) = await Net.open(Uri.parse(url),
          maxBytes: maxDownloadBytes,
          timeout: const Duration(seconds: 90),
          headers: headers);
      var n = 0, last = 0;
      await for (final chunk in stream) {
        n += chunk.length;
        ctl.send((
          'chunk',
          i,
          chunk is Uint8List ? chunk : Uint8List.fromList(chunk)
        ));
        if (n - last > 512 * 1024) {
          last = n;
          progress(n, total);
        }
      }
      ctl.send(('end', i, null));
    } catch (e) {
      try {
        ctl.send(('err', i, e));
      } catch (_) {
        ctl.send(('err', i, RepositoryException('$e')));
      }
    }
  }

  // Eigene Funktion: Die Closure darf nur [job] einfangen (keine Ports).
  static Future<XmltvResult> Function() _task(XmltvJob job) =>
      () => runJob(job);

  static const maxDownloadBytes = 300 * 1024 * 1024;

  /// Zeitlimit pro Quelle (manche Server erzeugen xmltv.php sehr langsam).
  static Duration sourceTimeout = const Duration(minutes: 6);

  /// Läuft im Hintergrund-Isolate (öffentlich für Tests/Messungen).
  static Future<XmltvResult> runJob(XmltvJob j) async {
    L10n.lang = j.lang;
    final ctlPort = ReceivePort();
    j.port.send(ctlPort.sendPort);
    // Durchgereichte Stücke (Test-Modus) je Quelle.
    final feeds = <int, StreamController<List<int>>>{};
    final ctlSub = ctlPort.listen((m) {
      if (m is (String, int, Object?)) {
        final c = feeds[m.$2];
        if (c == null) return;
        switch (m.$1) {
          case 'chunk':
            c.add(m.$3 as Uint8List);
          case 'end':
            c.close();
          case 'err':
            c.addError(m.$3 ?? 'Fehler');
            c.close();
        }
      }
    });
    try {
      final matcher = j.packedChannels == null
          ? null
          : EpgMatcher(_unpack(j.packedChannels!));
      final names = <String, String>{};
      final out = <String, List<EpgEntry>>{};
      Object? firstError;
      for (var i = 0; i < j.sources.length; i++) {
        final (url, offset) = j.sources[i];
        try {
          Stream<List<int>> input;
          if (j.download) {
            final (s, total) = await Net.open(Uri.parse(url),
                maxBytes: maxDownloadBytes,
                timeout: const Duration(seconds: 90),
                headers: j.headers);
            var n = 0, last = 0;
            input = s.map((chunk) {
              n += chunk.length;
              if (n - last > 512 * 1024) {
                last = n;
                j.port.send(('progress', i, n, total));
              }
              return chunk;
            });
          } else {
            final c = feeds[i] = StreamController<List<int>>();
            j.port.send(('want', i));
            input = c.stream;
          }
          final parsed = await _parseStream(input,
                  channelIds: j.channelIds,
                  wants: matcher?.wants,
                  namesOut: names,
                  offsetMinutes: offset,
                  onDownloaded: () => j.port.send(('parsing', i)))
              .timeout(sourceTimeout);
          final m = EpgWindow.cap(
              matcher == null ? parsed : matcher.assign(parsed),
              total: j.limit);
          for (final e in m.entries) {
            final prev = out[e.key];
            if (prev == null || prev.isEmpty) out[e.key] = e.value;
          }
        } catch (e) {
          firstError ??= e;
        }
      }
      if (out.isEmpty && firstError != null) throw firstError;
      var epg = EpgWindow.cap(out, total: j.limit);
      final shifts = j.shifts;
      if (shifts != null && shifts.isNotEmpty) {
        if (identical(epg, out)) epg = {...out};
        for (final e in shifts.entries) {
          final l = epg[e.key];
          if (l == null || l.isEmpty || e.value == 0) continue;
          final d = Duration(minutes: e.value);
          epg[e.key] = [for (final p in l) EpgWindow.shiftEntry(p, d)];
        }
      }
      final store = j.store;
      if (!j.encode && store == null) return XmltvResult(epg, names, null);
      // Prüfsumme stückweise (ohne die Cache-Bytes im Speicher zu sammeln).
      final hash = EpgCache.hashEpg(epg);
      if (store == null) return XmltvResult(epg, names, hash);
      if (store.prevHash == hash) {
        // Unverändert (steht schon so in der Datenbank).
        return XmltvResult(EpgCache.memoryWindow(epg), names, hash);
      }
      // Gleich hier in die Datenbank (vorbereitet; umgeschaltet wird erst,
      // wenn die App das Ergebnis übernimmt). Ins Haupt-Isolate geht dann
      // nur das Fenster um „jetzt“ – das Archiv bleibt in der Datenbank.
      try {
        final info = dbs.syncWriteEpg(store.path, store.portal, epg,
            saved: DateTime.now(), hash: hash, activate: false);
        if (info != null) {
          return XmltvResult(EpgCache.memoryWindow(epg), names, hash, info.gen);
        }
      } catch (_) {
        // Datenbank nicht nutzbar → wie bisher alles zurückgeben.
      }
      return XmltvResult(epg, names, hash);
    } finally {
      await ctlSub.cancel();
      ctlPort.close();
    }
  }

  /// Datenstrom (gzip oder unkomprimiert) parsen: jedes Stück wird sofort
  /// entpackt → UTF-8 → Scanner. Im Speicher liegt nie mehr als ein Stück
  /// plus das Ergebnis.
  static Future<Map<String, List<EpgEntry>>> _parseStream(
      Stream<List<int>> input,
      {Set<String>? channelIds,
      bool Function(String)? wants,
      Map<String, String>? namesOut,
      int offsetMinutes = 0,
      void Function()? onDownloaded}) async {
    final scanner = XmltvScanner(channelIds, parseTime, wants)
      ..shift = Duration(minutes: offsetMinutes);
    final text = const Utf8Decoder(allowMalformed: true)
        .startChunkedConversion(StringConversionSink.fromStringSink(scanner));
    Sink<List<int>>? sink;
    final head = <int>[];
    void feed(List<int> chunk) {
      if (sink == null) {
        // Erst nach 2 Bytes entscheiden: gzip (1f 8b) oder Text.
        if (head.length + chunk.length < 2) {
          head.addAll(chunk);
          return;
        }
        final first = head.isEmpty ? chunk : [...head, ...chunk];
        final gz = first[0] == 0x1f && first[1] == 0x8b;
        sink = gz ? gunzipSink(text) : text;
        head.clear();
        chunk = first;
      }
      // Große Stücke teilen, damit der Text-Rest klein bleibt.
      const step = 1024 * 1024;
      if (chunk.length <= step) {
        sink!.add(chunk);
      } else {
        final u = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
        for (var i = 0; i < u.length; i += step) {
          sink!.add(Uint8List.sublistView(
              u, i, i + step > u.length ? u.length : i + step));
        }
      }
    }

    await for (final chunk in input) {
      feed(chunk);
    }
    onDownloaded?.call();
    if (sink == null) {
      if (head.isNotEmpty) text.add(head);
      text.close();
    } else {
      sink!.close();
    }
    final out = scanner.finish();
    namesOut?.addAll(scanner.channelNames);
    return out;
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

/// Auftrag an das EPG-Isolate (nur sendbare, kompakte Werte).
class XmltvJob {
  final List<(String, int)> sources;
  final Map<String, String>? headers;
  final Set<String>? channelIds;
  final String? packedChannels;
  final int limit;
  final Map<String, int>? shifts;
  final bool encode;

  /// Gleich in die Datenbank schreiben (als vorbereitete Generation).
  final EpgStoreSpec? store;
  final SendPort port;
  final bool download;
  final String lang;
  const XmltvJob({
    required this.sources,
    required this.headers,
    required this.channelIds,
    required this.packedChannels,
    required this.limit,
    required this.shifts,
    required this.encode,
    this.store,
    required this.port,
    required this.download,
    required this.lang,
  });
}

class XmltvResult {
  final Map<String, List<EpgEntry>> epg;
  final Map<String, String> names;
  final String? hash;

  /// In die Datenbank geschriebene (noch nicht aktive) Generation.
  final int? staged;
  const XmltvResult(this.epg, this.names, this.hash, [this.staged]);
}
