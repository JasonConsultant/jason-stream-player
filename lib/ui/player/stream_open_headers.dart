import '../../data/stream_headers.dart';
import '../../models/models.dart';

/// HTTP-Kopfzeilen beim Öffnen eines Streams im Player: Portal-Einstellungen
/// (User-Agent, Referer …) und Angaben des Senders (#EXTVLCOPT) aus
/// [streamHeadersFor]; fehlt ein User-Agent, der App-Standard. Der Player
/// setzt daraus `user-agent`, `referrer` und `http-header-fields` in mpv.
Map<String, String> playerHeadersFor(Portal? portal, Channel? channel) {
  final h = portal == null
      ? <String, String>{}
      : {...streamHeadersFor(portal, channel)};
  if (headerValue(h, 'User-Agent') == null) {
    h.addAll(defaultPlayerHeaders);
  }
  return h;
}

const defaultPlayerHeaders = {'User-Agent': 'JasonStreamPlayer/0.4'};

/// Kopfzeile ohne Beachtung der Groß-/Kleinschreibung finden.
String? headerValue(Map<String, String> h, String name) {
  final n = name.toLowerCase();
  for (final e in h.entries) {
    if (e.key.toLowerCase() == n) return e.value;
  }
  return null;
}
