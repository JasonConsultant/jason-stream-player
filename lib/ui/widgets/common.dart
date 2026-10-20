import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/strings.dart';
import '../portals/portal_switcher.dart';
import 'package:intl/intl.dart';

import '../../core/theme.dart';
import '../../state/providers.dart' show isTvProvider;

DateFormat get hm => DateFormat.Hm(L10n.lang);

String fmtDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes % 60;
  if (h == 0) return trf('{0} Min.', [m]);
  return m == 0 ? trf('{0} Std.', [h]) : trf('{0} Std. {1} Min.', [h, m]);
}

String fmtClock(Duration d) {
  String two(int n) => n.toString().padLeft(2, '0');
  final h = d.inHours;
  final m = d.inMinutes % 60;
  final s = d.inSeconds % 60;
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
}

/// Seitenkopf mit großem Titel und optionalen Aktionen rechts.
class PageHeader extends StatelessWidget {
  final String title;
  final Widget? trailing;
  final EdgeInsets padding;
  const PageHeader(this.title,
      {super.key,
      this.trailing,
      this.padding = const EdgeInsets.fromLTRB(28, 26, 28, 14)});

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < 600;
    return Padding(
      padding: narrow ? const EdgeInsets.fromLTRB(16, 14, 16, 10) : padding,
      child: Row(children: [
        Text(title,
            style: (narrow
                    ? Theme.of(context).textTheme.headlineSmall
                    : Theme.of(context).textTheme.headlineMedium)
                ?.copyWith(fontFamily: 'InterDisplay')),
        const Spacer(),
        if (trailing != null) trailing!,
        // Handy: Portal-Schalter in jeder Kopfzeile (Tablet/TV: Seitenleiste).
        if (narrow) ...[
          const SizedBox(width: 6),
          const PortalButton(compact: true),
        ],
      ]),
    );
  }
}

/// Uhrzeit, die sich jede Minute aktualisiert.
class LiveClock extends StatelessWidget {
  final TextStyle? style;
  const LiveClock({super.key, this.style});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DateTime>(
      stream: Stream.periodic(const Duration(seconds: 20), (_) => DateTime.now()),
      initialData: DateTime.now(),
      builder: (context, snap) => Text(
        hm.format(snap.data!),
        style: style ??
            Theme.of(context).textTheme.titleMedium?.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()]),
      ),
    );
  }
}

/// Kompaktes Suchfeld.
/// Suchfeld, das auch mit der Fernbedienung funktioniert:
/// - ▲▼ (und ◀ am Anfang / ▶ am Ende des Textes) verlassen das Feld,
///   statt darin hängen zu bleiben.
/// - Zurück-Taste verlässt das Feld (und schließt nicht die App).
/// - Auf dem Fernseher öffnet sich die Tastatur erst mit OK, nicht schon
///   beim Darüberlaufen.
class SearchField extends ConsumerStatefulWidget {
  final TextEditingController controller;
  final String hint;
  final ValueChanged<String> onChanged;
  final double width;
  const SearchField({
    super.key,
    required this.controller,
    required this.hint,
    required this.onChanged,
    this.width = 280,
  });

