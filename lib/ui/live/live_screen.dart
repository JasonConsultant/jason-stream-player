import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/security.dart';
import '../../core/theme.dart';
import '../../models/models.dart';
import '../../state/my_groups.dart';
import '../../state/channel_variants.dart'
    show VariantCountBadge, resolveChannelIds;
import '../../state/epg_select.dart';
import '../../state/providers.dart';
import '../nav.dart';
import '../player/channel_digit_entry.dart';
import '../tv/tv_focus.dart';
import '../tv/tv_widgets.dart';
import '../widgets/artwork.dart';
import '../widgets/common.dart';
import '../widgets/fine_grained.dart';
import '../widgets/focusable_tile.dart';
import '../widgets/live_preview.dart';
import 'channel_sheet.dart';
import 'my_groups_ui.dart';
import 'parental.dart' show kidsGuard;
import 'reorder_screen.dart';
import '../../state/profile_mode.dart';
import '../widgets/a11y.dart';

const _favId = '__fav';
const _allId = '__all';
const _recentId = '__recent';

/// Live-TV. Breit/TV: Gruppen | Sender | Vorschau mit Programm und Catch-up.
/// Handy: Gruppen-Chips oben, Senderliste darunter.
class LiveScreen extends ConsumerStatefulWidget {
  const LiveScreen({super.key});

  @override
  ConsumerState<LiveScreen> createState() => _LiveScreenState();
}

class _LiveScreenState extends ConsumerState<LiveScreen> {
  String _categoryId = _allId;
  String _query = '';
  bool _searching = false;
  Object? _memoKey;
  Map<String, int> _memoCounts = const {};
  List<Channel> _memoChannels = const [];
  final _lowerNames = Expando<String>();

  /// Zuletzt fokussierter Sender (Vorschau/Info). Als Notifier, damit ein
  /// ▲/▼ nur die betroffenen Zeilen und die Info-Spalte neu baut – nicht
  /// den ganzen Bildschirm.
  final _focused = ValueNotifier<Channel?>(null);
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    _focused.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final live = ref.watch(visibleLiveDataProvider);
    final flags = ref.watch(channelFlagsProvider).value ?? ChannelFlags.empty;
    final order = ref.watch(sortOrderProvider).value ?? SortOrder.empty;
    // Kein EPG und kein Minutentakt hier: das beobachten die einzelnen
    // Zeilen (nowNextProvider, MinuteBuilder).
    final recents = ref.watch(recentProvider).value ?? const <String>[];
    final myGroups = ref.watch(visibleMyGroupsProvider);
    final tv = ref.watch(isTvProvider);
    final width = MediaQuery.sizeOf(context).width;
    final wide = tv || width >= 900;

