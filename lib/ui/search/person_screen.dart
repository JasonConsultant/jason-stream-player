import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../l10n/strings.dart';
import '../../models/models.dart';
import '../../state/providers.dart';
import '../../state/vod_library.dart';
import '../tv/tv_widgets.dart';
import '../widgets/focusable_tile.dart';
import '../vod/vod_screen.dart' show PosterCard, vodBadge, vodProgress;
import '../../player/data_saver.dart';
import '../../state/discover.dart' show searchMoviesProvider, searchSeriesProvider;
import '../../state/profile_mode.dart' show kidsModeProvider;
import '../../state/tmdb.dart';
import '../widgets/artwork.dart';

/// Alle Filme und Serien einer Person (Besetzung oder Regie).
///
/// Mit TMDB-Schlüssel (ab 2.3, nicht im Kindermodus): zusätzlich die
/// Filmografie von TMDB – Titel, die im Portal verfügbar sind, stehen oben
/// und sind abspielbar; der Rest ist als „nicht im Portal“ markiert.
class PersonScreen extends ConsumerWidget {
  final String name;
  final List<VodItem> titles;
  final bool director;

  /// TMDB-Personen-ID (aus der Besetzung einer Detailseite).
  final int? tmdbId;
  const PersonScreen(
      {super.key,
      required this.name,
      required this.titles,
      this.director = false,
      this.tmdbId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tv = ref.watch(isTvProvider);
    final st = ref.watch(storageProvider).value;
    final lib = ref.watch(vodLibraryProvider).value ?? VodLibrary.empty;
    final narrow = MediaQuery.sizeOf(context).width < 600;
    final pad = tv ? tvPad : (narrow ? 16.0 : 28.0);
    final saver = ref.watch(dataSaverActiveProvider);
    // TMDB-Filmografie (null: kein Schlüssel, Kindermodus, Fehler).
    final tmdbOn = ref.watch(tmdbClientProvider) != null &&
        !ref.watch(kidsModeProvider);
    final person = tmdbOn
        ? ref.watch(tmdbPersonProvider((name: name, id: tmdbId)))
        : null;
    final p = person?.value;

    // Portal-Titel: übergebene + über TMDB gefundene (nur sichtbare Listen).
    final portal = <String, VodItem>{
      for (final m in titles) VodLibrary.keyOf(m): m,
    };
    final missing = <TmdbPersonCredit>[];
    if (p != null) {
      final index = PortalTitleIndex([
        ...?ref.watch(searchMoviesProvider),
        ...?ref.watch(searchSeriesProvider),
      ]);
      for (final c in p.credits) {
        final hit = index.find(c);
        if (hit != null) {
          portal.putIfAbsent(VodLibrary.keyOf(hit), () => hit);
        } else {
          missing.add(c);
        }
      }
    }
    // Beste Bewertung zuerst, Filme und Serien gemischt.
    final list = portal.values.toList()
      ..sort((a, b) => (b.rating ?? 0).compareTo(a.rating ?? 0));
    final t = Theme.of(context).textTheme;
    final grid = tv
        ? const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 100,
            childAspectRatio: 88 / (88 * 1.5 + 30),
            crossAxisSpacing: 12,
            mainAxisSpacing: 12)
        : SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: narrow ? 130 : 180,
            // Lange Anbieter-Titel brechen zweizeilig um.
            childAspectRatio: 0.5,
            crossAxisSpacing: 14,
            mainAxisSpacing: 14);
    Widget heading(String text, Key key) => SliverPadding(
          key: key,
          padding: EdgeInsets.fromLTRB(pad, 14, pad, 8),
          sliver: SliverToBoxAdapter(
              child: Text(text, style: tv ? TvText.caps : t.labelSmall)),
        );
    return Scaffold(
      backgroundColor: tv ? TvColors.bg : null,
      body: SafeArea(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: EdgeInsets.fromLTRB(tv ? tvPad - 6 : 8, tv ? 14 : 8, pad, 8),
            child: Row(children: [
              IconButton(
                onPressed: () => Navigator.maybePop(context),
                icon: const Icon(Icons.arrow_back_rounded),
                iconSize: tv ? 14 : 24,
                tooltip: tr('Zurück'),
              ),
              const SizedBox(width: 6),
              p?.profilePath != null
                  ? ClipOval(
                      child: SizedBox(
                        width: tv ? 26 : 44,
                        height: tv ? 26 : 44,
                        child: NetworkArt(
                            url: TmdbImages.profile(p!.profilePath,
                                saver: saver),
                            seed: name),
                      ),
                    )
                  : PersonAvatar(name: name, size: tv ? 26 : 44),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: tv
                              ? TvText.title.copyWith(fontSize: 14)
                              : t.titleLarge),
                      Text(
                          (p == null
                                  ? trf('{0} Titel', [list.length])
                                  : trf('{0} im Portal · {1} laut TMDB', [
                                      list.length,
                                      p.credits.length,
                                    ])) +
                              (director ? ' · ${tr('Regie')}' : ''),
                          style: tv ? TvText.small : t.bodySmall),
                    ]),
              ),
              if (person != null && person.isLoading)
                const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2)),
            ]),
          ),
          Expanded(
            child: CustomScrollView(
              key: const ValueKey('person-grid'),
              slivers: [
                if (p != null)
                  heading(trf('IM PORTAL VERFÜGBAR ({0})', [list.length]),
                      const ValueKey('person-available')),
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(pad, 8, pad, 20),
                  sliver: SliverGrid.builder(
                    gridDelegate: grid,
                    itemCount: list.length,
                    itemBuilder: (_, i) => PosterCard(
                      item: list[i],
                      dense: tv,
                      autofocus: i == 0,
                      progress: vodProgress(st, list[i], lib),
                      badge: vodBadge(lib, list[i]),
                    ),
                  ),
                ),
                if (missing.isNotEmpty) ...[
                  heading(tr('WEITERE TITEL (NICHT IM PORTAL)'),
                      const ValueKey('person-missing')),
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(pad, 8, pad, 28),
                    sliver: SliverGrid.builder(
                      gridDelegate: grid,
                      itemCount: missing.length,
                      itemBuilder: (_, i) => _MissingCard(
                          credit: missing[i],
                          dense: tv,
                          saver: saver,
                          autofocus: list.isEmpty && i == 0),
                    ),
                  ),
                ],
                if (p != null)
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(pad, 0, pad, 24),
                    sliver: const SliverToBoxAdapter(child: TmdbAttributionText()),
                  ),
              ],
            ),
          ),
        ]),
      ),
    );
  }
}

