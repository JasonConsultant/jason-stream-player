import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Gefundener Fernseher im WLAN (mDNS/NSD).
class FoundTv {
  /// Dienstname (Anzeige, z. B. Gerätename des Fernsehers).
  final String name;
  final String host;
  final int port;

  /// TV-Kennung aus den TXT-Daten (zum Wiedererkennen gekoppelter TVs).
  final String? id;
  final int version;

  const FoundTv(
      {required this.name,
      required this.host,
      required this.port,
      this.id,
      this.version = 0});

  @override
  bool operator ==(Object other) =>
      other is FoundTv &&
      other.name == name &&
      other.host == host &&
      other.port == port &&
      other.id == id;

  @override
  int get hashCode => Object.hash(name, host, port, id);
}

/// Ankündigen (TV) und Suchen (Handy) über den Kanal des Plugins
/// (`RemoteBridge.kt`, Android NsdManager). Tests ersetzen das durch eine
/// eigene Implementierung.
abstract class RemoteDiscovery {
  /// Dienst ankündigen; liefert den tatsächlichen Namen (oder null).
  Future<String?> register(
      {required String name, required int port, required Map<String, String> attrs});
  Future<void> unregister();

  /// Suche starten: Funde/Verluste als Strom (Funde mit Adresse).
  Stream<FoundTv> discover();

  /// Name eines verschwundenen Dienstes.
  Stream<String> get lost;
  Future<void> stopDiscover();

  /// Lautstärke am Fernseher (+1/−1/0 = stumm umschalten). false = geht nicht.
  Future<bool> volume(int dir);

  /// Kann die App die Lautstärke regeln (nicht fest vorgegeben)?
  Future<bool> volumeControllable();

  static RemoteDiscovery platform() =>
      (!kIsWeb && defaultTargetPlatform == TargetPlatform.android)
          ? ChannelDiscovery()
          : const NoDiscovery();
}

/// Plattform ohne NSD (Web/Desktop-Vorschau).
class NoDiscovery implements RemoteDiscovery {
  const NoDiscovery();
  @override
  Future<String?> register(
          {required String name,
          required int port,
          required Map<String, String> attrs}) async =>
      null;
  @override
  Future<void> unregister() async {}
  @override
  Stream<FoundTv> discover() => const Stream.empty();
  @override
  Stream<String> get lost => const Stream.empty();
  @override
  Future<void> stopDiscover() async {}
  @override
  Future<bool> volume(int dir) async => false;
  @override
  Future<bool> volumeControllable() async => false;
}

class ChannelDiscovery implements RemoteDiscovery {
  static const _m = MethodChannel('de.jasonstream/remote');
  static const _e = EventChannel('de.jasonstream/remote/events');

  StreamSubscription<dynamic>? _sub;
  final _found = StreamController<FoundTv>.broadcast();
  final _lost = StreamController<String>.broadcast();

  @override
  Future<String?> register(
      {required String name,
      required int port,
      required Map<String, String> attrs}) async {
    try {
      return await _m.invokeMethod<String>(
          'register', {'name': name, 'port': port, 'attrs': attrs});
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<void> unregister() async {
    try {
      await _m.invokeMethod<void>('unregister');
    } catch (_) {}
  }

  @override
  Stream<FoundTv> discover() {
    _sub ??= _e.receiveBroadcastStream().listen((e) {
      if (e is! Map) return;
      switch (e['type']) {
        case 'found':
          final host = e['host'], port = e['port'], name = e['name'];
          if (host is! String || port is! int || name is! String) return;
          final attrs = e['attrs'] is Map ? e['attrs'] as Map : const {};
          final id = attrs['id'];
          _found.add(FoundTv(
              name: name,
              host: host,
              port: port,
              id: id is String ? id : null,
              version: int.tryParse('${attrs['v'] ?? ''}') ?? 0));
        case 'lost':
          final name = e['name'];
          if (name is String) _lost.add(name);
      }
    }, onError: (Object _) {});
    _m.invokeMethod<bool>('discover').catchError((Object _) => false);
    return _found.stream;
  }

  @override
  Stream<String> get lost => _lost.stream;

  @override
  Future<void> stopDiscover() async {
    try {
      await _m.invokeMethod<void>('stopDiscover');
    } catch (_) {}
    await _sub?.cancel();
    _sub = null;
  }

  @override
  Future<bool> volume(int dir) async {
    try {
      return await _m.invokeMethod<bool>('volume', {'dir': dir}) ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> volumeControllable() async {
    try {
      final m = await _m.invokeMapMethod<String, Object?>('volumeInfo');
      return m?['controllable'] == true;
    } catch (_) {
      return false;
    }
  }
}
