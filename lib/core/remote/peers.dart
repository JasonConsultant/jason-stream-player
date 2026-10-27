import 'dart:convert';
import 'dart:typed_data';

import 'crypto.dart';

/// Gekoppeltes Gerät – am Fernseher ein Handy, am Handy ein Fernseher.
/// Der Schlüssel ist geheim: die Liste wird wie Zugangsdaten verschlüsselt
/// gespeichert (Android-Keystore, nie in Sicherungen) und nie geloggt.
class RemotePeer {
  /// Zufällige Kennung des Geräts (kein Geheimnis).
  final String id;
  final String name;
  final Uint8List key;
  final DateTime pairedAt;

  /// Handy: zuletzt bekannte Adresse des Fernsehers (Schnellverbindung
  /// ohne Suche); am Fernseher leer.
  final String? host;
  final int? port;

  /// Zuletzt verbunden (Anzeige „Gekoppelte Geräte“).
  final DateTime? lastSeen;

  const RemotePeer({
    required this.id,
    required this.name,
    required this.key,
    required this.pairedAt,
    this.host,
    this.port,
    this.lastSeen,
  });

  RemotePeer copyWith(
          {String? name, String? host, int? port, DateTime? lastSeen}) =>
      RemotePeer(
        id: id,
        name: name ?? this.name,
        key: key,
        pairedAt: pairedAt,
        host: host ?? this.host,
        port: port ?? this.port,
        lastSeen: lastSeen ?? this.lastSeen,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'key': RemoteCrypto.b64(key),
        'at': pairedAt.millisecondsSinceEpoch,
        if (host != null) 'host': host,
        if (port != null) 'port': port,
        if (lastSeen != null) 'seen': lastSeen!.millisecondsSinceEpoch,
      };

  static RemotePeer? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['id'], name = j['name'];
    final key = RemoteCrypto.unb64(j['key'], length: 32);
    if (id is! String || name is! String || key == null) return null;
    final at = j['at'], seen = j['seen'], port = j['port'], host = j['host'];
    return RemotePeer(
      id: id,
      name: name,
      key: key,
      pairedAt: DateTime.fromMillisecondsSinceEpoch(at is int ? at : 0),
      host: host is String ? host : null,
      port: port is int ? port : null,
      lastSeen: seen is int ? DateTime.fromMillisecondsSinceEpoch(seen) : null,
    );
  }

  static List<RemotePeer> decodeList(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final j = jsonDecode(raw);
      if (j is! List) return const [];
      return [
        for (final e in j)
          if (RemotePeer.fromJson(e) case final p?) p,
      ];
    } catch (_) {
      return const [];
    }
  }

  static String encodeList(List<RemotePeer> peers) =>
      jsonEncode([for (final p in peers) p.toJson()]);

  /// Bewusst ohne Schlüssel.
  @override
  String toString() => 'RemotePeer($id, $name)';
}

/// Zufällige, nicht geheime Kennung (Gerät/Fernseher).
String newRemoteId() =>
    RemoteCrypto.b64(RemoteCrypto.random(12)).replaceAll('=', '');
