import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/vod_meta.dart';
import '../../models/models.dart';
import '../../state/discover.dart' show isSeen, watchedKeyOf;
import '../../state/providers.dart';
import '../../state/vod_library.dart';
import '../widgets/a11y.dart';
import '../widgets/common.dart';
import '../widgets/focusable_tile.dart';
import '../nav.dart';
import 'movie_detail_screen.dart';
import '../downloads/download_button.dart'
    show EpisodeDownloadIcon, SeasonDownloadButton;
import '../../l10n/strings.dart';
import '../../state/tmdb.dart' show tmdbDetail;
import 'tmdb_widgets.dart';

/// Serien-Details: Staffel-Reiter (D-Pad: ◀▶ wechselt die Staffel, ▼ in
/// die Folgen, ▲ von der ersten Folge zurück zum Reiter), Folgen mit
/// Fortschritt und Gesehen-Haken, Besetzung, „Weiterschauen S2 · F3“.
class SeriesDetailScreen extends ConsumerStatefulWidget {
  final VodItem series;
  const SeriesDetailScreen({super.key, required this.series});

  @override
  ConsumerState<SeriesDetailScreen> createState() => _SeriesDetailState();
}

class _SeriesDetailState extends ConsumerState<SeriesDetailScreen> {
  int? _season;
  final _tabNodes = <int, FocusNode>{};
  final _firstEpisode = FocusNode(debugLabel: 'first episode');
  bool _markedDone = false;

  @override
  void dispose() {
    for (final n in _tabNodes.values) {
      n.dispose();
    }
    _firstEpisode.dispose();
    super.dispose();
  }

  FocusNode _tabNode(int season) => _tabNodes.putIfAbsent(
      season, () => FocusNode(debugLabel: 'season tab $season'));

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(seriesDetailsProvider(widget.series));
    final storage = ref.watch(storageProvider).value;
    final details = async.value;
    final s0 = details?.series ?? widget.series;
    // TMDB (nur mit eigenem Schlüssel) nach den Anbieter-Details.
    final td = async.isLoading && details == null
        ? (item: s0, info: null)
        : tmdbDetail(ref, s0);
    final s = td.item;
    final seasons = details?.seasons ?? const <int, List<Episode>>{};
    final lib = ref.watch(vodLibraryProvider).value ?? VodLibrary.empty;

    bool watched(Episode e) =>
        (storage?.isWatched('ep_${e.id}') ?? false) || e.serverPlayed;

    double? prog(Episode e) {
      final r = storage?.resume('ep_${e.id}');
      if (r == null || r.total <= 0) {
        // Emby: Stand des Servers, solange lokal nichts bekannt ist.
        final pos = e.serverPosition, total = e.duration;
        if (pos == null || total == null || total.inSeconds <= 0) return null;
        if (watched(e)) return null;
        return (pos.inSeconds / total.inSeconds).clamp(0.0, 1.0);
      }
      return r.pos / r.total;
    }

    final hist = lib.lastOf(s);
    final target = resumeTarget(seasons,
        lastEpisodeId: hist?.episodeId, progress: prog, watched: watched);
    final next = target?.episode;
    final resumeNext = target?.resume ?? false;
    final started = hist != null || resumeNext;
    final nextProg = next == null ? null : prog(next);

    // Alle Folgen gesehen → Serie als gesehen merken (Filter „Ungesehen“).
    final all = episodesInOrder(seasons);
    if (!_markedDone &&
        storage != null &&
        all.isNotEmpty &&
        all.every(watched) &&
        !storage.isWatched(watchedKeyOf(s))) {
      _markedDone = true;
      WidgetsBinding.instance
          .addPostFrameCallback((_) => storage.setWatched(watchedKeyOf(s)));
    }

    final season = _season != null && seasons.containsKey(_season)
        ? _season
        : (next?.season ?? (seasons.isEmpty ? null : seasons.keys.first));
    final episodes = season == null ? const <Episode>[] : seasons[season]!;

    Future<void> play(Episode e) async {
      await playEpisode(context, ref, s, e);
      ref.invalidate(storageProvider);
    }

