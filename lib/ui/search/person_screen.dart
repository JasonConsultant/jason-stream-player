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

/// Alle Filme und Serien einer Person (Besetzung oder Regie).
class PersonScreen extends ConsumerWidget {
  final String name;
  final List<VodItem> titles;
  final bool director;
  const PersonScreen(
      {super.key,
      required this.name,
      required this.titles,
      this.director = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tv = ref.watch(isTvProvider);
    final st = ref.watch(storageProvider).value;
    final lib = ref.watch(vodLibraryProvider).value ?? VodLibrary.empty;
    final narrow = MediaQuery.sizeOf(context).width < 600;
    final pad = tv ? tvPad : (narrow ? 16.0 : 28.0);
    // Beste Bewertung zuerst, Filme und Serien gemischt.
    final list = [...titles]
      ..sort((a, b) => (b.rating ?? 0).compareTo(a.rating ?? 0));
    final t = Theme.of(context).textTheme;
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
              PersonAvatar(name: name, size: tv ? 26 : 44),
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
                          trf('{0} Titel', [list.length]) +
                              (director ? ' · ${tr('Regie')}' : ''),
                          style: tv ? TvText.small : t.bodySmall),
                    ]),
              ),
            ]),
          ),
          Expanded(
            child: GridView.builder(
              key: const ValueKey('person-grid'),
              padding: EdgeInsets.fromLTRB(pad, 8, pad, 28),
              gridDelegate: tv
                  ? const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 100,
                      childAspectRatio: 88 / (88 * 1.5 + 30),
                      crossAxisSpacing: 12,
                      mainAxisSpacing: 12)
                  : SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: narrow ? 130 : 180,
                      childAspectRatio: 0.52,
                      crossAxisSpacing: 14,
                      mainAxisSpacing: 14),
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
        ]),
      ),
    );
  }
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
