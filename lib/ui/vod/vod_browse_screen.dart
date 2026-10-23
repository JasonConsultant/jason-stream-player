import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/storage.dart';
import '../../data/vod_meta.dart';
import '../../l10n/strings.dart';
import '../../models/models.dart';
import '../../state/discover.dart';
import '../../state/providers.dart';
import '../../state/vod_library.dart';
import '../tv/tv_widgets.dart';
import '../widgets/common.dart';
import 'vod_screen.dart' show PosterCard, vodBadge, vodProgress;

/// Anzeigename eines Jahrzehnts („2010er“, „2010s“, „2010'lar“).
String decadeLabel(int decade) {
  if (L10n.lang == 'tr') {
    // Vokalharmonie: 1990'lar (doksan), 2020'ler (yirmi), 2000'ler (bin).
    const lar = {10, 30, 40, 60, 90};
    return "$decade'${lar.contains(decade % 100) ? 'lar' : 'ler'}";
  }
  return trf('{0}er', [decade]);
}

String sortLabel(VodSort s) => switch (s) {
      VodSort.standard => tr('Standard'),
      VodSort.newest => tr('Neueste zuerst'),
      VodSort.rating => tr('Beste Bewertung'),
      VodSort.title => tr('A–Z'),
      VodSort.year => tr('Erscheinungsjahr'),
    };

/// Filter/Sortierung für Film-/Serien-Raster.
class VodFilter {
  final String? genre; // Genre-Schlüssel
  final int? decade;
  final int? year;
  final VodSort sort;
  final bool unseen;
  const VodFilter(
      {this.genre,
      this.decade,
      this.year,
      this.sort = VodSort.standard,
      this.unseen = false});

  VodFilter copyWith({
    Object? genre = _keep,
    Object? decade = _keep,
    Object? year = _keep,
    VodSort? sort,
    bool? unseen,
  }) =>
      VodFilter(
        genre: genre == _keep ? this.genre : genre as String?,
        decade: decade == _keep ? this.decade : decade as int?,
        year: year == _keep ? this.year : year as int?,
        sort: sort ?? this.sort,
        unseen: unseen ?? this.unseen,
      );

  @override
  bool operator ==(Object other) =>
      other is VodFilter &&
      other.genre == genre &&
      other.decade == decade &&
      other.year == year &&
      other.sort == sort &&
      other.unseen == unseen;

  @override
  int get hashCode => Object.hash(genre, decade, year, sort, unseen);
}

const _keep = Object();

/// Wendet [f] auf den Katalog an (Genre über den Index, dann Jahr,
/// Gesehen, Sortierung).
List<VodItem> applyVodFilter(
    VodCatalog cat, GenreIndex? genres, VodFilter f, Storage? st) {
  Iterable<VodItem> it = f.genre == null
      ? (f.sort == VodSort.newest ? cat.newest : cat.items)
      : (genres?.itemsOf(f.genre!) ?? const <VodItem>[]);
  if (f.year != null) {
    it = it.where((m) => sanitizeYear(m.year) == f.year);
  } else if (f.decade != null) {
    it = it.where((m) => decadeOf(m.year) == f.decade);
  }
  if (f.unseen) it = it.where((m) => !isSeen(st, m));
  final list = it.toList();
  // Ohne Genre ist „Neueste“ schon vorsortiert (zwischengespeichert).
  if (f.sort == VodSort.newest && f.genre == null) return list;
  return sortVod(list, f.sort);
}

/// „Stöbern“: Genres (aus den Anbieter-Angaben gezählt), Jahrzehnte und
/// Jahre, Sortierung und „Ungesehen“ – darunter das Raster. Alles mit dem
/// D-Pad erreichbar (Chip-Reihen übereinander, ▼ ins Raster).
class VodBrowseScreen extends ConsumerStatefulWidget {
  final bool series;
  final VodFilter initial;

  /// Emby-Katalog statt Portal.
  final bool emby;

