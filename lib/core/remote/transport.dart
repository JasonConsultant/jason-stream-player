import 'dart:async';
import 'dart:typed_data';

import 'peers.dart';

/// Schnittstellen zwischen Netz (net_io.dart) und App (TV-Dienst bzw.
/// Handy-Verbindung) – ohne `dart:io`, damit die App auch im Web baut.

/// Was der Server am Fernseher von der App braucht.
abstract class RemoteTvHost {
  String get tvId;
  String get tvName;

  /// Fähigkeiten für `ready` (z. B. `volume`).
  Map<String, Object?> get caps;

  /// Gekoppeltes Handy oder null.
  RemotePeer? phone(String deviceId);

  /// Neues Handy gekoppelt (Schlüssel sicher speichern).
  Future<void> addPhone(RemotePeer p);

  /// Code am Fernseher anzeigen (Koppeln) bzw. wieder ausblenden.
  void showPairingCode(String code, String phoneName);
  void hidePairingCode({bool paired = false, String? phoneName});

  /// Verbindung eines gekoppelten Handys steht/ist weg.
  void connected(String deviceId);
  void disconnected(String deviceId);

  /// Nachricht eines angemeldeten Handys. Bei Anfragen (`t == 'req'`) die
  /// Antwort (ohne `t`/`id`), sonst null.
  Future<Map<String, Object?>?> handle(
      String deviceId, Map<String, Object?> msg);
}

/// Laufender Server am Fernseher.
abstract class RemoteServerHandle {
  int get port;
  String get address;

  /// Angemeldete Verbindungen.
  int get clients;

  /// An alle angemeldeten Handys (verschlüsselt).
  Future<void> broadcast(Map<String, Object?> msg);

  /// Verbindungen dieses Handys trennen (Gerät entfernt).
  void disconnect(String deviceId);

  Future<void> close();
}

/// Ergebnis der Begrüßung des Fernsehers.
class RemoteHello {
  final String tvId;
  final String name;
  final int version;
  final Uint8List nonce;
  const RemoteHello(this.tvId, this.name, this.version, this.nonce);
}

/// Anmeldung/Kopplung abgelehnt.
class RemoteRejected implements Exception {
  /// `unknown` = Handy nicht (mehr) gekoppelt, `locked` = zu viele
  /// Fehlversuche (siehe [lockedFor]), `busy` = andere Kopplung läuft,
  /// `code` = falscher Code, `auth`/`protocol` = Fehler.
  final String reason;
  final Duration? lockedFor;
  const RemoteRejected(this.reason, {this.lockedFor});
  @override
  String toString() => 'RemoteRejected($reason)';
}

/// Verbindung Handy → Fernseher.
abstract class RemoteConnection {
  RemoteHello get hello;

  /// Nach [authenticate]: Name/Fähigkeiten aus `ready`.
  Map<String, Object?> get ready;

  /// Ereignisse des Fernsehers (`status`, `text`, …) nach der Anmeldung.
  Stream<Map<String, Object?>> get events;

  /// Ende der Verbindung (normal oder Fehler).
  Future<void> get done;
  bool get isOpen;

  /// Mit Geräteschlüssel anmelden. Wirft [RemoteRejected].
  Future<void> authenticate(String deviceId, Uint8List key);

  /// Koppeln beginnen: Fernseher zeigt danach einen Code.
  Future<RemotePairingFlow> pair(String deviceId, String deviceName);

  Future<void> send(Map<String, Object?> msg);

  /// Anfrage mit Antwort (`res`). Wirft [TimeoutException] bzw.
  /// [RemoteRejected] (Verbindung weg).
  Future<Map<String, Object?>> request(String method,
      [Map<String, Object?> args = const {},
      Duration timeout = const Duration(seconds: 8)]);

  Future<void> close();
}

/// Laufende Kopplung am Handy (Code eingeben → Schlüssel).
abstract class RemotePairingFlow {
  /// Code bestätigen; liefert den Geräteschlüssel oder wirft
  /// [RemoteRejected] (`code`, `locked`, …). Danach ist die Verbindung zu.
  Future<Uint8List> submit(String code);
  Future<void> cancel();
}
