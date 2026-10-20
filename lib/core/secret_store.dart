import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Ver- und Entschlüsselung von Geheimnissen (Zugangsdaten, PIN-Hash).
///
/// Auf Android: AES-256-GCM mit einem Schlüssel, der im Android-Keystore
/// erzeugt wird und das Gerät nie verlässt (siehe MainActivity.kt).
/// Jeder Aufruf hat ein Zeitlimit – der App-Start darf nie hängen.
abstract class SecretStore {
  Future<String> encrypt(String plain);
  Future<String> decrypt(String cipher);

  /// Passender Speicher für die aktuelle Plattform.
  static SecretStore platform() =>
      (!kIsWeb && defaultTargetPlatform == TargetPlatform.android)
          ? KeystoreSecretStore()
          : PreviewSecretStore();
}

class SecretStoreException implements Exception {
  final String message;
  SecretStoreException(this.message);
  @override
  String toString() => message;
}

class KeystoreSecretStore implements SecretStore {
  static const _channel = MethodChannel('de.jasonstream.player/secure');
  static const _timeout = Duration(seconds: 6);

  Future<String> _call(String method, String value) async {
    try {
      final r = await _channel
          .invokeMethod<String>(method, {'value': value}).timeout(_timeout);
      if (r == null) throw SecretStoreException('Keine Antwort vom Keystore');
      return r;
    } on TimeoutException {
      throw SecretStoreException('Der Schlüsselspeicher antwortet nicht.');
    } on PlatformException catch (e) {
      throw SecretStoreException('Schlüsselspeicher-Fehler: ${e.code}');
    } on MissingPluginException {
      throw SecretStoreException('Schlüsselspeicher nicht verfügbar.');
    }
  }

  @override
  Future<String> encrypt(String plain) => _call('encrypt', plain);

  @override
  Future<String> decrypt(String cipher) => _call('decrypt', cipher);
}

/// Nur für Web-Vorschau und Tests: keine echte Verschlüsselung.
/// Die App wird ausschließlich für Android ausgeliefert.
class PreviewSecretStore implements SecretStore {
  @override
  Future<String> encrypt(String plain) async =>
      'p1:${base64Encode(utf8.encode(plain))}';

  @override
  Future<String> decrypt(String cipher) async {
    if (!cipher.startsWith('p1:')) {
      throw SecretStoreException('Unbekanntes Format');
    }
    return utf8.decode(base64Decode(cipher.substring(3)));
  }
}
