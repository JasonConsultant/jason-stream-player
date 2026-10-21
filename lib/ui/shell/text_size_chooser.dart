import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform_info.dart';
import '../../core/theme.dart';
import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../tv/tv_focus.dart';
import 'app_guard.dart' show AppLock;
import 'ui_scale.dart';

/// Erster Start auf dem Fernseher: einmal fragen, wie groß die Schrift
/// sein soll (Normal / Groß / Sehr groß → Oberflächengröße). Später über
/// Einstellungen → Oberflächengröße änderbar.
class TextSizeChooser extends ConsumerStatefulWidget {
  const TextSizeChooser({super.key});

  /// Merker `set_textsizeasked` (gehört zum Gerät, nicht in die Sicherung).
  static const askedFlag = 'textsizeasked';

  /// Wahlmöglichkeiten → Schlüssel aus [uiScaleOptions].
  static const choices = ['normal', 'gross', 'sehrgross'];

  /// In Widget-Tests standardmäßig aus (sonst läge der Dialog über jedem
  /// TV-Shell-Test); eigene Tests setzen das auf true.
  @visibleForTesting
  static bool debugAllowInTests = false;

  static bool get _inTest => WidgetsBinding.instance.runtimeType
      .toString()
      .contains('TestWidgetsFlutterBinding');

  /// Zeigt die Auswahl, wenn: Fernseher, noch nie gefragt und die
  /// Oberflächengröße noch nicht selbst gewählt wurde.
  static Future<void> maybeShow(BuildContext context, WidgetRef ref) async {
    if (_inTest && !debugAllowInTests) return;
    final st = await ref.read(storageProvider.future);
    if (st.flag(askedFlag)) return;
    final tv = ref.read(isTvProvider) || await PlatformInfo.isTv();
    if (!tv) return;
    if (st.option('uiscale', 'auto') != 'auto') {
      await st.setFlag(askedFlag, true);
      return;
    }
    // Erst nach dem Entsperren (App-Sperre) …
    await _whenUnlocked();
    if (!context.mounted) return;
    // … und nie über etwas anderem (Player aus einer Erinnerung, über den
    // TV-Startbildschirm gestarteter Sender, Detailseite): dann beim
    // nächsten Start fragen.
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => const TextSizeChooser(),
    ));
  }

  static Future<void> _whenUnlocked() async {
    if (!AppLock.locked.value) return;
    final done = Completer<void>();
    void check() {
      if (!AppLock.locked.value && !done.isCompleted) done.complete();
    }

    AppLock.locked.addListener(check);
    try {
      await done.future;
    } finally {
      AppLock.locked.removeListener(check);
    }
  }

  @override
  ConsumerState<TextSizeChooser> createState() => _TextSizeChooserState();
}

String _label(String k) => switch (k) {
      'gross' => tr('Groß'),
      'sehrgross' => tr('Sehr groß'),
      _ => tr('Normal'),
    };

class _TextSizeChooserState extends ConsumerState<TextSizeChooser> {
  String _focused = 'normal';
  bool _done = false;

  @override
  void initState() {
    super.initState();
    AppLock.locked.addListener(_onLock);
  }

  @override
  void dispose() {
    AppLock.locked.removeListener(_onLock);
    super.dispose();
  }

  /// Sperre kam doch noch darüber (Start-Reihenfolge): Danach war der Fokus
  /// weg (gesperrter Inhalt ist nicht fokussierbar) → zurückholen.
  void _onLock() {
    if (AppLock.locked.value || !mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !(ModalRoute.of(context)?.isCurrent ?? false)) return;
      final scope = FocusScope.of(context);
      final last = scope.focusedChild;
      if (last != null && last.canRequestFocus) {
        last.requestFocus();
        return;
      }
      for (final n in scope.traversalDescendants) {
        if (n.canRequestFocus) {
          n.requestFocus();
          return;
        }
      }
    });
  }

  /// Speichert die Wahl (null = Normal behalten) und schließt.
  Future<void> _finish(String? choice) async {
    if (_done) return;
    _done = true;
    final st = await ref.read(storageProvider.future);
    await st.setFlag(TextSizeChooser.askedFlag, true);
    if (choice != null && choice != 'normal') {
      await st.setOption('uiscale', choice);
    }
    if (!mounted) return;
    Navigator.of(context).pop();
    if (choice != null && choice != 'normal') {
      ref.invalidate(storageProvider); // Oberflächengröße übernehmen
    }
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    if (e.logicalKey == LogicalKeyboardKey.escape ||
        e.logicalKey == LogicalKeyboardKey.goBack) {
      _finish(null);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scale = uiScaleOptions[_focused] ?? 1.0;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _finish(null); // Zurück = Normal behalten
      },
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: _onKey,
        child: Scaffold(
          backgroundColor: AppColors.bg,
          body: SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(32),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(tr('Wie groß soll die Schrift sein?'),
                      textAlign: TextAlign.center, style: t.headlineMedium),
                  const SizedBox(height: 8),
                  Text(
                      tr('◀ ▶ wählen, OK übernehmen. Später änderbar unter '
                          'Einstellungen → Oberflächengröße.'),
                      textAlign: TextAlign.center,
                      style: t.bodyMedium),
                  const SizedBox(height: 28),
                  // Vorschau: eine Senderzeile in der gewählten Größe.
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    width: 520 * scale,
                    height: 76 * scale,
                    child: FittedBox(
                      child: SizedBox(
                          width: 520, height: 76, child: _SampleRow(t: t)),
                    ),
                  ),
                  const SizedBox(height: 32),
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    for (final k in TextSizeChooser.choices)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: TvTile(
                          key: ValueKey('textsize_$k'),
                          semanticLabel: _label(k),
                          autofocus: k == 'normal',
                          scaleOnFocus: true,
                          onFocus: () => setState(() => _focused = k),
                          onTap: () => _finish(k),
                          child: Container(
                            width: 150,
                            padding: const EdgeInsets.symmetric(vertical: 18),
                            decoration: BoxDecoration(
                              color: AppColors.surface2,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Column(children: [
                              Text('Aa',
                                  style: TextStyle(
                                      fontSize: 22 * (uiScaleOptions[k] ?? 1),
                                      fontWeight: FontWeight.w800,
                                      color: AppColors.text)),
                              const SizedBox(height: 6),
                              Text(_label(k), style: t.titleSmall),
                            ]),
                          ),
                        ),
                      ),
                  ]),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SampleRow extends StatelessWidget {
  final TextTheme t;
  const _SampleRow({required this.t});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.surface3,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.accent, width: 2),
        ),
        child: Row(children: [
          Container(
            width: 52,
            height: 52,
            alignment: Alignment.center,
            decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(10)),
            child: Text('1',
                style: t.titleMedium?.copyWith(color: AppColors.accent)),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(tr('Beispielsender HD'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.titleMedium),
                  const SizedBox(height: 3),
                  Text(tr('20:15 – Spielfilm am Abend'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.bodyMedium),
                ]),
          ),
        ]),
      );
}
