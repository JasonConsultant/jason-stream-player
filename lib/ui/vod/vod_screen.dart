import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/security.dart';
import '../../core/theme.dart';
import '../../data/storage.dart';
import '../../models/models.dart';
import '../../state/providers.dart';
import '../../state/vod_library.dart';
import '../nav.dart';
import '../widgets/artwork.dart';
import '../widgets/common.dart';
import '../widgets/focusable_tile.dart';
import '../../l10n/strings.dart';

/// Filme oder Serien: großes Titelbild, „Weiterschauen“, Reihen je Kategorie.
/// Mit Suche oder gewählter Kategorie wird daraus ein Raster.
class VodScreen extends ConsumerStatefulWidget {
  final bool series;
  const VodScreen({super.key, required this.series});

  @override
  ConsumerState<VodScreen> createState() => _VodScreenState();
}

const _favId = '__fav';
const _recentId = '__recent';

/// Fortschritt eines Films bzw. der zuletzt gesehenen Folge einer Serie.
double? vodProgress(Storage? storage, VodItem m, [VodLibrary? lib]) {
  if (storage == null) return null;
  String? key;
  if (m.isSeries) {
    final ep = lib?.lastOf(m)?.episodeId;
    if (ep == null) return null;
    key = 'ep_$ep';
  } else {
    key = 'movie_${m.id}';
  }
  final r = storage.resume(key);
  if (r == null || r.total <= 0) return null;
  return r.pos / r.total;
}

/// „S2 · F3“ für zuletzt gesehene Serien.
String? vodBadge(VodLibrary lib, VodItem m) {
  if (!m.isSeries) return null;
  final h = lib.lastOf(m);
  if (h?.season == null || h?.episode == null) return null;
  return trf('S{0} · F{1}', [h!.season, h.episode]);
}

class _VodScreenState extends ConsumerState<VodScreen> {
  final _search = TextEditingController();
  String _query = '';
  String? _categoryId;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final async =
        ref.watch(widget.series ? seriesProvider : moviesProvider);
    final storage = ref.watch(storageProvider).value;
    final lib = ref.watch(vodLibraryProvider).value ?? VodLibrary.empty;
    final narrow = MediaQuery.sizeOf(context).width < 600;
    final tv = ref.watch(isTvProvider);
    final title = widget.series ? tr('Serien') : tr('Filme');

    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => EmptyState(
          icon: Icons.cloud_off_rounded, title: tr('Keine Verbindung'), message: Redactor.friendly(e)),
      data: (data) {
        if (data.items.isEmpty) {
          return Column(children: [
            PageHeader(title),
            Expanded(
              child: EmptyState(
                icon: widget.series
                    ? Icons.video_library_outlined
                    : Icons.movie_outlined,
                title: widget.series ? tr('Keine Serien') : tr('Keine Filme'),
                message: widget.series
                    ? tr('Dein Portal bietet keine Serien an. M3U-Playlisten enthalten meist nur Live-TV.')
                    : tr('Dein Portal bietet keine Filme an. M3U-Playlisten enthalten meist nur Live-TV.'),
              ),
            ),
          ]);
        }

        final q = _query.trim().toLowerCase();
        final filtering = q.isNotEmpty || _categoryId != null;
        final byId = {for (final m in data.items) m.id: m};
        // Verlauf: neueste zuerst; dazu alte angefangene Filme ohne Verlauf.
        final recent = <VodItem>[
          for (final h in lib.history)
            if (h.series == widget.series && byId[h.id] != null) byId[h.id]!,
        ];
        for (final m in data.items) {
          if ((_progress(storage, m) ?? 0) > 0 && !recent.contains(m)) {
            recent.add(m);
          }
        }
        final favs = data.items.where(lib.isFavorite).toList();
        final List<VodItem> items;
        if (_categoryId == _favId) {
          items = [...favs];
        } else if (_categoryId == _recentId) {
          items = [...recent];
        } else {
          items = data.items
              .where((m) => _categoryId == null || m.categoryId == _categoryId)
              .toList();
        }
        if (q.isNotEmpty) {
          items.retainWhere((m) => m.name.toLowerCase().contains(q));
        }
        final chipList = <(String?, String)>[
          (null, tr('Entdecken')),
          if (favs.isNotEmpty || _categoryId == _favId)
            (_favId, tr('★ Meine Liste')),
          if (recent.isNotEmpty || _categoryId == _recentId)
            (_recentId, tr('Zuletzt gesehen')),
          for (final c in data.categories) (c.id, c.name),
        ];

        final header = PageHeader(
          title,
          trailing: narrow
              ? null
              : SearchField(
                  controller: _search,
                  hint: trf('{0} durchsuchen', [title]),
                  onChanged: (v) => setState(() => _query = v),
                ),
        );

        final chips = SizedBox(
          height: 44,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.symmetric(horizontal: narrow ? 16 : 28),
            itemCount: chipList.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (_, i) {
              final (id, label) = chipList[i];
              final sel = id == _categoryId;
              return ChoiceChip(
                label: Text(label),
                selected: sel,
                showCheckmark: false,
                labelStyle: TextStyle(
                    color: sel ? const Color(0xFF1A0B04) : AppColors.text,
                    fontWeight: FontWeight.w600),
                onSelected: (_) => setState(() => _categoryId = id),
              );
            },
          ),
        );

