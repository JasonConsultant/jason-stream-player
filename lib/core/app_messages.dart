import 'package:flutter/material.dart';

/// Meldungen ohne eigenen BuildContext (z. B. aus dem PlaybackController,
/// während nur der Mini-Player sichtbar ist).
final appMessengerKey = GlobalKey<ScaffoldMessengerState>();

abstract final class AppMessages {
  /// Zuletzt gezeigte Meldungen (Tests/Diagnose, höchstens 20).
  static final history = <String>[];

  static void show(String text) {
    history.add(text);
    if (history.length > 20) history.removeAt(0);
    appMessengerKey.currentState
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
          content: Text(text), duration: const Duration(seconds: 5)));
  }
}