/// Titel aus der TMDB-Filmografie, der im Portal fehlt (nicht abspielbar).
class _MissingCard extends StatelessWidget {
  final TmdbPersonCredit credit;
  final bool dense;
  final bool saver;
  final bool autofocus;
  const _MissingCard(
      {required this.credit,
      required this.dense,
      required this.saver,
      this.autofocus = false});

  @override
  Widget build(BuildContext context) {
    final c = credit;
    final label = c.year == null ? c.title : '${c.title} (${c.year})';
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      AspectRatio(
        aspectRatio: 2 / 3,
        child: FocusableTile(
          key: ValueKey('person-missing-${c.tv ? 't' : 'm'}${c.id}'),
          autofocus: autofocus,
          radius: BorderRadius.circular(dense ? 9 : 12),
          semanticLabel: '$label, ${tr('nicht im Portal')}',
          onTap: () => ScaffoldMessenger.maybeOf(context)
            ?..hideCurrentSnackBar()
            ..showSnackBar(SnackBar(
                content: Text(trf('„{0}“ ist in deinem Portal nicht verfügbar.',
                    [c.title])))),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(dense ? 7 : 10),
            child: Stack(fit: StackFit.expand, children: [
              Opacity(
                opacity: 0.45,
                child: NetworkArt(
                    url: TmdbImages.poster(c.posterPath, saver: true),
                    seed: c.title),
              ),
              Positioned(
                left: dense ? 4 : 6,
                bottom: dense ? 4 : 6,
                child: Tag(tr('Nicht im Portal'), color: AppColors.textDim),
              ),
            ]),
          ),
        ),
      ),
      SizedBox(height: dense ? 3 : 6),
      Text(label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
              fontSize: dense ? 8.5 : 12.5,
              fontWeight: FontWeight.w600,
              color: AppColors.textDim)),
    ]);
  }
}

/// Quellenhinweis unter TMDB-Daten.
class TmdbAttributionText extends StatelessWidget {
  const TmdbAttributionText({super.key});
  @override
  Widget build(BuildContext context) => Text(tr('Filmografie: TMDB'),
      style: const TextStyle(fontSize: 11, color: AppColors.textFaint));
}

/// Runder Platzhalter mit Initialen.
class PersonAvatar extends StatelessWidget {
  final String name;
  final double size;
  const PersonAvatar({super.key, required this.name, this.size = 44});

  @override
  Widget build(BuildContext context) {
    final parts = name.trim().split(RegExp(r'\s+'));
    final ini = parts.length == 1
        ? parts.first.characters.take(2).toString()
        : '${parts.first.characters.first}${parts.last.characters.first}';
    final hue = (name.hashCode % 360).abs().toDouble();
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: HSLColor.fromAHSL(1, hue, 0.35, 0.32).toColor(),
      ),
      child: Text(ini.toUpperCase(),
          style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
              fontSize: size * 0.38)),
    );
  }
}

/// Kachel einer Person in der Suche.
class PersonTile extends StatelessWidget {
  final String name;
  final int count;
  final bool director;
  final VoidCallback onTap;
  const PersonTile(
      {super.key,
      required this.name,
      required this.count,
      required this.onTap,
      this.director = false});

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 130,
        child: FocusableTile(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(children: [
              PersonAvatar(name: name, size: 48),
              const SizedBox(height: 8),
              Text(name,
                  maxLines: 2,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: AppColors.text)),
              Text(
                  director
                      ? trf('Regie · {0} Titel', [count])
                      : trf('{0} Titel', [count]),
                  maxLines: 1,
                  style: const TextStyle(
                      fontSize: 11, color: AppColors.textFaint)),
            ]),
          ),
        ),
      );
}
