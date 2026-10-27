import 'dart:async';

import 'package:flutter/services.dart';

import 'protocol.dart';

/// Tasten der Handy-Fernbedienung als echte Tastenereignisse am Fernseher.
///
/// Die Ereignisse laufen denselben Weg wie die einer Fernbedienung, die
/// Android an Flutter meldet: erst [HardwareKeyboard] (gedrückte Tasten,
/// globale Handler), dann der Schlüssel-Handler des Fokus-Systems
/// (`KeyEventManager.keyMessageHandler` = FocusManager) – also frühe
/// Handler, Fokus-Knoten, Shortcuts/Actions. Fokusverhalten, Tasten-Takt
/// (KeyPacer), PIN-Dialoge und Sperren verhalten sich dadurch genau wie mit
/// der Fernbedienung.
///
/// Gedrückt halten: KeyDown, nach [repeatDelay] KeyRepeat alle
/// [repeatInterval] (Android-Vorgaben: 500 ms / 50 ms), KeyUp beim Loslassen.
/// Kommt kein Loslassen (Verbindung weg), endet das Halten spätestens nach
/// [maxHold] bzw. mit [releaseAll].
class KeyInjector {
  /// Vorgabe: Ereignis wie vom System einspeisen. Tests ersetzen das.
  final bool Function(KeyEvent e) dispatch;

  /// Zurück wurde von keinem Element verbraucht → System-Zurück (wie
  /// Android: Activity → „popRoute“).
  final void Function() onUnhandledBack;

  final Duration repeatDelay;
  final Duration repeatInterval;
  final Duration maxHold;

  KeyInjector({
    bool Function(KeyEvent e)? dispatch,
    void Function()? onUnhandledBack,
    this.repeatDelay = const Duration(milliseconds: 500),
    this.repeatInterval = const Duration(milliseconds: 50),
    this.maxHold = const Duration(seconds: 15),
  })  : dispatch = dispatch ?? systemDispatch,
        onUnhandledBack = onUnhandledBack ?? systemBack;

  final _held = <RemoteKey, _Hold>{};

  /// Gerade gehaltene Tasten (Tests).
  Iterable<RemoteKey> get held => _held.keys;

  /// Taste kurz drücken (Down + Up).
  void tap(RemoteKey k) {
    if (k.isVolume || k == RemoteKey.home) return;
    if (_held.containsKey(k)) up(k);
    down(k, hold: false);
    up(k);
  }

  /// Taste drücken; [hold] = Wiederholung bis [up].
  void down(RemoteKey k, {bool hold = true}) {
    if (k.isVolume || k == RemoteKey.home) return;
    if (_held.containsKey(k)) return; // schon gedrückt (doppelte Nachricht)
    final keys = remoteKeyMap[k]!;
    final h = _Hold(keys.$1, keys.$2);
    _held[k] = h;
    h.handled = dispatch(KeyDownEvent(
        physicalKey: keys.$2, logicalKey: keys.$1, timeStamp: _now()));
    if (hold && k.repeats) {
      h.timer = Timer(repeatDelay, () {
        h.timer = Timer.periodic(repeatInterval, (_) {
          if (_held[k] != h) return;
          dispatch(KeyRepeatEvent(
              physicalKey: keys.$2, logicalKey: keys.$1, timeStamp: _now()));
        });
      });
    }
    h.limit = Timer(maxHold, () => up(k));
  }

  void up(RemoteKey k) {
    final h = _held.remove(k);
    if (h == null) return;
    h.cancel();
    dispatch(KeyUpEvent(
        physicalKey: h.physical, logicalKey: h.logical, timeStamp: _now()));
    if (k == RemoteKey.back && !h.handled) onUnhandledBack();
  }

  /// Alle gehaltenen Tasten loslassen (Verbindung beendet, Dienst aus).
  void releaseAll() {
    for (final k in _held.keys.toList()) {
      final h = _held.remove(k)!;
      h.cancel();
      dispatch(KeyUpEvent(
          physicalKey: h.physical, logicalKey: h.logical, timeStamp: _now()));
    }
  }

  static final _clock = Stopwatch()..start();
  static Duration _now() => _clock.elapsed;

  /// Wie eine echte Taste: HardwareKeyboard + Fokus-System.
  static bool systemDispatch(KeyEvent e) {
    final hw = HardwareKeyboard.instance;
    // Doppeltes Drücken derselben Taste (echte Fernbedienung hält sie
    // gerade) würde den Tastenzustand verwirren → nur die Fokus-Kette.
    final pressed = hw.physicalKeysPressed.contains(e.physicalKey);
    var handled = false;
    if (!(e is KeyDownEvent && pressed) &&
        !(e is KeyUpEvent && !pressed) &&
        !(e is KeyRepeatEvent && !pressed)) {
      handled = hw.handleKeyEvent(e);
    }
    // ignore: deprecated_member_use
    final handler = ServicesBinding.instance.keyEventManager.keyMessageHandler;
    if (handler != null) {
      // ignore: deprecated_member_use
      handled = handler(KeyMessage([e], null)) || handled;
    }
    return handled;
  }

