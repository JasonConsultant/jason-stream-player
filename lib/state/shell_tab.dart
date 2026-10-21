import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Reiter-Nummern der Hauptansicht (Reihenfolge wie in home_shell.dart).
abstract final class ShellTab {
  static const guide = 2;
}

/// Wunsch, in der Hauptansicht einen bestimmten Reiter zu öffnen – z. B. die
/// blaue Taste im Player („TV-Guide“). Die Hauptansicht hört darauf, wechselt
/// den Reiter und setzt den Wunsch wieder auf `null`.
class ShellTabRequest extends Notifier<int?> {
  @override
  int? build() => null;

  void open(int tab) => state = tab;
  void clear() => state = null;
}

final shellTabRequestProvider =
    NotifierProvider<ShellTabRequest, int?>(ShellTabRequest.new);