  @override
  ConsumerState<SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends ConsumerState<SearchField> {
  late final FocusNode _node = FocusNode(onKeyEvent: _onKey);
  bool _editing = false;

  @override
  void initState() {
    super.initState();
    _node.addListener(() {
      if (!_node.hasFocus && _editing) setState(() => _editing = false);
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _node.dispose();
    super.dispose();
  }

  bool get _tv => ref.read(isTvProvider);

  void _leave(TraversalDirection d) {
    SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    if (!_node.focusInDirection(d)) {
      // Nichts in dieser Richtung → wenigstens weiter in der Reihenfolge.
      d == TraversalDirection.up || d == TraversalDirection.left
          ? _node.previousFocus()
          : _node.nextFocus();
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    final sel = widget.controller.selection;
    final len = widget.controller.text.length;
    final atStart = !sel.isValid || (sel.isCollapsed && sel.baseOffset <= 0);
    final atEnd = !sel.isValid || (sel.isCollapsed && sel.baseOffset >= len);

    if (k == LogicalKeyboardKey.arrowDown) {
      _leave(TraversalDirection.down);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowUp) {
      _leave(TraversalDirection.up);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowLeft && (atStart || !_editing && _tv)) {
      _leave(TraversalDirection.left);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowRight && (atEnd || !_editing && _tv)) {
      _leave(TraversalDirection.right);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.goBack || k == LogicalKeyboardKey.escape) {
      if (_editing) {
        setState(() => _editing = false);
        SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
      } else {
        _leave(TraversalDirection.down);
      }
      return KeyEventResult.handled;
    }
    // TV: OK startet die Eingabe (Tastatur auf).
    if (_tv &&
        !_editing &&
        (k == LogicalKeyboardKey.select ||
            k == LogicalKeyboardKey.enter ||
            k == LogicalKeyboardKey.numpadEnter)) {
      setState(() => _editing = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        SystemChannels.textInput.invokeMethod<void>('TextInput.show');
      });
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final tv = ref.watch(isTvProvider);
    final focused = _node.hasFocus;
    return SizedBox(
      width: widget.width,
      height: 44,
      child: TextField(
        controller: widget.controller,
        focusNode: _node,
        // TV: ohne OK nur „markiert“, Tastatur bleibt zu.
        readOnly: tv && !_editing,
        showCursor: !tv || _editing,
        onTap: tv ? () => setState(() => _editing = true) : null,
        onChanged: widget.onChanged,
        onSubmitted: (_) {
          if (tv) {
            setState(() => _editing = false);
            _leave(TraversalDirection.down);
          }
        },
        style: const TextStyle(fontSize: 14, color: AppColors.text),
        decoration: InputDecoration(
          hintText: tv && focused && !_editing
              ? '${widget.hint}  ·  ${tr('OK = tippen')}'
              : widget.hint,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(vertical: 12),
          prefixIcon:
              const Icon(Icons.search, size: 20, color: AppColors.textFaint),
          suffixIcon: ValueListenableBuilder(
            valueListenable: widget.controller,
            builder: (_, v, __) => v.text.isEmpty
                ? const SizedBox.shrink()
                : IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () {
                      widget.controller.clear();
                      widget.onChanged('');
                    },
                  ),
          ),
        ),
      ),
    );
  }
}

/// Leer- oder Fehlerzustand mit klarer nächster Aktion.
class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? message;
  final String? action;
  final VoidCallback? onAction;
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 48, color: AppColors.textFaint),
            const SizedBox(height: 16),
            Text(title, style: t.titleLarge, textAlign: TextAlign.center),
            if (message != null) ...[
              const SizedBox(height: 8),
              Text(message!, style: t.bodyMedium, textAlign: TextAlign.center),
            ],
            if (action != null) ...[
              const SizedBox(height: 22),
              FilledButton(
                  autofocus: true, onPressed: onAction, child: Text(action!)),
            ],
          ]),
        ),
      ),
    );
  }
}

/// Dünner Fortschrittsbalken mit runden Enden.
class ThinProgress extends StatelessWidget {
  final double value;
  final Color color;
  final double height;
  const ThinProgress(
      {super.key,
      required this.value,
      this.color = AppColors.accent,
      this.height = 3});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(height),
      child: LinearProgressIndicator(
        value: value,
        minHeight: height,
        color: color,
        backgroundColor: Colors.white.withValues(alpha: 0.10),
      ),
    );
  }
}

/// Bewertung mit Stern.
class RatingLabel extends StatelessWidget {
  final double rating;
  final double size;
  const RatingLabel(this.rating, {super.key, this.size = 13});

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.star_rounded, size: size + 3, color: AppColors.gold),
      const SizedBox(width: 3),
      Text(rating.toStringAsFixed(1),
          style: TextStyle(
              fontSize: size,
              fontWeight: FontWeight.w700,
              color: AppColors.text)),
    ]);
  }
}
