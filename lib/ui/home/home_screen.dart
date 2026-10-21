import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/theme.dart';
import '../../data/storage.dart';
import '../../l10n/strings.dart';
import '../../models/models.dart';
import '../../state/channel_variants.dart' show variantIndexProvider;
import '../../state/my_groups.dart';
import '../../state/providers.dart';
import '../../state/vod_library.dart';
import '../live/channel_sheet.dart';
import '../settings/adult_lock_info.dart';
import '../../state/content_filter.dart' show kAdultAutoLockFeature;
import '../nav.dart';
import '../tv/tv_focus.dart';
import '../tv/tv_widgets.dart';
import '../vod/vod_screen.dart' show PosterCard, vodProgress, vodBadge;
import '../widgets/artwork.dart';
import '../widgets/common.dart';
import '../widgets/focusable_tile.dart';
import '../widgets/voice_search.dart';
import '../../state/profile_mode.dart';

/// Startseite: alles Wichtige auf einen Blick – zuletzt gesehene Sender,
/// Favoriten, Weiterschauen bei Filmen/Serien und große Kacheln zu allen
/// Bereichen.
class HomeScreen extends ConsumerWidget {
  /// Wechselt in der Hauptnavigation zu Tab [i] (1 = Live TV …).
  final ValueChanged<int> onOpenTab;
  const HomeScreen({super.key, required this.onOpenTab});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final narrow = MediaQuery.sizeOf(context).width < 600;
    final pad = EdgeInsets.symmetric(horizontal: narrow ? 16 : 28);
    final live = ref.watch(visibleLiveDataProvider).value;
    final epg = ref.watch(epgProvider).value ?? const {};
    final flags = ref.watch(channelFlagsProvider).value ?? ChannelFlags.empty;
    final recents = ref.watch(recentProvider).value ?? const <String>[];
    final myGroups = ref.watch(visibleMyGroupsProvider);
    final lib = ref.watch(vodLibraryProvider).value ?? VodLibrary.empty;
    final movies = ref.watch(visibleMoviesProvider).value?.items ?? const <VodItem>[];
    final series = ref.watch(visibleSeriesProvider).value?.items ?? const <VodItem>[];
    final storage = ref.watch(storageProvider).value;
    ref.watch(minuteTickProvider);
    // Einmaliger Hinweis: Erwachseneninhalte gesperrt, noch keine PIN.
    if (kAdultAutoLockFeature) listenAdultLockInfo(context, ref);

    final channels = live?.channels ?? const <Channel>[];
    final byId = {for (final c in channels) c.id: c};
    // IDs verdeckter Sender-Varianten zählen als ihr sichtbarer Vertreter.
    final recentCh = [
      for (final c in ref.watch(variantIndexProvider).resolve(recents, byId))
        if (!flags.isHidden(c.id)) c,
    ];
    final favCh = channels
        .where((c) => flags.favorites.contains(c.id) && !flags.isHidden(c.id))
        .toList();

    final vodById = {
      for (final m in movies) 'm:${m.id}': m,
      for (final s in series) 's:${s.id}': s,
    };
    final continueVod = <VodItem>[
      for (final h in lib.history)
        if (vodById['${h.series ? 's' : 'm'}:${h.id}'] != null)
          vodById['${h.series ? 's' : 'm'}:${h.id}']!,
    ];

    final now = DateTime.now();
    final greeting = now.hour < 11
        ? tr('Guten Morgen')
        : now.hour < 18
            ? tr('Guten Tag')
            : tr('Guten Abend');
    final date = DateFormat('EEEE, d. MMMM', L10n.lang).format(now);
    final t = Theme.of(context).textTheme;

    /// Sprachsuche: Ergebnis im Such-Tab anzeigen.
    void openSearch(String q) {
      ref.read(searchRequestProvider.notifier).request(q);
      onOpenTab(5);
    }

