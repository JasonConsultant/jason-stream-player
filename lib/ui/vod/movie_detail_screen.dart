import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/security.dart';
import '../../core/theme.dart';
import '../../models/models.dart';
import '../../state/providers.dart';
import '../../state/vod_library.dart';
import '../nav.dart';
import '../widgets/artwork.dart';
import '../widgets/a11y.dart';
import '../widgets/common.dart';
import '../widgets/focusable_tile.dart';
import '../../l10n/strings.dart';
import '../../state/profile_mode.dart' show guestModeProvider;
import '../../state/discover.dart' show isSeen;
import '../../state/emby.dart' show setEmbyPlayed;
import '../../core/trailer.dart';
import '../../data/vod_meta.dart' show youtubeId;
import 'package:qr_flutter/qr_flutter.dart';

class MovieDetailScreen extends ConsumerWidget {
  final VodItem movie;
  const MovieDetailScreen({super.key, required this.movie});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final m = ref.watch(movieDetailsProvider(movie)).value ?? movie;
    final storage = ref.watch(storageProvider).value;
    final r = storage?.resume('movie_${m.id}');
    final hasResume = r != null && r.pos > 30;
    return DetailScaffold(
      item: m,
      kind: m.isEmby ? 'EMBY · ${tr('FILM')}' : tr('FILM'),
      actions: [
        FilledButton.icon(
          autofocus: true,
          onPressed: () async {
            await playMovie(context, ref, m);
            ref.invalidate(storageProvider);
          },
          icon: const Icon(Icons.play_arrow_rounded),
          label: Text(hasResume
              ? trf('Fortsetzen · {0}', [fmtClock(Duration(seconds: r.pos))])
              : tr('Abspielen')),
        ),
        if (hasResume)
          _GhostButton(
            icon: Icons.replay_rounded,
            label: tr('Von vorne'),
            onTap: () async {
              await storage!.setResume('movie_${m.id}', 0, r.total);
              if (context.mounted) await playMovie(context, ref, m);
              ref.invalidate(storageProvider);
            },
          ),
        FavoriteButton(item: m),
        if (m.isEmby) EmbyPlayedButton(item: m, seen: isSeen(storage, m)),
        if (youtubeId(m.trailer) != null) TrailerButton(item: m),
      ],
      progress: hasResume && r.total > 0 ? r.pos / r.total : null,
      extra: [
        if (m.director != null) _Fact(tr('Regie'), m.director!),
        if (m.cast != null) _Fact(tr('Besetzung'), m.cast!),
      ],
    );
  }
}

/// Gemeinsames Layout für Film- und Serien-Details.
class DetailScaffold extends StatelessWidget {
  final VodItem item;
  final String kind;
  final List<Widget> actions;
  final List<Widget> extra;
  final double? progress;
  final Widget? below;

  const DetailScaffold({
    super.key,
    required this.item,
    required this.kind,
    required this.actions,
    this.extra = const [],
    this.progress,
    this.below,
  });

