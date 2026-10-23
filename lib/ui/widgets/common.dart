import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/strings.dart';
import '../portals/portal_switcher.dart';
import 'package:intl/intl.dart';

import '../../core/theme.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart' show isTvProvider;
import 'dpad_text_field.dart';
import 'focusable_tile.dart';
import 'voice_search.dart';

DateFormat get hm => DateFormat.Hm(L10n.lang);

String fmtDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes % 60;
  if (h == 0) return trf('{0} Min.', [m]);
  return m == 0 ? trf('{0} Std.', [h]) : trf('{0} Std. {1} Min.', [h, m]);
}

/// „Archiv · 7 Tage“ (1 → „Archiv · 1 Tag“): Catch-up-Fenster eines
/// Senders für Infobereich, Sender-Menü und Vorlesetexte.
String archiveLabel(int days) =>
    days == 1 ? tr('Archiv · 1 Tag') : trf('Archiv · {0} Tage', [days]);

/// Kurzform „7d“ für breite Listen.
String archiveShort(int days) => '${days}d';

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
        // Der Titel darf schrumpfen (z. B. neben einem langen Datum
        // „Donnerstag, 22. Oktober“), statt überzulaufen.
        Expanded(
          child: Text(title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: (narrow
                      ? Theme.of(context).textTheme.headlineSmall
                      : Theme.of(context).textTheme.headlineMedium)
                  ?.copyWith(fontFamily: 'InterDisplay')),
        ),
        if (trailing != null) ...[const SizedBox(width: 12), trailing!],
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

  /// Mikrofon für die Sprachsuche anbieten (nur sichtbar, wenn das Gerät
  /// eine Spracheingabe hat). Erkannter Text landet im Feld und löst die
  /// Suche aus ([onChanged]).
  final bool voice;

  /// Fernseher: Sprachsuche als beschrifteter Knopf und ein großer,
  /// fokussierbarer „Löschen“-Knopf neben dem Feld; langes OK bzw. die
  /// Menü-Taste auf dem Feld leert es ebenfalls.
  final bool tvActions;

  /// Feld per OK/„Fertig“ der Tastatur abgeschlossen.
  final ValueChanged<String>? onSubmitted;

  /// Fokus-Knoten des Textfelds (z. B. um nach einer Auswahl unterhalb
  /// wieder ins Feld zu springen); sonst ein eigener.
  final FocusNode? focusNode;

  const SearchField({
    super.key,
    required this.controller,
    required this.hint,
    required this.onChanged,
    this.width = 280,
    this.voice = true,
    this.tvActions = false,
    this.onSubmitted,
    this.focusNode,
  });

  @override
  ConsumerState<SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends ConsumerState<SearchField> {
  final _ownNode = FocusNode(debugLabel: 'search field');
  FocusNode get _node => widget.focusNode ?? _ownNode;

  /// Fernseher mit „Löschen“-Knopf: X im Feld nur für Touch (kein
  /// zusätzlicher, kaum sichtbarer Fokus-Halt zwischen Feld und Knöpfen).
  final _xNode =
      FocusNode(debugLabel: 'search x', skipTraversal: true, canRequestFocus: false);

  @override
  void dispose() {
    _ownNode.dispose();
    _xNode.dispose();
    super.dispose();
  }

  void _voiceResult(String text) {
    widget.controller.value = TextEditingValue(
        text: text, selection: TextSelection.collapsed(offset: text.length));
    widget.onChanged(text);
  }

  void _clear({bool focusField = false}) {
    if (widget.controller.text.isEmpty) return;
    widget.controller.clear();
    widget.onChanged('');
    // Der „Löschen“-Knopf verschwindet → Fokus zurück ins Feld.
    if (focusField) _node.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final hint = widget.hint;
    final tv = ref.watch(isTvProvider);
    final field = DpadTextField(
      controller: controller,
      always: true,
      backLeaves: true,
      onClear: widget.tvActions ? _clear : null,
      builder: (context, f) {
        return TextField(
          controller: controller,
          focusNode: _node,
          readOnly: f.readOnly,
          showCursor: f.showCursor,
          onTap: f.onTap,
          onChanged: widget.onChanged,
          onSubmitted: (v) {
            f.submitted();
            widget.onSubmitted?.call(v);
          },
          style: const TextStyle(fontSize: 14, color: AppColors.text),
          decoration: InputDecoration(
            hintText: f.tv && f.focused && !f.editing
                ? '$hint  ·  ${tr('OK = tippen')}'
                : hint,
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(vertical: 12),
            prefixIcon:
                const Icon(Icons.search, size: 20, color: AppColors.textFaint),
            suffixIcon: ValueListenableBuilder(
              valueListenable: controller,
              builder: (_, v, __) => v.text.isEmpty
                  ? const SizedBox.shrink()
                  : IconButton(
                      key: const ValueKey('search-clear-x'),
                      focusNode: widget.tvActions && tv ? _xNode : null,
                      tooltip: tr('Löschen'),
                      icon: const Icon(Icons.close_rounded, size: 24),
                      onPressed: _clear,
                    ),
            ),
          ),
        );
      },
    );
    return SizedBox(
      width: widget.width,
      height: 44,
      // Mikrofon neben (nicht im) Feld: eigener Fokus-Eintrag, ▶ am
      // Textende erreicht ihn; OK startet die Spracheingabe.
      child: Row(children: [
        Expanded(child: field),
        if (widget.voice)
          VoiceSearchButton(
              onResult: _voiceResult, labelled: widget.tvActions && tv),
        if (widget.tvActions)
          ValueListenableBuilder(
            valueListenable: controller,
            builder: (_, v, __) => !tv || v.text.isEmpty
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: FocusableTile(
                      key: const ValueKey('search-clear-chip'),
                      radius: BorderRadius.circular(22),
                      semanticLabel: tr('Löschen'),
                      onTap: () => _clear(focusField: true),
                      child: Container(
                        height: 44,
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        decoration: BoxDecoration(
                          color: AppColors.surface3,
                          borderRadius: BorderRadius.circular(22),
                        ),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          const Icon(Icons.backspace_outlined,
                              size: 22, color: AppColors.text),
                          const SizedBox(width: 8),
                          Text(tr('Löschen'),
                              style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.text)),
                        ]),
                      ),
                    ),
                  ),
          ),
      ]),
    );
  }
}