    return TabBackHandler(
      // Handy: Zurück schließt zuerst die offene Suche.
      onBack: () {
        if (!_searching || ref.read(isTvProvider)) return false;
        setState(() {
          _searching = false;
          _search.clear();
          _query = '';
        });
        return true;
      },
      // Zifferntasten: Direktwahl (aktuelle Gruppe, sonst alle Sender).
      child: ChannelDigitEntry(
        channels: () => _memoChannels,
        all: () =>
            ref.read(visibleLiveDataProvider).value?.channels ?? const [],
        onPick: (c, list) =>
            withPreviewPaused(ref, () => playChannel(context, ref, c, list)),
        child: _body(
            context, live, flags, order, recents, myGroups, tv, width, wide),
      ),
    );
  }

  Widget _body(
    BuildContext context,
    AsyncValue<LiveData> live,
    ChannelFlags flags,
    SortOrder order,
    List<String> recents,
    List<MyGroup> myGroups,
    bool tv,
    double width,
    bool wide,
  ) {
    return live.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => EmptyState(
        icon: Icons.cloud_off_rounded,
        title: tr('Verbindung fehlgeschlagen'),
        message: Redactor.friendly(e),
        action: tr('Erneut versuchen'),
        onAction: () {
          ref.invalidate(repositoryProvider);
          ref.invalidate(liveDataProvider);
        },
      ),
      data: (data) {
        // Nur neu berechnen, wenn sich Daten, Markierungen, Gruppe, Suche
        // oder Verlauf ändern – nicht bei jedem Tastendruck/Fokuswechsel
        // (12.000+ Sender).
        final key =
            (data, flags, _categoryId, _query, order, recents, myGroups);
        if (key != _memoKey) {
          _memoKey = key;
          _memoCounts = _counts(data, flags, recents)
            ..addAll({for (final g in myGroups) g.id: g.channels.length});
          _memoChannels = _filter(data, flags, order, recents, myGroups);
        }
        final counts = _memoCounts;
        final channels = _memoChannels;
        // Gastmodus: Favoriten und Verlauf ausblenden.
        final guest = ref.watch(guestModeProvider);
        final hasRecent = !guest && (counts[_recentId] ?? 0) > 0;
        final cats = [
          Category(id: _allId, name: tr('Alle Sender')),
          if (!guest) Category(id: _favId, name: tr('Favoriten')),
          if (!guest && (hasRecent || _categoryId == _recentId))
            Category(id: _recentId, name: tr('Zuletzt gesehen')),
          for (final g in myGroups) Category(id: g.id, name: g.name),
          ...order
              .sortGroups(data.categories)
              .where((c) => !order.hiddenGroups.contains(c.id)),
        ];
        final list = _ChannelList(
          channels: channels,
          flags: flags,
          focused: wide ? _focused : null,
          onFocus: wide ? (c) => _focused.value = c : null,
          onOpen: (c) => withPreviewPaused(
              ref, () => playChannel(context, ref, c, channels)),
          onMenu: (c) => showChannelSheet(context, ref, c,
              inRecent: _categoryId == _recentId),
        );

        if (!wide) {
          return Column(children: [
            PageHeader(tr('Live TV'),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (_categoryId == _recentId && hasRecent)
                    IconButton(
                      tooltip: tr('Verlauf löschen'),
                      icon: const Icon(Icons.delete_sweep_rounded),
                      onPressed: () => _clearRecent(context),
                    ),
                  IconButton(
                    tooltip: tr('Gruppen & Sender sortieren'),
                    icon: const Icon(Icons.swap_vert_rounded),
                    onPressed: () => _openReorder(context),
                  ),
                  IconButton(
                    icon: Icon(_searching ? Icons.close : Icons.search),
                    onPressed: () => setState(() {
                      _searching = !_searching;
                      if (!_searching) {
                        _search.clear();
                        _query = '';
                      }
                    }),
                  ),
                ])),
            if (_searching)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: SearchField(
                  controller: _search,
                  hint: tr('Sender suchen'),
                  width: double.infinity,
                  onChanged: (v) => setState(() => _query = v.trim()),
                ),
              ),
            SizedBox(
              height: 44,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: cats.length + 1,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (_, i) {
                  if (i == cats.length) {
                    return ActionChip(
                      avatar: const Icon(Icons.add_rounded, size: 18),
                      label: Text(tr('Gruppe')),
                      onPressed: () => _newGroup(context),
                    );
                  }
                  final c = cats[i];
                  final sel = c.id == _categoryId;
                  final my = MyGroup.isMy(c.id);
                  return GestureDetector(
                    onLongPress: my
                        ? () => _groupMenu(context, c.id, myGroups)
                        : c.id == _recentId
                            ? () => _clearRecent(context)
                            : null,
                    child: ChoiceChip(
                      avatar: c.id == _recentId || my
                          ? Icon(
                              my
                                  ? Icons.folder_special_rounded
                                  : Icons.history_rounded,
                              size: 16,
                              color: sel
                                  ? const Color(0xFF1A0B04)
                                  : (my ? AppColors.accent : AppColors.textDim))
                          : null,
                      label: Text(c.id == _favId ? tr('★ Favoriten') : c.name),
                      selected: sel,
                      showCheckmark: false,
                      labelStyle: TextStyle(
                          color: sel ? const Color(0xFF1A0B04) : AppColors.text,
                          fontWeight: FontWeight.w600),
                      onSelected: (_) => setState(() => _categoryId = c.id),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 6),
            Expanded(child: list),
          ]);
        }

        if (tv) {
          return _tvLayout(
            context,
            cats: cats,
            counts: counts,
            channels: channels,
            flags: flags,
            myGroups: myGroups,
            hasRecent: hasRecent,
          );
        }

        return Row(children: [
          SizedBox(
            width: tv ? 250 : 230,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                PageHeader(tr('Live TV'),
                    padding: const EdgeInsets.fromLTRB(24, 26, 8, 14),
                    trailing: IconButton(
                      tooltip: tr('Gruppen & Sender sortieren'),
                      icon: const Icon(Icons.swap_vert_rounded),
                      onPressed: () => _openReorder(context),
                    )),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(12, 0, 8, 24),
                    children: [
                      for (final c in cats)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 2),
                          child: FocusableTile(
                            selected: c.id == _categoryId,
                            onTap: () => setState(() => _categoryId = c.id),
                            onLongPress: MyGroup.isMy(c.id)
                                ? () => _groupMenu(context, c.id, myGroups)
                                : c.id == _recentId
                                    ? () => _clearRecent(context)
                                    : null,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 10),
                              child: Row(children: [
                                if (c.id == _favId) ...[
                                  const Icon(Icons.star_rounded,
                                      size: 18, color: AppColors.gold),
                                  const SizedBox(width: 8),
                                ],
                                if (c.id == _recentId) ...[
                                  const Icon(Icons.history_rounded,
                                      size: 18, color: AppColors.textDim),
                                  const SizedBox(width: 8),
                                ],
                                if (MyGroup.isMy(c.id)) ...[
                                  Icon(Icons.folder_special_rounded,
                                      size: 18, color: AppColors.accent),
                                  const SizedBox(width: 8),
                                ],
                                Expanded(
                                  child: Text(c.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: c.id == _categoryId
                                            ? FontWeight.w700
                                            : FontWeight.w500,
                                        color: c.id == _categoryId
                                            ? AppColors.text
                                            : AppColors.textDim,
                                      )),
                                ),
                                Text('${counts[c.id] ?? 0}',
                                    style: const TextStyle(
                                        fontSize: 12,
                                        color: AppColors.textFaint)),
                              ]),
                            ),
                          ),
                        ),
                      FocusableTile(
                        onTap: () => _newGroup(context),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 10),
                          child: Row(children: [
                            Icon(Icons.create_new_folder_outlined,
                                size: 18, color: AppColors.accent),
                            const SizedBox(width: 8),
                            Text(tr('Neue Gruppe'),
                                style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.accent)),
                          ]),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Container(width: 1, color: AppColors.line),
          Expanded(
            flex: 5,
            child: Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
                child: Row(children: [
                  Expanded(
                    child: Text(
                      cats
                          .firstWhere((c) => c.id == _categoryId,
                              orElse: () => cats.first)
                          .name,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  if (MyGroup.isMy(_categoryId)) ...[
                    IconButton(
                      tooltip: tr('Gruppe bearbeiten'),
                      icon: const Icon(Icons.edit_rounded),
                      onPressed: () =>
                          _groupMenu(context, _categoryId, myGroups),
                    ),
                    const SizedBox(width: 8),
                  ],
                  if (_categoryId == _recentId && hasRecent) ...[
                    TextButton.icon(
                      onPressed: () => _clearRecent(context),
                      icon: const Icon(Icons.delete_sweep_rounded, size: 18),
                      label: Text(tr('Verlauf löschen')),
                    ),
                    const SizedBox(width: 8),
                  ],
                  SearchField(
                    controller: _search,
                    hint: tr('Sender suchen'),
                    width: 220,
                    onChanged: (v) => setState(() => _query = v.trim()),
                  ),
                ]),
              ),
              Expanded(child: list),
            ]),
          ),
          if (width >= 1100 || tv)
            SizedBox(
              width: tv ? 440 : 400,
              child: ValueListenableBuilder<Channel?>(
                valueListenable: _focused,
                builder: (context, f, _) {
                  final preview = _previewOf(f, channels);
                  return preview == null
                      ? const SizedBox.shrink()
                      : _PreviewPanel(
                          channel: preview,
                          onWatch: () => withPreviewPaused(
                              ref,
                              () =>
                                  playChannel(context, ref, preview, channels)),
                        );
                },
              ),
            ),
        ]);
      },
    );
  }

  /// Android TV: drei ruhige Spalten (Gruppen | Sender | Info), ohne großen
  /// Seitenkopf – Sortieren und Suche als kleine Elemente in den Spaltenköpfen.
  Widget _tvLayout(
    BuildContext context, {
    required List<Category> cats,
    required Map<String, int> counts,
    required List<Channel> channels,
    required ChannelFlags flags,
    required List<MyGroup> myGroups,
    required bool hasRecent,
  }) {
    final current =
        cats.firstWhere((c) => c.id == _categoryId, orElse: () => cats.first);
    final groups = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TvCaps(tr('Live TV'),
            padding: const EdgeInsets.fromLTRB(16, 18, 6, 8),
            trailing: TvIconButton(
              icon: Icons.swap_vert_rounded,
              tooltip: tr('Gruppen & Sender sortieren'),
              onTap: () => _openReorder(context),
            )),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(8, 0, 6, 20),
            children: [
              for (final c in cats)
                _TvGroupRow(
                  category: c,
                  count: counts[c.id] ?? 0,
                  selected: c.id == _categoryId,
                  onTap: () => setState(() => _categoryId = c.id),
                  onLongPress: MyGroup.isMy(c.id)
                      ? () => _groupMenu(context, c.id, myGroups)
                      : c.id == _recentId
                          ? () => _clearRecent(context)
                          : null,
                ),
              _TvGroupRow(
                category: Category(id: '', name: tr('Neue Gruppe')),
                newGroup: true,
                onTap: () => _newGroup(context),
              ),
            ],
          ),
        ),
      ],
    );

    final list = Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 6),
        child: Row(children: [
          Flexible(
            child: Text(_query.isEmpty ? current.name : tr('Suche'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TvText.name.copyWith(fontSize: 11.5)),
          ),
          const SizedBox(width: 6),
          Text('${channels.length}', style: TvText.small),
          const Spacer(),
          if (MyGroup.isMy(_categoryId)) ...[
            TvIconButton(
              icon: Icons.edit_rounded,
              tooltip: tr('Gruppe bearbeiten'),
              onTap: () => _groupMenu(context, _categoryId, myGroups),
            ),
            const SizedBox(width: 4),
          ],
          if (_categoryId == _recentId && hasRecent) ...[
            TvIconButton(
              icon: Icons.delete_sweep_rounded,
              tooltip: tr('Verlauf löschen'),
              onTap: () => _clearRecent(context),
            ),
            const SizedBox(width: 4),
          ],
          TvSearchField(
            controller: _search,
            hint: tr('Sender suchen'),
            width: 140,
            onChanged: (v) => setState(() => _query = v.trim()),
          ),
        ]),
      ),
      Expanded(
        child: channels.isEmpty
            ? EmptyState(
                icon: Icons.tv_off_rounded,
                title: tr('Keine Sender'),
                message: tr(
                    'In dieser Gruppe gibt es nichts – oder alles ist versteckt.'),
              )
            : ListView.builder(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 20),
                itemCount: channels.length,
                itemExtent: 34,
                // Zeilen haben keinen Zustand, der das Herausscrollen
                // überleben müsste – spart je Zeile vier Hüll-Elemente.
                addAutomaticKeepAlives: false,
                itemBuilder: (context, i) {
                  final c = channels[i];
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: _TvChannelItem(
                      channel: c,
                      channels: channels,
                      flags: flags,
                      focused: _focused,
                      autofocus: i == 0,
                      onTap: () => withPreviewPaused(
                          ref, () => playChannel(context, ref, c, channels)),
                      onLongPress: () => showChannelSheet(context, ref, c,
                          inRecent: _categoryId == _recentId),
                    ),
                  );
                },
              ),
      ),
    ]);

    return ColoredBox(
      color: TvColors.bg,
      child: TvColumns(
          // Nach Gruppenwechsel/Suche oben in der neuen Liste beginnen.
          memoryKeys: [
            null,
            (_categoryId, _query)
          ],
          // Anderer Sender in der Info-Spalte → dort wieder vorn beginnen.
          memoryResets: {
            2: _focused
          },
          children: [
            SizedBox(
              width: 170,
              child: DecoratedBox(
                decoration: const BoxDecoration(
                    border: Border(right: BorderSide(color: TvColors.line))),
                child: groups,
              ),
            ),
            Expanded(child: list),
            SizedBox(
              width: 300,
              child: ValueListenableBuilder<Channel?>(
                valueListenable: _focused,
                builder: (context, f, _) {
                  final preview = _previewOf(f, channels);
                  return preview == null
                      ? const ColoredBox(color: TvColors.panel)
                      : _TvInfoPanel(
                          channel: preview,
                          onWatch: () => withPreviewPaused(
                              ref,
                              () =>
                                  playChannel(context, ref, preview, channels)),
                        );
                },
              ),
            ),
          ]),
    );
  }

  Future<void> _openReorder(BuildContext context) async {
    // Kindermodus: Sortieren/Ausblenden nur mit PIN.
    if (!await kidsGuard(context, ref) || !context.mounted) return;
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const ReorderScreen()));
  }

  Future<void> _newGroup(BuildContext context) async {
    final g = await createGroup(context, ref);
    if (g == null || !mounted) return;
    setState(() => _categoryId = g.id);
    ScaffoldMessenger.of(this.context).showSnackBar(SnackBar(
        content: Text(tr('Gruppe angelegt. Sender lange drücken → „Gruppen“, '
            'um sie hinzuzufügen.'))));
  }

  Future<void> _groupMenu(
      BuildContext context, String id, List<MyGroup> groups) async {
    final g = groups.where((x) => x.id == id).firstOrNull;
    if (g == null) return;
    final deleted = await showMyGroupMenu(context, ref, g);
    if (deleted && mounted && _categoryId == id) {
      setState(() => _categoryId = _allId);
    }
  }

  Future<void> _clearRecent(BuildContext context) async {
    if (!await kidsGuard(context, ref) || !context.mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Verlauf löschen')),
        content: Text(tr('Liste der zuletzt gesehenen Sender leeren?')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr('Abbrechen'))),
          FilledButton(
              autofocus: true,
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr('Löschen'))),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(recentProvider.notifier).clear();
    if (mounted && _categoryId == _recentId) {
      setState(() => _categoryId = _allId);
    }
  }

  Map<String, int> _counts(LiveData d, ChannelFlags f, List<String> recents) {
    final m = <String, int>{};
    if (recents.isNotEmpty) {
      m[_recentId] = resolveChannelIds(ref, recents, {
        for (final c in d.channels)
          if (!f.isHidden(c.id)) c.id: c
      }).length;
    }
    for (final c in d.channels) {
      if (f.isHidden(c.id)) continue;
      m[c.categoryId] = (m[c.categoryId] ?? 0) + 1;
      m[_allId] = (m[_allId] ?? 0) + 1;
      if (f.favorites.contains(c.id)) m[_favId] = (m[_favId] ?? 0) + 1;
    }
    return m;
  }

  List<Channel> _filter(LiveData d, ChannelFlags f, SortOrder order,
      List<String> recents, List<MyGroup> myGroups) {
    final q = _query.replaceAll('​', '').trim().toLowerCase();
    Iterable<Channel> it = d.channels.where((c) => !f.isHidden(c.id));
    if (q.isNotEmpty) {
      it = it
          .where((c) => (_lowerNames[c] ??= c.name.toLowerCase()).contains(q));
    } else if (_categoryId == _recentId) {
      // Neueste zuerst – Reihenfolge des Verlaufs.
      final byId = {for (final c in it) c.id: c};
      return resolveChannelIds(ref, recents, byId);
    } else if (MyGroup.isMy(_categoryId)) {
      final g = myGroups.where((x) => x.id == _categoryId).firstOrNull;
      if (g == null) return const [];
      final byId = {for (final c in it) c.id: c};
      return order.sortChannels(g.id, resolveChannelIds(ref, g.channels, byId));
    } else if (_categoryId == _favId) {
      return order.sortChannels(
          _favId, it.where((c) => f.favorites.contains(c.id)).toList());
    } else if (_categoryId != _allId) {
      return order.sortChannels(
          _categoryId, it.where((c) => c.categoryId == _categoryId).toList());
    } else {
      // „Alle Sender“: ausgeblendete Gruppen weglassen
      it = it.where((c) => !order.hiddenGroups.contains(c.categoryId));
    }
    return it.toList();
  }
}