    Future<void> playFromStart(Episode e) async {
      final r = storage?.resume('ep_${e.id}');
      if (r != null) await storage!.setResume('ep_${e.id}', 0, r.total);
      if (context.mounted) await play(e);
    }

    /// Angefangene Folge antippen → fragen: weiter oder von vorne.
    Future<void> tapEpisode(Episode e) async {
      final r = storage?.resume('ep_${e.id}');
      if (r == null || r.pos < 30) return play(e);
      final pick = await showModalBottomSheet<int>(
        useRootNavigator: true,
        context: context,
        constraints: const BoxConstraints(maxWidth: 480),
        builder: (ctx) => SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ListTile(
                autofocus: true,
                leading: const Icon(Icons.play_arrow_rounded),
                title: Text(trf(
                    'Fortsetzen · {0}', [fmtClock(Duration(seconds: r.pos))])),
                onTap: () => Navigator.pop(ctx, 0)),
            ListTile(
                leading: const Icon(Icons.replay_rounded),
                title: Text(tr('Von vorne')),
                onTap: () => Navigator.pop(ctx, 1)),
          ]),
        ),
      );
      if (pick == 0) await play(e);
      if (pick == 1) await playFromStart(e);
    }

    final cast = (td.info?.cast.isNotEmpty ?? false)
        ? null
        : (details?.cast ?? s.cast);
    return DetailScaffold(
      item: s,
      kind: s.isEmby ? 'EMBY · ${tr('SERIE')}' : tr('SERIE'),
      progress: resumeNext && nextProg != null ? nextProg : null,
      actions: [
        if (next != null)
          FilledButton.icon(
            key: const ValueKey('series-continue'),
            autofocus: true,
            onPressed: () => play(next),
            icon: const Icon(Icons.play_arrow_rounded),
            label: Text(started
                ? trf('Weiterschauen S{0} · F{1}', [next.season, next.number])
                : trf('S{0} F{1} ansehen', [next.season, next.number])),
          ),
        if (next != null && resumeNext)
          GhostButton(
            icon: Icons.replay_rounded,
            label: tr('Von vorne'),
            onTap: () => playFromStart(next),
          ),
        FavoriteButton(item: s),
        if (season != null && episodes.isNotEmpty)
          SeasonDownloadButton(series: s, season: season, episodes: episodes),
        if (s.isEmby && details != null)
          EmbyPlayedButton(
              item: s,
              seen: isSeen(storage, s) ||
                  (all.isNotEmpty && all.every(watched)),
              episodes: all),
        if (youtubeId(s.trailer) != null) TrailerButton(item: s),
      ],
      extra: [
        if (cast != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(trf('Mit {0}', [cast]),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(fontSize: 13, color: AppColors.textFaint)),
          ),
        if (s.director != null)
          Text(trf('Regie: {0}', [s.director]),
              style: const TextStyle(fontSize: 13, color: AppColors.textFaint)),
      ],
      below: async.isLoading && details == null
          ? const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator()))
          : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (seasons.isNotEmpty)
                SeasonTabs(
                  seasons: seasons.keys.toList(),
                  selected: season,
                  nodeOf: _tabNode,
                  watchedCount: (n) => seasons[n]!.where(watched).length,
                  episodeCount: (n) => seasons[n]!.length,
                  onSelect: (n) => setState(() => _season = n),
                  onDown: episodes.isEmpty
                      ? null
                      : () => _firstEpisode.requestFocus(),
                ),
              const SizedBox(height: 16),
              for (var i = 0; i < episodes.length; i++)
                Focus(
                  canRequestFocus: false,
                  skipTraversal: true,
                  onKeyEvent: i == 0 && season != null
                      ? (_, e) {
                          if (e is KeyDownEvent &&
                              e.logicalKey == LogicalKeyboardKey.arrowUp) {
                            _tabNode(season).requestFocus();
                            return KeyEventResult.handled;
                          }
                          return KeyEventResult.ignored;
                        }
                      : null,
                  child: EpisodeTile(
                    key: ValueKey('ep-${episodes[i].id}'),
                    focusNode: i == 0 ? _firstEpisode : null,
                    episode: episodes[i],
                    seed: s.name,
                    progress: prog(episodes[i]),
                    watched: watched(episodes[i]),
                    onTap: () => tapEpisode(episodes[i]),
                    trailing: kIsWeb
                        ? null
                        : EpisodeDownloadIcon(series: s, episode: episodes[i]),
                  ),
                ),
              if (td.info != null && td.info!.cast.isNotEmpty) ...[
                const SizedBox(height: 24),
                TmdbCastRow(info: td.info!),
              ],
            ]),
    );
  }
}