  /// System-Zurück wie von Android (Navigator schließt Seite/Dialog, auf
  /// der Startseite geht die App in den Hintergrund).
  static void systemBack() {
    ServicesBinding.instance.channelBuffers.push(
        SystemChannels.navigation.name,
        SystemChannels.navigation.codec
            .encodeMethodCall(const MethodCall('popRoute')),
        (_) {});
  }
}

class _Hold {
  final LogicalKeyboardKey logical;
  final PhysicalKeyboardKey physical;
  Timer? timer;
  Timer? limit;
  bool handled = false;
  _Hold(this.logical, this.physical);

  void cancel() {
    timer?.cancel();
    limit?.cancel();
  }
}

/// Synthetische physische Taste (für Tasten ohne eigene Konstante).
PhysicalKeyboardKey _synthetic(LogicalKeyboardKey l) =>
    PhysicalKeyboardKey(0x11000000000 | (l.keyId & 0xffffffff));

/// Abbildung wie die Android-Tastencodes der Fernbedienung
/// (DPAD_* → Pfeile, DPAD_CENTER → select, BACK → goBack, MENU →
/// contextMenu, CHANNEL_UP/DOWN, 0–9, MEDIA_*, PROG_RED… → colorF0Red…,
/// INFO).
final Map<RemoteKey, (LogicalKeyboardKey, PhysicalKeyboardKey)> remoteKeyMap = {
  RemoteKey.up: (LogicalKeyboardKey.arrowUp, PhysicalKeyboardKey.arrowUp),
  RemoteKey.down: (LogicalKeyboardKey.arrowDown, PhysicalKeyboardKey.arrowDown),
  RemoteKey.left: (LogicalKeyboardKey.arrowLeft, PhysicalKeyboardKey.arrowLeft),
  RemoteKey.right:
      (LogicalKeyboardKey.arrowRight, PhysicalKeyboardKey.arrowRight),
  RemoteKey.ok: (LogicalKeyboardKey.select, PhysicalKeyboardKey.select),
  RemoteKey.back: (LogicalKeyboardKey.goBack, PhysicalKeyboardKey.browserBack),
  RemoteKey.home: (LogicalKeyboardKey.browserHome, PhysicalKeyboardKey.browserHome),
  RemoteKey.menu:
      (LogicalKeyboardKey.contextMenu, PhysicalKeyboardKey.contextMenu),
  RemoteKey.channelUp:
      (LogicalKeyboardKey.channelUp, PhysicalKeyboardKey.channelUp),
  RemoteKey.channelDown:
      (LogicalKeyboardKey.channelDown, PhysicalKeyboardKey.channelDown),
  RemoteKey.digit0: (LogicalKeyboardKey.digit0, PhysicalKeyboardKey.digit0),
  RemoteKey.digit1: (LogicalKeyboardKey.digit1, PhysicalKeyboardKey.digit1),
  RemoteKey.digit2: (LogicalKeyboardKey.digit2, PhysicalKeyboardKey.digit2),
  RemoteKey.digit3: (LogicalKeyboardKey.digit3, PhysicalKeyboardKey.digit3),
  RemoteKey.digit4: (LogicalKeyboardKey.digit4, PhysicalKeyboardKey.digit4),
  RemoteKey.digit5: (LogicalKeyboardKey.digit5, PhysicalKeyboardKey.digit5),
  RemoteKey.digit6: (LogicalKeyboardKey.digit6, PhysicalKeyboardKey.digit6),
  RemoteKey.digit7: (LogicalKeyboardKey.digit7, PhysicalKeyboardKey.digit7),
  RemoteKey.digit8: (LogicalKeyboardKey.digit8, PhysicalKeyboardKey.digit8),
  RemoteKey.digit9: (LogicalKeyboardKey.digit9, PhysicalKeyboardKey.digit9),
  RemoteKey.playPause:
      (LogicalKeyboardKey.mediaPlayPause, PhysicalKeyboardKey.mediaPlayPause),
  RemoteKey.rewind:
      (LogicalKeyboardKey.mediaRewind, PhysicalKeyboardKey.mediaRewind),
  RemoteKey.fastForward: (
    LogicalKeyboardKey.mediaFastForward,
    PhysicalKeyboardKey.mediaFastForward
  ),
  RemoteKey.red: (
    LogicalKeyboardKey.colorF0Red,
    _synthetic(LogicalKeyboardKey.colorF0Red)
  ),
  RemoteKey.green: (
    LogicalKeyboardKey.colorF1Green,
    _synthetic(LogicalKeyboardKey.colorF1Green)
  ),
  RemoteKey.yellow: (
    LogicalKeyboardKey.colorF2Yellow,
    _synthetic(LogicalKeyboardKey.colorF2Yellow)
  ),
  RemoteKey.blue: (
    LogicalKeyboardKey.colorF3Blue,
    _synthetic(LogicalKeyboardKey.colorF3Blue)
  ),
  RemoteKey.info: (LogicalKeyboardKey.info, PhysicalKeyboardKey.info),
  RemoteKey.volumeUp:
      (LogicalKeyboardKey.audioVolumeUp, PhysicalKeyboardKey.audioVolumeUp),
  RemoteKey.volumeDown: (
    LogicalKeyboardKey.audioVolumeDown,
    PhysicalKeyboardKey.audioVolumeDown
  ),
  RemoteKey.mute:
      (LogicalKeyboardKey.audioVolumeMute, PhysicalKeyboardKey.audioVolumeMute),
};
