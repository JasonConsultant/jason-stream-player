import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/host_failover.dart';
import '../../data/repository.dart';
import '../../models/models.dart';

/// Abspiel-Adresse eines Live-Senders. Xtream/M3U brauchen dafür keinen
/// Login (nur die zuletzt funktionierende Server-Adresse) – der erste
/// Senderstart wartet also nicht auf die Anmeldung, die läuft parallel
/// weiter. MAC-Portale (Stalker) erzeugen die Adresse beim Portal und
/// warten wie bisher.
Future<String> resolveLiveUrl(
  Channel c, {
  required Portal? portal,
  required AsyncValue<IptvRepository?> current,
  required Future<IptvRepository?> Function() repo,
}) async {
  final ready = current.value;
  if (ready != null) return ready.resolveStreamUrl(c);
  if (portal != null &&
      (portal.type == PortalType.xtream || portal.type == PortalType.m3u)) {
    // Anmeldung trotzdem anstoßen (Kontoinfos, Server-Wechsel).
    unawaited(repo().then((_) {}, onError: (_) {}));
    return HostFailover.rewrite(portal, c.streamUrl);
  }
  final r = await repo();
  return r == null ? c.streamUrl : r.resolveStreamUrl(c);
}