/// Sender in Vorschau/Info: der zuletzt fokussierte, sonst der erste.
Channel? _previewOf(Channel? f, List<Channel> channels) {
  if (f != null && channels.contains(f)) return f;
  return channels.isEmpty ? null : channels.first;
}

/// Ist [c] (aus [channels]) der Sender in Vorschau/Info? Nur die erste
/// Zeile muss dafür die Liste durchsuchen.
bool _isPreview(Channel c, Channel? f, List<Channel> channels) {
  if (identical(f, c)) return true;
  if (!identical(c, channels.first)) return false;
  return f == null || !channels.contains(f);
}

/// Großes EPG kennt den Sender nicht → Kurz-Programm vom Portal holen.
void _wantEpg(WidgetRef ref, Channel c, NowNext nn) {
  if (nn.isEmpty) ref.read(epgProvider.notifier).want(c);
}

class _ChannelList extends StatelessWidget {
  final List<Channel> channels;
  final ChannelFlags flags;
  final ValueListenable<Channel?>? focused;
  final ValueChanged<Channel>? onFocus;
  final ValueChanged<Channel> onOpen;
  final ValueChanged<Channel> onMenu;

  const _ChannelList({
    required this.channels,
    required this.flags,
    required this.onOpen,
    required this.onMenu,
    this.focused,
    this.onFocus,
  });