  @override
  Widget build(BuildContext context) {
    final m = item;
    final t = Theme.of(context).textTheme;
    final size = MediaQuery.sizeOf(context);
    final narrow = size.width < 700;
    final meta = [
      if (m.year != null) '${m.year}',
      if (m.genre != null) m.genre!,
      if (m.duration != null && m.duration!.inMinutes > 0)
        fmtDuration(m.duration!),
    ];

    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Tag(kind, color: AppColors.accent, filled: true),
          const SizedBox(width: 10),
          if (m.rating != null && m.rating! > 0)
            Semantics(
                container: true,
                label: ratingSemantics(m.rating!),
                excludeSemantics: true,
                child: RatingLabel(m.rating!, size: 14)),
        ]),
        const SizedBox(height: 14),
        Semantics(
          container: true,
          header: true,
          child: Text(m.name,
              style: (narrow ? t.headlineMedium : t.displaySmall)
                  ?.copyWith(fontFamily: 'InterDisplay', height: 1.02)),
        ),
        const SizedBox(height: 10),
        Text(meta.join('  ·  '), style: t.bodyMedium),
        if (progress != null) ...[
          const SizedBox(height: 14),
          SizedBox(
              width: 260, child: ThinProgress(value: progress!, height: 4)),
        ],
        const SizedBox(height: 22),
        Wrap(spacing: 10, runSpacing: 10, children: actions),
        if (m.plot != null) ...[
          const SizedBox(height: 26),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Text(m.plot!,
                style: t.bodyLarge
                    ?.copyWith(color: AppColors.textDim, height: 1.55)),
          ),
        ],
        if (extra.isNotEmpty) ...[
          const SizedBox(height: 20),
          ...extra,
        ],
      ],
    );

    return Scaffold(
      body: Stack(children: [
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          height: (narrow ? 320 : size.height * 0.78).roundToDouble(),
          child: Stack(fit: StackFit.expand, children: [
            NetworkArt(url: m.backdropUrl ?? m.posterUrl, seed: m.name),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0x55090B10), AppColors.bg, AppColors.bg],
                  stops: [0.25, 0.9, 1],
                ),
              ),
            ),
            if (!narrow)
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [AppColors.bg, Color(0x00090B10)],
                    stops: [0.05, 0.7],
                  ),
                ),
              ),
          ]),
        ),
        ListView(
          padding: EdgeInsets.fromLTRB(narrow ? 20 : 56,
              narrow ? 220 : size.height * 0.22, narrow ? 20 : 56, 40),
          children: [
            if (narrow)
              info
            else
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(
                  width: 220,
                  child: AspectRatio(
                    aspectRatio: 2 / 3,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: NetworkArt(
                        url: m.posterUrl,
                        seed: m.name,
                        fallbackChild: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Align(
                            alignment: Alignment.bottomLeft,
                            child: Text(m.name,
                                style: const TextStyle(
                                    fontFamily: 'InterDisplay',
                                    fontWeight: FontWeight.w800,
                                    fontSize: 22,
                                    height: 1.05,
                                    color: Colors.white)),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 40),
                Expanded(child: info),
              ]),
            if (below != null) ...[const SizedBox(height: 32), below!],
          ],
        ),
        // TV: Zurück-Taste der Fernbedienung genügt – der schwebende Knopf
        // würde beim Scrollen den Titel überdecken.
        Consumer(
          builder: (context, ref, _) => ref.watch(isTvProvider)
              ? const SizedBox.shrink()
              : SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: IconButton.filledTonal(
                      style: IconButton.styleFrom(
                          foregroundColor: Colors.white,
                          backgroundColor:
                              Colors.black.withValues(alpha: 0.45)),
                      onPressed: () => Navigator.pop(context),
                      tooltip: tr('Zurück'),
                      icon: const Icon(Icons.arrow_back_rounded),
                    ),
                  ),
                ),
        ),
      ]),
    );
  }
}

class _Fact extends StatelessWidget {
  final String label;
  final String value;
  const _Fact(this.label, this.value);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
            width: 100,
            child: Text(label,
                style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textFaint)),
          ),
          Expanded(
            child: Text(value,
                style: const TextStyle(fontSize: 13, color: AppColors.textDim)),
          ),
        ]),
      );
}

class _GhostButton extends ConsumerWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? color;
  const _GhostButton(
      {super.key,
      required this.icon,
      required this.label,
      required this.onTap,
      this.color});

  @override
  Widget build(BuildContext context, WidgetRef ref) => OutlinedButton.icon(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.text,
          side: const BorderSide(color: AppColors.line),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ).copyWith(
          // Fernbedienung: deutlicher Fokusrahmen.
          side: ref.watch(isTvProvider)
              ? WidgetStateProperty.resolveWith((s) => BorderSide(
                  color: s.contains(WidgetState.focused)
                      ? AppColors.text
                      : AppColors.line,
                  width: s.contains(WidgetState.focused) ? 2 : 1))
              : null,
        ),
        onPressed: onTap,
        icon: Icon(icon, color: color),
        label: Text(label),
      );
}

/// Für die Serien-Seite: Umriss-Knopf wie „Von vorne“.
class GhostButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const GhostButton(
      {super.key,
      required this.icon,
      required this.label,
      required this.onTap});
  @override
  Widget build(BuildContext context) =>
      _GhostButton(icon: icon, label: label, onTap: onTap);
}

/// Für Serien: Episoden-Zeile.
class EpisodeTile extends StatelessWidget {
  final Episode episode;
  final String seed;
  final double? progress;
  final bool autofocus;
  final bool watched;
  final VoidCallback onTap;
  final FocusNode? focusNode;
  const EpisodeTile({
    super.key,
    required this.episode,
    required this.seed,
    required this.onTap,
    this.progress,
    this.autofocus = false,
    this.watched = false,
    this.focusNode,
  });

