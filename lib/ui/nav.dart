import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/vod_meta.dart' show nextEpisodeOf;
import '../models/models.dart';
import '../state/profile_mode.dart';
import '../state/list_refresh.dart' show PlaybackGate;
import '../state/emby.dart' show embyPlaybackFor;
import '../state/downloads.dart';
import '../state/providers.dart';
import '../state/vod_library.dart';
import 'live/parental.dart';
import 'player/player_screen.dart';
import 'shell/reminder_host.dart' show appNavigatorKey;
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

Future<void> openPlayer(BuildContext context, PlayRequest req) {
  // Stilles Listen-Nachladen wartet, bis der Stream läuft.
  PlaybackGate.starting();
  // Vollbild über der ganzen App (nicht im Stapel eines Reiters).
  return Navigator.of(context, rootNavigator: true)
      .push(_fade(PlayerScreen(request: req)));
}

/// Mini-Player angetippt: Vollbild mit derselben Player-Instanz (kein
/// Neustart des Streams).
Future<void> openPlayerAttached(PlayRequest req) async {
  final nav = appNavigatorKey.currentState;
  if (nav == null) return;
  await nav.push(_fade(PlayerScreen(request: req, attach: true)));
}

void openVodItem(BuildContext context, VodItem item) {
  final page = item.isSeries
      ? SeriesDetailScreen(series: item)
      : MovieDetailScreen(movie: item);
  final tv = ProviderScope.containerOf(context, listen: false)
      .read(isTvProvider);
  // Handy/Tablet: Material-Übergang mit vorausschauendem Zurück.
  Navigator.of(context).push(
      tv ? _fade(page) : MaterialPageRoute<void>(builder: (_) => page));
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

Future<void> playMovie(BuildContext context, WidgetRef ref, VodItem m) async {
  ref.read(vodLibraryProvider.notifier).watchedMovie(m);
  final container = ProviderScope.containerOf(context, listen: false);
  // Heruntergeladen → Datei auf dem Gerät (spart Daten, geht offline).
  final off = await _offline(container, m, m.id);
  if (!context.mounted) return;
  if (off != null) {
    return openPlayer(
        context,
        _withOffline(
            PlayRequest(
              title: m.name,
              subtitle: [
                if (m.year != null) '${m.year}',
                if (m.genre != null) m.genre!
              ].join(' · '),
              url: m.streamUrl,
              resumeKey: 'movie_${m.id}',
              artworkSeed: m.name,
              artworkUrl: m.backdropUrl ?? m.posterUrl,
            ),
            off));
  }
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
        // Emby: Adresse beim Öffnen holen, Fortschritt an den Server.
        remote: m.isEmby
            ? embyPlaybackFor(container, m.id, serverPosition: m.serverPosition)
            : null,
      ),
    );
}

Future<void> playEpisode(
    BuildContext context, WidgetRef ref, VodItem s, Episode e) async {
  ref.read(vodLibraryProvider.notifier).watchedEpisode(s, e);
  final container = ProviderScope.containerOf(context, listen: false);
  final off = await _offline(container, s, e.id);
  if (!context.mounted) return;
  return openPlayer(context, episodeRequest(container, s, e, offline: off));
}

/// Fertiger Download mit vorhandener Datei (sonst null → online).
Future<DownloadItem?> _offline(
    ProviderContainer container, VodItem item, String id) async {
  try {
    return await offlineCopy(
        container.read, downloadScopeOf(container.read, item), id);
  } catch (_) {
    return null;
  }
}

/// Anfrage auf die heruntergeladene Datei umstellen (gleicher
/// „Weiterschauen“-Schlüssel, gleiche „Nächste Folge“).
PlayRequest _withOffline(PlayRequest r, DownloadItem d) => PlayRequest(
      title: r.title,
      subtitle: r.subtitle == null || r.subtitle!.isEmpty
          ? tr('Offline')
          : '${r.subtitle} · ${tr('Offline')}',
      url: offlineRequest(d).url,
      resumeKey: r.resumeKey,
      artworkSeed: r.artworkSeed,
      artworkUrl: r.artworkUrl,
      nextUp: r.nextUp,
      remote: offlineRequest(d).remote,
    );

/// Heruntergeladenen Titel abspielen (Downloads-Seite). Folgen: danach
/// die nächste heruntergeladene Folge derselben Serie.
Future<void> openOfflineDownload(
    BuildContext context, WidgetRef ref, DownloadItem d) async {
  if (!await downloadFileExists(d)) {
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
          content: Text(tr('Die Datei ist nicht mehr vorhanden.'))));
    }
    return;
  }
  if (!context.mounted) return;
  final container = ProviderScope.containerOf(context, listen: false);
  PlayRequest req(DownloadItem x) =>
      offlineRequest(x, nextUp: x.isEpisode ? () async {
        final all = container.read(downloadsProvider);
        final next = nextDownloadedEpisode(all, x);
        if (next == null || !await downloadFileExists(next)) return null;
        return NextUp(
          label: trf('S{0} · F{1} – {2}', [next.season, next.episode, next.title]),
          request: req(next),
        );
      } : null);
  await openPlayer(context, req(d));
}

/// Abspiel-Anfrage einer Folge – mit „Nächste Folge“ (auch über das
/// Staffelende hinweg), die wiederum ihre nächste Folge kennt.
/// [offline]: heruntergeladene Datei statt Stream.
PlayRequest episodeRequest(ProviderContainer container, VodItem s, Episode e,
    {DownloadItem? offline}) {
  final r = _episodeRequest(container, s, e);
  return offline == null ? r : _withOffline(r, offline);
}

PlayRequest _episodeRequest(ProviderContainer container, VodItem s, Episode e) =>
    PlayRequest(
      title: s.name,
      subtitle: trf('S{0} · F{1} – {2}', [e.season, e.number, e.title]),
      url: e.streamUrl,
      resumeKey: 'ep_${e.id}',
      artworkSeed: s.name,
      artworkUrl: e.stillUrl ?? s.backdropUrl ?? s.posterUrl,
      remote: s.isEmby
          ? embyPlaybackFor(container, e.id, serverPosition: e.serverPosition)
          : null,
      nextUp: () async {
        final d = await container.read(seriesDetailsProvider(s).future);
        final n = nextEpisodeOf(d.seasons, e);
        if (n == null) {
          // Letzte Folge zu Ende → Serie gilt als gesehen.
          await container.read(storageProvider).value?.setWatched('series_${s.id}');
          return null;
        }
        final off = await _offline(container, s, n.id);
        return NextUp(
          label: trf('S{0} · F{1} – {2}', [n.season, n.number, n.title]),
          request: episodeRequest(container, s, n, offline: off),
          onStart: () =>
              container.read(vodLibraryProvider.notifier).watchedEpisode(s, n),
        );
      },
    );
