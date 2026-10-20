import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../models/models.dart';
import '../../state/my_groups.dart';
import '../../state/providers.dart';
import '../widgets/artwork.dart';

/// Gruppen und Sender umsortieren, Gruppen ausblenden.
///
/// Touch: am Griff ziehen. Fernbedienung: OK nimmt einen Eintrag auf,
/// ▲▼ verschiebt ihn, OK legt ihn ab.
class ReorderScreen extends ConsumerStatefulWidget {
  const ReorderScreen({super.key});

  @override
  ConsumerState<ReorderScreen> createState() => _ReorderScreenState();
}

class _ReorderScreenState extends ConsumerState<ReorderScreen> {
  String? _group; // null = Gruppen-Liste, sonst Sender dieser Gruppe

  @override
  Widget build(BuildContext context) {
    final live = ref.watch(liveDataProvider).value;
    final order = ref.watch(sortOrderProvider).value ?? SortOrder.empty;
    final flags = ref.watch(channelFlagsProvider).value ?? ChannelFlags.empty;
    final myGroups = ref.watch(myGroupsProvider).value ?? const <MyGroup>[];
    if (live == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final notifier = ref.read(sortOrderProvider.notifier);

    final Widget body;
    final String title;
    if (_group == null) {
      title = tr('Gruppen sortieren');
      final groups = [
        Category(id: '__fav', name: tr('★ Favoriten')),
        ...order.sortGroups(live.categories),
      ];
      body = _SortableList<Category>(
        key: const ValueKey('groups'),
        items: groups.skip(1).toList(),
        header: Column(mainAxisSize: MainAxisSize.min, children: [
          _Row(
            title: groups.first.name,
            subtitle: tr('Reihenfolge der Favoriten ändern'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => setState(() => _group = '__fav'),
          ),
          for (final g in myGroups)
            _Row(
              leading: const Icon(Icons.folder_special_rounded,
                  color: AppColors.accent),
              title: g.name,
              subtitle: trf('{0} Sender', [g.channels.length]),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => setState(() => _group = g.id),
            ),
        ]),
        id: (c) => c.id,
        build: (c, moving) => _Row(
          title: c.name,
          moving: moving,
          dim: order.hiddenGroups.contains(c.id),
          subtitle:
              trf('{0} Sender', [
            live.channels.where((x) => x.categoryId == c.id).length
          ]),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(
              tooltip: order.hiddenGroups.contains(c.id)
                  ? tr('Einblenden')
                  : tr('Ausblenden'),
              icon: Icon(order.hiddenGroups.contains(c.id)
                  ? Icons.visibility_off_rounded
                  : Icons.visibility_rounded),
              onPressed: () {
                final h = {...order.hiddenGroups};
                h.contains(c.id) ? h.remove(c.id) : h.add(c.id);
                notifier.setHiddenGroups(h);
              },
            ),
            IconButton(
              tooltip: tr('Sender sortieren'),
              icon: const Icon(Icons.chevron_right_rounded),
              onPressed: () => setState(() => _group = c.id),
            ),
          ]),
        ),
        onReorder: (ids) => notifier.setGroups(ids),
      );
    } else {
      final g = _group!;
      final my = myGroups.where((x) => x.id == g).firstOrNull;
      final byId = {for (final c in live.channels) c.id: c};
      final source = g == '__fav'
          ? live.channels.where((c) => flags.favorites.contains(c.id)).toList()
          : my != null
              ? [
                  for (final id in my.channels)
                    if (byId[id] != null) byId[id]!,
                ]
              : live.channels.where((c) => c.categoryId == g).toList();
      title = g == '__fav'
          ? tr('Favoriten sortieren')
          : my != null
              ? my.name
              : live.categories
              .firstWhere((c) => c.id == g,
                  orElse: () => Category(id: '', name: tr('Sender')))
              .name;
      body = _SortableList<Channel>(
        key: ValueKey('ch_$g'),
        items: order.sortChannels(g, source),
        id: (c) => c.id,
        build: (c, moving) => _Row(
          title: c.name,
          moving: moving,
          leading: ChannelLogo(name: c.name, url: c.logoUrl, size: 30),
        ),
        onReorder: (ids) => notifier.setChannels(g, ids),
      );
    }

    return PopScope(
      canPop: _group == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _group = null);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(title),
          actions: [
            if (_group == null)
              TextButton.icon(
                onPressed: () async {
                  await notifier.reset();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: Text(tr('Ursprüngliche Reihenfolge wiederhergestellt'))));
                  }
                },
                icon: const Icon(Icons.restart_alt_rounded),
                label: Text(tr('Zurücksetzen')),
              ),
          ],
        ),
        body: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
            child: Text(
              tr('Am Griff ziehen – oder mit der Fernbedienung: OK aufnehmen, '
                '▲▼ verschieben, OK ablegen.'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          Expanded(child: body),
        ]),
      ),
    );
  }
}