  @override
  Widget build(BuildContext context) {
    if (channels.isEmpty) {
      return EmptyState(
        icon: Icons.tv_off_rounded,
        title: tr('Keine Sender'),
        message:
            tr('In dieser Gruppe gibt es nichts – oder alles ist versteckt.'),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
      itemCount: channels.length,
      itemExtent: 76,
      addAutomaticKeepAlives: false,
      itemBuilder: (context, i) {
        final c = channels[i];
        return Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: _ChannelItem(
            channel: c,
            channels: channels,
            flags: flags,
            focused: focused,
            autofocus: i == 0 && onFocus != null,
            onTap: () => onOpen(c),
            onLongPress: () => onMenu(c),
            onFocus: onFocus == null ? null : () => onFocus!(c),
          ),
        );
      },
    );
  }
}

/// Eine Senderzeile (Handy/Tablet): beobachtet nur das eigene Programm;
/// die Hervorhebung hängt allein an „bin ich die Vorschau?“.
class _ChannelItem extends ConsumerWidget {
  final Channel channel;
  final List<Channel> channels;
  final ChannelFlags flags;
  final ValueListenable<Channel?>? focused;
  final bool autofocus;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback? onFocus;
  const _ChannelItem({
    required this.channel,
    required this.channels,
    required this.flags,
    required this.focused,
    required this.autofocus,
    required this.onTap,
    required this.onLongPress,
    required this.onFocus,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = channel;
    final nn = ref.watch(nowNextProvider(c));
    _wantEpg(ref, c, nn);
    final label = channelSemantics(c, nn.now);
    Widget tile(bool selected, Widget? child) => FocusableTile(
          autofocus: autofocus,
          selected: selected,
          onTap: onTap,
          onLongPress: onLongPress,
          onFocus: onFocus,
          semanticLabel: label,
          child: child!,
        );
    final row = _ChannelRow(channel: c, flags: flags, nn: nn);
    final f = focused;
    if (f == null) return tile(false, row);
    return ValueSelector<Channel?, bool>(
      listenable: f,
      selector: (v) => _isPreview(c, v, channels),
      builder: (context, sel, child) => tile(sel, child),
      child: row,
    );
  }
}

class _ChannelRow extends StatelessWidget {
  final Channel channel;
  final ChannelFlags flags;
  final NowNext nn;
  const _ChannelRow(
      {required this.channel, required this.flags, required this.nn});