        if (filtering) {
          return Column(children: [
            header,
            if (narrow) _phoneSearch(title),
            chips,
            const SizedBox(height: 12),
            Expanded(
              child: items.isEmpty
                  ? EmptyState(
                      icon: Icons.search_off_rounded, title: tr('Nichts gefunden'))
                  : GridView.builder(
                      padding: EdgeInsets.fromLTRB(
                          narrow ? 16 : 28, 4, narrow ? 16 : 28, 28),
                      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: narrow ? 130 : (tv ? 200 : 180),
                        childAspectRatio: 0.52,
                        crossAxisSpacing: 14,
                        mainAxisSpacing: 14,
                      ),
                      itemCount: items.length,
                      itemBuilder: (_, i) => PosterCard(
                        item: items[i],
                        autofocus: i == 0,
                        progress: _progress(storage, items[i], lib),
                        badge: _badge(lib, items[i]),
                      ),
                    ),
            ),
          ]);
        }

        final featured = [...data.items]
          ..sort((a, b) => (b.rating ?? 0).compareTo(a.rating ?? 0));
        final newest = [...data.items]
          ..sort((a, b) => (b.added ?? DateTime(2000))
              .compareTo(a.added ?? DateTime(2000)));

        return ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            header,
            if (narrow) _phoneSearch(title),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: narrow ? 16 : 28),
              child: _Hero(item: featured.first, series: widget.series),
            ),
            const SizedBox(height: 18),
            chips,
            if (recent.isNotEmpty)
              _Row(
                title: tr('Weiterschauen & zuletzt gesehen'),
                items: recent.take(20).toList(),
                storage: storage,
                lib: lib,
                narrow: narrow,
                onMore: () => setState(() => _categoryId = _recentId),
              ),
            if (favs.isNotEmpty)
              _Row(
                title: tr('Meine Liste'),
                items: favs,
                storage: storage,
                lib: lib,
                narrow: narrow,
                onMore: () => setState(() => _categoryId = _favId),
              ),
            _Row(
              title: widget.series ? tr('Beliebte Serien') : tr('Top bewertet'),
              items: featured.take(12).toList(),
              storage: storage,
              lib: lib,
              narrow: narrow,
            ),
            if (!widget.series)
              _Row(
                title: tr('Neu hinzugefügt'),
                items: newest.take(12).toList(),
                storage: storage,
                lib: lib,
                narrow: narrow,
              ),
            for (final c in data.categories)
              if (data.items.any((m) => m.categoryId == c.id) && c.id != 'new')
                _Row(
                  title: c.name,
                  items:
                      data.items.where((m) => m.categoryId == c.id).toList(),
                  storage: storage,
                  lib: lib,
                  narrow: narrow,
                  onMore: () => setState(() => _categoryId = c.id),
                ),
          ],
        );
      },
    );
  }

  Widget _phoneSearch(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: SearchField(
          controller: _search,
          hint: trf('{0} durchsuchen', [title]),
          width: double.infinity,
          onChanged: (v) => setState(() => _query = v),
        ),
      );

  double? _progress(Storage? storage, VodItem m, [VodLibrary? lib]) =>
      vodProgress(storage, m, lib);

  String? _badge(VodLibrary lib, VodItem m) => vodBadge(lib, m);
}