class _SortableList<T> extends StatefulWidget {
  final List<T> items;
  final String Function(T) id;
  final Widget Function(T, bool moving) build;
  final ValueChanged<List<String>> onReorder;
  final Widget? header;
  const _SortableList({
    super.key,
    required this.items,
    required this.id,
    required this.build,
    required this.onReorder,
    this.header,
  });

  @override
  State<_SortableList<T>> createState() => _SortableListState<T>();
}

class _SortableListState<T> extends State<_SortableList<T>> {
  late List<T> _items = [...widget.items];
  int? _moving;
  final _nodes = <String, FocusNode>{};

  @override
  void didUpdateWidget(covariant _SortableList<T> old) {
    super.didUpdateWidget(old);
    if (_moving == null) _items = [...widget.items];
  }

  @override
  void dispose() {
    for (final n in _nodes.values) {
      n.dispose();
    }
    super.dispose();
  }

  void _commit() => widget.onReorder([for (final x in _items) widget.id(x)]);

  void _move(int from, int to) {
    if (to < 0 || to >= _items.length) return;
    setState(() {
      final x = _items.removeAt(from);
      _items.insert(to, x);
      _moving = to;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _nodes[widget.id(_items[to])]?.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    return ReorderableListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 32),
      header: widget.header,
      buildDefaultDragHandles: false,
      itemCount: _items.length,
      onReorderItem: (from, to) {
        setState(() => _items.insert(to, _items.removeAt(from)));
        _commit();
      },
      itemBuilder: (context, i) {
        final item = _items[i];
        final key = widget.id(item);
        final node = _nodes.putIfAbsent(key, FocusNode.new);
        final moving = _moving == i;
        return Focus(
          key: ValueKey(key),
          focusNode: node,
          onKeyEvent: (n, e) {
            if (e is! KeyDownEvent) return KeyEventResult.ignored;
            final k = e.logicalKey;
            if (k == LogicalKeyboardKey.select ||
                k == LogicalKeyboardKey.enter) {
              if (moving) {
                setState(() => _moving = null);
                _commit();
              } else {
                setState(() => _moving = i);
              }
              return KeyEventResult.handled;
            }
            if (moving && k == LogicalKeyboardKey.arrowUp) {
              _move(i, i - 1);
              return KeyEventResult.handled;
            }
            if (moving && k == LogicalKeyboardKey.arrowDown) {
              _move(i, i + 1);
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: Builder(builder: (context) {
            final focused = Focus.of(context).hasFocus;
            return Container(
              margin: const EdgeInsets.only(bottom: 4),
              decoration: BoxDecoration(
                color: moving
                    ? AppColors.accentSoft
                    : focused
                        ? AppColors.surface3
                        : AppColors.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                    color: focused || moving
                        ? AppColors.accent
                        : Colors.transparent,
                    width: 2),
              ),
              child: Row(children: [
                ReorderableDragStartListener(
                  index: i,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12, vertical: 16),
                    child: Icon(Icons.drag_indicator_rounded,
                        color: AppColors.textFaint),
                  ),
                ),
                Expanded(child: widget.build(item, moving)),
              ]),
            );
          }),
        );
      },
    );
  }
}

class _Row extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final bool moving;
  final bool dim;
  final VoidCallback? onTap;
  const _Row({
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.moving = false,
    this.dim = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) => ListTile(
        onTap: onTap,
        leading: leading,
        title: Text(title,
            style: TextStyle(
                fontWeight: FontWeight.w600,
                color: dim ? AppColors.textFaint : AppColors.text)),
        subtitle: moving
            ? Text(tr('▲▼ verschieben · OK ablegen'),
                style: TextStyle(color: AppColors.accent))
            : subtitle == null
                ? null
                : Text(dim ? trf('{0} · ausgeblendet', [subtitle]) : subtitle!),
        trailing: trailing,
      );
}
