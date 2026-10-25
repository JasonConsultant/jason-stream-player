/// Zapping-Schutz: Bei schnellen CH±-Drücken zeigt der Player den neuen
/// Sender sofort an, öffnet den Stream aber erst nach kurzer Ruhe. Viele
/// Stream-Öffnungen in wenigen Sekunden führen bei manchen Anbietern zu
/// HTTP 429/458 (Sperre); ein einzelner Druck schaltet ohne Verzögerung.
///
/// Reine Logik (Uhr von außen): [press] liefert die Wartezeit bis zum
/// Öffnen. Der Aufrufer bricht ein noch wartendes Öffnen beim nächsten
/// Druck ab – nur der letzte Sender wird geöffnet.
class ZapGuard {
  /// Ruhe, nach der ein schneller Druck den Stream öffnet.
  final Duration settle;

  /// Liegt der letzte Druck länger zurück, gilt ein Druck als einzeln.
  final Duration burst;
  ZapGuard({
    this.settle = const Duration(milliseconds: 500),
    this.burst = const Duration(milliseconds: 1500),
  });

  DateTime? _last;

  /// Ein Umschalt-Druck zum Zeitpunkt [now]; liefert die Wartezeit bis zum
  /// Öffnen (Duration.zero = sofort).
  Duration press(DateTime now) {
    final last = _last;
    _last = now;
    if (last == null) return Duration.zero;
    final gap = now.difference(last);
    if (gap.isNegative || gap >= burst) return Duration.zero;
    return settle;
  }

  void reset() => _last = null;
}