    if (ref.watch(isTvProvider)) {
      return _TvHome(
        onOpenTab: onOpenTab,
        onVoice: openSearch,
        greeting: greeting,
        dateLine: '$date · ${hm.format(now)}',
        channels: channels,
        recentCh: recentCh,
        favCh: favCh,
        continueVod: continueVod,
        myGroups: myGroups,
        epg: epg,
        lib: lib,
        storage: storage,
        movieCount: movies.length,
        seriesCount: series.length,
      );
    }

    return ListView(
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        PageHeader(greeting,
            trailing: narrow
                ? null
                : Text('$date · ${hm.format(now)}',
                    style: t.titleMedium?.copyWith(color: AppColors.textDim))),
        if (narrow)
          Padding(
            padding: pad.copyWith(bottom: 12),
            child: Text('$date · ${hm.format(now)}',
                style: t.bodyMedium?.copyWith(color: AppColors.textDim)),
          ),
        // Suche – öffnet den Such-Tab
        Padding(
          padding: pad,
          child: Row(children: [
            Expanded(
              child: FocusableTile(
                onTap: () => onOpenTab(5),
                radius: BorderRadius.circular(14),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Row(children: [
                    const Icon(Icons.search_rounded, color: AppColors.textDim),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                          tr('Sender, Sendung, Film oder Serie suchen …'),
                          style: const TextStyle(color: AppColors.textFaint)),
                    ),
                  ]),
                ),
              ),
            ),
            VoiceSearchButton(size: 48, iconSize: 22, onResult: openSearch),
          ]),
        ),
        const SizedBox(height: 16),
        // Große Kacheln
        Padding(
          padding: pad,
          child: LayoutBuilder(builder: (context, box) {
            final cols = box.maxWidth > 900 ? 4 : 2;
            final tiles = [
              _Tile(
                  icon: Icons.live_tv_rounded,
                  label: tr('Live TV'),
                  info: trf('{0} Sender', [channels.length]),
                  color: AppColors.accent,
                  autofocus: true,
                  onTap: () => onOpenTab(1)),
              _Tile(
                  icon: Icons.view_timeline_rounded,
                  label: tr('TV-Guide'),
                  info: tr('Was läuft jetzt?'),
                  color: AppColors.catchup,
                  onTap: () => onOpenTab(2)),
              _Tile(
                  icon: Icons.movie_rounded,
                  label: tr('Filme'),
                  info: movies.isEmpty ? '' : trf('{0} Filme', [movies.length]),
                  color: const Color(0xFF7C8CFF),
                  onTap: () => onOpenTab(3)),
              _Tile(
                  icon: Icons.video_library_rounded,
                  label: tr('Serien'),
                  info:
                      series.isEmpty ? '' : trf('{0} Serien', [series.length]),
                  color: const Color(0xFFFF6B8B),
                  onTap: () => onOpenTab(4)),
            ];
            return GridView.count(
              crossAxisCount: cols,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: narrow ? 1.7 : 2.2,
              children: tiles,
            );
          }),
        ),
        if (recentCh.isNotEmpty) ...[
          _Heading(tr('Zuletzt gesehen'), pad),
          _ChannelRow(
              channels: recentCh.take(15).toList(),
              all: channels,
              epg: epg,
              pad: pad,
              recent: true),
        ],
        if (favCh.isNotEmpty) ...[
          _Heading(tr('Favoriten'), pad),
          _ChannelRow(channels: favCh, all: channels, epg: epg, pad: pad),
        ],
        if (continueVod.isNotEmpty) ...[
          _Heading(tr('Weiterschauen'), pad),
          SizedBox(
            height: (narrow ? 110 : 140) / 0.52,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: pad,
              itemCount: continueVod.length.clamp(0, 15),
              separatorBuilder: (_, __) => const SizedBox(width: 12),
              itemBuilder: (_, i) => SizedBox(
                width: narrow ? 110 : 140,
                child: PosterCard(
                  item: continueVod[i],
                  progress: vodProgress(storage, continueVod[i], lib),
                  badge: vodBadge(lib, continueVod[i]),
                ),
              ),
            ),
          ),
        ],
        if (myGroups.isNotEmpty) ...[
          _Heading(tr('Meine Gruppen'), pad),
          Padding(
            padding: pad,
            child: Wrap(spacing: 8, runSpacing: 8, children: [
              for (final g in myGroups)
                ActionChip(
                  avatar: const Icon(Icons.folder_special_rounded,
                      size: 18, color: AppColors.accent),
                  label: Text('${g.name} · ${g.channels.length}'),
                  onPressed: () => onOpenTab(1),
                ),
            ]),
          ),
        ],
        if (recentCh.isEmpty && favCh.isEmpty && continueVod.isEmpty)
          Padding(
            padding: pad.copyWith(top: 28),
            child: Text(
              tr('Tipp: Sender lange drücken → Favorit oder eigene Gruppe. '
                  'Zuletzt Gesehenes erscheint dann hier.'),
              style: t.bodySmall,
            ),
          ),
      ],
    );
  }
}

