/// Google Cast (Android-Framework) und Verbindungsart über Plattformkanäle.
/// Ohne Plugin (Tests, andere Plattformen) bleibt alles still: keine Geräte,
/// Verbindung „unbekannt“.
library;

import 'dart:async';

import 'package:flutter/services.dart';

abstract final class JspCastChannels {
  static const method = MethodChannel('de.jasonstream/cast');
  static const events = EventChannel('de.jasonstream/cast/events');
  static const network = MethodChannel('de.jasonstream/network');
  static const networkEvents = EventChannel('de.jasonstream/network/events');
}

/// Ergebnis von [JspCast.load].
class JspCastLoad {
  final bool ok;
  final int code;
  const JspCastLoad(this.ok, this.code);
}

/// Cast-Fernsteuerung. Ereignisse (`e`): devices, session, status, pos,
/// unavailable.
class JspCast {
  const JspCast();
  static const _m = JspCastChannels.method;

  /// Ereignisse; Tests können sie überschreiben (EventChannel-Nachrichten
  /// laufen im Widget-Test nicht synchron durch).
  Stream<Map<Object?, Object?>> events() => JspCastChannels.events
      .receiveBroadcastStream()
      .where((e) => e is Map)
      .cast<Map<Object?, Object?>>();

  Future<void> _call(String method, [Map<String, Object?>? args]) async {
    try {
      await _m.invokeMethod<void>(method, args);
    } on MissingPluginException {
      // Keine Cast-Unterstützung auf dieser Plattform.
    }
  }

  Future<void> startDiscovery() => _call('startDiscovery');
  Future<void> stopDiscovery() => _call('stopDiscovery');

  Future<bool> connect(String id) async {
    try {
      return await _m.invokeMethod<bool>('connect', {'id': id}) ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<void> disconnect() => _call('disconnect');

  /// Lädt [url] auf dem verbundenen Gerät (Live: ab Live-Kante).
  Future<JspCastLoad> load({
    required String url,
    required String mime,
    required bool live,
    Duration position = Duration.zero,
    String? title,
    String? subtitle,
    String? image,
  }) async {
    try {
      final r = await _m.invokeMapMethod<String, Object?>('load', {
        'url': url,
        'mime': mime,
        'live': live,
        'positionMs': position.inMilliseconds,
        'title': title,
        'subtitle': subtitle,
        'image': image,
      });
      return JspCastLoad(
          r?['ok'] == true, (r?['code'] as num?)?.toInt() ?? -1);
    } on MissingPluginException {
      return const JspCastLoad(false, -1);
    }
  }

  Future<void> play() => _call('play');
  Future<void> pause() => _call('pause');
  Future<void> stop() => _call('stop');
  Future<void> seek(Duration d) => _call('seek', {'ms': d.inMilliseconds});
}

/// Verbindungsart (ConnectivityManager).
class JspNetState {
  final bool connected;
  final bool metered;
  final bool cellular;
  const JspNetState(
      {this.connected = true, this.metered = false, this.cellular = false});

  static const unknown = JspNetState();

  factory JspNetState.fromMap(Map<Object?, Object?> m) => JspNetState(
        connected: m['connected'] != false,
        metered: m['metered'] == true,
        cellular: m['cellular'] == true,
      );

  @override
  bool operator ==(Object other) =>
      other is JspNetState &&
      other.connected == connected &&
      other.metered == metered &&
      other.cellular == cellular;

  @override
  int get hashCode => Object.hash(connected, metered, cellular);
}

class JspNetwork {
  const JspNetwork();

  /// Aktueller Stand und jede Änderung (live).
  Stream<JspNetState> watch() => JspCastChannels.networkEvents
      .receiveBroadcastStream()
      .where((e) => e is Map)
      .map((e) => JspNetState.fromMap(e as Map<Object?, Object?>))
      .handleError((Object _) {}, test: (e) => e is MissingPluginException);

  Future<JspNetState> status() async {
    try {
      final r = await JspCastChannels.network
          .invokeMapMethod<Object?, Object?>('status');
      return r == null ? JspNetState.unknown : JspNetState.fromMap(r);
    } on MissingPluginException {
      return JspNetState.unknown;
    }
  }
}
