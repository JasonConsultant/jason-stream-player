import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/vod_meta.dart' show nextEpisodeOf;
import '../models/models.dart';
import '../state/profile_mode.dart';
import '../state/providers.dart';
import '../state/vod_library.dart';
import 'live/parental.dart';
import 'player/player_screen.dart';
import 'vod/movie_detail_screen.dart';
import 'vod/series_detail_screen.dart';
import '../l10n/strings.dart';

PageRoute<T> _fade<T>(Widget page) => PageRouteBuilder<T>(
      transitionDuration: const Duration(milliseconds: 220),
      reverseTransitionDuration: const Duration(milliseconds: 160),
      pageBuilder: (_, __, ___) => page,
      transitionsBuilder: (_, a, __, child) =>
          FadeTransition(opacity: a, child: child),
    );

Future<void> openPlayer(BuildContext context, PlayRequest req) =>
    Navigator.of(context).push(_fade(PlayerScreen(request: req)));

void openVodItem(BuildContext context, VodItem item) {
  Navigator.of(context).push(_fade(item.isSeries
      ? SeriesDetailScreen(series: item)
      : MovieDetailScreen(movie: item)));
}

/// Live-Sender abspielen (mit PIN-Abfrage bei gesperrten Sendern).
Future<void> playChannel(BuildContext context, WidgetRef ref, Channel c,
    List<Channel> list) async {
  final flags = ref.read(channelFlagsProvider).value ?? ChannelFlags.empty;
  if (flags.locked.contains(c.id) && !await askPin(context, ref)) return;
  if (!context.mounted) return;
  await openPlayer(
    context,
    PlayRequest(
      title: c.name,
      url: c.streamUrl,
      isLive: true,
      channels: list,
      channel: c,
      artworkSeed: c.name,
    ),
  );
}

/// Sendung als Replay abspielen (Catch-up) – vergangen oder die laufende
/// Sendung von Anfang an. [channels] erlaubt im Player den Sprung zu Live.
Future<void> playCatchup(
    BuildContext context, WidgetRef ref, Channel c, EpgEntry e,
    {List<Channel>? channels}) async {
  final req = await replayRequest(ref, c, e, channels: channels);
  if (!context.mounted) return;
  if (req == null) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(tr('Für diesen Sender gibt es kein Replay.'))));
    return;
  }
  final flags = ref.read(channelFlagsProvider).value ?? ChannelFlags.empty;
  if (flags.locked.contains(c.id) && !await askPin(context, ref)) return;
  if (!context.mounted) return;
  await openPlayer(context, req);
}

/// Baut die Replay-Anfrage oder null, wenn der Sender kein Archiv hat.
Future<PlayRequest?> replayRequest(WidgetRef ref, Channel c, EpgEntry e,
    {List<Channel>? channels}) async {
  final repo = await ref.read(repositoryProvider.future);
  final url = repo?.catchupUrl(c, e);
  if (url == null) return null;
  final all = channels ?? (await readVisibleLive(ref)).channels;
  return PlayRequest(
    title: e.title,
    subtitle: c.name,
    url: url,
    channel: c,
    channels: all,
    replayEntry: e,
    resumeKey: 'cu_${c.id}_${e.start.millisecondsSinceEpoch}',
    artworkSeed: e.title,
  );
}

Future<void> playMovie(BuildContext context, WidgetRef ref, VodItem m) {
  ref.read(vodLibraryProvider.notifier).watchedMovie(m);
  return openPlayer(
      context,
      PlayRequest(
        title: m.name,
        subtitle: [if (m.year != null) '${m.year}', if (m.genre != null) m.genre!]
            .join(' · '),
        url: m.streamUrl,
        resumeKey: 'movie_${m.id}',
        artworkSeed: m.name,
        artworkUrl: m.backdropUrl ?? m.posterUrl,
      ),
    );
}

Future<void> playEpisode(
    BuildContext context, WidgetRef ref, VodItem s, Episode e) {
  ref.read(vodLibraryProvider.notifier).watchedEpisode(s, e);
  final container = ProviderScope.containerOf(context, listen: false);
  return openPlayer(context, episodeRequest(container, s, e));
}

/// Abspiel-Anfrage einer Folge – mit „Nächste Folge“ (auch über das
/// Staffelende hinweg), die wiederum ihre nächste Folge kennt.
PlayRequest episodeRequest(ProviderContainer container, VodItem s, Episode e) =>
    PlayRequest(
      title: s.name,
      subtitle: trf('S{0} · F{1} – {2}', [e.season, e.number, e.title]),
      url: e.streamUrl,
      resumeKey: 'ep_${e.id}',
      artworkSeed: s.name,
      artworkUrl: e.stillUrl ?? s.backdropUrl ?? s.posterUrl,
      nextUp: () async {
        final d = await container.read(seriesDetailsProvider(s).future);
        final n = nextEpisodeOf(d.seasons, e);
        if (n == null) {
          // Letzte Folge zu Ende → Serie gilt als gesehen.
          await container.read(storageProvider).value?.setWatched('series_${s.id}');
          return null;
        }
        return NextUp(
          label: trf('S{0} · F{1} – {2}', [n.season, n.number, n.title]),
          request: episodeRequest(container, s, n),
          onStart: () =>
              container.read(vodLibraryProvider.notifier).watchedEpisode(s, n),
        );
      },
    );
