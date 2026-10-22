import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../widgets/focusable_tile.dart';

/// Wie [FocusableTile], aber für die Fernbedienung: OK löst beim Loslassen
/// aus, OK gedrückt halten (≥ 500 ms) bzw. die Menü-Taste öffnet
/// [onLongPress]. Touch/Maus verhalten sich wie gewohnt.
class TvTile extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onFocus;
  final bool autofocus;
  final bool selected;
  final bool scaleOnFocus;
  final BorderRadius radius;

  /// Vorlesetext für TalkBack (siehe [FocusableTile.semanticLabel]).
  final String? semanticLabel;
  const TvTile({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.onFocus,
    this.autofocus = false,
    this.selected = false,
    this.scaleOnFocus = false,
    this.radius = const BorderRadius.all(Radius.circular(12)),
    this.semanticLabel,
  });

  @override
  State<TvTile> createState() => _TvTileState();
}

/// Ab dieser Haltedauer gilt OK als „lange gedrückt“.
const tvLongOk = Duration(milliseconds: 500);

bool _isOk(LogicalKeyboardKey k) =>
    k == LogicalKeyboardKey.select ||
    k == LogicalKeyboardKey.enter ||
    k == LogicalKeyboardKey.numpadEnter ||
    k == LogicalKeyboardKey.gameButtonA;

/// Fokus-Knoten einer [TvTile]; [selected] = aktuell gewählter Eintrag
/// (z. B. gewählte Gruppe, Sender in der Vorschau) – Ziel beim Betreten
/// einer Spalte in [TvColumns].
class TvTileNode extends FocusNode {
  bool selected = false;
  TvTileNode({super.onKeyEvent});
}

class _TvTileState extends State<TvTile> {
  late final TvTileNode _node = TvTileNode(onKeyEvent: _onKey);
  Timer? _hold;
  bool _down = false;
  bool _fired = false;

  void _long() {
    if (_fired || !_down) return;
    _fired = true;
    widget.onLongPress?.call();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (!_isOk(e.logicalKey)) return KeyEventResult.ignored;
    if (e is KeyDownEvent) {
      _down = true;
      _fired = false;
      _hold?.cancel();
      if (widget.onLongPress != null) _hold = Timer(tvLongOk, _long);
    } else if (e is KeyRepeatEvent) {
      // Wiederholung kommt erst nach der System-Haltezeit → lang gedrückt.
      if (widget.onLongPress != null) _long();
    } else if (e is KeyUpEvent) {
      _hold?.cancel();
      final wasDown = _down;
      _down = false;
      if (wasDown && !_fired) widget.onTap?.call();
    }
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    _hold?.cancel();
    _node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _node.selected = widget.selected;
    return FocusableTile(
      focusNode: _node,
      autofocus: widget.autofocus,
      selected: widget.selected,
      scaleOnFocus: widget.scaleOnFocus,
      radius: widget.radius,
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      onFocus: widget.onFocus,
      semanticLabel: widget.semanticLabel,
      child: widget.child,
    );
  }
}

/// Spalten nebeneinander mit vorhersehbarer ◀/▶-Navigation für das D-Pad:
/// Innerhalb einer Spalte geht es zum nächsten Element in der Richtung;
/// am Spaltenrand springt der Fokus in die Nachbarspalte – auf das dort
/// zuletzt fokussierte Element, sonst den gewählten Eintrag ([TvTile.selected])
/// bzw. das nächstgelegene sichtbare. ◀ in der
/// ersten Spalte bleibt der Standard-Navigation überlassen (→ Seitenleiste).
/// ▲/▼ verlassen eine Spalte nie: am Ende der Liste bleibt der Fokus stehen.
class TvColumns extends StatefulWidget {
  /// Spalten in Reihenfolge von links nach rechts; Breiten über [Expanded]
  /// bzw. [SizedBox] wie in einer [Row].
  final List<Widget> children;

  /// Ändert sich ein Eintrag, vergisst die Spalte ihr zuletzt fokussiertes
  /// Element (z. B. nach Gruppenwechsel → oben in der neuen Liste beginnen).
  final List<Object?> memoryKeys;

