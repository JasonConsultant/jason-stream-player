import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../l10n/strings.dart';
import '../../player/data_saver.dart';
import '../../state/providers.dart';
import '../../state/tmdb.dart';
import '../search/person_screen.dart';
import '../tv/tv_widgets.dart';
import '../widgets/artwork.dart';
import '../widgets/focusable_tile.dart';

/// Besetzung mit Fotos (TMDB) unter der Detailseite. OK/Antippen öffnet
/// die Person (Filmografie, im Portal verfügbare Titel markiert).
class TmdbCastRow extends ConsumerWidget {
  final TmdbInfo info;
  const TmdbCastRow({super.key, required this.info});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (info.cast.isEmpty) return const SizedBox.shrink();
    final tv = ref.watch(isTvProvider);
    final saver = ref.watch(dataSaverActiveProvider);
    final t = Theme.of(context).textTheme;
    final size = tv ? 44.0 : 72.0;
    return Column(
      key: const ValueKey('tmdb-cast'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(tr('Besetzung'),
            style: tv ? TvText.caps : t.titleMedium),
        SizedBox(height: tv ? 6 : 10),
        SizedBox(
          height: size + (tv ? 46 : 64),
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: info.cast.length,
            separatorBuilder: (_, __) => SizedBox(width: tv ? 6 : 10),
            itemBuilder: (_, i) {
              final c = info.cast[i];
              return SizedBox(
                width: size + (tv ? 26 : 30),
                child: FocusableTile(
                  key: ValueKey('tmdb-cast-${c.id}'),
                  scaleOnFocus: true,
                  semanticLabel: c.character == null
                      ? c.name
                      : '${c.name}, ${c.character}',
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => PersonScreen(
                          name: c.name, titles: const [], tmdbId: c.id))),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Column(children: [
                      ClipOval(
                        child: SizedBox(
                          width: size,
                          height: size,
                          child: c.profilePath == null
                              ? PersonAvatar(name: c.name, size: size)
                              : NetworkArt(
                                  url: TmdbImages.profile(c.profilePath,
                                      saver: saver),
                                  seed: c.name),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(c.name,
                          maxLines: 2,
                          textAlign: TextAlign.center,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: tv ? 8.5 : 12,
                              height: 1.15,
                              fontWeight: FontWeight.w600,
                              color: AppColors.text)),
                      if (c.character != null && !tv)
                        Text(c.character!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 11, color: AppColors.textFaint)),
                    ]),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 6),
        const TmdbAttribution(),
      ],
    );
  }
}

/// Kleiner Quellenhinweis („Infos: TMDB“).
class TmdbAttribution extends StatelessWidget {
  const TmdbAttribution({super.key});
  @override
  Widget build(BuildContext context) => Text(
        tr('Zusätzliche Infos: TMDB'),
        style: const TextStyle(fontSize: 11, color: AppColors.textFaint),
      );
}
