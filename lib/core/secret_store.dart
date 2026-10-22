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

/// Optional: mehrere Geheimnisse in einem Aufruf entschlüsseln (App-Start).
/// Ergebnis in gleicher Reihenfolge, null = nicht lesbar. Wirft
/// [SecretStoreException], wenn der Speicher gar nicht antwortet.
abstract interface class BatchSecretStore {
  Future<List<String?>> decryptAll(List<String> ciphers);
}

class SecretStoreException implements Exception {
  final String message;
  SecretStoreException(this.message);
  @override
  String toString() => message;
}

class KeystoreSecretStore implements SecretStore, BatchSecretStore {
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

  /// Ein Kanal-Aufruf für alle Geheimnisse; der Keystore-Schlüssel wird auf
  /// Android pro Prozess nur einmal geladen (SecureBox.kt). Ältere native
  /// Seite ohne „decryptAll“ → einzeln wie bisher.
  @override
  Future<List<String?>> decryptAll(List<String> ciphers) async {
    if (ciphers.isEmpty) return const [];
    try {
      final r = await _channel.invokeMethod<List<Object?>>(
          'decryptAll', {'values': ciphers}).timeout(_timeout);
      if (r == null || r.length != ciphers.length) {
        throw SecretStoreException('Keine Antwort vom Keystore');
      }
      return [for (final v in r) v is String ? v : null];
    } on TimeoutException {
      throw SecretStoreException('Der Schlüsselspeicher antwortet nicht.');
    } on MissingPluginException {
      return _oneByOne(ciphers);
    } on PlatformException catch (e) {
      throw SecretStoreException('Schlüsselspeicher-Fehler: ${e.code}');
    }
  }

  Future<List<String?>> _oneByOne(List<String> ciphers) async => [
        for (final c in ciphers)
          await decrypt(c).then<String?>((v) => v,
              onError: (Object e) =>
                  e is SecretStoreException ? null : throw e),
      ];
}

/// Nur für Web-Vorschau und Tests: keine echte Verschlüsselung.
/// Die App wird ausschließlich für Android ausgeliefert.
class PreviewSecretStore implements SecretStore, BatchSecretStore {
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

  @override
  Future<List<String?>> decryptAll(List<String> ciphers) async => [
        for (final c in ciphers)
          c.startsWith('p1:') ? _tryDecode(c.substring(3)) : null,
      ];

  static String? _tryDecode(String b64) {
    try {
      return utf8.decode(base64Decode(b64));
    } catch (_) {
      return null;
    }
  }
}
