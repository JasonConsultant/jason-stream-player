import 'text_size_chooser.dart';
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/strings.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app.dart';
import '../../core/platform_info.dart';
import '../../core/theme.dart';
import '../../core/tv_home.dart';
import '../../state/providers.dart';
import '../../state/shell_tab.dart';
import '../../state/profile_mode.dart' show profileModeProvider;
import '../guide/guide_screen.dart';
import '../home/home_screen.dart';
import '../live/live_screen.dart';
import '../portals/portal_switcher.dart';
import '../search/search_screen.dart';
import '../settings/profile_modes.dart' show ProfileBadge;
import '../settings/settings_screen.dart';
import '../tv/tv_safe.dart';
import '../widgets/common.dart';
import '../widgets/voice_search.dart';
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
  _Dest('Start', Icons.home_outlined, Icons.home_rounded),
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
  late int _index = initialTabFromLaunch() ??
      (ref.read(storageProvider).value?.option('starttab', 'home') == 'live'
          ? 1
          : 0);
  final _visited = <int>{};
  Timer? _tvHomeTimer;

  /// TV: Fokus-Knoten der Leisten-Einträge (für „Zurück“ → Leiste).
  final _railNodes = [
    for (final d in _dests) FocusNode(debugLabel: 'rail ${d.label}'),
  ];
  final _railScope = FocusNode(
      debugLabel: 'rail', canRequestFocus: false, skipTraversal: true);

  /// Zweimal Zurück auf dem Start-Tab beendet die App.
  final _exit = BackToExit();

  /// TV: zuletzt fokussiertes Inhaltselement je Tab (▶ aus der Leiste).
  final _lastContent = <int, FocusNode>{};

  /// Umschließt den Inhalt je Tab (nicht fokussierbar), um darin ein Ziel
  /// für den ersten Fokus zu finden.
  final _pageNodes = [
    for (final d in _dests)
      FocusNode(
          debugLabel: 'page ${d.label}',
          canRequestFocus: false,
          skipTraversal: true),
  ];

  /// Je Tab: Elemente, die Zurück zuerst bekommen (z. B. offene Suche).
  final _backHandlers = [for (final _ in _dests) <bool Function()>[]];

  @visibleForTesting
  List<FocusNode> get debugRailNodes => _railNodes;

  bool _inRail(FocusNode f) =>
      f == _railScope || f.ancestors.contains(_railScope);

  void _trackFocus() {
    final f = FocusManager.instance.primaryFocus;
    final c = f?.context;
    // TV: Fokus „verloren“ (z. B. fokussiertes Element beim Neuaufbau
    // entfernt → Fokus beim Wurzelbereich)? Dann gleich wieder in den
    // Inhalt – sonst landet die nächste Taste in der Leiste.
    if (mounted && _nothingFocused(f) && ref.read(isTvProvider)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _nothingFocused(FocusManager.instance.primaryFocus)) {
          _focusContent();
        }
      });
      return;
    }
    if (f == null || c == null || !mounted || _inRail(f)) return;
    // Nur Elemente dieser Seite (nicht aus Dialogen/Blättern darüber).
    if (ModalRoute.of(c) != ModalRoute.of(context)) return;
    _lastContent[_index] = f;
  }

  /// ▶ in der Leiste: zurück zum zuletzt fokussierten Inhaltselement des
  /// Tabs; sonst entscheidet die normale Richtungsnavigation.
  final _railOpen = ValueNotifier(false);

  @visibleForTesting
  bool get debugRailOpen => _railOpen.value;

  /// Nach einem Reiterwechsel in den Inhalt springen – wartet ggf. ein paar
  /// Bilder, bis die Seite (beim ersten Öffnen) fokussierbare Elemente hat.
  void _enterContentSoon([int tries = 0]) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_railRight() || _focusContent()) return;
      if (tries < 20) {
        Future.delayed(const Duration(milliseconds: 50),
            () => _enterContentSoon(tries + 1));
      }
    });
  }

  bool _railRight() {
    final n = _lastContent[_index];
    final c = n?.context;
    if (n == null || c == null || !c.mounted || !n.canRequestFocus) {
      return false;
    }
    n.requestFocus();
    return true;
  }

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_trackFocus);
    FocusManager.instance.addEarlyKeyEventHandler(_focusFallback);
    FocusManager.instance.addEarlyKeyEventHandler(_searchKey);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // TV: Start im Inhalt (erste Kachel), nicht in der Leiste.
      if (ref.read(isTvProvider) &&
          _nothingFocused(FocusManager.instance.primaryFocus)) {
        _focusContent();
      }
      runLaunchAction(context, ref);
      // TV, erster Start: Schriftgröße einmal abfragen.
      TextSizeChooser.maybeShow(context, ref);
      Future.delayed(const Duration(seconds: 4), () {
        if (mounted) autoCheckForUpdate(context, ref);
      });
      _scheduleTvHomeSync(const Duration(seconds: 6));
    });
    // Android TV: Favoriten-Zeile auf dem Startbildschirm nachführen, wenn
    // sich Favoriten oder EPG ändern (gebündelt, 2 s Verzögerung).
    ref.listenManual(channelFlagsProvider, (_, __) => _scheduleTvHomeSync());
    ref.listenManual(epgProvider, (_, __) => _scheduleTvHomeSync());
    ref.listenManual(profileModeProvider, (_, __) => _scheduleTvHomeSync());
    // Blaue Taste im Player: zum TV-Guide wechseln.
    ref.listenManual(shellTabRequestProvider, (_, tab) {
      if (tab == null || !mounted) return;
      setState(() => _index = tab);
      ref.read(shellTabRequestProvider.notifier).clear();
    });
  }

  void _scheduleTvHomeSync([Duration delay = const Duration(seconds: 2)]) {
    // Nicht über isTvProvider abkürzen: der ist beim ersten Frame oft noch
    // nicht aufgelöst (false) – TvHome.sync prüft selbst (PlatformInfo.isTv).
    if (!PlatformInfo.isAndroid) return;
    _tvHomeTimer?.cancel();
    _tvHomeTimer = Timer(delay, () {
      if (mounted) TvHome.sync(ref);
    });
  }

  @override
  void dispose() {
    _railOpen.dispose();
    _tvHomeTimer?.cancel();
    _exit.reset();
    FocusManager.instance.removeListener(_trackFocus);
    FocusManager.instance.removeEarlyKeyEventHandler(_focusFallback);
    FocusManager.instance.removeEarlyKeyEventHandler(_searchKey);
    for (final n in [..._railNodes, ..._pageNodes]) {
      n.dispose();
    }
    _railScope.dispose();
    super.dispose();
  }

  /// TV: Hat noch nichts in dieser Seite den Fokus (z. B. der Start-Tab
  /// lädt noch und hat nichts per Autofokus gewählt), holt die erste
  /// Richtungstaste bzw. OK den Fokus in den Inhalt – nicht in die Leiste.
  KeyEventResult _focusFallback(KeyEvent e) {
    if (e is! KeyDownEvent || !mounted || !ref.read(isTvProvider)) {
      return KeyEventResult.ignored;
    }
    final keys = {
      LogicalKeyboardKey.arrowUp,
      LogicalKeyboardKey.arrowDown,
      LogicalKeyboardKey.arrowLeft,
      LogicalKeyboardKey.arrowRight,
      LogicalKeyboardKey.select,
      LogicalKeyboardKey.enter,
    };
    if (!keys.contains(e.logicalKey)) return KeyEventResult.ignored;
    if (!_nothingFocused(FocusManager.instance.primaryFocus)) {
      return KeyEventResult.ignored;
    }
    return _focusContent() ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  /// Such-Taste der Fernbedienung (KEYCODE_SEARCH → browserSearch): auf den
  /// Hauptseiten Sprachsuche starten (Ergebnis im Such-Tab); ohne
  /// Spracheingabe einfach den Such-Tab öffnen. Nicht über Dialogen/Seiten.
  KeyEventResult _searchKey(KeyEvent e) {
    if (e.logicalKey != LogicalKeyboardKey.browserSearch || !mounted) {
      return KeyEventResult.ignored;
    }
    final route = ModalRoute.of(context);
    if (route == null || !route.isCurrent) return KeyEventResult.ignored;
    if (e is KeyDownEvent) openVoiceSearch();
    return KeyEventResult.handled;
  }

  /// Sprachsuche → Such-Tab mit dem erkannten Text.
  @visibleForTesting
  Future<void> openVoiceSearch() async {
    void show(String q) {
      ref.read(searchRequestProvider.notifier).request(q);
      if (mounted) setState(() => _index = 5);
    }

    final ok = await startVoiceSearch(ref, show);
    if (!ok && mounted) setState(() => _index = 5);
  }

  /// Hat nur ein Bereich (Wurzel bzw. diese Seite) den Fokus, aber kein
  /// Element? Nur, solange diese Seite oben liegt (keine Dialoge/Blätter
  /// oder anderen Seiten darüber).
  bool _nothingFocused(FocusNode? f) {
    final route = ModalRoute.of(context);
    if (route == null || !route.isCurrent) return false;
    if (f == null) return true;
    if (f is! FocusScopeNode) return false;
    final c = f.context;
    if (c == null || !c.mounted) return true;
    final r = ModalRoute.of(c);
    return r == null || r == route;
  }

  /// Fokus in den Inhalt des aktuellen Tabs: bevorzugt das Element mit
  /// Autofokus (z. B. erste Kachel der Startseite), sonst das oberste/linke
  /// sichtbare. false = nichts Fokussierbares da (z. B. lädt noch).
  bool _focusContent() {
    final page = _pageNodes[_index];
    bool usable(FocusNode n) =>
        n.context != null &&
        n.canRequestFocus &&
        !n.skipTraversal &&
        !n.rect.intersect(page.rect).isEmpty;
    FocusNode? auto;
    void visit(Element e) {
      if (auto != null) return;
      final w = e.widget;
      if (w is Focus && w.autofocus) {
        e.visitChildren((c) {
          final n = Focus.maybeOf(c, createDependency: false);
          if (auto == null && n != null && usable(n)) auto = n;
        });
      }
      e.visitChildren(visit);
    }

    final pc = page.context;
    if (pc is Element) visit(pc);
    if (auto != null) {
      auto!.requestFocus();
      return true;
    }
    final cands = page.traversalDescendants.where(usable).toList()
      ..sort((a, b) {
        final dy = a.rect.top.compareTo(b.rect.top);
        return dy != 0 ? dy : a.rect.left.compareTo(b.rect.left);
      });
    if (cands.isEmpty) return false;
    cands.first.requestFocus();
    return true;
  }

  /// Zurück-Taste im Hauptbildschirm: Fokus zur Leiste (TV) → Start-Tab →
  /// zweimal Zurück zum Beenden.
  void _onBack(bool tv) {
    if (TabBackScope.dispatch(_backHandlers[_index])) return;
    if (tv) {
      final f = FocusManager.instance.primaryFocus;
      if (f == null || !_inRail(f)) {
        _railNodes[_index].requestFocus();
        return;
      }
    }
    if (_index != 0) {
      _exit.reset();
      setState(() => _index = 0);
      if (tv) _railNodes[0].requestFocus();
      return;
    }
    _exit.press(context);
  }

  @override
  Widget build(BuildContext context) {
    final tv = ref.watch(isTvProvider);
    final wide = tv || MediaQuery.sizeOf(context).width >= 900;
    _visited.add(_index);

    // Tabs erst beim ersten Öffnen bauen (spart Ladezeit), dann behalten.
    final pages = [
      for (var i = 0; i < _dests.length; i++)
        Focus(
          focusNode: _pageNodes[i],
          canRequestFocus: false,
          skipTraversal: true,
          child: TabBackScope(
            handlers: _backHandlers[i],
            // Hintergrund-Reiter: Animationen ruhen, und Riverpod pausiert
            // dort alle Beobachtungen (EPG, Minutentakt …) – nichts baut im
            // Verborgenen neu; Änderungen kommen beim Wiedereinblenden an.
            // (IndexedStack schaltet TickerMode nicht mehr selbst ab.)
            child: TickerMode(
              enabled: i == _index,
              child: _visited.contains(i) ? _page(i) : const SizedBox.shrink(),
            ),
          ),
        ),
    ];
    final body = IndexedStack(index: _index, children: pages);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _onBack(tv);
      },
      child: Stack(children: [
        Positioned.fill(child: _shell(body, tv: tv, wide: wide)),
        _badge(tv: tv, wide: wide),
      ]),
    );
  }

  /// Plakette „Kindermodus“/„Gast“ unten rechts – auf dem Fernseher im
  /// sicheren Bereich, auf dem Handy über der Navigationsleiste.
  Widget _badge({required bool tv, required bool wide}) {
    final pad = MediaQuery.paddingOf(context);
    return Positioned(
      right: tv ? math.max(TvSafe.horizontal, pad.right) + 4 : 12,
      bottom: tv
          ? math.max(TvSafe.vertical, pad.bottom) + 2
          : (wide ? 12 : 80 + 8 + pad.bottom),
      child: const ProfileBadge(),
    );
  }

  Widget _shell(Widget body, {required bool tv, required bool wide}) {
    if (tv) {
      // TV: schmale Symbolleiste; bei Fokus klappt sie über den Inhalt auf.
      return Scaffold(
        body: Stack(children: [
          // Overscan: Inhalt ≥ 48 dp vom linken Rand (die Leiste zählt mit),
          // rechts 48 dp, oben/unten 27 dp (bzw. das gemeldete padding).
          SafeArea(
            minimum: TvSafe.insets
                .copyWith(left: math.max(TvSafe.horizontal, TvRail.width)),
            child: body,
          ),
          // Aufgeklappte Leiste: Inhalt dahinter sanft abdunkeln (wirkt
          // gewollt statt „abgeschnitten“).
          Positioned.fill(
            child: IgnorePointer(
              child: ValueListenableBuilder<bool>(
                valueListenable: _railOpen,
                builder: (_, open, __) => TweenAnimationBuilder<double>(
                  tween: Tween(end: open ? 1 : 0),
                  duration: const Duration(milliseconds: 150),
                  builder: (_, v, __) => v == 0
                      ? const SizedBox.shrink()
                      : DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(colors: [
                              Color.fromRGBO(5, 7, 10, 0.92 * v),
                              Color.fromRGBO(5, 7, 10, 0.70 * v),
                              Color.fromRGBO(5, 7, 10, 0.0),
                            ], stops: const [
                              0.0,
                              0.32,
                              0.62
                            ]),
                          ),
                        ),
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            child: TvRail(
              index: _index,
              nodes: _railNodes,
              scope: _railScope,
              onRight: _railRight,
              onOpenChanged: (o) => _railOpen.value = o,
              // Fokus auf einem Reiter wechselt die Seite (Vorschau) …
              onSelect: (i) => setState(() => _index = i),
              // … OK geht zusätzlich direkt in den Inhalt (Leiste klappt
              // zu, nichts bleibt verdeckt).
              onActivate: (i) {
                setState(() => _index = i);
                _enterContentSoon();
              },
            ),
          ),
        ]),
      );
    }

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

  /// Gleichbleibende Instanz: ein Neuaufbau der Hauptansicht (Reiterwechsel)
  /// baut die Startseite nicht mit neu.
  late final Widget _homePage =
      HomeScreen(onOpenTab: (t) => setState(() => _index = t));

  Widget _page(int i) => switch (i) {
        0 => _homePage,
        1 => const LiveScreen(),
        2 => const GuideScreen(),
        3 => const VodScreen(series: false),
        4 => const VodScreen(series: true),
        5 => const SearchScreen(),
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
    return MergeSemantics(
        child: Semantics(
            button: true,
            selected: sel,
            child: Focus(
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
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
                  decoration: BoxDecoration(
                    color: sel ? AppColors.accentSoft : Colors.transparent,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                        color: _focus ? AppColors.accent : Colors.transparent,
                        width: 2),
                  ),
                  child: Row(children: [
                    Icon(sel ? widget.dest.activeIcon : widget.dest.icon,
                        size: 22,
                        color: sel ? AppColors.accent : AppColors.textDim),
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
            )));
  }
}

/// TV-Navigation (TiviMate-artig): 48 dp schmale Symbolleiste. Solange ein
/// Eintrag den D-Pad-Fokus hat, klappt sie (über dem Inhalt, ohne ihn zu
/// verschieben) auf ~180 dp mit Beschriftungen auf. Fokus auf einen Eintrag
/// wechselt den Bereich direkt.
class TvRail extends StatefulWidget {
  static const width = 48.0;
  static const expandedWidth = 180.0;

  final int index;
  final ValueChanged<int> onSelect;
  final List<FocusNode>? nodes;
  final FocusNode? scope;

  /// Gewählten Eintrag beim Start fokussieren. In der Shell aus: dort
  /// beginnt der Fokus im Inhalt, die Leiste klappt erst auf, wenn man
  /// mit ◀ hineingeht.
  final bool autofocus;

  /// ▶ gedrückt: true = behandelt (Fokus zurück in den Inhalt).
  final bool Function()? onRight;

  /// Leiste auf-/zugeklappt (für das Abdunkeln des Inhalts).
  final ValueChanged<bool>? onOpenChanged;

  /// OK auf einem Reiter (Seite öffnen und in den Inhalt gehen).
  final ValueChanged<int>? onActivate;
  const TvRail({
    super.key,
    required this.index,
    required this.onSelect,
    this.nodes,
    this.scope,
    this.onRight,
    this.onOpenChanged,
    this.onActivate,
    this.autofocus = false,
  });

  @override
  State<TvRail> createState() => _TvRailState();
}

class _TvRailState extends State<TvRail> {
  bool _open = false;

  static const _bg = Color(0xFF0E1117);
  static const _border = Color(0xFF1A1F29);

  @override
  Widget build(BuildContext context) {
    Widget item(int i) => _RailItem(
          dest: _dests[i],
          selected: i == widget.index,
          expanded: _open,
          autofocus: widget.autofocus && i == widget.index,
          focusNode: widget.nodes?[i],
          onRight: widget.onRight,
          onTap: () => widget.onSelect(i),
          onActivate:
              widget.onActivate == null ? null : () => widget.onActivate!(i),
        );

    return Focus(
      focusNode: widget.scope,
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (f) {
        setState(() => _open = f);
        widget.onOpenChanged?.call(f);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOutCubic,
        width: _open ? TvRail.expandedWidth : TvRail.width,
        decoration: BoxDecoration(
          color: _bg,
          border: const Border(right: BorderSide(color: _border)),
          boxShadow: _open
              ? const [BoxShadow(color: Color(0x99000000), blurRadius: 24)]
              : null,
        ),
        // Symbole und Fokusrahmen oben/unten im sicheren Bereich (Overscan).
        padding: EdgeInsets.fromLTRB(
            10,
            math.max(TvSafe.vertical, MediaQuery.paddingOf(context).top),
            0,
            math.max(TvSafe.vertical, MediaQuery.paddingOf(context).bottom)),
        child: ClipRect(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(
                width: 28,
                child: Center(child: Wordmark(size: 17.6, compact: true)),
              ),
              const SizedBox(height: 13 + 7),
              for (var i = 0; i < _dests.length - 1; i++) ...[
                item(i),
                const SizedBox(height: 7),
              ],
              const Spacer(),
              item(_dests.length - 1),
              const SizedBox(height: 10),
              // Portal-Schalter (kompakt) ganz unten.
              const _RailPortal(),
            ],
          ),
        ),
      ),
    );
  }
}

