import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/storage.dart';
import '../../data/vod_groups.dart';
import '../../data/vod_meta.dart';
import '../../l10n/strings.dart';
import '../../models/models.dart';
import '../../state/discover.dart';
import '../../state/providers.dart';
import '../../state/vod_library.dart';
import '../widgets/common.dart';
import 'vod_browse_screen.dart' show sortLabel;
import 'vod_screen.dart' show PosterCard, vodBadge, vodProgress;

/// Ansicht oben in Filme/Serien (Handy/Tablet): „Entdecken“ (Titelbild,
/// Reihen) oder eine Gruppen-Übersicht.
enum VodView { discover, category, genre, year, language }

extension VodViewMode on VodView {
  VodGroupMode? get mode => switch (this) {
        VodView.discover => null,
        VodView.category => VodGroupMode.category,
        VodView.genre => VodGroupMode.genre,
        VodView.year => VodGroupMode.year,
        VodView.language => VodGroupMode.language,
      };

  String get label => switch (this) {
        VodView.discover => tr('Entdecken'),
        VodView.category => tr('Kategorie'),
        VodView.genre => tr('Genre'),
        VodView.year => tr('Jahr'),
        VodView.language => tr('Sprache'),
      };

  IconData get icon => switch (this) {
        VodView.discover => Icons.auto_awesome_outlined,
        VodView.category => Icons.folder_outlined,
        VodView.genre => Icons.theater_comedy_outlined,
        VodView.year => Icons.calendar_month_outlined,
        VodView.language => Icons.translate_rounded,
      };
}

/// Gemerkte Ansicht je Liste (Option `vodview_m` / `vodview_s`).
VodView storedVodView(Storage? st, bool series) {
  final v = st?.option(series ? 'vodview_s' : 'vodview_m', 'discover');
  return VodView.values.firstWhere((e) => e.name == v,
      orElse: () => VodView.discover);
}

Future<void> storeVodView(Storage? st, bool series, VodView v) async =>
    st?.setOption(series ? 'vodview_s' : 'vodview_m', v.name);

/// Anzeigename einer Sprachgruppe.
String languageLabel(String code) => switch (code) {
      'DE' => tr('Deutsch'),
      'EN' => tr('Englisch'),
      'TR' => tr('Türkisch'),
      'FR' => tr('Französisch'),
      'IT' => tr('Italienisch'),
      'ES' => tr('Spanisch'),
      'NL' => tr('Niederländisch'),
      'PL' => tr('Polnisch'),
      'RU' => tr('Russisch'),
      'AR' => tr('Arabisch'),
      'KU' => tr('Kurdisch'),
      'AL' => tr('Albanisch'),
      'PT' => tr('Portugiesisch'),
      'GR' => tr('Griechisch'),
      'RO' => tr('Rumänisch'),
      'BG' => tr('Bulgarisch'),
      'HU' => tr('Ungarisch'),
      'CZ' => tr('Tschechisch'),
      'EXYU' => tr('Ex-YU (Serbisch, Kroatisch, Bosnisch)'),
      'SV' => tr('Schwedisch'),
      'NO' => tr('Norwegisch'),
      'DA' => tr('Dänisch'),
      'FI' => tr('Finnisch'),
      'FA' => tr('Persisch'),
      'HI' => 'Hindi',
      'UR' => 'Urdu',
      'ZH' => tr('Chinesisch'),
      'JA' => tr('Japanisch'),
      'KO' => tr('Koreanisch'),
      'AZ' => tr('Aserbaidschanisch'),
      VodGroupKey.none => tr('Ohne Sprache'),
      _ => code,
    };

/// Anzeigename einer Gruppe.
String vodGroupLabel(VodGroupMode mode, VodGroup g) => switch (mode) {
      VodGroupMode.category => g.label,
      VodGroupMode.genre =>
        g.key == VodGroupKey.none ? tr('Ohne Genre') : g.label,
      VodGroupMode.year => g.key == VodGroupKey.before
          ? trf('Vor {0}', [VodGroups.firstYear])
          : g.key == VodGroupKey.none
              ? tr('Ohne Jahr')
              : g.key,
      VodGroupMode.language => languageLabel(g.key),
    };