/// Staffel-Reiter: Fokus wechselt die Staffel (wie Reiter am Fernseher),
/// Antippen ebenso. ▼ springt in die erste Folge.
class SeasonTabs extends StatelessWidget {
  final List<int> seasons;
  final int? selected;
  final FocusNode Function(int season) nodeOf;
  final int Function(int season) watchedCount;
  final int Function(int season) episodeCount;
  final ValueChanged<int> onSelect;
  final VoidCallback? onDown;
  const SeasonTabs({
    super.key,
    required this.seasons,
    required this.selected,
    required this.nodeOf,
    required this.watchedCount,
    required this.episodeCount,
    required this.onSelect,
    this.onDown,
  });

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (_, e) {
        if (e is! KeyDownEvent && e is! KeyRepeatEvent) {
          return KeyEventResult.ignored;
        }
        final k = e.logicalKey;
        final cur = seasons.indexWhere((n) => nodeOf(n).hasFocus);
        if (cur < 0) return KeyEventResult.ignored;
        if (k == LogicalKeyboardKey.arrowRight ||
            k == LogicalKeyboardKey.arrowLeft) {
          final j = cur + (k == LogicalKeyboardKey.arrowRight ? 1 : -1);
          // Am Rand stehen bleiben (◀ am ersten Reiter nicht ins Leere).
          if (j >= 0 && j < seasons.length) nodeOf(seasons[j]).requestFocus();
          return KeyEventResult.handled;
        }
        if (k == LogicalKeyboardKey.arrowDown && onDown != null) {
          onDown!();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none,
        child: Row(children: [
          for (final n in seasons)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: _SeasonTab(
                key: ValueKey('season-tab-$n'),
                node: nodeOf(n),
                label: n == 0 ? tr('Extras') : trf('Staffel {0}', [n]),
                info: '${watchedCount(n)}/${episodeCount(n)}',
                semantics: seasonSemantics(
                    n == 0 ? tr('Extras') : trf('Staffel {0}', [n]),
                    watchedCount(n),
                    episodeCount(n)),
                selected: n == selected,
                onFocus: () {
                  if (n != selected) onSelect(n);
                },
                onTap: () => onSelect(n),
              ),
            ),
        ]),
      ),
    );
  }
}

class _SeasonTab extends StatelessWidget {
  final FocusNode node;
  final String label;
  final String info;
  final String semantics;
  final bool selected;
  final VoidCallback onFocus;
  final VoidCallback onTap;
  const _SeasonTab({
    super.key,
    required this.node,
    required this.label,
    required this.info,
    required this.semantics,
    required this.selected,
    required this.onFocus,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final fg = selected ? const Color(0xFF1A0B04) : AppColors.text;
    return FocusableTile(
      focusNode: node,
      onFocus: onFocus,
      onTap: onTap,
      semanticLabel: semantics,
      semanticSelected: selected,
      radius: BorderRadius.circular(22),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        decoration: BoxDecoration(
          color: selected ? AppColors.accent : AppColors.surface,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(label,
              style: TextStyle(
                  color: fg, fontWeight: FontWeight.w700, fontSize: 14)),
          const SizedBox(width: 8),
          Text(info,
              style: TextStyle(
                  color: fg.withValues(alpha: 0.7),
                  fontSize: 12,
                  fontFeatures: const [FontFeature.tabularFigures()])),
        ]),
      ),
    );
  }
}