class _Heading extends StatelessWidget {
  final String text;
  final EdgeInsets pad;
  const _Heading(this.text, this.pad);

  @override
  Widget build(BuildContext context) => Padding(
        padding: pad.copyWith(top: 26, bottom: 10),
        child: Text(text, style: Theme.of(context).textTheme.titleLarge),
      );
}

class _Tile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String info;
  final Color color;
  final bool autofocus;
  final VoidCallback onTap;
  const _Tile({
    required this.icon,
    required this.label,
    required this.info,
    required this.color,
    required this.onTap,
    this.autofocus = false,
  });

  @override
  Widget build(BuildContext context) => FocusableTile(
        autofocus: autofocus,
        scaleOnFocus: true,
        onTap: onTap,
        radius: BorderRadius.circular(18),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                color.withValues(alpha: 0.28),
                color.withValues(alpha: 0.08)
              ],
            ),
            border: Border.all(color: color.withValues(alpha: 0.35)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Icon(icon, color: color, size: 30),
              // Schmale Handys (≤ 360 dp): Text verkleinern statt überlaufen.
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.bottomLeft,
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(label,
                            style: const TextStyle(
                                fontFamily: 'InterDisplay',
                                fontSize: 18,
                                fontWeight: FontWeight.w800,
                                color: AppColors.text)),
                        if (info.isNotEmpty)
                          Text(info,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 12.5, color: AppColors.textDim)),
                      ]),
                ),
              ),
            ],
          ),
        ),
      );
}

