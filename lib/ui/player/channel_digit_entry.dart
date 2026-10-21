import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme.dart';
import '../../l10n/strings.dart';
import '../../models/models.dart';
import 'zap_bar.dart' show digitOfKey;

/// Direktwahl per Zifferntasten außerhalb des Players (z. B. Live-TV-Liste):
/// Ziffern erscheinen groß oben rechts; nach 1,5 s ohne Eingabe (oder OK)
/// wird der Sender mit dieser Nummer gestartet – zuerst in [channels]
/// (aktuelle Gruppe), sonst in [all]. Unbekannt → kurzer Hinweis.
/// Eingaben in Textfeldern (Suche) werden nicht abgefangen.
class ChannelDigitEntry extends StatefulWidget {
  final List<Channel> Function() channels;
  final List<Channel> Function()? all;
  final void Function(Channel channel, List<Channel> list) onPick;
  final Widget child;
  const ChannelDigitEntry({
    super.key,
    required this.channels,
    this.all,
    required this.onPick,
    required this.child,
  });

  @override
  State<ChannelDigitEntry> createState() => _ChannelDigitEntryState();
}

class _ChannelDigitEntryState extends State<ChannelDigitEntry> {
  String _digits = '';
  String? _message;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  bool get _inTextField {
    final ctx = FocusManager.instance.primaryFocus?.context;
    if (ctx == null) return false;
    return ctx.widget is EditableText ||
        ctx.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (_digits.isNotEmpty &&
        (k == LogicalKeyboardKey.select ||
            k == LogicalKeyboardKey.enter ||
            k == LogicalKeyboardKey.numpadEnter)) {
      _commit();
      return KeyEventResult.handled;
    }
    final d = digitOfKey(k);
    if (d == null || _inTextField) return KeyEventResult.ignored;
    _timer?.cancel();
    setState(() {
      final next = '$_digits$d';
      _digits = next.length > 4 ? next.substring(1) : next;
      _message = null;
    });
    _timer = Timer(const Duration(milliseconds: 1500), _commit);
    return KeyEventResult.handled;
  }

  void _commit() {
    _timer?.cancel();
    final n = int.tryParse(_digits) ?? -1;
    if (!mounted) return;
    setState(() => _digits = '');
    for (final list in [widget.channels(), widget.all?.call() ?? const []]) {
      final i = list.indexWhere((c) => c.number == n);
      if (i >= 0) {
        widget.onPick(list[i], list);
        return;
      }
    }
    setState(() => _message = trf('Sender {0} nicht gefunden', [n]));
    _timer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _message = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final show = _digits.isNotEmpty || _message != null;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onKey,
      child: Stack(fit: StackFit.passthrough, children: [
        widget.child,
        if (show)
          Positioned(
            top: 32,
            right: 48,
            child: IgnorePointer(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 22, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.8),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppColors.accent, width: 2),
                ),
                child: Text(_message ?? _digits,
                    style: _message != null
                        ? const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            color: Colors.white)
                        : const TextStyle(
                            fontFamily: 'InterDisplay',
                            fontSize: 44,
                            fontWeight: FontWeight.w800,
                            color: Colors.white)),
              ),
            ),
          ),
      ]),
    );
  }
}
