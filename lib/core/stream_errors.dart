import 'package:flutter/material.dart';

import '../l10n/strings.dart';

/// Ordnet Fehler beim Abspielen einer verständlichen Ursache zu.
enum StreamErrorKind {
  /// HTTP 451 – vom Anbieter für diesen Standort gesperrt.
  geoBlocked,

  /// HTTP 403 – Zugriff verweigert (Standort, Abo-Umfang oder zu viele
  /// gleichzeitige Verbindungen).
  forbidden,

  /// HTTP 401 – Zugangsdaten abgelehnt.
  unauthorized,

  /// HTTP 404 – Sender/Sendung existiert nicht (mehr).
  notFound,

  /// Server/Internet nicht erreichbar.
  unreachable,

  /// Von der App aus Sicherheitsgründen blockiert.
  blockedByApp,

  other,
}

class StreamError {
  final StreamErrorKind kind;
  const StreamError(this.kind);

  static StreamError classify(String message) {
    final m = message.toLowerCase();
    // Nur echte HTTP-Statusangaben werten („HTTP error 403 Forbidden“,
    // „Server returned 451“, „status: 404“) – keine Zahlen aus Stream-URLs.
    final status = RegExp(
            r'(?:http(?:\s*error)?|server returned|status(?:\s*code)?)[\s:]*([1-5]\d\d)\b')
        .firstMatch(m)
        ?.group(1);
    bool code(String c) => status == c;
    if (m.contains('sicherheitsgründen') ||
        m.contains('security reasons') ||
        m.contains('güvenlik nedeniyle')) {
      return const StreamError(StreamErrorKind.blockedByApp);
    }
    if (code('451') || m.contains('unavailable for legal reasons')) {
      return const StreamError(StreamErrorKind.geoBlocked);
    }
    if (code('403') || m.contains('forbidden')) {
      return const StreamError(StreamErrorKind.forbidden);
    }
    if (code('401') || m.contains('unauthorized')) {
      return const StreamError(StreamErrorKind.unauthorized);
    }
    if (code('404') || m.contains('not found')) {
      return const StreamError(StreamErrorKind.notFound);
    }
    if (m.contains('timed out') ||
        m.contains('timeout') ||
        m.contains('connection refused') ||
        m.contains('failed to resolve') ||
        m.contains('host lookup') ||
        m.contains('network is unreachable') ||
        m.contains('failed to open')) {
      return const StreamError(StreamErrorKind.unreachable);
    }
    return const StreamError(StreamErrorKind.other);
  }

  /// Gilt als „an diesem Standort nicht verfügbar“ und wird am Sender
  /// vermerkt.
  bool get isLocationRelated =>
      kind == StreamErrorKind.geoBlocked || kind == StreamErrorKind.forbidden;

  IconData get icon => switch (kind) {
        StreamErrorKind.geoBlocked ||
        StreamErrorKind.forbidden =>
          Icons.public_off_rounded,
        StreamErrorKind.unauthorized => Icons.key_off_rounded,
        StreamErrorKind.notFound => Icons.tv_off_rounded,
        StreamErrorKind.blockedByApp => Icons.gpp_bad_rounded,
        _ => Icons.signal_wifi_bad_rounded,
      };

  String get title => switch (kind) {
        StreamErrorKind.geoBlocked => tr('An deinem Standort nicht verfügbar'),
        StreamErrorKind.forbidden => tr('Kein Zugriff auf diesen Sender'),
        StreamErrorKind.unauthorized => tr('Zugangsdaten abgelehnt'),
        StreamErrorKind.notFound => tr('Sender nicht gefunden'),
        StreamErrorKind.unreachable => tr('Server nicht erreichbar'),
        StreamErrorKind.blockedByApp => tr('Aus Sicherheitsgründen blockiert'),
        StreamErrorKind.other => tr('Stream nicht abspielbar'),
      };

  String get message => switch (kind) {
        StreamErrorKind.geoBlocked =>
          tr('Der Anbieter hat diesen Sender für dein Land gesperrt – meist wegen '
              'Senderechten. Frag deinen Anbieter, ob er ihn für deinen Standort '
              'freischalten kann.'),
        StreamErrorKind.forbidden =>
          tr('Mögliche Gründe: Der Sender ist an deinem Standort gesperrt, nicht in '
              'deinem Abo enthalten, oder es laufen zu viele Geräte gleichzeitig.'),
        StreamErrorKind.unauthorized =>
          tr('Der Server akzeptiert die Zugangsdaten nicht mehr. Prüfe in den '
              'Einstellungen, ob dein Zugang noch gültig ist.'),
        StreamErrorKind.notFound =>
          tr('Den Sender gibt es beim Anbieter nicht mehr. Lade die Senderliste '
              'neu (Einstellungen → Sender & EPG neu laden).'),
        StreamErrorKind.unreachable =>
          tr('Prüfe deine Internetverbindung. Wenn alles andere geht, hat dein '
              'Anbieter gerade eine Störung.'),
        StreamErrorKind.blockedByApp =>
          tr('Die Adresse dieses Streams ist ungültig oder unsicher.'),
        StreamErrorKind.other =>
          tr('Der Stream konnte nicht geladen werden. Versuch es gleich noch einmal.'),
      };
}
