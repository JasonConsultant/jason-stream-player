/// Anmeldung vom Handy auf den Fernseher übertragen (per QR-Code).
///
/// Der Fernseher startet mit [PairingSession.start] einen kleinen Webserver im
/// lokalen Netz und zeigt [PairingSession.url] als QR-Code an. Das Handy öffnet
/// die Adresse im normalen Browser, füllt das Formular aus und schickt die
/// Zugangsdaten direkt an den Fernseher – ohne Umweg über das Internet.
///
/// Auf Web gibt es keinen `dart:io`-Server; dort wirft [PairingSession.start]
/// einen [UnsupportedError].
library;

export 'pairing_server_stub.dart'
    if (dart.library.io) 'pairing_server.dart';

/// Die vom Handy übertragenen Zugangsdaten.
class PairingResult {
  /// 'xtream', 'm3u' oder 'stalker' (MAC-Portal).
  final String type;
  final String name;

  /// Server- (Xtream), Playlist- (M3U) oder Portal-Adresse (MAC-Portal).
  final String url;
  final String? username;
  final String? password;

  /// MAC-Adresse im Format XX:XX:XX:XX:XX:XX (nur MAC-Portal).
  final String? mac;
  final String? epgUrl;

  const PairingResult({
    required this.type,
    required this.name,
    required this.url,
    this.username,
    this.password,
    this.mac,
    this.epgUrl,
  });

  /// Bewusst ohne Zugangsdaten, damit nichts in Logs landet.
  @override
  String toString() => 'PairingResult(type: $type, name: $name)';
}

/// Fehler einer Kopplung (Zeit abgelaufen, abgebrochen, kein Netzwerk).
class PairingException implements Exception {
  final String message;
  const PairingException(this.message);

  @override
  String toString() => message;
}
