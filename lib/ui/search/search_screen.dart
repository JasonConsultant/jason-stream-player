import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../models/models.dart';
import '../../state/providers.dart';
import '../nav.dart';
import '../vod/vod_screen.dart' show PosterCard;
import '../widgets/artwork.dart';
import '../widgets/common.dart';
import '../widgets/focusable_tile.dart';

/// Eine Suche für alles: Sender, Sendungen im EPG (jetzt, demnächst und im
/// Archiv), Filme und Serien.
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

typedef _Show = ({Channel channel, EpgEntry entry});

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _ctrl = TextEditingController();
  Timer? _debounce;
  String _q = '';

  // Kleinbuchstaben einmal berechnen statt bei jeder Eingabe.
  final _lower = Expando<String>();
  String _l(Object o, String s) => _lower[o] ??= s.toLowerCase();

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  void _onChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 220),
        () => setState(() => _q = v.trim().toLowerCase()));
  }

  @override
  Widget build(BuildContext context) {
    final live = ref.watch(liveDataProvider).value;
    final epg = ref.watch(epgProvider).value ?? const {};
    final movies = ref.watch(moviesProvider).value?.items ?? const [];
    final series = ref.watch(seriesProvider).value?.items ?? const [];
    final flags = ref.watch(channelFlagsProvider).value ?? ChannelFlags.empty;
    final narrow = MediaQuery.sizeOf(context).width < 600;
    final pad = EdgeInsets.symmetric(horizontal: narrow ? 16 : 28);

    final channels = <Channel>[];
    final shows = <_Show>[];
    final films = <VodItem>[];
    final shows2 = <VodItem>[];
    if (_q.length >= 2 && live != null) {
      final visible =
          live.channels.where((c) => !flags.isHidden(c.id)).toList();
      for (final c in visible) {
        if (_l(c, c.name).contains(_q)) channels.add(c);
        if (channels.length >= 40) break;
      }
      final now = DateTime.now();
      final from = now.subtract(const Duration(days: 7));
      final to = now.add(const Duration(days: 2));
      final byEpg = <String, Channel>{
        for (final c in visible)
          epgKeyOf(c): c,
      };
      for (final e in epg.entries) {
        final c = byEpg[e.key];
        if (c == null) continue;
        for (final p in e.value) {
          if (p.end.isBefore(from) || p.start.isAfter(to)) continue;
          // Vergangenes nur, wenn es im Archiv liegt.
          if (p.isPastAt(now) && !c.hasCatchup) continue;
          if (_l(p, p.title).contains(_q)) shows.add((channel: c, entry: p));
        }
      }
      // Läuft gerade → demnächst → vergangen (neueste zuerst)
      int rank(EpgEntry e) => e.isNowAt(now) ? 0 : e.start.isAfter(now) ? 1 : 2;
      shows.sort((a, b) {
        final r = rank(a.entry).compareTo(rank(b.entry));
        if (r != 0) return r;
        return rank(a.entry) == 2
            ? b.entry.start.compareTo(a.entry.start)
            : a.entry.start.compareTo(b.entry.start);
      });
      if (shows.length > 60) shows.removeRange(60, shows.length);
      films.addAll(movies.where((m) => _l(m, m.name).contains(_q)).take(30));
      shows2.addAll(series.where((m) => _l(m, m.name).contains(_q)).take(30));
    }

    final empty = _q.length >= 2 &&
        channels.isEmpty && shows.isEmpty && films.isEmpty && shows2.isEmpty;

    return ListView(
      padding: const EdgeInsets.only(bottom: 40),
      children: [
        PageHeader(tr('Suche')),
        Padding(
          padding: pad,
          child: SearchField(
            controller: _ctrl,
            hint: tr('Sender, Sendung, Film oder Serie …'),
            width: double.infinity,
            onChanged: _onChanged,
          ),
        ),
        if (_q.length < 2)
          Padding(
            padding: const EdgeInsets.only(top: 60),
            child: EmptyState(
              icon: Icons.manage_search_rounded,
              title: tr('Wonach suchst du?'),
              message: tr('Mindestens 2 Buchstaben – z. B. „Tatort“, „Bundesliga“ '
                  'oder einen Sendernamen.'),
            ),
          ),
        if (empty)
          Padding(
            padding: const EdgeInsets.only(top: 60),
            child: EmptyState(
                icon: Icons.search_off_rounded, title: tr('Nichts gefunden')),
          ),
        if (channels.isNotEmpty) ...[
          _Heading(tr('Sender'), channels.length, pad),
          SizedBox(
            height: 112,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: pad,
              itemCount: channels.length,
              separatorBuilder: (_, __) => const SizedBox(width: 10),
              itemBuilder: (_, i) {
                final c = channels[i];
                return SizedBox(
                  width: 130,
                  child: FocusableTile(
                    onTap: () => playChannel(context, ref, c, live!.channels),
                    child: Padding(
                      padding: const EdgeInsets.all(10),
                      child: Column(children: [
                        ChannelLogo(name: c.name, url: c.logoUrl, size: 44),
                        const SizedBox(height: 8),
                        Text(c.name,
                            maxLines: 2,
                            textAlign: TextAlign.center,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                                color: AppColors.text)),
                      ]),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
        if (shows.isNotEmpty) ...[
          _Heading(tr('Sendungen'), shows.length, pad),
          for (final s in shows)
            Padding(
              padding: pad.copyWith(bottom: 4),
              child: _ShowTile(
                show: s,
                onTap: () {
                  final now = DateTime.now();
                  if (s.entry.isPastAt(now)) {
                    playCatchup(context, ref, s.channel, s.entry,
                        channels: live!.channels);
                  } else {
                    playChannel(context, ref, s.channel, live!.channels);
                  }
                },
              ),
            ),
        ],
        for (final (title, list) in [(tr('Filme'), films), (tr('Serien'), shows2)])
          if (list.isNotEmpty) ...[
            _Heading(title, list.length, pad),
            SizedBox(
              height: (narrow ? 118 : 150) / 0.52,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: pad,
                itemCount: list.length,
                separatorBuilder: (_, __) => const SizedBox(width: 14),
                itemBuilder: (_, i) => SizedBox(
                    width: narrow ? 118 : 150,
                    child: PosterCard(item: list[i])),
              ),
            ),
          ],
      ],
    );
  }
}

class _Heading extends StatelessWidget {
  final String title;
  final int count;
  final EdgeInsets pad;
  const _Heading(this.title, this.count, this.pad);

  @override
  Widget build(BuildContext context) => Padding(
        padding: pad.copyWith(top: 24, bottom: 10),
        child: Row(children: [
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(width: 8),
          Text('$count', style: Theme.of(context).textTheme.bodySmall),
        ]),
      );
}

class _ShowTile extends StatelessWidget {
  final _Show show;
  final VoidCallback onTap;
  const _ShowTile({required this.show, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final e = show.entry;
    final now = DateTime.now();
    final (tag, color) = e.isNowAt(now)
        ? (tr('LÄUFT'), AppColors.live)
        : e.isPastAt(now)
            ? (tr('REPLAY'), AppColors.catchup)
            : (tr('DEMNÄCHST'), AppColors.textDim);
    final day = DateUtils.isSameDay(e.start, now)
        ? tr('Heute')
        : DateUtils.isSameDay(e.start, now.add(const Duration(days: 1)))
            ? tr('Morgen')
            : DateUtils.isSameDay(e.start, now.subtract(const Duration(days: 1)))
                ? tr('Gestern')
                : '${e.start.day}.${e.start.month}.';
    return FocusableTile(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        child: Row(children: [
          ChannelLogo(name: show.channel.name, url: show.channel.logoUrl, size: 34),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(e.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 2),
              Text('${show.channel.name} · $day ${hm.format(e.start)}–${hm.format(e.end)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall),
            ]),
          ),
          Tag(tag, color: color, filled: color != AppColors.textDim),
        ]),
      ),
    );
  }
}
