import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;

import '../models/models.dart';
import 'repository.dart';

/// Ersatz-Adressen eines Portals ([Portal.altUrls]): Antwortet die
/// Hauptadresse nicht (Zeitüberschreitung, Verbindungsfehler, HTTP 404/5xx),
/// wird automatisch die nächste probiert. Die zuletzt funktionierende wird
/// gemerkt und beim nächsten Mal zuerst genommen – auch für Streams
/// ([rewrite]).
class HostFailover {
  HostFailover._();

  /// Portal-ID → Index der zuletzt funktionierenden Adresse in [bases].
  static final _active = <String, int>{};

  /// Speichert die Wahl dauerhaft (setzt Storage beim Öffnen).
  static void Function(String portalId, int index)? persist;

  /// Gespeicherte Wahl beim Start übernehmen.
  static void restore(String portalId, int index) => _active[portalId] = index;

  @visibleForTesting
  static void reset() => _active.clear();

  /// Gemerkte Wahl verwerfen (Adressen des Portals wurden geändert).
  static void forget(String portalId) => _active.remove(portalId);

  /// Alle Adressen: Hauptadresse zuerst, dann Ersatz-Adressen (ohne Doppelte).
  static List<String> bases(Portal p) {
    final out = <String>[];
    for (final u in [p.url, ...p.altUrls]) {
      final t = u.trim();
      if (t.isNotEmpty && !out.contains(t)) out.add(t);
    }
    return out;
  }

  static int activeIndex(Portal p) {
    final i = _active[p.id] ?? 0;
    return i < bases(p).length ? i : 0;
  }

  /// Aktuell bevorzugte Adresse.
  static String activeBase(Portal p) {
    final b = bases(p);
    return b.isEmpty ? p.url.trim() : b[activeIndex(p)];
  }

  /// Reihenfolge der Versuche: bevorzugte zuerst, dann die übrigen.
  static List<int> order(Portal p) {
    final n = bases(p).length;
    final a = activeIndex(p);
    return [
      a,
      for (var i = 0; i < n; i++)
        if (i != a) i
    ];
  }

  static void markWorking(Portal p, int index) {
    if (_active[p.id] == index) return;
    if (index == 0 && !_active.containsKey(p.id)) return;
    _active[p.id] = index;
    persist?.call(p.id, index);
  }

  /// Fehler, bei dem eine andere Adresse helfen könnte (nicht bei falschen
  /// Zugangsdaten – die wären auf jedem Spiegel falsch).
  static bool isHostFailure(Object e) {
    if (e is TimeoutException || e is http.ClientException) return true;
    if (e is RepositoryException) {
      final s = e.statusCode;
      return s != null && (s == 404 || s == 408 || s == 429 || s >= 500);
    }
    final t = e.runtimeType.toString();
    return t.contains('Socket') ||
        t.contains('Handshake') ||
        t.contains('Tls') ||
        t.contains('HttpException');
  }

  /// [f] mit der bevorzugten Adresse ausführen, bei Host-Fehlern mit den
  /// übrigen. Die erste erfolgreiche wird gemerkt.
  static Future<T> run<T>(Portal p, Future<T> Function(String base) f) async {
    final b = bases(p);
    if (b.length <= 1) return f(b.isEmpty ? p.url.trim() : b.first);
    Object? firstError;
    StackTrace? firstStack;
    for (final i in order(p)) {
      try {
        final r = await f(b[i]);
        markWorking(p, i);
        return r;
      } catch (e, st) {
        if (!isHostFailure(e)) rethrow;
        if (firstError == null) {
          firstError = e;
          firstStack = st;
        }
      }
    }
    Error.throwWithStackTrace(firstError!, firstStack!);
  }

  static String _origin(Uri u) =>
      '${u.scheme}://${u.host}${u.hasPort ? ':${u.port}' : ''}';

  /// Stream-Adresse auf die bevorzugte Adresse umschreiben, wenn sie zu
  /// einer der anderen Adressen des Portals gehört.
  static String rewrite(Portal p, String url) {
    final b = bases(p);
    if (b.length <= 1) return url;
    return rewriteTo(p, url, activeIndex(p));
  }

  /// Wie [rewrite], aber auf Adresse Nr. [target].
  static String rewriteTo(Portal p, String url, int target) {
    final b = [for (final x in bases(p)) x.replaceAll(RegExp(r'/+$'), '')];
    if (target < 0 || target >= b.length) return url;
    // 1) Gleiches Präfix (Xtream: http://host:port/pfad)
    for (var i = 0; i < b.length; i++) {
      if (i != target && b[i].isNotEmpty && url.startsWith('${b[i]}/')) {
        return b[target] + url.substring(b[i].length);
      }
    }
    // 2) Gleicher Host (M3U: Playlist und Streams auf demselben Server)
    final u = Uri.tryParse(url);
    final t = Uri.tryParse(b[target]);
    if (u == null || t == null || !u.hasScheme || t.host.isEmpty) return url;
    final o = _origin(u);
    for (var i = 0; i < b.length; i++) {
      if (i == target) continue;
      final bi = Uri.tryParse(b[i]);
      if (bi == null || bi.host.isEmpty) continue;
      if (_origin(bi) == o) return _origin(t) + url.substring(o.length);
    }
    return url;
  }

  /// Alle Varianten einer Stream-Adresse (bevorzugte zuerst) – damit der
  /// Player bei einem Fehler die nächste probieren kann.
  static List<String> streamCandidates(Portal p, String url) {
    final out = <String>[];
    for (final i in order(p)) {
      final r = rewriteTo(p, url, i);
      if (!out.contains(r)) out.add(r);
    }
    if (out.isEmpty) out.add(url);
    return out;
  }
}