class _ChannelRow extends ConsumerWidget {
  final List<Channel> channels;
  final List<Channel> all;
  final Map<String, List<EpgEntry>> epg;
  final EdgeInsets pad;
  final bool recent;
  const _ChannelRow(
      {required this.channels,
      required this.all,
      required this.epg,
      required this.pad,
      this.recent = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final narrow = MediaQuery.sizeOf(context).width < 600;
    final w = narrow ? 150.0 : 190.0;
    return SizedBox(
      height: 132,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: pad,
        itemCount: channels.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (_, i) {
          final c = channels[i];
          final now = nowPlaying(epg, c);
          if (epgOf(epg, c).isEmpty) {
            ref.read(epgProvider.notifier).want(c);
          }
          // progressAt fängt Dauer 0 ab (sonst Division durch null → NaN).
          final p = now?.progressAt(DateTime.now());
          return SizedBox(
            width: w,
            child: FocusableTile(
              onTap: () => playChannel(context, ref, c, all),
              onLongPress: () =>
                  showChannelSheet(context, ref, c, inRecent: recent),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      ChannelLogo(name: c.name, url: c.logoUrl, size: 34),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(c.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w700,
                                color: AppColors.text)),
                      ),
                    ]),
                    const Spacer(),
                    Text(now?.title ?? tr('Keine Programminfo'),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12,
                            color: now == null
                                ? AppColors.textFaint
                                : AppColors.textDim)),
                    if (p != null) ...[
                      const SizedBox(height: 6),
                      ThinProgress(value: p, height: 3),
                    ],
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Android TV
// ---------------------------------------------------------------------------

/// TV-Startseite: kleine Begrüßung, vier flache Kacheln, darunter Reihen –
/// auf 960×540 dp möglichst ohne Scrollen.
class _TvHome extends StatelessWidget {
  final ValueChanged<int> onOpenTab;
  final ValueChanged<String> onVoice;
  final String greeting;
  final String dateLine;
  final List<Channel> channels;
  final List<Channel> recentCh;
  final List<Channel> favCh;
  final List<VodItem> continueVod;
  final List<MyGroup> myGroups;
  final Map<String, List<EpgEntry>> epg;
  final VodLibrary lib;
  final Storage? storage;
  final int movieCount;
  final int seriesCount;
  const _TvHome({
    required this.onOpenTab,
    required this.onVoice,
    required this.greeting,
    required this.dateLine,
    required this.channels,
    required this.recentCh,
    required this.favCh,
    required this.continueVod,
    required this.myGroups,
    required this.epg,
    required this.lib,
    required this.storage,
    required this.movieCount,
    required this.seriesCount,
  });

  static const _pad = EdgeInsets.symmetric(horizontal: tvPad);

  @override
  Widget build(BuildContext context) {
    Widget heading(String text) =>
        TvCaps(text, padding: const EdgeInsets.fromLTRB(tvPad, 16, tvPad, 7));
    return ColoredBox(
      color: TvColors.bg,
      child: ListView(
        padding: const EdgeInsets.only(top: 20, bottom: 20),
        children: [
          Padding(
            padding: _pad,
            child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(dateLine.toUpperCase(), style: TvText.caps),
                    const SizedBox(height: 4),
                    Text(greeting, style: TvText.title),
                  ],
                ),
              ),
              FocusableTile(
                onTap: () => onOpenTab(5),
                radius: const BorderRadius.all(Radius.circular(14)),
                child: Container(
                  width: 210,
                  height: 24,
                  padding: const EdgeInsets.symmetric(horizontal: 9),
                  decoration: BoxDecoration(
                    color: TvColors.surface,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(children: [
                    const Icon(Icons.search_rounded,
                        size: 12, color: TvColors.textFaint),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                          tr('Sender, Sendung, Film oder Serie suchen …'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style:
                              TvText.body.copyWith(color: TvColors.textFaint)),
                    ),
                  ]),
                ),
              ),
              const SizedBox(width: 4),
              VoiceSearchButton(size: 24, iconSize: 13, onResult: onVoice),
            ]),
          ),
          const SizedBox(height: 14),
          Padding(
            padding: _pad,
            child: SizedBox(
              height: 70,
              child: Row(children: [
                Expanded(
                  child: _TvTile(
                      icon: Icons.live_tv_rounded,
                      label: tr('Live TV'),
                      info: trf('{0} Sender', [channels.length]),
                      color: AppColors.accent,
                      autofocus: true,
                      onTap: () => onOpenTab(1)),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _TvTile(
                      icon: Icons.view_timeline_rounded,
                      label: tr('TV-Guide'),
                      info: tr('Was läuft jetzt?'),
                      color: AppColors.catchup,
                      onTap: () => onOpenTab(2)),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _TvTile(
                      icon: Icons.movie_rounded,
                      label: tr('Filme'),
                      info:
                          movieCount == 0 ? '' : trf('{0} Filme', [movieCount]),
                      color: const Color(0xFF7C8CFF),
                      onTap: () => onOpenTab(3)),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _TvTile(
                      icon: Icons.video_library_rounded,
                      label: tr('Serien'),
                      info: seriesCount == 0
                          ? ''
                          : trf('{0} Serien', [seriesCount]),
                      color: const Color(0xFFFF6B8B),
                      onTap: () => onOpenTab(4)),
                ),
              ]),
            ),
          ),
          if (recentCh.isNotEmpty) ...[
            heading(tr('Zuletzt gesehen')),
            _TvChannelCards(
                channels: recentCh.take(15).toList(),
                all: channels,
                epg: epg,
                recent: true),
          ],
          if (favCh.isNotEmpty) ...[
            heading(tr('Favoriten')),
            _TvChannelCards(channels: favCh, all: channels, epg: epg),
          ],
          if (continueVod.isNotEmpty) ...[
            heading(tr('Weiterschauen')),
            SizedBox(
              height: 80 * 1.5 + 30,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: _pad,
                itemCount: continueVod.length.clamp(0, 15),
                separatorBuilder: (_, __) => const SizedBox(width: 10),
                itemBuilder: (_, i) => SizedBox(
                  width: 80,
                  child: PosterCard(
                    item: continueVod[i],
                    dense: true,
                    progress: vodProgress(storage, continueVod[i], lib),
                    badge: vodBadge(lib, continueVod[i]),
                  ),
                ),
              ),
            ),
          ],
          if (myGroups.isNotEmpty) ...[
            heading(tr('Meine Gruppen')),
            Padding(
              padding: _pad,
              child: Wrap(spacing: 6, runSpacing: 6, children: [
                for (final g in myGroups)
                  TvChip(
                    icon: Icons.folder_special_rounded,
                    color: TvColors.text,
                    label: '${g.name} · ${g.channels.length}',
                    onTap: () => onOpenTab(1),
                  ),
              ]),
            ),
          ],
          if (recentCh.isEmpty && favCh.isEmpty && continueVod.isEmpty)
            Padding(
              padding: _pad.copyWith(top: 22),
              child: Text(
                tr('Tipp: Sender lange drücken → Favorit oder eigene Gruppe. '
                    'Zuletzt Gesehenes erscheint dann hier.'),
                style: TvText.body,
              ),
            ),
        ],
      ),
    );
  }
}