  @override
  Widget build(BuildContext context) {
    final c = channel;
    final now = nn.now;
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(children: [
        SizedBox(
          width: 30,
          child: Text('${c.number}',
              textAlign: TextAlign.right,
              style: const TextStyle(
                  fontSize: 13,
                  color: AppColors.textFaint,
                  fontFeatures: [FontFeature.tabularFigures()])),
        ),
        const SizedBox(width: 12),
        ChannelLogo(name: c.name, url: c.logoUrl, size: 40),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Flexible(
                  child: Text(c.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.titleSmall?.copyWith(fontSize: 15)),
                ),
                if (flags.favorites.contains(c.id)) ...[
                  const SizedBox(width: 6),
                  const Icon(Icons.star_rounded,
                      size: 15, color: AppColors.gold),
                ],
                if (flags.locked.contains(c.id)) ...[
                  const SizedBox(width: 6),
                  const Icon(Icons.lock_rounded,
                      size: 14, color: AppColors.textDim),
                ],
                if (c.hasCatchup) ...[
                  const SizedBox(width: 6),
                  Semantics(
                    label: archiveLabel(c.catchupDays),
                    child: const Icon(Icons.history_rounded,
                        size: 15, color: AppColors.catchup),
                  ),
                  // Breite Zeilen: Archivfenster als winzige Zahl („7d“).
                  if (MediaQuery.sizeOf(context).width >= 900) ...[
                    const SizedBox(width: 3),
                    ExcludeSemantics(
                      child: Text(archiveShort(c.catchupDays),
                          style: t.labelSmall?.copyWith(
                              fontSize: 10.5, color: AppColors.catchup)),
                    ),
                  ],
                ],
                if (flags.unavailable.contains(c.id)) ...[
                  const SizedBox(width: 6),
                  const Icon(Icons.public_off_rounded,
                      size: 15, color: AppColors.gold),
                ],
                VariantCountBadge(channelId: c.id),
              ]),
              const SizedBox(height: 4),
              if (flags.unavailable.contains(c.id))
                Text(tr('Zuletzt an deinem Standort nicht verfügbar'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: t.bodySmall?.copyWith(color: AppColors.gold))
              else if (now != null) ...[
                Text(
                  now.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: t.bodySmall?.copyWith(fontSize: 13),
                ),
                const SizedBox(height: 5),
                Row(children: [
                  SizedBox(
                    width: 90,
                    child: MinuteBuilder(
                        builder: (_, t) =>
                            ThinProgress(value: now.progressAt(t), height: 3)),
                  ),
                  const SizedBox(width: 8),
                  Text(trf('bis {0}', [hm.format(now.end)]),
                      style: const TextStyle(
                          fontSize: 11, color: AppColors.textFaint)),
                ]),
              ] else
                Text(tr('Keine Programminfo'),
                    style: t.bodySmall?.copyWith(color: AppColors.textFaint)),
            ],
          ),
        ),
      ]),
    );
  }
}

