import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../state/providers.dart';
import '../nav.dart';
import '../vod/vod_screen.dart' show PosterCard;
import '../widgets/artwork.dart';
import '../widgets/common.dart';
import '../widgets/focusable_tile.dart';
import '../widgets/voice_search.dart';
import 'search_engine.dart';
import '../../state/profile_mode.dart';

/// Eine Suche für alles: Sender, Sendungen im EPG (jetzt, demnächst und im
/// Archiv), Filme und Serien.
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

typedef _Show = SearchShow;

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _ctrl = TextEditingController();
  Timer? _debounce;
  String _q = '';

  // Suchindex (Kleinbuchstaben, Weitersuche in Treffern) – neu, sobald sich
  // Senderliste, EPG, Filme/Serien oder Ausblendungen ändern.
  SearchEngine? _engine;
  List<Object?> _engineFor = const [];

  SearchEngine _engineOf(List<Object?> inputs, SearchEngine Function() make) {
    final same = _engine != null &&
        inputs.length == _engineFor.length &&
        [for (var i = 0; i < inputs.length; i++) identical(inputs[i], _engineFor[i])]
            .every((x) => x);
    if (!same) {
      _engine = make();
      _engineFor = inputs;
    }
    return _engine!;
  }

  @override
  void initState() {
    super.initState();
    // Suchbegriff aus Sprachsuche/Such-Taste übernehmen (Tab neu gebaut).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final q = ref.read(searchRequestProvider.notifier).take();
      if (q != null) _apply(q);
    });
  }

  /// Text ins Feld übernehmen und sofort suchen.
  void _apply(String q) {
    _ctrl.value = TextEditingValue(
        text: q, selection: TextSelection.collapsed(offset: q.length));
    _debounce?.cancel();
    setState(() => _q = q.trim().toLowerCase());
  }

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
    // Tab war schon offen: neuen Suchbegriff direkt übernehmen.
    ref.listen<String?>(searchRequestProvider, (_, q) {
      if (q == null) return;
      ref.read(searchRequestProvider.notifier).take();
      _apply(q);
    });
    final live = ref.watch(visibleLiveDataProvider).value;
    final epg = ref.watch(epgProvider).value ?? const {};
    final movies = ref.watch(visibleMoviesProvider).value?.items ?? const [];
    final series = ref.watch(visibleSeriesProvider).value?.items ?? const [];
    final flags = ref.watch(channelFlagsProvider).value ?? ChannelFlags.empty;
    final narrow = MediaQuery.sizeOf(context).width < 600;
    final pad = EdgeInsets.symmetric(horizontal: narrow ? 16 : 28);

    var res = SearchResults.empty;
    if (_q.length >= 2 && live != null) {
      final engine = _engineOf(
          [live, epg, movies, series, flags],
          () => SearchEngine(
                channels:
                    live.channels.where((c) => !flags.isHidden(c.id)).toList(),
                epg: epg,
                movies: movies,
                series: series,
              ));
      res = engine.search(_q, DateTime.now());
    }
    final channels = res.channels;
    final shows = res.shows;
    final films = res.films;
    final shows2 = res.series;

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