  /// Wie [memoryKeys], aber ohne Neuaufbau: meldet sich der Listenable
  /// (Spaltennummer → Listenable), vergisst die Spalte ihr zuletzt
  /// fokussiertes Element (z. B. anderer Sender in der Info-Spalte).
  final Map<int, Listenable> memoryResets;

  const TvColumns({
    super.key,
    required this.children,
    this.memoryKeys = const [],
    this.memoryResets = const {},
  });

  @override
  State<TvColumns> createState() => _TvColumnsState();
}

class _TvColumnsState extends State<TvColumns> {
  final _cols = <FocusNode>[];
  final _memory = <int, FocusNode>{};

  final _resetters = <int, VoidCallback>{};

  @override
  void initState() {
    super.initState();
    _sync();
    _listenResets();
    FocusManager.instance.addListener(_track);
  }

  void _listenResets() {
    widget.memoryResets.forEach((i, l) {
      void forget() => _memory.remove(i);
      _resetters[i] = forget;
      l.addListener(forget);
    });
  }

  void _unlistenResets(Map<int, Listenable> resets) {
    resets.forEach((i, l) {
      final f = _resetters.remove(i);
      if (f != null) l.removeListener(f);
    });
  }

  void _sync() {
    while (_cols.length < widget.children.length) {
      final i = _cols.length;
      _cols.add(FocusNode(
        debugLabel: 'TvColumn$i',
        skipTraversal: true,
        canRequestFocus: false,
        onKeyEvent: (n, e) => _onKey(i, e),
      ));
    }
  }

  @override
  void didUpdateWidget(TvColumns old) {
    super.didUpdateWidget(old);
    _sync();
    if (!_sameResets(old.memoryResets, widget.memoryResets)) {
      _unlistenResets(old.memoryResets);
      _listenResets();
    }
    for (var i = 0; i < widget.memoryKeys.length; i++) {
      if (i >= old.memoryKeys.length ||
          old.memoryKeys[i] != widget.memoryKeys[i]) {
        _memory.remove(i);
      }
    }
  }

  static bool _sameResets(Map<int, Listenable> a, Map<int, Listenable> b) =>
      a.length == b.length &&
      a.entries.every((e) => identical(b[e.key], e.value));

  @override
  void dispose() {
    _unlistenResets(widget.memoryResets);
    FocusManager.instance.removeListener(_track);
    for (final n in _cols) {
      n.dispose();
    }
    super.dispose();
  }

  void _track() {
    final f = FocusManager.instance.primaryFocus;
    if (f == null) return;
    for (var i = 0; i < _cols.length; i++) {
      if (f.ancestors.contains(_cols[i])) {
        _memory[i] = f;
        return;
      }
    }
  }

  bool _usable(FocusNode n, int col) =>
      n.context != null &&
      n.canRequestFocus &&
      !n.skipTraversal &&
      n.ancestors.contains(_cols[col]) &&
      !n.rect.intersect(_cols[col].rect).isEmpty;

  KeyEventResult _onKey(int col, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final right = e.logicalKey == LogicalKeyboardKey.arrowRight;
    final left = e.logicalKey == LogicalKeyboardKey.arrowLeft;
    final up = e.logicalKey == LogicalKeyboardKey.arrowUp;
    final down = e.logicalKey == LogicalKeyboardKey.arrowDown;
    if (!right && !left && !up && !down) return KeyEventResult.ignored;
    final from = FocusManager.instance.primaryFocus;
    if (from == null) return KeyEventResult.ignored;
    final r = from.rect;
    if (up || down) return _vertical(col, from, down);

    // 1. Innerhalb der Spalte in Pfeilrichtung (gleiche Höhe).
    final inCol = _cols[col].traversalDescendants.where((n) {
      if (n == from || !_usable(n, col)) return false;
      final c = n.rect.center.dx;
      final dir = right ? c > r.right : c < r.left;
      return dir && n.rect.top < r.bottom && n.rect.bottom > r.top;
    }).toList()
      ..sort((a, b) => (a.rect.center.dx - r.center.dx)
          .abs()
          .compareTo((b.rect.center.dx - r.center.dx).abs()));
    if (inCol.isNotEmpty) {
      inCol.first.requestFocus();
      return KeyEventResult.handled;
    }

    // 2. Nachbarspalte.
    final target = col + (right ? 1 : -1);
    if (target < 0 || target >= _cols.length) return KeyEventResult.ignored;
    final mem = _memory[target];
    if (mem != null && _usable(mem, target)) {
      mem.requestFocus();
      return KeyEventResult.handled;
    }
    final cands = _cols[target]
        .traversalDescendants
        .where((n) => _usable(n, target))
        .toList();
    // Gewählter Eintrag (sichtbar) zuerst, sonst der nächstgelegene.
    final sel = cands.whereType<TvTileNode>().where((n) => n.selected);
    if (sel.isNotEmpty) {
      sel.first.requestFocus();
      return KeyEventResult.handled;
    }
    cands.sort((a, b) => (a.rect.center.dy - r.center.dy)
        .abs()
        .compareTo((b.rect.center.dy - r.center.dy).abs()));
    if (cands.isEmpty) return KeyEventResult.handled; // leere Spalte: bleiben
    cands.first.requestFocus();
    return KeyEventResult.handled;
  }