/// Flache Kachel (70 dp hoch) für die TV-Startseite.
class _TvTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String info;
  final Color color;
  final bool autofocus;
  final VoidCallback onTap;
  const _TvTile({
    required this.icon,
    required this.label,
    required this.info,
    required this.color,
    required this.onTap,
    this.autofocus = false,
  });

  @override
  Widget build(BuildContext context) => FocusableTile(
        autofocus: autofocus,
        onTap: onTap,
        radius: const BorderRadius.all(Radius.circular(12)),
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color.alphaBlend(
                    color.withValues(alpha: 0.13), TvColors.surface),
                TvColors.surface,
              ],
            ),
          ),
          child: Row(children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Icon(icon, color: color, size: 16),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TvText.name.copyWith(
                          fontSize: 11.5, fontWeight: FontWeight.w700)),
                  if (info.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(info,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TvText.body.copyWith(fontSize: 8)),
                  ],
                ],
              ),
            ),
          ]),
        ),
      );
}

/// Waagerechte Reihe kleiner Senderkarten (150×64 dp).
class _TvChannelCards extends ConsumerWidget {
  final List<Channel> channels;
  final List<Channel> all;
  final Map<String, List<EpgEntry>> epg;
  final bool recent;
  const _TvChannelCards(
      {required this.channels,
      required this.all,
      required this.epg,
      this.recent = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SizedBox(
      height: 64,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: tvPad),
        itemCount: channels.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final c = channels[i];
          final now = nowPlaying(epg, c);
          if (epgOf(epg, c).isEmpty) {
            ref.read(epgProvider.notifier).want(c);
          }
          final p = now?.progressAt(DateTime.now());
          return SizedBox(
            width: 150,
            child: TvTile(
              radius: const BorderRadius.all(Radius.circular(10)),
              onTap: () => playChannel(context, ref, c, all),
              onLongPress: () =>
                  showChannelSheet(context, ref, c, inRecent: recent),
              child: Container(
                padding: const EdgeInsets.fromLTRB(8, 7, 8, 8),
                decoration: BoxDecoration(
                  color: TvColors.surface,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      ChannelLogo(name: c.name, url: c.logoUrl, size: 18),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Text(c.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TvText.name.copyWith(fontSize: 9)),
                      ),
                    ]),
                    const Spacer(),
                    Text(now?.title ?? tr('Keine Programminfo'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TvText.body.copyWith(
                            fontSize: 8,
                            color: now == null
                                ? TvColors.textFaint
                                : TvColors.textDim)),
                    const SizedBox(height: 4),
                    TvProgress(value: p ?? 0),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