/// Rechte Spalte: großes Bild, Jetzt/Danach, Programm, Catch-up-Einstieg.
class _PreviewPanel extends ConsumerWidget {
  final Channel channel;
  final VoidCallback onWatch;
  const _PreviewPanel({required this.channel, required this.onWatch});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = channel;
    final t = Theme.of(context).textTheme;
    final nn = ref.watch(nowNextProvider(c));
    final now = nn.now;
    final upcoming = nn.upcoming(4);
    final livePreview = ref.watch(livePreviewEnabledProvider).value ?? true;

    return Container(
      color: AppColors.surface,
      // Volle Höhe wie zuvor die ListView (die Zeile richtet sonst mittig aus).
      constraints: const BoxConstraints.expand(),
      child: SingleChildScrollView(
        // Spalte statt ListView: baut pro Senderwechsel keine Hüllen je Eintrag.

        padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (livePreview)
            LivePreview(channel: c, onOpen: onWatch)
          else
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: GeneratedArt(
                  seed: now?.title ?? c.name,
                  child: Stack(children: [
                    const Positioned(left: 12, top: 12, child: LiveBadge()),
                    Positioned(
                      right: 12,
                      top: 12,
                      child:
                          ChannelLogo(name: c.name, url: c.logoUrl, size: 30),
                    ),
                    Center(
                      child: Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.35),
                          shape: BoxShape.circle,
                          border: Border.all(
                              color: Colors.white.withValues(alpha: 0.5)),
                        ),
                        child: const Icon(Icons.play_arrow_rounded,
                            color: Colors.white, size: 34),
                      ),
                    ),
                  ]),
                ),
              ),
            ),
          const SizedBox(height: 18),
          Text('${c.number}  ·  ${c.name}',
              style: t.labelSmall?.copyWith(color: AppColors.textDim)),
          const SizedBox(height: 8),
          Text(now?.title ?? c.name,
              style: t.headlineSmall?.copyWith(fontFamily: 'InterDisplay')),
          if (now != null) ...[
            const SizedBox(height: 10),
            Row(children: [
              Text('${hm.format(now.start)} – ${hm.format(now.end)}',
                  style: t.bodySmall),
              if (now.genre != null) ...[
                const SizedBox(width: 10),
                Tag(now.genre!.toUpperCase()),
              ],
              const Spacer(),
              MinuteBuilder(
                  builder: (_, at) => Text(
                      trf('noch {0} Min.', [now.end.difference(at).inMinutes]),
                      style: t.bodySmall)),
            ]),
            const SizedBox(height: 8),
            MinuteBuilder(
                builder: (_, at) =>
                    ThinProgress(value: now.progressAt(at), height: 4)),
            if (now.description != null) ...[
              const SizedBox(height: 14),
              Text(now.description!,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: t.bodyMedium?.copyWith(height: 1.5)),
            ],
          ],
          const SizedBox(height: 18),
          Row(children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: onWatch,
                icon: const Icon(Icons.play_arrow_rounded),
                label: Text(tr('Ansehen')),
              ),
            ),
            if (c.hasCatchup && now != null) ...[
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.catchup,
                    side: const BorderSide(color: AppColors.line),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: () => withPreviewPaused(
                      ref, () => playCatchup(context, ref, c, now)),
                  icon: const Icon(Icons.replay_rounded),
                  label: Text(tr('Von Anfang')),
                ),
              ),
            ],
            if (c.hasCatchup) ...[
              const SizedBox(width: 10),
              Tooltip(
                message: archiveLabel(c.catchupDays),
                child: IconButton.outlined(
                  style: IconButton.styleFrom(
                    foregroundColor: AppColors.catchup,
                    side: const BorderSide(color: AppColors.line),
                    padding: const EdgeInsets.all(14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: () =>
                      showChannelSheet(context, ref, c, archiveFirst: true),
                  icon: const Icon(Icons.history_rounded),
                ),
              ),
            ],
          ]),
          if (upcoming.isNotEmpty) ...[
            const SizedBox(height: 26),
            Text(tr('DANACH'), style: t.labelSmall),
            const SizedBox(height: 8),
            for (final e in upcoming)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 7),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 52,
                      child: Text(hm.format(e.start),
                          style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textDim,
                              fontFeatures: [FontFeature.tabularFigures()])),
                    ),
                    Expanded(
                      child: Text(e.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 14, color: AppColors.text)),
                    ),
                  ],
                ),
              ),
          ],
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Android TV
// ---------------------------------------------------------------------------

