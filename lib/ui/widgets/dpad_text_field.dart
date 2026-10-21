import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart' show isTvProvider;

/// Zustand eines Textfelds unter [DpadTextField] – an das eigentliche
/// [TextField]/[TextFormField] durchreichen.
class DpadField {
  /// Fernseher: Feld ist nur markiert, bis OK die Eingabe startet.
  final bool readOnly;
  final bool showCursor;

  /// Hat das Feld gerade den Fokus?
  final bool focused;

  /// Läuft gerade eine Eingabe (TV: nach OK)?
  final bool editing;

  final bool tv;

  /// Antippen (Touch) startet auf dem Fernseher ebenfalls die Eingabe.
  final VoidCallback? onTap;

  /// An `onSubmitted`/`onFieldSubmitted` hängen: beendet die Eingabe auf dem
  /// Fernseher und geht zum nächsten Element darunter.
  final VoidCallback submitted;

  const DpadField._({
    required this.readOnly,
    required this.showCursor,
    required this.focused,
    required this.editing,
    required this.tv,
    required this.onTap,
    required this.submitted,
  });
}

/// Textfeld, das auch mit der Fernbedienung funktioniert (gemeinsames
/// Verhalten wie im [SearchField]):
/// - ▲▼ (und ◀ am Anfang / ▶ am Ende des Textes) verlassen das Feld,
///   statt darin hängen zu bleiben.
/// - Auf dem Fernseher öffnet sich die Tastatur erst mit OK, nicht schon
///   beim Darüberlaufen; ◀▶ verlassen das Feld, solange nicht getippt wird.
/// - Zurück beendet eine laufende Eingabe; sonst schließt es wie gewohnt
///   Dialog/Seite ([backLeaves] = stattdessen Feld nach unten verlassen).
///
/// Ohne Fernseher bleibt das Feld unverändert, außer [always] ist gesetzt.
class DpadTextField extends ConsumerStatefulWidget {
  /// Für die Cursorposition (◀/▶ am Rand verlassen). Ohne Controller
  /// verlassen ◀/▶ das Feld nur, solange nicht getippt wird.
  final TextEditingController? controller;
  final bool backLeaves;
  final bool always;
  final Widget Function(BuildContext context, DpadField field) builder;

  const DpadTextField({
    super.key,
    required this.builder,
    this.controller,
    this.backLeaves = false,
    this.always = false,
  });

  @override
  ConsumerState<DpadTextField> createState() => _DpadTextFieldState();
}

bool _isOk(LogicalKeyboardKey k) =>
    k == LogicalKeyboardKey.select ||
    k == LogicalKeyboardKey.enter ||
    k == LogicalKeyboardKey.numpadEnter;

class _DpadTextFieldState extends ConsumerState<DpadTextField> {
  bool _editing = false;
  bool _focused = false;

  /// Fokus-Knoten des Felds (auch nach „Fertig“ der Tastatur, die den
  /// Fokus schon abgegeben hat – Ausgangspunkt für [_leave]).
  FocusNode? _field;

  bool get _tv => ref.read(isTvProvider);

  void _hideKeyboard() =>
      SystemChannels.textInput.invokeMethod<void>('TextInput.hide');

  void _leave(TraversalDirection d) {
    _hideKeyboard();
    final f = _field;
    final node = f != null && f.context != null
        ? f
        : FocusManager.instance.primaryFocus;
    if (node == null) return;
    // Nach „Fertig“ hat das Feld den Fokus schon abgegeben – dann rechnet
    // die Richtungssuche vom zuletzt gemerkten Knoten des Bereichs aus
    // (z. B. dem Zurück-Pfeil oben). Erst wieder als Ausgangspunkt setzen.
    // („hasPrimaryFocus“ ist dann noch true, die Abgabe aber vorgemerkt –
    // maßgeblich ist der gemerkte Knoten des Bereichs.)
    if (node.canRequestFocus && node.nearestScope?.focusedChild != node) {
      node.requestFocus();
    }
    if (!node.focusInDirection(d)) {
      // Nichts in dieser Richtung → wenigstens weiter in der Reihenfolge.
      d == TraversalDirection.up || d == TraversalDirection.left
          ? node.previousFocus()
          : node.nextFocus();
    }
  }

  void _submitted() {
    if (!_tv) return;
    setState(() => _editing = false);
    _leave(TraversalDirection.down);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (!widget.always && !_tv) return KeyEventResult.ignored;
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final k = e.logicalKey;
    final tv = _tv;
    final c = widget.controller;
    final sel = c?.selection;
    final len = c?.text.length ?? 0;
    // Ohne Controller ist die Cursorposition unbekannt → nie „am Rand“.
    final atStart = sel != null &&
        (!sel.isValid || (sel.isCollapsed && sel.baseOffset <= 0));
    final atEnd = sel != null &&
        (!sel.isValid || (sel.isCollapsed && sel.baseOffset >= len));
    final typing = _editing || !tv;

    if (k == LogicalKeyboardKey.arrowDown) {
      _leave(TraversalDirection.down);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowUp) {
      _leave(TraversalDirection.up);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowLeft && (atStart || !typing)) {
      _leave(TraversalDirection.left);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowRight && (atEnd || !typing)) {
      _leave(TraversalDirection.right);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.goBack || k == LogicalKeyboardKey.escape) {
      if (_editing) {
        setState(() => _editing = false);
        _hideKeyboard();
        return KeyEventResult.handled;
      }
      if (widget.backLeaves) {
        _leave(TraversalDirection.down);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored; // Dialog/Seite schließt wie gewohnt
    }
    // TV: OK startet die Eingabe (Tastatur auf).
    if (tv && !_editing && _isOk(k)) {
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
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onKey,
      onFocusChange: (f) => setState(() {
        _focused = f;
        if (f) _field = FocusManager.instance.primaryFocus;
        if (!f) _editing = false;
      }),
      child: widget.builder(
        context,
        DpadField._(
          // TV: ohne OK nur „markiert“, Tastatur bleibt zu.
          readOnly: tv && !_editing,
          showCursor: !tv || _editing,
          focused: _focused,
          editing: _editing,
          tv: tv,
          onTap: tv ? () => setState(() => _editing = true) : null,
          submitted: _submitted,
        ),
      ),
    );
  }
}