  /// ▲/▼ bleiben in der Spalte: am Listenende/-anfang passiert nichts
  /// (kein Sprung in die Nachbarspalte, kein Umlauf).
  KeyEventResult _vertical(int col, FocusNode from, bool down) {
    final r = from.rect;
    // Auch noch nicht sichtbare (vorgebaute) Einträge der Liste zählen –
    // die Standard-Navigation scrollt dorthin.
    final cands = _cols[col].traversalDescendants.where((n) =>
        n != from &&
        n.context != null &&
        n.canRequestFocus &&
        !n.skipTraversal &&
        (down ? n.rect.center.dy >= r.bottom : n.rect.center.dy <= r.top));
    if (cands.isEmpty) return KeyEventResult.handled; // Rand: bleiben
    // Liegt ein Ziel senkrecht über/unter dem Element, findet die
    // Standard-Navigation es (nur in dieser Spalte, die Spalten
    // überlappen sich nicht).
    if (cands.any((n) => n.rect.left < r.right && n.rect.right > r.left)) {
      return KeyEventResult.ignored;
    }
    // Sonst das nächstgelegene Ziel in dieser Spalte selbst wählen.
    final list = cands.toList()
      ..sort((a, b) {
        double d(FocusNode n) =>
            (n.rect.center.dy - r.center.dy).abs() +
            (n.rect.center.dx - r.center.dx).abs();
        return d(a).compareTo(d(b));
      });
    list.first.requestFocus();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < widget.children.length; i++)
            _wrap(widget.children[i], _cols[i]),
        ],
      );

  /// Breite (Expanded/SizedBox) der Spalte erhalten, Fokus-Knoten darin.
  Widget _wrap(Widget w, FocusNode node) {
    if (w is Expanded) {
      return Expanded(
          flex: w.flex, child: Focus(focusNode: node, child: w.child));
    }
    return Focus(focusNode: node, child: w);
  }
}

/// Fernbedienung: Verschwindet das fokussierte Element (Liste neu
/// aufgebaut, Knopf ausgeblendet, Blatt geschlossen …), landet der Fokus
/// beim Wurzelbereich – dann kommen OK/Pfeile nirgends sinnvoll an. Holt
/// den Fokus in die oberste Seite zurück (dort zuletzt fokussiertes
/// Element, sonst die Seite selbst – die nächste Pfeiltaste wählt dann das
/// erste Element in dieser Richtung).
class TvFocusRescue extends StatefulWidget {
  final bool enabled;
  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;
  const TvFocusRescue({
    super.key,
    required this.enabled,
    required this.navigatorKey,
    required this.child,
  });

  @override
  State<TvFocusRescue> createState() => _TvFocusRescueState();
}

class _TvFocusRescueState extends State<TvFocusRescue> {
  bool _scheduled = false;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_check);
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_check);
    super.dispose();
  }

  static bool _lost(FocusNode? f) =>
      f == null || f == FocusManager.instance.rootScope;

  void _check() {
    if (!widget.enabled || _scheduled) return;
    if (!_lost(FocusManager.instance.primaryFocus)) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted || !_lost(FocusManager.instance.primaryFocus)) return;
      widget.navigatorKey.currentState?.focusNode.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
