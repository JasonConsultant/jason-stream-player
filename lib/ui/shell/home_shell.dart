import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app.dart';
import '../../core/theme.dart';
import '../../state/providers.dart';
import '../guide/guide_screen.dart';
import '../live/live_screen.dart';
import '../portals/portal_switcher.dart';
import '../search/search_screen.dart';
import '../settings/settings_screen.dart';
import '../widgets/common.dart';
import '../vod/vod_screen.dart';
import 'launch.dart';
import 'update_dialog.dart';

class _Dest {
  final String label;
  final IconData icon;
  final IconData activeIcon;
  const _Dest(this.label, this.icon, this.activeIcon);
}

const _dests = [
  _Dest('Live TV', Icons.live_tv_outlined, Icons.live_tv),
  _Dest('TV-Guide', Icons.view_timeline_outlined, Icons.view_timeline),
  _Dest('Filme', Icons.movie_outlined, Icons.movie),
  _Dest('Serien', Icons.video_library_outlined, Icons.video_library),
  _Dest('Suche', Icons.search_rounded, Icons.manage_search_rounded),
  _Dest('Einstellungen', Icons.settings_outlined, Icons.settings),
];

/// Hauptnavigation. Breit (Tablet/TV): Seitenleiste. Schmal (Handy): unten.
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  late int _index = initialTabFromLaunch();
  final _visited = <int>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) runLaunchAction(context, ref);
      Future.delayed(const Duration(seconds: 4), () {
        if (mounted) autoCheckForUpdate(context, ref);
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final tv = ref.watch(isTvProvider);
    final wide = tv || MediaQuery.sizeOf(context).width >= 900;
    _visited.add(_index);

    // Tabs erst beim ersten Öffnen bauen (spart Ladezeit), dann behalten.
    final pages = [
      for (var i = 0; i < _dests.length; i++)
        _visited.contains(i) ? _page(i) : const SizedBox.shrink(),
    ];
    final body = IndexedStack(index: _index, children: pages);

    if (!wide) {
      return Scaffold(
        body: SafeArea(bottom: false, child: body),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _index,
          labelBehavior: NavigationDestinationLabelBehavior.onlyShowSelected,
          onDestinationSelected: (i) => setState(() => _index = i),
          destinations: [
            for (final d in _dests)
              NavigationDestination(
                icon: Icon(d.icon),
                selectedIcon: Icon(d.activeIcon),
                label: d.label == 'Einstellungen' ? tr('Mehr') : tr(d.label),
              ),
          ],
        ),
      );
    }

    return Scaffold(
      body: Row(children: [
        _SideBar(
          index: _index,
          tv: tv,
          onSelect: (i) => setState(() => _index = i),
        ),
        Expanded(child: body),
      ]),
    );
  }

  Widget _page(int i) => switch (i) {
        0 => const LiveScreen(),
        1 => const GuideScreen(),
        2 => const VodScreen(series: false),
        3 => const VodScreen(series: true),
        4 => const SearchScreen(),
        _ => const SettingsScreen(),
      };
}

class _SideBar extends ConsumerWidget {
  final int index;
  final bool tv;
  final ValueChanged<int> onSelect;
  const _SideBar(
      {required this.index, required this.tv, required this.onSelect});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      width: tv ? 248 : 220,
      color: AppColors.surface,
      padding: const EdgeInsets.fromLTRB(16, 28, 16, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(left: 8),
            child: Wordmark(size: 20),
          ),
          const SizedBox(height: 36),
          for (var i = 0; i < _dests.length; i++) ...[
            if (i == _dests.length - 1) const Spacer(),
            _SideItem(
              dest: _dests[i],
              selected: i == index,
              autofocus: i == index,
              onTap: () => onSelect(i),
            ),
            const SizedBox(height: 4),
          ],
          const SizedBox(height: 12),
          const PortalButton(),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.only(left: 10),
            child: LiveClock(style: Theme.of(context).textTheme.bodySmall),
          ),
        ],
      ),
    );
  }
}

class _SideItem extends StatefulWidget {
  final _Dest dest;
  final bool selected;
  final bool autofocus;
  final VoidCallback onTap;
  const _SideItem({
    required this.dest,
    required this.selected,
    required this.autofocus,
    required this.onTap,
  });

  @override
  State<_SideItem> createState() => _SideItemState();
}

class _SideItemState extends State<_SideItem> {
  bool _focus = false;

  @override
  Widget build(BuildContext context) {
    final sel = widget.selected;
    return Focus(
      onFocusChange: (f) {
        setState(() => _focus = f);
        if (f) widget.onTap(); // TV: Fokus wechselt den Bereich direkt
      },
      child: InkWell(
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(12),
        canRequestFocus: false,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          decoration: BoxDecoration(
            color: sel ? AppColors.accentSoft : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color: _focus ? AppColors.accent : Colors.transparent, width: 2),
          ),
          child: Row(children: [
            Icon(sel ? widget.dest.activeIcon : widget.dest.icon,
                size: 22, color: sel ? AppColors.accent : AppColors.textDim),
            const SizedBox(width: 14),
            Text(
              tr(widget.dest.label),
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 15,
                fontWeight: sel ? FontWeight.w700 : FontWeight.w500,
                color: sel ? AppColors.text : AppColors.textDim,
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