/// Kompakte Gruppenzeile (26 dp) mit Anzahl rechts.
class _TvGroupRow extends StatelessWidget {
  final Category category;
  final int count;
  final bool selected;
  final bool newGroup;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  const _TvGroupRow({
    required this.category,
    required this.onTap,
    this.count = 0,
    this.selected = false,
    this.newGroup = false,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final c = category;
    final icon = newGroup
        ? (Icons.create_new_folder_outlined, AppColors.accent)
        : c.id == _favId
            ? (Icons.star_rounded, AppColors.gold)
            : c.id == _recentId
                ? (Icons.history_rounded, TvColors.textDim)
                : MyGroup.isMy(c.id)
                    ? (Icons.folder_special_rounded, AppColors.accent)
                    : null;
    return SizedBox(
      height: 28,
      child: TvTile(
        selected: selected,
        radius: const BorderRadius.all(Radius.circular(7)),
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(children: [
            if (icon != null) ...[
              Icon(icon.$1, size: 11, color: icon.$2),
              const SizedBox(width: 6),
            ],
            Expanded(
              child: Text(c.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 9,
                    fontWeight: selected || newGroup
                        ? FontWeight.w600
                        : FontWeight.w500,
                    color: newGroup
                        ? AppColors.accent
                        : selected
                            ? TvColors.text
                            : TvColors.textDim,
                  )),
            ),
            if (!newGroup) Text('$count', style: TvText.small),
          ]),
        ),
      ),
    );
  }
}

/// Eine TV-Senderzeile: beobachtet nur das eigene Programm; die
/// Hervorhebung („in der Info-Spalte“) hängt allein an [focused] – pro ▼
/// bauen so nur die alte und die neue Zeile neu.
class _TvChannelItem extends ConsumerWidget {
  final Channel channel;
  final List<Channel> channels;
  final ChannelFlags flags;
  final ValueNotifier<Channel?> focused;
  final bool autofocus;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  const _TvChannelItem({
    required this.channel,
    required this.channels,
    required this.flags,
    required this.focused,
    required this.autofocus,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = channel;
    final nn = ref.watch(nowNextProvider(c));
    _wantEpg(ref, c, nn);
    final label = channelSemantics(c, nn.now);
    return ValueSelector<Channel?, bool>(
      listenable: focused,
      selector: (v) => _isPreview(c, v, channels),
      child: _TvChannelRow(channel: c, flags: flags, nn: nn),
      builder: (context, sel, child) => TvTile(
        autofocus: autofocus,
        selected: sel,
        radius: const BorderRadius.all(Radius.circular(7)),
        onTap: onTap,
        onLongPress: onLongPress,
        onFocus: () => focused.value = c,
        semanticLabel: label,
        child: child!,
      ),
    );
  }
}

/// Senderzeile (32 dp): Nummer, Logo, Name, laufende Sendung + Fortschritt.
class _TvChannelRow extends StatelessWidget {
  final Channel channel;
  final ChannelFlags flags;
  final NowNext nn;
  const _TvChannelRow(
      {required this.channel, required this.flags, required this.nn});

