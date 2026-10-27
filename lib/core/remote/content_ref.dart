import 'dart:convert';

import 'package:crypto/crypto.dart' as c;

import '../../models/models.dart';
import 'protocol.dart';

/// Art eines Inhalts für „Auf dem TV abspielen“.
enum ContentKind {
  live('live'),
  movie('movie'),
  episode('episode');

  const ContentKind(this.wire);
  final String wire;
  static ContentKind? fromWire(Object? w) => switch (w) {
        'live' => live,
        'movie' => movie,
        'episode' => episode,
        _ => null,
      };
}

/// Inhalt, den das Handy an den Fernseher übergibt – nur Kennungen, nie
/// eine Adresse oder Zugangsdaten. Der Fernseher öffnet ihn aus seinem
/// eigenen Portal bzw. Emby-Zugang.
class ContentRef {
  /// `portal` oder `emby`.
  final String source;

  /// Fingerabdrücke des Portals ([portalFingerprints]) bzw. des
  /// Emby-Servers ([embyFingerprint]) – Hashwerte, keine Adressen.
  final List<String> scope;
  final ContentKind kind;

  /// Sender-, Film- bzw. Folgen-Kennung im Portal/auf dem Server.
  final String id;

  /// Folge: Kennung der Serie.
  final String? seriesId;

  /// Stelle in Sekunden (Film/Folge), 0 = Anfang bzw. wie am Fernseher.
  final int position;

  /// Nur zur Anzeige in Meldungen.
  final String title;

  const ContentRef({
    required this.source,
    required this.scope,
    required this.kind,
    required this.id,
    this.seriesId,
    this.position = 0,
    this.title = '',
  });

  bool get isEmby => source == 'emby';

  Map<String, Object?> toJson() => {
        'src': source,
        'scope': scope,
        'kind': kind.wire,
        'id': id,
        if (seriesId != null) 'series': seriesId,
        if (position > 0) 'pos': position,
        if (title.isNotEmpty) 'title': title,
      };

  static ContentRef? fromJson(Map<String, Object?>? m) {
    if (m == null) return null;
    final src = Wire.str(m, 'src', max: 8);
    final kind = ContentKind.fromWire(m['kind']);
    final id = Wire.str(m, 'id');
    final rawScope = m['scope'];
    if ((src != 'portal' && src != 'emby') || kind == null || id == null ||
        id.isEmpty || rawScope is! List || rawScope.length > 8) {
      return null;
    }
    final scope = [
      for (final s in rawScope)
        if (s is String && s.length <= 64) s,
    ];
    if (scope.isEmpty) return null;
    if (src == 'emby' && kind == ContentKind.live) return null;
    return ContentRef(
      source: src!,
      scope: scope,
      kind: kind,
      id: id,
      seriesId: Wire.str(m, 'series'),
      position: Wire.integer(m, 'pos', max: 1 << 24) ?? 0,
      title: Wire.str(m, 'title', max: 200) ?? '',
    );
  }
}

String _fp(String s) =>
    c.sha256.convert(utf8.encode(s)).toString().substring(0, 32);

/// Adresse vereinheitlichen: Kleinbuchstaben, Standard-Port weg, ohne
/// Schrägstrich am Ende (Abfrageteil bleibt – M3U-Listen unterscheiden
/// sich oft nur darin).
String normalizePortalUrl(String url) {
  final u = Uri.tryParse(url.trim());
  if (u == null || u.host.isEmpty) return url.trim().toLowerCase();
  final port = u.hasPort &&
          !((u.scheme == 'http' && u.port == 80) ||
              (u.scheme == 'https' && u.port == 443))
      ? ':${u.port}'
      : '';
  var path = u.path;
  while (path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  final q = u.hasQuery ? '?${u.query}' : '';
  return '${u.scheme.toLowerCase()}://${u.host.toLowerCase()}$port$path$q';
}

/// Fingerabdrücke eines Portals – je Adresse (Haupt- und Ersatzadressen)
/// einer, damit Handy und Fernseher dasselbe Konto auch erkennen, wenn sie
/// unterschiedliche Server-Adressen eingetragen haben. Gehasht mit
/// Benutzername bzw. MAC (nie mit Passwort); keine Rückrechnung möglich.
List<String> portalFingerprints(Portal p) {
  final who = switch (p.type) {
    PortalType.stalker =>
      (p.username ?? '').trim().toUpperCase().replaceAll('-', ':'),
    PortalType.xtream => (p.username ?? '').trim(),
    _ => '',
  };
  final urls = <String>{
    normalizePortalUrl(p.url),
    for (final a in p.altUrls) normalizePortalUrl(a),
  };
  return [
    for (final u in urls.take(6)) _fp('jsp-portal|${p.type.name}|$u|$who'),
  ];
}

/// Fingerabdruck eines Emby-/Jellyfin-Servers (Server-Kennung).
String embyFingerprint(String serverId) =>
    _fp('jsp-emby|${serverId.trim().toLowerCase()}');

/// Ergebnis der Portal-Zuordnung am Fernseher.
enum PortalMatch {
  /// Aktives Portal passt.
  active,

  /// Ein eingerichtetes, aber gerade nicht aktives Portal passt.
  inactive,

  /// Kein passendes Portal.
  none,
}

/// Welches Portal des Fernsehers gehört zu [ref]?
PortalMatch matchPortal(ContentRef ref, List<Portal> portals, Portal? active) {
  final want = ref.scope.toSet();
  bool hit(Portal p) => portalFingerprints(p).any(want.contains);
  if (active != null && hit(active)) return PortalMatch.active;
  for (final p in portals) {
    if (hit(p)) return PortalMatch.inactive;
  }
  return PortalMatch.none;
}
