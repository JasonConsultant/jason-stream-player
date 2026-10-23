import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../l10n/strings.dart';

/// Setzt eine mpv-Eigenschaft (NativePlayer.setProperty bzw. Ersatz im Test).
typedef MpvPropertySetter = Future<void> Function(String name, String value);

/// Untertitel-Verzögerung des Players (mpv `sub-delay`): −10 … +10 s in
/// Schritten von 0,5 s. Negativ = Untertitel erscheinen früher.
/// Gilt bis zum nächsten Sender/Film ([reset] beim Öffnen).
class SubtitleDelay extends ChangeNotifier {
  static const step = 0.5;
  static const limit = 10.0;

  final MpvPropertySetter _set;
  double _seconds = 0;

  SubtitleDelay(this._set);

  double get seconds => _seconds;
  bool get isZero => _seconds == 0;
  bool get atMin => _seconds <= -limit;
  bool get atMax => _seconds >= limit;

  /// Um [steps] Schritte (±1 …) verschieben, am Rand begrenzt.
  Future<void> adjust(int steps) => setSeconds(_seconds + steps * step);

  Future<void> reset() => setSeconds(0);

  Future<void> setSeconds(double s) async {
    // Auf halbe Sekunden runden, Rundungsreste (0.1+0.2) vermeiden.
    var v = (s / step).round() * step;
    v = v.clamp(-limit, limit).toDouble();
    if (v == -0.0) v = 0;
    if (v == _seconds) return;
    _seconds = v;
    notifyListeners();
    try {
      await _set('sub-delay', v.toStringAsFixed(1));
    } catch (_) {
      // Option in dieser libmpv unbekannt – Anzeige bleibt trotzdem stimmig.
    }
  }

  /// „+1,5 s“ / „−0,5 s“ / „0 s“ (Komma außer auf Englisch).
  static String format(double s) {
    if (s == 0) return '0 s';
    final sign = s < 0 ? '−' : '+';
    var num = s.abs().toStringAsFixed(1);
    if (num.endsWith('.0')) num = num.substring(0, num.length - 2);
    if (L10n.lang != 'en') num = num.replaceAll('.', ',');
    return '$sign$num s';
  }

  /// Anzeige in Listen: „Keine Verzögerung“ oder der Wert.
  String get label => isZero ? tr('Keine Verzögerung') : format(_seconds);
}

/// Inhalt des Auswahlblatts „Untertitel-Verzögerung“: −/+ in 0,5-s-Schritten,
/// Zurücksetzen, Schließen. Fernbedienung: Start auf „+“, ◀▶ zwischen den
/// Knöpfen, Zurück schließt (Dialog, keine Fokusfalle).
class SubtitleDelaySheet extends StatelessWidget {
  final SubtitleDelay delay;
  const SubtitleDelaySheet({super.key, required this.delay});

  /// Öffnet das Blatt; kehrt zurück, wenn es geschlossen wurde.
  static Future<void> show(BuildContext context, SubtitleDelay delay) =>
      showModalBottomSheet<void>(
        context: context,
        constraints: const BoxConstraints(maxWidth: 560),
        builder: (_) => SubtitleDelaySheet(delay: delay),
      );

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return SafeArea(
      child: AnimatedBuilder(
        animation: delay,
        builder: (context, _) => SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              const Icon(Icons.timer_outlined, size: 20),
              const SizedBox(width: 10),
              Expanded(
                  child: Text(tr('Untertitel-Verzögerung'),
                      style: t.titleMedium)),
            ]),
            const SizedBox(height: 18),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              IconButton.filledTonal(
                key: const ValueKey('subdelay-minus'),
                tooltip: tr('Untertitel früher'),
                iconSize: 28,
                onPressed: delay.atMin ? null : () => delay.adjust(-1),
                icon: const Icon(Icons.remove_rounded),
              ),
              SizedBox(
                width: 140,
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    SubtitleDelay.format(delay.seconds),
                    key: const ValueKey('subdelay-value'),
                    textAlign: TextAlign.center,
                    style: t.headlineSmall?.copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                        color: delay.isZero ? AppColors.textDim : null),
                  ),
                ),
              ),
              IconButton.filledTonal(
                key: const ValueKey('subdelay-plus'),
                tooltip: tr('Untertitel später'),
                iconSize: 28,
                autofocus: true,
                onPressed: delay.atMax ? null : () => delay.adjust(1),
                icon: const Icon(Icons.add_rounded),
              ),
            ]),
            const SizedBox(height: 10),
            Text(
              tr('Minus: Untertitel erscheinen früher · Plus: später. Gilt bis zum nächsten Sender/Film.'),
              textAlign: TextAlign.center,
              style: t.bodySmall?.copyWith(color: AppColors.textDim),
            ),
            const SizedBox(height: 16),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              TextButton.icon(
                key: const ValueKey('subdelay-reset'),
                onPressed: delay.isZero ? null : delay.reset,
                icon: const Icon(Icons.restart_alt_rounded, size: 18),
                label: Text(tr('Zurücksetzen')),
              ),
              const SizedBox(width: 8),
              FilledButton.tonal(
                key: const ValueKey('subdelay-close'),
                onPressed: () => Navigator.of(context).maybePop(),
                child: Text(tr('Schließen')),
              ),
            ]),
          ]),
        ),
      ),
    );
  }
}
