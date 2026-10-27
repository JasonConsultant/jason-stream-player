import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/remote/net.dart';
import '../core/remote/nsd.dart';
import '../core/remote/peers.dart';
import '../core/remote/transport.dart';
import '../core/updater.dart';
import 'providers.dart';

/// Handy als Fernbedienung (ab 2.4) – gemeinsame Zustände.

/// Ankündigen/Suchen per NSD und Lautstärke (Tests ersetzen das).
final remoteDiscoveryProvider =
    Provider<RemoteDiscovery>((_) => RemoteDiscovery.platform());

typedef RemoteServerStarter = Future<RemoteServerHandle> Function(
    RemoteTvHost host);

/// Server am Fernseher starten (Tests: Loopback).
final remoteServerStarterProvider =
    Provider<RemoteServerStarter>((_) => (h) => startRemoteServer(h));

typedef RemoteConnector = Future<RemoteConnection> Function(
    String host, int port);

/// Verbindung zum Fernseher aufbauen (Tests: Loopback).
final remoteConnectorProvider =
    Provider<RemoteConnector>((_) => (h, p) => connectRemote(h, p));

/// Name dieses Geräts (Anzeige auf der Gegenseite).
final remoteDeviceNameProvider = FutureProvider<String>((_) async {
  final m = await Updater.deviceModel();
  return m.trim().isEmpty ? 'Android' : m.trim();
});

// ------------------------------------------------------------------ TV

/// Einstellung „Handy als Fernbedienung“ (Fernseher, Standard an).
class RemoteEnabledNotifier extends Notifier<bool> {
  static const optionKey = 'remote_enabled';

  @override
  bool build() =>
      ref.watch(storageProvider).value?.flag(optionKey, fallback: true) ??
      true;

  Future<void> set(bool on) async {
    final st = await ref.read(storageProvider.future);
    await st.setFlag(optionKey, on);
    state = on;
  }
}

final remoteEnabledProvider =
    NotifierProvider<RemoteEnabledNotifier, bool>(RemoteEnabledNotifier.new);

/// Laufende Kopplung: Code für die Anzeige am Fernseher.
class PairPrompt {
  final String code;
  final String phoneName;
  const PairPrompt(this.code, this.phoneName);
}

class PairPromptNotifier extends Notifier<PairPrompt?> {
  @override
  PairPrompt? build() => null;
  void show(PairPrompt p) => state = p;
  void hide() => state = null;
}

final remotePairPromptProvider =
    NotifierProvider<PairPromptNotifier, PairPrompt?>(PairPromptNotifier.new);

/// Zustand des Dienstes am Fernseher (Einstellungen).
class RemoteServerInfo {
  final bool running;
  final String? address;
  final int clients;

  /// `network` = kein privates WLAN/LAN gefunden.
  final String? error;
  const RemoteServerInfo(
      {this.running = false, this.address, this.clients = 0, this.error});
}

class RemoteServerInfoNotifier extends Notifier<RemoteServerInfo> {
  @override
  RemoteServerInfo build() => const RemoteServerInfo();
  void set(RemoteServerInfo i) => state = i;
}

final remoteServerInfoProvider =
    NotifierProvider<RemoteServerInfoNotifier, RemoteServerInfo>(
        RemoteServerInfoNotifier.new);

/// Gekoppelte Geräte – am Fernseher die Handys ([tv] = true), am Handy die
/// Fernseher.
class RemotePeersNotifier extends Notifier<List<RemotePeer>> {
  RemotePeersNotifier(this.tv);
  final bool tv;

  @override
  List<RemotePeer> build() =>
      ref.watch(storageProvider).value?.remotePeers(tv: tv) ?? const [];

  Future<void> _save(List<RemotePeer> list) async {
    final st = await ref.read(storageProvider.future);
    await st.setRemotePeers(list, tv: tv);
    state = list;
  }

  /// Neu gekoppelt (ersetzt einen alten Eintrag desselben Geräts).
  Future<void> add(RemotePeer p) =>
      _save([p, ...state.where((x) => x.id != p.id)]);

  Future<void> remove(String id) =>
      _save(state.where((x) => x.id != id).toList());

  /// Zuletzt verbunden / neue Adresse merken (selten schreiben).
  Future<void> touch(String id, {String? host, int? port, String? name}) async {
    final i = state.indexWhere((x) => x.id == id);
    if (i < 0) return;
    final cur = state[i];
    final now = DateTime.now();
    final changed = (host != null && host != cur.host) ||
        (port != null && port != cur.port) ||
        (name != null && name != cur.name) ||
        cur.lastSeen == null ||
        now.difference(cur.lastSeen!) > const Duration(hours: 6);
    if (!changed) return;
    final list = [...state];
    list[i] = cur.copyWith(host: host, port: port, name: name, lastSeen: now);
    await _save(list);
  }
}

final remotePhonesProvider =
    NotifierProvider<RemotePeersNotifier, List<RemotePeer>>(
        () => RemotePeersNotifier(true));

final remoteTvsProvider =
    NotifierProvider<RemotePeersNotifier, List<RemotePeer>>(
        () => RemotePeersNotifier(false));