class _Hero extends ConsumerWidget {
  final VodItem item;
  final bool series;
  const _Hero({required this.item, required this.series});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final narrow = MediaQuery.sizeOf(context).width < 600;
    final t = Theme.of(context).textTheme;
    final meta = [
      if (item.year != null) '${item.year}',
      if (item.genre != null) item.genre!,
      if (item.duration != null && item.duration!.inMinutes > 0)
        fmtDuration(item.duration!),
    ].join('  ·  ');

    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: SizedBox(
        height: narrow ? 300 : 360,
        child: Stack(fit: StackFit.expand, children: [
          NetworkArt(url: item.backdropUrl ?? item.posterUrl, seed: item.name),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomLeft,
                end: Alignment.topRight,
                colors: [Color(0xF2090B10), Color(0x66090B10), Color(0x00090B10)],
                stops: [0, 0.55, 1],
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.all(narrow ? 18 : 32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Tag(series ? tr('SERIE') : tr('FILM'),
                      color: AppColors.accent, filled: true),
                  const SizedBox(width: 10),
                  if (item.rating != null) RatingLabel(item.rating!),
                ]),
                const SizedBox(height: 12),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: Text(item.name,
                      style: (narrow ? t.headlineMedium : t.displaySmall)
                          ?.copyWith(
                              fontFamily: 'InterDisplay',
                              color: Colors.white,
                              height: 1.02)),
                ),
                const SizedBox(height: 10),
                Text(meta,
                    style: t.bodyMedium?.copyWith(color: Colors.white70)),
                if (item.plot != null && !narrow) ...[
                  const SizedBox(height: 10),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 520),
                    child: Text(item.plot!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: t.bodyMedium?.copyWith(
                            color: Colors.white70, height: 1.45)),
                  ),
                ],
                const SizedBox(height: 18),
                Row(children: [
                  FilledButton.icon(
                    onPressed: () => series
                        ? openVodItem(context, item)
                        : playMovie(context, ref, item),
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: Text(series ? tr('Folgen ansehen') : tr('Abspielen')),
                  ),
                  const SizedBox(width: 10),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      backgroundColor: Colors.white.withValues(alpha: 0.08),
                      side: BorderSide(
                          color: Colors.white.withValues(alpha: 0.25)),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 18, vertical: 16),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: () => openVodItem(context, item),
                    icon: const Icon(Icons.info_outline_rounded),
                    label: Text(tr('Details')),
                  ),
                ]),
              ],
            ),
          ),
        ]),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  final String title;
  final List<VodItem> items;
  final Storage? storage;
  final VodLibrary lib;
  final bool narrow;
  final VoidCallback? onMore;
  const _Row({
    required this.title,
    required this.items,
    required this.storage,
    required this.lib,
    required this.narrow,
    this.onMore,
  });

  @override
  Widget build(BuildContext context) {
    final w = narrow ? 118.0 : 158.0;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: EdgeInsets.fromLTRB(narrow ? 16 : 28, 22, narrow ? 8 : 20, 10),
        child: Row(children: [
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const Spacer(),
          if (onMore != null)
            TextButton(onPressed: onMore, child: Text(tr('Alle'))),
        ]),
      ),
      SizedBox(
        height: w / 0.52,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: EdgeInsets.symmetric(horizontal: narrow ? 16 : 28),
          itemCount: items.length,
          separatorBuilder: (_, __) => const SizedBox(width: 14),
          itemBuilder: (_, i) => SizedBox(
              width: w,
              child: PosterCard(
                  item: items[i],
                  progress: vodProgress(storage, items[i], lib),
                  badge: vodBadge(lib, items[i]))),
        ),
      ),
    ]);
  }
}

/// Poster mit Titel darunter; skaliert bei Fokus (TV).
class PosterCard extends StatelessWidget {
  final VodItem item;
  final bool autofocus;
  final double? progress;

  /// Kleines Etikett unten links, z. B. „S2 · F3“.
  final String? badge;
  const PosterCard(
      {super.key,
      required this.item,
      this.autofocus = false,
      this.progress,
      this.badge});

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      AspectRatio(
        aspectRatio: 2 / 3,
        child: FocusableTile(
          autofocus: autofocus,
          scaleOnFocus: true,
          radius: BorderRadius.circular(12),
          onTap: () => openVodItem(context, item),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Stack(fit: StackFit.expand, children: [
              NetworkArt(
                url: item.posterUrl,
                seed: item.name,
                fallbackChild: LayoutBuilder(
                  builder: (_, box) => Padding(
                    padding: EdgeInsets.all(box.maxWidth * 0.08),
                    child: Align(
                      alignment: Alignment.bottomLeft,
                      child: Text(item.name,
                          maxLines: 4,
                          style: TextStyle(
                              fontFamily: 'InterDisplay',
                              fontWeight: FontWeight.w800,
                              fontSize: box.maxWidth * 0.105,
                              height: 1.05,
                              letterSpacing: -0.3,
                              color: Colors.white)),
                    ),
                  ),
                ),
              ),
              if (item.rating != null && item.rating! > 0)
                Positioned(
                  top: 8,
                  right: 8,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: RatingLabel(item.rating!, size: 11),
                  ),
                ),
              if (badge != null)
                Positioned(
                  left: 8,
                  bottom: progress != null ? 18 : 8,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                    decoration: BoxDecoration(
                      color: AppColors.accent,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(badge!,
                        style: const TextStyle(
                            color: Color(0xFF1A0B04),
                            fontSize: 11,
                            fontWeight: FontWeight.w800)),
                  ),
                ),
              if (progress != null)
                Positioned(
                  left: 8,
                  right: 8,
                  bottom: 8,
                  child: ThinProgress(value: progress!, height: 4),
                ),
            ]),
          ),
        ),
      ),
      const SizedBox(height: 8),
      Text(item.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
              fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.text)),
      Text(
        [if (item.year != null) '${item.year}', if (item.genre != null) item.genre!]
            .join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12, color: AppColors.textFaint),
      ),
    ]);
  }
}
