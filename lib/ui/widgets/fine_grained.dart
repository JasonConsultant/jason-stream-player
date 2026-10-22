import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart' show minuteTickProvider;

/// Bausteine gegen „Rebuild-Stürme“: nur die kleinen Teile neu bauen, die
/// sich wirklich ändern (Uhrzeit, Fortschritt, Auswahl), statt ganzer
/// Bildschirme.

// Unsichtbare Reiter/Seiten: Riverpod 3 pausiert die Beobachtung von
// Consumer-Widgets unter abgeschaltetem [TickerMode] (HomeShell schaltet
// Hintergrund-Reiter ab, verdeckte Seiten sowieso) – dort baut nichts neu;
// verpasste Änderungen kommen beim Wiedereinblenden an.

/// Baut [builder] im Minutentakt (minuteTickProvider) neu – für Uhrzeit,
/// „noch x Min.“ und Fortschrittsbalken. In unsichtbaren Reitern ruht der
/// Takt (siehe oben).
class MinuteBuilder extends ConsumerWidget {
  final Widget Function(BuildContext context, DateTime now) builder;
  const MinuteBuilder({super.key, required this.builder});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(minuteTickProvider);
    return builder(context, DateTime.now());
  }
}

/// Wie [ValueListenableBuilder], baut aber nur neu, wenn sich der
/// ausgewählte Wert [selector] ändert (z. B. „ist diese Zeile gewählt?“ –
/// pro ▼ betrifft das zwei Zeilen statt aller sichtbaren).
class ValueSelector<T, S> extends StatefulWidget {
  final ValueListenable<T> listenable;
  final S Function(T value) selector;
  final Widget Function(BuildContext context, S selected, Widget? child)
      builder;
  final Widget? child;
  const ValueSelector({
    super.key,
    required this.listenable,
    required this.selector,
    required this.builder,
    this.child,
  });

  @override
  State<ValueSelector<T, S>> createState() => _ValueSelectorState<T, S>();
}

class _ValueSelectorState<T, S> extends State<ValueSelector<T, S>> {
  late S _sel = widget.selector(widget.listenable.value);

  @override
  void initState() {
    super.initState();
    widget.listenable.addListener(_changed);
  }

  @override
  void didUpdateWidget(ValueSelector<T, S> old) {
    super.didUpdateWidget(old);
    if (old.listenable != widget.listenable) {
      old.listenable.removeListener(_changed);
      widget.listenable.addListener(_changed);
    }
    _sel = widget.selector(widget.listenable.value);
  }

  @override
  void dispose() {
    widget.listenable.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    final s = widget.selector(widget.listenable.value);
    if (s != _sel) setState(() => _sel = s);
  }

  @override
  Widget build(BuildContext context) =>
      widget.builder(context, _sel, widget.child);
}