  /// Eigene Überschrift (z. B. „Neu hinzugefügt“); sonst „Stöbern“.
  final String? title;
  const VodBrowseScreen(
      {super.key,
      required this.series,
      this.initial = const VodFilter(),
      this.emby = false,
      this.title});

  @override
  ConsumerState<VodBrowseScreen> createState() => _VodBrowseState();
}

class _VodBrowseState extends ConsumerState<VodBrowseScreen> {
  late VodFilter _f = widget.initial;
  List<VodItem>? _cache;
  Object? _cacheFor;
  // Jahrzehnte/Jahre nur neu zählen, wenn Genre oder Jahrzehnt wechseln.
  (List<(int, int)>, List<(int, int)>)? _dec;
  Object? _decFor;

  void _set(VodFilter f) => setState(() => _f = f);

  @override
  Widget build(BuildContext context) {
    final cat = watchCatalog(ref, widget.series, emby: widget.emby);
    final st = ref.watch(storageProvider).value;
    final lib = ref.watch(vodLibraryProvider).value ?? VodLibrary.empty;
    final tv = ref.watch(isTvProvider);
    final narrow = MediaQuery.sizeOf(context).width < 600;
    final kind = widget.series ? tr('Serien') : tr('Filme');
    final title = widget.title ?? trf('{0} stöbern', [kind]);

    if (cat == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    // Genres werden bei großen Listen im Hintergrund gezählt; bis dahin
    // fehlt nur die Genre-Reihe.
    final gi = watchGenreIndex(ref, widget.series, emby: widget.emby);
    final key = (cat, gi, _f, st);
    if (_cacheFor != key) {
      _cache = applyVodFilter(cat, gi, _f, st);
      _cacheFor = key;
    }
    final items = _cache!;
    final genres = gi?.top(30) ?? const <GenreCount>[];
    // Jahrzehnte/Jahre passend zum gewählten Genre.
    final base = _f.genre == null
        ? cat.items
        : (gi?.itemsOf(_f.genre!) ?? const <VodItem>[]);
    final dKey = (cat, gi, _f.genre, _f.decade);
    if (_decFor != dKey) {
      _decFor = dKey;
      _dec = (
        _f.genre == null ? cat.decades : decadesOf(base),
        _f.decade == null ? const <(int, int)>[] : yearsIn(base, _f.decade!),
      );
    }
    final (decades, years) = _dec!;
    final pad = tv ? tvPad : (narrow ? 16.0 : 28.0);

    Widget chip(String label, bool sel, VoidCallback onTap,
        {Key? key, IconData? icon}) {
      if (tv) {
        return TvChip(
            key: key, label: label, icon: icon, selected: sel, onTap: onTap);
      }
      return ChoiceChip(
        key: key,
        avatar: icon == null ? null : Icon(icon, size: 16),
        label: Text(label),
        selected: sel,
        showCheckmark: false,
        labelStyle: TextStyle(
            color: sel ? const Color(0xFF1A0B04) : AppColors.text,
            fontWeight: FontWeight.w600),
        onSelected: (_) => onTap(),
      );
    }

    Widget row(String caption, List<Widget> chips) => Padding(
          padding: EdgeInsets.only(top: tv ? 6 : 8),
          child: Row(children: [
            SizedBox(
              width: tv ? 84 : (narrow ? 0 : 110),
              child: tv || !narrow
                  ? Padding(
                      padding: EdgeInsets.only(left: pad),
                      child: Text(caption.toUpperCase(),
                          maxLines: 1,
                          style: tv
                              ? TvText.caps
                              : Theme.of(context).textTheme.labelSmall),
                    )
                  : null,
            ),
            Expanded(
              child: SizedBox(
                height: tv ? 21 : 44,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: EdgeInsets.only(
                      left: tv || !narrow ? 0 : pad, right: pad),
                  itemCount: chips.length,
                  separatorBuilder: (_, __) => SizedBox(width: tv ? 4 : 8),
                  itemBuilder: (_, i) => chips[i],
                ),
              ),
            ),
          ]),
        );

    final header = Padding(
      padding: EdgeInsets.fromLTRB(tv ? tvPad - 6 : 8, tv ? 14 : 8, pad, 4),
      child: Row(children: [
        IconButton(
          onPressed: () => Navigator.maybePop(context),
          icon: const Icon(Icons.arrow_back_rounded),
          iconSize: tv ? 14 : 24,
          tooltip: tr('Zurück'),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: Text(title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: tv
                  ? TvText.title.copyWith(fontSize: 14)
                  : Theme.of(context).textTheme.titleLarge),
        ),
        Text(trf('{0} Titel', [items.length]),
            style: tv ? TvText.small : Theme.of(context).textTheme.bodySmall),
      ]),
    );

    final filters = <Widget>[
      if (genres.isNotEmpty)
        row(tr('Genre'), [
          chip(tr('Alle'), _f.genre == null, () => _set(_f.copyWith(genre: null)),
              key: const ValueKey('genre-all')),
          for (final g in genres)
            chip('${g.label} · ${g.count}', _f.genre == g.key,
                () => _set(_f.copyWith(genre: g.key)),
                key: ValueKey('genre-${g.key}')),
        ]),
      if (decades.isNotEmpty)
        row(tr('Jahr'), [
          chip(tr('Alle'), _f.decade == null && _f.year == null,
              () => _set(_f.copyWith(decade: null, year: null)),
              key: const ValueKey('decade-all')),
          for (final (d, _) in decades) ...[
            chip(decadeLabel(d), _f.decade == d && _f.year == null,
                () => _set(_f.copyWith(decade: d, year: null)),
                key: ValueKey('decade-$d')),
            if (_f.decade == d)
              for (final (y, _) in years)
                chip('$y', _f.year == y,
                    () => _set(_f.copyWith(year: _f.year == y ? null : y)),
                    key: ValueKey('year-$y')),
          ],
        ]),
      row(tr('Sortierung'), [
        for (final s in VodSort.values)
          chip(sortLabel(s), _f.sort == s, () => _set(_f.copyWith(sort: s)),
              key: ValueKey('sort-${s.name}')),
        chip(tr('Ungesehen'), _f.unseen,
            () => _set(_f.copyWith(unseen: !_f.unseen)),
            key: const ValueKey('filter-unseen'),
            icon: Icons.visibility_off_rounded),
      ]),
    ];

    final grid = items.isEmpty
        ? EmptyState(icon: Icons.search_off_rounded, title: tr('Nichts gefunden'))
        : GridView.builder(
            key: const ValueKey('browse-grid'),
            padding: EdgeInsets.fromLTRB(pad, tv ? 10 : 12, pad, 28),
            gridDelegate: tv
                ? const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 100,
                    childAspectRatio: 88 / (88 * 1.5 + 30),
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                  )
                : SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: narrow ? 130 : 180,
                    childAspectRatio: 0.52,
                    crossAxisSpacing: 14,
                    mainAxisSpacing: 14,
                  ),
            itemCount: items.length,
            itemBuilder: (_, i) => PosterCard(
              item: items[i],
              dense: tv,
              autofocus: i == 0,
              progress: vodProgress(st, items[i], lib),
              badge: vodBadge(lib, items[i]),
            ),
          );

    return Scaffold(
      backgroundColor: tv ? TvColors.bg : null,
      body: SafeArea(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          header,
          ...filters,
          Expanded(child: grid),
        ]),
      ),
    );
  }
}

/// Öffnet „Stöbern“ (bzw. ein vorsortiertes Raster wie „Neu hinzugefügt“).
Future<void> openVodBrowse(BuildContext context,
        {required bool series,
        VodFilter initial = const VodFilter(),
        String? title,
        bool emby = false}) =>
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => VodBrowseScreen(
            series: series, initial: initial, title: title, emby: emby)));
