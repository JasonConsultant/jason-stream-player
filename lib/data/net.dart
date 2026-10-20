import 'dart:async';
import 'dart:typed_data';

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
  static final _client = http.Client();

  static Future<Uint8List> get(
    Uri uri, {
    int maxBytes = 64 * 1024 * 1024,
    Duration timeout = const Duration(seconds: 30),
    Map<String, String>? headers,
    void Function(int received, int? total)? onProgress,
  }) async {
    var current = uri;
    for (var hop = 0; hop <= 5; hop++) {
      if (!UrlPolicy.isWeb(current.toString())) {
        throw RepositoryException(tr('Unsichere Adresse blockiert.'));
      }
      final req = http.Request('GET', current)
        ..followRedirects = false
        ..headers['User-Agent'] = userAgent;
      if (headers != null) req.headers.addAll(headers); // darf User-Agent ersetzen
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
            tr('An deinem Standort nicht verfügbar (HTTP 451).'));
      }
      if (res.statusCode == 401 || res.statusCode == 403) {
        await res.stream.drain<void>();
        throw RepositoryException(trf(
            'Zugriff verweigert – Zugangsdaten prüfen (HTTP {0}).', [res.statusCode]));
      }
      if (res.statusCode != 200) {
        await res.stream.drain<void>();
        throw RepositoryException(
            trf('Server antwortet mit HTTP {0}.', [res.statusCode]));
      }
      final declared = res.contentLength ?? 0;
      if (declared > maxBytes) {
        await res.stream.drain<void>();
        throw RepositoryException(tr('Antwort des Servers ist zu groß.'));
      }

      final builder = BytesBuilder(copy: false);
      final total = declared > 0 ? declared : null;
      var lastReport = 0;
      await for (final chunk in res.stream.timeout(timeout)) {
        builder.add(chunk);
        if (onProgress != null && builder.length - lastReport > 512 * 1024) {
          lastReport = builder.length;
          onProgress(builder.length, total);
        }
        if (builder.length > maxBytes) {
          throw RepositoryException(tr('Antwort des Servers ist zu groß.'));
        }
      }
      return builder.takeBytes();
    }
    throw RepositoryException(tr('Zu viele Weiterleitungen.'));
  }
}
