import 'pairing.dart';

/// Platzhalter für Web: Dort gibt es keinen lokalen Webserver (`dart:io`).
class PairingSession {
  PairingSession._();

  /// Gültigkeit einer Kopplung.
  static const ttl = Duration(minutes: 10);

  /// Auf Web nicht verfügbar.
  static Future<PairingSession> start({
    Object? bindAddress,
    Duration timeout = ttl,
  }) async {
    throw UnsupportedError('Nur auf Android verfügbar');
  }

  Uri get url => throw UnsupportedError('Nur auf Android verfügbar');

  Future<PairingResult> get result =>
      throw UnsupportedError('Nur auf Android verfügbar');

  bool get isActive => false;

  Future<void> cancel() async {}
}