/// Umschalter „Entdecken · Kategorie · Genre · Jahr · Sprache“ (Chips,
/// waagrecht scrollbar – passt so auch auf schmale Handys).
class VodViewSwitch extends StatelessWidget {
  final VodView view;
  final ValueChanged<VodView> onChanged;
  final EdgeInsets padding;
  const VodViewSwitch(
      {super.key,
      required this.view,
      required this.onChanged,
      this.padding = EdgeInsets.zero});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    Widget chip(VodView v) {
      final sel = v == view;
      return ChoiceChip(
        key: ValueKey('vod-view-${v.name}'),
        avatar:
            Icon(v.icon, size: 18, color: sel ? cs.onPrimary : AppColors.textDim),
        label: Text(v.label),
        selected: sel,
        showCheckmark: false,
        labelStyle: TextStyle(
            color: sel ? cs.onPrimary : AppColors.text,
            fontWeight: FontWeight.w600),
        onSelected: (_) {
          if (sel) return;
          HapticFeedback.selectionClick();
          onChanged(v);
        },
      );
    }

    // Nur fünf Chips: alle gebaut (kein Lazy-Bau), damit „Sprache“ beim
    // Wischen sofort da ist.
    return SizedBox(
      height: 44,
      width: double.infinity,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: padding,
        child: Row(children: [
          for (final v in VodView.values) ...[
            if (v != VodView.discover) const SizedBox(width: 8),
            chip(v),
          ],
        ]),
      ),
    );
  }
}

/// Gruppen als Karten mit Titelanzahl; „Alle Titel“ zuerst.
class VodGroupsGrid extends ConsumerWidget {
  final bool series;
  final bool emby;
  final VodGroupMode mode;
  final double pad;
  const VodGroupsGrid({
    super.key,
    required this.series,
    required this.emby,
    required this.mode,
    required this.pad,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groups = watchVodGroups(ref, series, emby: emby);
    if (groups == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final list = groups.of(mode);
    final noGenres = mode == VodGroupMode.genre && !groups.hasGenres;
    final kind = series ? tr('Serien') : tr('Filme');

    void open(VodGroup? g) => Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => VodGroupScreen(
            series: series,
            emby: emby,
            mode: mode,
            groupKey: g?.key,
            title: g == null ? trf('Alle {0}', [kind]) : vodGroupLabel(mode, g))));

    final all = _GroupCard(
      key: const ValueKey('vod-group-all'),
      icon: Icons.apps_rounded,
      title: tr('Alle Titel'),
      count: groups.items.length,
      highlight: true,
      onTap: () => open(null),
    );

    return CustomScrollView(
      key: ValueKey('vod-groups-${mode.name}'),
      slivers: [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(pad, 8, pad, 0),
          sliver: SliverToBoxAdapter(child: all),
        ),
        if (noGenres)
          SliverToBoxAdapter(
            child: EmptyState(
              icon: Icons.theater_comedy_outlined,
              title: tr('Keine Genre-Angaben'),
              message: tr(
                  'Dein Anbieter liefert zu diesen Titeln keine Genres. Kategorie, Jahr oder Sprache helfen beim Stöbern.'),
            ),
          )
        else
          SliverPadding(
            padding: EdgeInsets.fromLTRB(pad, 12, pad, 28),
            sliver: SliverGrid.builder(
              // Handy: eine Spalte (lange Namen wie „Dokumentation“ oder
              // „DE | Kinofilme 2024“ bleiben lesbar), sonst Raster.
              gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent:
                    MediaQuery.sizeOf(context).width < 600 ? 600 : 280,
                mainAxisExtent: 72,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
              ),
              itemCount: list.length,
              itemBuilder: (_, i) {
                final g = list[i];
                return _GroupCard(
                  key: ValueKey('vod-group-${g.key}'),
                  icon: _iconOf(mode, g),
                  badge: mode == VodGroupMode.language &&
                          g.key != VodGroupKey.none
                      ? (g.key == 'EXYU' ? 'YU' : g.key)
                      : null,
                  title: vodGroupLabel(mode, g),
                  count: g.count,
                  onTap: () => open(g),
                );
              },
            ),
          ),
      ],
    );
  }

  static IconData _iconOf(VodGroupMode mode, VodGroup g) {
    if (g.key == VodGroupKey.none) return Icons.help_outline_rounded;
    return switch (mode) {
      VodGroupMode.category => Icons.folder_outlined,
      VodGroupMode.genre => Icons.theater_comedy_outlined,
      VodGroupMode.year => g.key == VodGroupKey.before
          ? Icons.history_rounded
          : Icons.calendar_today_outlined,
      VodGroupMode.language => Icons.translate_rounded,
    };
  }
}