  @override
  Widget build(BuildContext context) {
    final c = channel;
    final now = nn.now;
    final unavailable = flags.unavailable.contains(c.id);
    Widget flag(IconData i, Color col) => Padding(
          padding: const EdgeInsets.only(left: 4),
          child: Icon(i, size: 9, color: col),
        );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Row(children: [
        SizedBox(
          width: 22,
          child: Text('${c.number}',
              textAlign: TextAlign.right, style: TvText.small),
        ),
        const SizedBox(width: 8),
        ChannelLogo(name: c.name, url: c.logoUrl, size: 20),
        const SizedBox(width: 9),
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Flexible(
                  child: Text(c.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TvText.name),
                ),
                if (flags.favorites.contains(c.id))
                  flag(Icons.star_rounded, AppColors.gold),
                if (flags.locked.contains(c.id))
                  flag(Icons.lock_rounded, TvColors.textDim),
                if (c.hasCatchup)
                  Semantics(
                      label: archiveLabel(c.catchupDays),
                      child: flag(Icons.history_rounded, AppColors.catchup)),
                if (unavailable) flag(Icons.public_off_rounded, AppColors.gold),
                VariantCountBadge(channelId: c.id, compact: true),
              ]),
              const SizedBox(height: 1.5),
              Text(
                unavailable
                    ? tr('Zuletzt an deinem Standort nicht verfügbar')
                    : now?.title ?? tr('Keine Programminfo'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TvText.body.copyWith(
                    fontSize: 8,
                    color: unavailable
                        ? AppColors.gold
                        : now == null
                            ? TvColors.textFaint
                            : TvColors.textDim),
              ),
            ],
          ),
        ),
        if (now != null && !unavailable) ...[
          const SizedBox(width: 10),
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(trf('bis {0}', [hm.format(now.end)]),
                  style: TvText.small.copyWith(fontSize: 7.5)),
              const SizedBox(height: 3),
              MinuteBuilder(
                  builder: (_, t) =>
                      TvProgress(value: now.progressAt(t), width: 36)),
            ],
          ),
        ],
      ]),
    );
  }
}

/// Rechte Spalte: Vorschau, laufende Sendung, Danach, kleine Aktionen.
class _TvInfoPanel extends ConsumerWidget {
  final Channel channel;
  final VoidCallback onWatch;
  const _TvInfoPanel({required this.channel, required this.onWatch});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = channel;
    final nn = ref.watch(nowNextProvider(c));
    final now = nn.now;
    final next = nn.next;
    final livePreview = ref.watch(livePreviewEnabledProvider).value ?? true;
    const radius = BorderRadius.all(Radius.circular(10));

    return Container(
      color: TvColors.panel,
      // Volle Höhe wie zuvor die ListView (die Zeile richtet sonst mittig aus).
      constraints: const BoxConstraints.expand(),
      child: SingleChildScrollView(
        // Spalte statt ListView: baut pro Senderwechsel keine Hüllen je Eintrag.

        padding: const EdgeInsets.fromLTRB(18, 18, 22, 20),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (livePreview)
            LivePreview(channel: c, onOpen: onWatch, radius: radius)
          else
            ClipRRect(
              borderRadius: radius,
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: GeneratedArt(
                  seed: now?.title ?? c.name,
                  child: Stack(children: [
                    const Positioned(left: 8, top: 8, child: LiveBadge()),
                    Center(
                        child: ChannelLogo(
                            name: c.name, url: c.logoUrl, size: 34)),
                  ]),
                ),
              ),
            ),
          const SizedBox(height: 14),
          Text('${c.number} · ${c.name}'.toUpperCase(),
              maxLines: 1, overflow: TextOverflow.ellipsis, style: TvText.caps),
          const SizedBox(height: 5),
          Text(now?.title ?? c.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TvText.title.copyWith(fontSize: 14)),
          if (now != null) ...[
            const SizedBox(height: 6),
            Row(children: [
              Expanded(
                child: Text(
                    [
                      '${hm.format(now.start)} – ${hm.format(now.end)}',
                      if (now.genre != null && now.genre!.isNotEmpty)
                        now.genre!,
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TvText.body),
              ),
              MinuteBuilder(
                  builder: (_, at) => Text(
                      trf('noch {0} Min.', [now.end.difference(at).inMinutes]),
                      style: TvText.small)),
            ]),
            const SizedBox(height: 6),
            MinuteBuilder(
                builder: (_, at) =>
                    TvProgress(value: now.progressAt(at), height: 2.5)),
            if (now.description != null && now.description!.isNotEmpty) ...[
              const SizedBox(height: 9),
              Text(now.description!,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TvText.body
                      .copyWith(color: TvColors.textFaint, height: 1.45)),
            ],
          ] else ...[
            const SizedBox(height: 6),
            Text(tr('Keine Programminfo'), style: TvText.body),
          ],
          if (next != null) ...[
            const SizedBox(height: 9),
            Text.rich(
              TextSpan(children: [
                TextSpan(
                    text: '${trf('Danach: {0}', [hm.format(next.start)])}  ',
                    style: const TextStyle(color: TvColors.textFaint)),
                TextSpan(text: next.title),
              ]),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TvText.body,
            ),
          ],
          const SizedBox(height: 12),
          Wrap(spacing: 6, runSpacing: 6, children: [
            TvChip(
              label: tr('Ansehen'),
              icon: Icons.play_arrow_rounded,
              primary: true,
              onTap: onWatch,
            ),
            if (c.hasCatchup && now != null)
              TvChip(
                label: tr('Von Anfang'),
                icon: Icons.replay_rounded,
                color: AppColors.catchup,
                onTap: () => withPreviewPaused(
                    ref, () => playCatchup(context, ref, c, now)),
              ),
            // Fernseher: Archivfenster direkt im Etikett („Archiv · 7 Tage“).
            if (c.hasCatchup)
              TvChip(
                label: archiveLabel(c.catchupDays),
                icon: Icons.history_rounded,
                color: AppColors.catchup,
                onTap: () =>
                    showChannelSheet(context, ref, c, archiveFirst: true),
              ),
          ]),
        ]),
      ),
    );
  }
}