/// Zweimal Zurück (innerhalb von 2 s) beendet die App; beim ersten Mal
/// erscheint ein Hinweis. Für die Startseiten (Start-Tab, Willkommen).
class BackToExit {
  Timer? _armed;

  void reset() {
    _armed?.cancel();
    _armed = null;
  }

  void press(BuildContext context) {
    if (_armed?.isActive ?? false) {
      reset();
      SystemNavigator.pop();
      return;
    }
    _armed = Timer(const Duration(seconds: 2), () {});
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(tr('Zum Beenden nochmal Zurück drücken')),
        duration: const Duration(seconds: 2),
      ));
  }
}

/// Stellt den [TabBackHandler]n eines Tabs der Hauptnavigation ihre Liste
/// bereit (von der Shell je Tab gesetzt).
class TabBackScope extends InheritedWidget {
  final List<bool Function()> handlers;
  const TabBackScope({super.key, required this.handlers, required super.child});

  /// Zurück zuerst den Elementen des Tabs anbieten (zuletzt angemeldetes
  /// zuerst). true = verbraucht.
  static bool dispatch(List<bool Function()> handlers) {
    for (final h in handlers.reversed.toList()) {
      if (h()) return true;
    }
    return false;
  }

  @override
  bool updateShouldNotify(TabBackScope oldWidget) => false;
}

/// Lässt ein Element eines Tabs die Zurück-Taste verbrauchen, bevor die
/// Hauptnavigation den Tab wechselt (z. B. offene Suche schließen).
/// [onBack] liefert true, wenn es etwas geschlossen hat.
class TabBackHandler extends StatefulWidget {
  final bool Function() onBack;
  final Widget child;
  const TabBackHandler({super.key, required this.onBack, required this.child});

  @override
  State<TabBackHandler> createState() => _TabBackHandlerState();
}

class _TabBackHandlerState extends State<TabBackHandler> {
  List<bool Function()>? _list;
  bool _handle() => mounted && widget.onBack();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final l = context.getInheritedWidgetOfExactType<TabBackScope>()?.handlers;
    if (!identical(l, _list)) {
      _list?.remove(_handle);
      _list = l?..add(_handle);
    }
  }

  @override
  void dispose() {
    _list?.remove(_handle);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
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
  final Color? color;
  final double height;
  const ThinProgress(
      {super.key,
      required this.value,
      this.color,
      this.height = 3});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(height),
      child: LinearProgressIndicator(
        value: value,
        minHeight: height,
        color: color ?? AppColors.accent,
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
