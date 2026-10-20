import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../models/models.dart';
import '../../state/providers.dart';
import '../../state/vod_library.dart';
import '../widgets/common.dart';
import '../nav.dart';
import 'movie_detail_screen.dart';
import '../../l10n/strings.dart';

class SeriesDetailScreen extends ConsumerStatefulWidget {
  final VodItem series;
  const SeriesDetailScreen({super.key, required this.series});

  @override
  ConsumerState<SeriesDetailScreen> createState() => _SeriesDetailState();
}

class _SeriesDetailState extends ConsumerState<SeriesDetailScreen> {
  int? _season;

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(seriesDetailsProvider(widget.series));
    final storage = ref.watch(storageProvider).value;
    final details = async.value;
    final s = details?.series ?? widget.series;
    final seasons = details?.seasons ?? const <int, List<Episode>>{};
    final season = _season ?? (seasons.isEmpty ? null : seasons.keys.first);
    final episodes = season == null ? const <Episode>[] : seasons[season]!;

    double? prog(Episode e) {
      final r = storage?.resume('ep_${e.id}');
      if (r == null || r.total <= 0) return null;
      return r.pos / r.total;
    }

    final lib = ref.watch(vodLibraryProvider).value ?? VodLibrary.empty;
    final all = [for (final l in seasons.values) ...l];
    bool watched(Episode e) => storage?.isWatched('ep_${e.id}') ?? false;

    // Weiterschauen: zuletzt gesehene Folge – angefangen → dort weiter,
    // zu Ende gesehen → nächste Folge. Ohne Verlauf: erste Folge.
    Episode? next;
    var resumeNext = false;
    final last = lib.lastOf(s)?.episodeId;
    final li = last == null ? -1 : all.indexWhere((e) => e.id == last);
    if (li >= 0) {
      final e = all[li];
      if ((prog(e) ?? 0) > 0) {
        next = e;
        resumeNext = true;
      } else if (watched(e) && li + 1 < all.length) {
        next = all[li + 1];
      } else {
        next = e;
      }
    } else {
      for (final e in all) {
        if ((prog(e) ?? 0) > 0) {
          next = e;
          resumeNext = true;
          break;
        }
      }
    }
    next ??= all.firstOrNull;
    final nextPos = next == null ? null : storage?.resume('ep_${next.id}');

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
        context: context,
        constraints: const BoxConstraints(maxWidth: 480),
        builder: (ctx) => SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ListTile(
                autofocus: true,
                leading: const Icon(Icons.play_arrow_rounded),
                title: Text(trf('Fortsetzen · {0}',
                    [fmtClock(Duration(seconds: r.pos))])),
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

    return DetailScaffold(
      item: s,
      kind: tr('SERIE'),
      actions: [
        if (next != null)
          FilledButton.icon(
            autofocus: true,
            onPressed: () => play(next!),
            icon: const Icon(Icons.play_arrow_rounded),
            label: Text(resumeNext && nextPos != null
                ? trf('S{0} F{1} fortsetzen · {2}', [
                    next.season,
                    next.number,
                    fmtClock(Duration(seconds: nextPos.pos))
                  ])
                : trf('S{0} F{1} ansehen', [next.season, next.number])),
          ),
        if (next != null && resumeNext)
          GhostButton(
            icon: Icons.replay_rounded,
            label: tr('Von vorne'),
            onTap: () => playFromStart(next!),
          ),
        FavoriteButton(item: s),
      ],
      extra: [
        if (details?.cast != null)
          Text(trf('Mit {0}', [details!.cast]),
              style: const TextStyle(fontSize: 13, color: AppColors.textFaint)),
      ],
      below: async.isLoading
          ? const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator()))
          : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (seasons.length > 1)
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final n in seasons.keys)
                    ChoiceChip(
                      label: Text(trf('Staffel {0}', [n])),
                      selected: n == season,
                      showCheckmark: false,
                      labelStyle: TextStyle(
                          color: n == season
                              ? const Color(0xFF1A0B04)
                              : AppColors.text,
                          fontWeight: FontWeight.w600),
                      onSelected: (_) => setState(() => _season = n),
                    ),
                ])
              else if (season != null)
                Text(trf('Staffel {0}', [season]),
                    style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 16),
              for (final e in episodes)
                EpisodeTile(
                  episode: e,
                  seed: s.name,
                  progress: prog(e),
                  watched: watched(e),
                  onTap: () => tapEpisode(e),
                ),
            ]),
    );
  }
}