  @override
  Widget build(BuildContext context) {
    final e = episode;
    final t = Theme.of(context).textTheme;
    final narrow = MediaQuery.sizeOf(context).width < 600;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: FocusableTile(
        focusNode: focusNode,
        autofocus: autofocus,
        onTap: onTap,
        semanticLabel:
            episodeSemantics(e, watched: watched, progress: progress),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(children: [
            SizedBox(
              width: narrow ? 120 : 180,
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Stack(fit: StackFit.expand, children: [
                    NetworkArt(
                        url: e.stillUrl, seed: '$seed ${e.season}x${e.number}'),
                    Center(
                      child: Icon(
                          watched
                              ? Icons.check_circle_rounded
                              : Icons.play_circle_fill_rounded,
                          color: watched ? AppColors.catchup : Colors.white70,
                          size: 34),
                    ),
                    if (progress != null)
                      Positioned(
                        left: 6,
                        right: 6,
                        bottom: 6,
                        child: ThinProgress(value: progress!, height: 3),
                      ),
                  ]),
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${e.number}. ${e.title}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.titleMedium),
                  const SizedBox(height: 4),
                  Text(
                      [
                        if (e.duration != null && e.duration!.inMinutes > 0)
                          fmtDuration(e.duration!),
                        if (watched)
                          tr('Gesehen')
                        else if (progress != null && progress! > 0)
                          trf('{0} % gesehen', [(progress! * 100).round()]),
                      ].join('  ·  '),
                      style: t.bodySmall?.copyWith(
                          color: watched ? AppColors.catchup : null)),
                  if (e.plot != null && !narrow) ...[
                    const SizedBox(height: 6),
                    Text(e.plot!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: t.bodySmall?.copyWith(height: 1.45)),
                  ],
                ],
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Emby: „Als gesehen markieren“ bzw. „Als ungesehen markieren“ – auf dem
/// Server und lokal. Im Gastmodus ausgeblendet (nichts an den Server).
class EmbyPlayedButton extends ConsumerWidget {
  final VodItem item;
  final bool seen;
  final List<Episode> episodes;
  const EmbyPlayedButton(
      {super.key,
      required this.item,
      required this.seen,
      this.episodes = const []});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(guestModeProvider)) return const SizedBox.shrink();
    return _GhostButton(
      key: const ValueKey('emby-played'),
      icon: seen ? Icons.check_circle_rounded : Icons.check_circle_outline_rounded,
      color: seen ? AppColors.catchup : null,
      label: seen ? tr('Als ungesehen markieren') : tr('Als gesehen markieren'),
      onTap: () async {
        final messenger = ScaffoldMessenger.maybeOf(context);
        try {
          await setEmbyPlayed(
              ProviderScope.containerOf(context, listen: false), item, !seen,
              episodes: episodes);
        } catch (e) {
          messenger?.showSnackBar(
              SnackBar(content: Text(Redactor.friendly(e))));
        }
      },
    );
  }
}

/// „Meine Liste“ an/aus – für Filme und Serien.
class FavoriteButton extends ConsumerWidget {
  final VodItem item;
  const FavoriteButton({super.key, required this.item});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Gastmodus: „Meine Liste“ unveränderbar → Knopf ausblenden.
    if (ref.watch(guestModeProvider)) return const SizedBox.shrink();
    final lib = ref.watch(vodLibraryProvider).value ?? VodLibrary.empty;
    final fav = lib.isFavorite(item);
    return _GhostButton(
      icon: fav ? Icons.favorite_rounded : Icons.favorite_border_rounded,
      label: fav ? tr('In meiner Liste') : tr('Meine Liste'),
      color: fav ? AppColors.live : null,
      onTap: () => ref.read(vodLibraryProvider.notifier).toggleFavorite(item),
    );
  }
}

/// „Trailer“: öffnet die YouTube-App (TV: YouTube für Android TV), sonst
/// den Browser. Ohne passende App: Adresse und QR-Code fürs Handy.
class TrailerButton extends StatelessWidget {
  final VodItem item;
  const TrailerButton({super.key, required this.item});

  @override
  Widget build(BuildContext context) => _GhostButton(
        key: const ValueKey('trailer-button'),
        icon: Icons.smart_display_rounded,
        label: tr('Trailer'),
        onTap: () => openTrailer(context, item.trailer),
      );
}

Future<void> openTrailer(BuildContext context, String? raw) async {
  final id = youtubeId(raw);
  if (id == null) return;
  if (await TrailerLauncher.open(id)) return;
  if (!context.mounted) return;
  final url = TrailerLauncher.webUrl(id);
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(tr('Trailer')),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(tr('Keine YouTube-App gefunden. Mit dem Handy scannen:')),
        const SizedBox(height: 14),
        Container(
          color: Colors.white,
          padding: const EdgeInsets.all(8),
          child: QrImageView(data: url, size: 180),
        ),
        const SizedBox(height: 10),
        SelectableText(url, style: const TextStyle(fontSize: 12)),
      ]),
      actions: [
        TextButton(
          autofocus: true,
          onPressed: () => Navigator.pop(ctx),
          child: Text(tr('Schließen')),
        ),
      ],
    ),
  );
}
