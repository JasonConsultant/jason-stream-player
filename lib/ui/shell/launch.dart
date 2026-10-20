import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform_info.dart';
import '../../models/models.dart';
import '../../state/providers.dart';
import '../live/channel_sheet.dart';
import '../nav.dart';

/// Startparameter für die Web-Vorschau (z. B. ?demo=1&screen=guide).
/// Auf Android/iOS gibt es keine Parameter – dort startet immer „Live TV“.
/// null = kein Parameter → Start-Tab laut Einstellung.
int? initialTabFromLaunch() => switch (PlatformInfo.launchParams['screen']) {
      'home' => 0,
      'live' || 'player' || 'archive' || 'replay' => 1,
      'guide' => 2,
      'movies' || 'movie' || 'vodplayer' => 3,
      'series' || 'seriesdetail' => 4,
      'search' => 5,
      'settings' => 6,
      _ => null,
    };

Future<void> runLaunchAction(BuildContext context, WidgetRef ref) async {
  final screen = PlatformInfo.launchParams['screen'];
  switch (screen) {
    case 'movie':
      final data = await ref.read(moviesProvider.future);
      if (data.items.length > 2 && context.mounted) {
        openVodItem(context, data.items[2]);
      }
    case 'seriesdetail':
      final data = await ref.read(seriesProvider.future);
      if (data.items.isNotEmpty && context.mounted) {
        openVodItem(context, data.items.first);
      }
    case 'vodplayer':
      final data = await ref.read(moviesProvider.future);
      if (data.items.length > 1 && context.mounted) {
        await playMovie(context, ref, data.items[1]);
      }
    case 'archive':
      final live = await ref.read(liveDataProvider.future);
      if (live.channels.isNotEmpty && context.mounted) {
        await showChannelSheet(context, ref, live.channels[0],
            archiveFirst: true);
      }
    case 'replay':
      final live = await ref.read(liveDataProvider.future);
      final epg = await ref.read(epgProvider.future);
      if (live.channels.isEmpty || !context.mounted) return;
      final c = live.channels[0];
      final list = epgOf(epg, c);
      final now = nowPlaying(epg, c);
      final i = now == null ? -1 : list.indexOf(now);
      if (i > 1) {
        await playCatchup(context, ref, c, list[i - 2], channels: live.channels);
      }
    case 'player':
      final live = await ref.read(liveDataProvider.future);
      await ref.read(epgProvider.future);
      if (live.channels.isEmpty || !context.mounted) return;
      final c = live.channels[6];
      openPlayer(
        context,
        PlayRequest(
          title: c.name,
          url: c.streamUrl,
          isLive: true,
          channels: live.channels,
          channel: c,
        ),
      );
  }
}