class _RailItem extends StatefulWidget {
  final _Dest dest;
  final bool selected, expanded, autofocus;
  final FocusNode? focusNode;
  final VoidCallback onTap;
  final VoidCallback? onActivate;
  final bool Function()? onRight;
  const _RailItem({
    this.onRight,
    this.onActivate,
    required this.dest,
    required this.selected,
    required this.expanded,
    required this.autofocus,
    required this.focusNode,
    required this.onTap,
  });

  @override
  State<_RailItem> createState() => _RailItemState();
}

class _RailItemState extends State<_RailItem> {
  bool _focus = false;

  @override
  Widget build(BuildContext context) {
    final sel = widget.selected;
    final color = sel || _focus ? AppColors.accent : const Color(0xFF7C8494);
    // TalkBack: ein Eintrag mit Namen (auch bei zugeklappter Leiste).
    return MergeSemantics(
        child: Semantics(
            button: true,
            selected: sel,
            label: tr(widget.dest.label),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onTap,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                width: widget.expanded ? TvRail.expandedWidth - 20 : 28,
                height: 28,
                decoration: BoxDecoration(
                  color: _focus
                      ? AppColors.surface3
                      : sel
                          ? AppColors.accentSoft
                          : Colors.transparent,
                  borderRadius: BorderRadius.circular(7),
                  border: Border.all(
                      color: _focus ? AppColors.accent : Colors.transparent,
                      width: 1.5),
                ),
                child: Row(children: [
                  // Der Fokus-Knoten umfasst nur das Symbol: so bleibt die
                  // D-Pad-Navigation nach rechts in den Inhalt auch bei
                  // aufgeklappter Leiste korrekt.
                  Focus(
                    focusNode: widget.focusNode,
                    autofocus: widget.autofocus,
                    onFocusChange: (f) {
                      setState(() => _focus = f);
                      // TV: Fokus wechselt den Bereich direkt.
                      if (f) widget.onTap();
                    },
                    onKeyEvent: (node, e) {
                      if (e is! KeyUpEvent &&
                          e.logicalKey == LogicalKeyboardKey.arrowRight &&
                          (widget.onRight?.call() ?? false)) {
                        return KeyEventResult.handled;
                      }
                      if (e is KeyDownEvent &&
                          (e.logicalKey == LogicalKeyboardKey.select ||
                              e.logicalKey == LogicalKeyboardKey.enter)) {
                        (widget.onActivate ?? widget.onTap)();
                        return KeyEventResult.handled;
                      }
                      return KeyEventResult.ignored;
                    },
                    child: SizedBox(
                      width: 25,
                      height: 25,
                      child: Icon(
                          sel ? widget.dest.activeIcon : widget.dest.icon,
                          size: 15,
                          color: color),
                    ),
                  ),
                  Flexible(
                    child: Padding(
                      padding: const EdgeInsets.only(left: 6, right: 6),
                      child: Text(
                        tr(widget.dest.label),
                        semanticsLabel: '',
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.fade,
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 9,
                          fontWeight:
                              sel || _focus ? FontWeight.w600 : FontWeight.w500,
                          color: sel || _focus
                              ? AppColors.text
                              : AppColors.textDim,
                        ),
                      ),
                    ),
                  ),
                ]),
              ),
            )));
  }
}

/// Kompakter Portal-Schalter unten in der Leiste, mit deutlichem
/// Fokusrahmen für die Fernbedienung.
class _RailPortal extends StatefulWidget {
  const _RailPortal();

  @override
  State<_RailPortal> createState() => _RailPortalState();
}

class _RailPortalState extends State<_RailPortal> {
  bool _focus = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (f) => setState(() => _focus = f),
      child: Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
              color: _focus ? AppColors.accent : Colors.transparent,
              width: 1.5),
        ),
        child: const FittedBox(child: PortalButton(compact: true)),
      ),
    );
  }
}