class _GroupCard extends StatelessWidget {
  final IconData icon;
  final String? badge;
  final String title;
  final int count;
  final bool highlight;
  final VoidCallback onTap;
  const _GroupCard({
    super.key,
    required this.icon,
    required this.title,
    required this.count,
    required this.onTap,
    this.badge,
    this.highlight = false,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Card.filled(
      margin: EdgeInsets.zero,
      color: highlight ? AppColors.accentSoft : cs.surfaceContainerHigh,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(children: [
            Container(
              width: 44,
              height: 44,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: highlight ? AppColors.accent : cs.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: badge != null
                  ? Text(badge!,
                      style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 15,
                          color: AppColors.accent))
                  : Icon(icon,
                      size: 22,
                      color: highlight ? cs.onPrimary : AppColors.textDim),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: t.titleSmall?.copyWith(height: 1.2)),
                  const SizedBox(height: 2),
                  Text(trf('{0} Titel', [count]), style: t.bodySmall),
                ],
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Titel einer Gruppe (bzw. alle Titel) als Raster mit Sortierung.
class VodGroupScreen extends ConsumerStatefulWidget {
  final bool series;
  final bool emby;
  final VodGroupMode mode;

  /// null = alle Titel.
  final String? groupKey;
  final String title;
  const VodGroupScreen({
    super.key,
    required this.series,
    required this.emby,
    required this.mode,
    required this.groupKey,
    required this.title,
  });

  @override
  ConsumerState<VodGroupScreen> createState() => _VodGroupScreenState();
}

class _VodGroupScreenState extends ConsumerState<VodGroupScreen> {
  VodSort _sort = VodSort.standard;
  bool _unseen = false;
  List<VodItem>? _cache;
  Object? _cacheFor;

  @override
  Widget build(BuildContext context) {
    final groups = watchVodGroups(ref, widget.series, emby: widget.emby);
    final st = ref.watch(storageProvider).value;
    final lib = ref.watch(vodLibraryProvider).value ?? VodLibrary.empty;
    final narrow = MediaQuery.sizeOf(context).width < 600;
    final pad = narrow ? 16.0 : 28.0;

    final key = (groups, _sort, _unseen, st);
    if (groups != null && _cacheFor != key) {
      final g = widget.groupKey == null
          ? null
          : groups.find(widget.mode, widget.groupKey!);
      var list = widget.groupKey == null
          ? groups.items
          : (g == null ? const <VodItem>[] : groups.itemsOf(g));
      if (_unseen) list = [for (final m in list) if (!isSeen(st, m)) m];
      _cache = sortVod(list, _sort);
      _cacheFor = key;
    }
    final items = _cache;

    final chips = <(String, bool, VoidCallback, IconData?)>[
      for (final s in VodSort.values)
        (sortLabel(s), _sort == s, () => setState(() => _sort = s), null),
      (
        tr('Ungesehen'),
        _unseen,
        () => setState(() => _unseen = !_unseen),
        Icons.visibility_off_rounded
      ),
    ];
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          if (items != null)
            Text(trf('{0} Titel', [items.length]),
                style: Theme.of(context).textTheme.bodySmall),
        ]),
      ),
      body: items == null
          ? const Center(child: CircularProgressIndicator())
          : Column(children: [
              SizedBox(
                height: 44,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: EdgeInsets.symmetric(horizontal: pad),
                  itemCount: chips.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (_, i) {
                    final (label, sel, onTap, icon) = chips[i];
                    return FilterChip(
                      label: Text(label),
                      avatar: icon == null ? null : Icon(icon, size: 16),
                      selected: sel,
                      showCheckmark: false,
                      labelStyle: TextStyle(
                          color: sel ? cs.onPrimary : AppColors.text,
                          fontWeight: FontWeight.w600),
                      onSelected: (_) => onTap(),
                    );
                  },
                ),
              ),
              Expanded(
                child: items.isEmpty
                    ? EmptyState(
                        icon: Icons.search_off_rounded,
                        title: tr('Nichts gefunden'))
                    : GridView.builder(
                        key: const ValueKey('vod-group-grid'),
                        padding: EdgeInsets.fromLTRB(pad, 12, pad, 28),
                        gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: narrow ? 130 : 180,
                          // Poster 2:3 + zwei Textzeilen (ohne Überlauf auch
                          // bei schmalen Spalten).
                          childAspectRatio: 0.5,
                          crossAxisSpacing: 14,
                          mainAxisSpacing: 14,
                        ),
                        itemCount: items.length,
                        itemBuilder: (_, i) => PosterCard(
                          item: items[i],
                          progress: vodProgress(st, items[i], lib),
                          badge: vodBadge(lib, items[i]),
                        ),
                      ),
              ),
            ]),
    );
  }
}
