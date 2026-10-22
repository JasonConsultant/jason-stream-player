import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;

import '../core/security.dart';
import '../l10n/strings.dart';
import 'repository.dart';

/// Sichere HTTP-Abrufe für Portal, Playlist und EPG.
///
/// - Nur http/https.
/// - Größenlimit, damit eine manipulierte Antwort den Speicher nicht flutet.
/// - Weiterleitungen werden selbst verfolgt: höchstens 5, und nie von
///   https auf http (sonst gingen Zugangsdaten unverschlüsselt raus).
class Net {
  static const userAgent = 'JasonStreamPlayer/0.9';
  static http.Client _client = http.Client();
  static bool _custom = false;

  /// Nur für Tests: HTTP-Client ersetzen (z. B. MockClient).
  @visibleForTesting
  static set client(http.Client c) {
    _client = c;
    _custom = true;
  }

  /// true, wenn ein Test-Client gesetzt ist – der existiert nur in diesem
  /// Isolate, Hintergrund-Isolates müssen dann über das Haupt-Isolate laden.
  static bool get hasCustomClient => _custom;

  static Future<Uint8List> get(
    Uri uri, {
    int maxBytes = 64 * 1024 * 1024,
    Duration timeout = const Duration(seconds: 30),
    Map<String, String>? headers,
    void Function(int received, int? total)? onProgress,
  }) async {
    final (stream, declared) =
        await open(uri, maxBytes: maxBytes, timeout: timeout, headers: headers);
    final builder = BytesBuilder(copy: false);
    final total = declared;
    var lastReport = 0;
    await for (final chunk in stream) {
      builder.add(chunk);
      if (onProgress != null && builder.length - lastReport > 512 * 1024) {
        lastReport = builder.length;
        onProgress(builder.length, total);
      }
    }
    return builder.takeBytes();
  }

  /// Wie [get], liefert aber den Inhalt als Datenstrom (Stück für Stück,
  /// nie komplett im Speicher) und die angekündigte Größe. Größenlimit und
  /// Zeitlimit pro Stück gelten weiterhin.
  static Future<(Stream<List<int>>, int?)> open(
    Uri uri, {
    int maxBytes = 64 * 1024 * 1024,
    Duration timeout = const Duration(seconds: 30),
    Map<String, String>? headers,
  }) async {
    var current = uri;
    for (var hop = 0; hop <= 5; hop++) {
      if (!UrlPolicy.isWeb(current.toString())) {
        throw RepositoryException(tr('Unsichere Adresse blockiert.'));
      }
      final req = http.Request('GET', current)
        ..followRedirects = false
        ..headers['User-Agent'] = userAgent;
      // darf User-Agent ersetzen
      if (headers != null) req.headers.addAll(headers);
      final res = await _client.send(req).timeout(timeout);

      if (res.isRedirect || (res.statusCode >= 300 && res.statusCode < 400)) {
        final loc = res.headers['location'];
        await res.stream.drain<void>();
        if (loc == null) {
          throw RepositoryException(tr('Ungültige Weiterleitung vom Server.'));
        }
        final next = current.resolve(loc);
        if (current.scheme == 'https' && next.scheme != 'https') {
          throw RepositoryException(
              tr('Weiterleitung auf unverschlüsselte Verbindung blockiert.'));
        }
        current = next;
        continue;
      }

      if (res.statusCode == 451) {
        await res.stream.drain<void>();
        throw RepositoryException(
            tr('An deinem Standort nicht verfügbar (HTTP 451).'),
            statusCode: 451);
      }
      if (res.statusCode == 401 || res.statusCode == 403) {
        await res.stream.drain<void>();
        throw RepositoryException(
            trf('Zugriff verweigert – Zugangsdaten prüfen (HTTP {0}).',
                [res.statusCode]),
            statusCode: res.statusCode);
      }
      if (res.statusCode != 200) {
        await res.stream.drain<void>();
        throw RepositoryException(
            trf('Server antwortet mit HTTP {0}.', [res.statusCode]),
            statusCode: res.statusCode);
      }
      final declared = res.contentLength ?? 0;
      if (declared > maxBytes) {
        await res.stream.drain<void>();
        throw RepositoryException(tr('Antwort des Servers ist zu groß.'));
      }

      return (
        _limited(res.stream.timeout(timeout), maxBytes),
        declared > 0 ? declared : null
      );
    }
    throw RepositoryException(tr('Zu viele Weiterleitungen.'));
  }

  static Stream<List<int>> _limited(Stream<List<int>> s, int maxBytes) async* {
    var n = 0;
    await for (final chunk in s) {
      n += chunk.length;
      if (n > maxBytes) {
        throw RepositoryException(tr('Antwort des Servers ist zu groß.'));
      }
      yield chunk;
    }
  }
}
