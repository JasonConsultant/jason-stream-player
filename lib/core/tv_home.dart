import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/strings.dart';
import '../models/models.dart';
import '../state/providers.dart';
import 'platform_info.dart';

/// Eine Kachel in der Favoriten-Zeile des Android-TV-Startbildschirms.
class TvHomeItem {
  final String channelId;
  final String name;
  final String? logoUrl;

  /// Titel der gerade laufenden Sendung; leer, wenn kein EPG vorliegt.
  final String title;
  final String portal;

  const TvHomeItem({
    required this.channelId,
    required this.name,
    required this.title,
    this.logoUrl,
    this.portal = '',
  });

  Map<String, Object?> toMap() => {
        'channelId': channelId,
        'name': name,
        'logoUrl': logoUrl,
        'title': title,
        'portal': portal,
      };
}

/// Höchstzahl an Kacheln in der Zeile (der Launcher zeigt ohnehin nur
/// wenige Dutzend sinnvoll an).
const tvHomeMaxItems = 30;

/// Favoriten in Senderlisten-Reihenfolge (wie auf der Startseite), versteckte
/// Sender ausgelassen, höchstens [max] Einträge; Sendungstitel aus dem EPG
/// zu [now] (Standard: jetzt), sonst leer.
List<TvHomeItem> buildTvHomeItems({
  required List<Channel> channels,
  required ChannelFlags flags,
  required Map<String, List<EpgEntry>> epg,
  String portal = '',
  DateTime? now,
  int max = tvHomeMaxItems,
}) {
  final out = <TvHomeItem>[];
  for (final c in channels) {
    if (!flags.favorites.contains(c.id) || flags.isHidden(c.id)) continue;
    final e = nowPlaying(epg, c, now);
    out.add(TvHomeItem(
      channelId: c.id,
      name: c.name,
      logoUrl: (c.logoUrl ?? '').isEmpty ? null : c.logoUrl,
      title: e?.title.trim() ?? '',
      portal: portal,
    ));
    if (out.length >= max) break;
  }
  return out;
}

/// Android TV: Favoriten-Zeile („Jason Stream Player – Favoriten“) auf dem
/// Startbildschirm pflegen. Auf anderen Geräten No-op.
class TvHome {
  static const _channel = MethodChannel('de.jasonstream.player/platform');
  static const flagKey = 'tvhome';

  /// Kanal mit den aktuellen Favoriten + „läuft gerade“ befüllen.
  /// Liefert false, wenn nichts geschrieben wurde (kein TV, Einstellung aus,
  /// kein Portal).
  static Future<bool> sync(WidgetRef ref) async {
    if (!PlatformInfo.isAndroid || !await PlatformInfo.isTv()) return false;
    try {
      final storage = await ref.read(storageProvider.future);
      if (!storage.flag(flagKey, fallback: true)) return false;
      final portal = await ref.read(activePortalProvider.future);
      if (portal == null) return false;
      final live = await ref.read(liveDataProvider.future);
      final flags = await ref.read(channelFlagsProvider.future);
      final epg = ref.read(epgProvider).value ?? const {};
      final items = buildTvHomeItems(
        channels: live.channels,
        flags: flags,
        epg: epg,
        portal: portal.id,
      );
      return await _channel.invokeMethod<bool>('tvSync', {
            'name': tr('Favoriten'),
            'items': [for (final i in items) i.toMap()],
          }) ??
          false;
    } on Object {
      return false;
    }
  }

  /// Kanal vom Startbildschirm entfernen (Einstellung ausgeschaltet).
  static Future<void> clear() async {
    if (!PlatformInfo.isAndroid) return;
    try {
      await _channel.invokeMethod('tvClear');
    } on Object {
      // ignorieren
    }
  }
}
