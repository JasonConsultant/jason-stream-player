import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';

import '../../core/platform_info.dart';
import '../../core/theme.dart';
import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../../app.dart' show Wordmark;
import 'reminder_host.dart' show appNavigatorKey;

/// App-Sperre per Fingerabdruck / Gesicht / Geräte-PIN.
class AppLock {
  static final _auth = LocalAuthentication();

  /// Kann das Gerät sperren? (Bildschirmsperre muss eingerichtet sein)
  static Future<bool> available() async {
    if (kIsWeb || !PlatformInfo.isAndroid) return false;
    try {
      return await _auth.isDeviceSupported();
    } catch (_) {
      return false;
    }
  }

  static Future<bool> authenticate() async {
    try {
      return await _auth.authenticate(
        localizedReason: tr('Jason Stream Player entsperren'),
        persistAcrossBackgrounding: true,
      );
    } catch (_) {
      return false;
    }
  }
}

/// Schützt die App: blockiert veränderte Kopien, warnt bei Root/Debugger
/// und zeigt die App-Sperre.
class AppGuard extends ConsumerStatefulWidget {
  final Widget child;
  const AppGuard({super.key, required this.child});

  @override
  ConsumerState<AppGuard> createState() => _AppGuardState();
}

class _AppGuardState extends ConsumerState<AppGuard>
    with WidgetsBindingObserver {
  bool _tampered = false;
  bool _locked = false;
  bool _lockChecked = false;
  bool _authBusy = false;
  DateTime? _backgroundSince;

  /// Nach so langer Zeit im Hintergrund wird wieder gesperrt.
  static const _relockAfter = Duration(minutes: 1);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkIntegrity();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _checkIntegrity() async {
    final r = await PlatformInfo.integrity();
    if (!mounted) return;
    if (!r.signatureOk) {
      setState(() => _tampered = true);
      return;
    }
    if (r.rooted || r.debugger) {
      final st = await ref.read(storageProvider.future);
      if (st.flag('riskack')) return;
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _riskWarning(r.debugger));
    }
  }

  Future<void> _riskWarning(bool debugger) async {
    final ctx = appNavigatorKeyContext();
    if (ctx == null) return;
    final ack = await showDialog<bool>(
      context: ctx,
      builder: (c) => AlertDialog(
        icon: const Icon(Icons.gpp_maybe_rounded, color: AppColors.gold),
        title: Text(tr('Sicherheitshinweis')),
        content: Text(debugger
            ? tr('An die App ist ein Debugger angeschlossen. Fremde Programme '
                'könnten Daten der App mitlesen.')
            : tr(
                'Dieses Gerät ist gerootet. Andere Apps mit Root-Rechten können '
                'Daten aller Apps lesen – auch deine Zugangsdaten. Nutze die App '
                'nur, wenn du allen Root-Apps vertraust.')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, true),
              child: Text(tr('Nicht mehr anzeigen'))),
          FilledButton(
              autofocus: true,
              onPressed: () => Navigator.pop(c, false),
              child: Text(tr('Verstanden'))),
        ],
      ),
    );
    if (ack == true) {
      final st = await ref.read(storageProvider.future);
      await st.setFlag('riskack', true);
    }
  }

  Future<void> _initialLock() async {
    if (_lockChecked) return;
    final st = ref.read(storageProvider).value;
    if (st == null) return;
    _lockChecked = true;
    if (st.flag('applock') && await AppLock.available()) {
      setState(() => _locked = true);
      _unlock();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    final st = ref.read(storageProvider).value;
    if (st == null || !st.flag('applock')) return;
    if (s == AppLifecycleState.paused || s == AppLifecycleState.hidden) {
      // Während der Fingerabdruck-Abfrage geht die App kurz in den
      // Hintergrund – das zählt nicht.
      if (!_authBusy) _backgroundSince ??= DateTime.now();
    } else if (s == AppLifecycleState.resumed) {
      final since = _backgroundSince;
      _backgroundSince = null;
      if (since != null &&
          DateTime.now().difference(since) >= _relockAfter &&
          !_locked) {
        setState(() => _locked = true);
        _unlock();
      }
    }
  }

  Future<void> _unlock() async {
    if (_authBusy) return;
    _authBusy = true;
    // Bildschirmsperre inzwischen entfernt → Abfrage kann nie gelingen;
    // sonst wäre die App dauerhaft gesperrt.
    final ok = !await AppLock.available() || await AppLock.authenticate();
    _authBusy = false;
    if (ok && mounted) setState(() => _locked = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_tampered) return const _TamperedScreen();
    ref.listen(storageProvider, (_, __) => _initialLock());
    if (!_lockChecked) Future.microtask(_initialLock);
    // Bis bekannt ist, ob die Sperre an ist: Inhalt nicht zeigen (sonst
    // blitzt er kurz auf). Dauert normalerweise nur Millisekunden.
    final hide = !_lockChecked && ref.read(storageProvider).value == null;
    return Stack(children: [
      // Gesperrt: Inhalt darunter weder antippbar noch per D-Pad erreichbar.
      IgnorePointer(
        ignoring: _locked,
        child: ExcludeFocus(excluding: _locked, child: widget.child),
      ),
      if (hide) const Positioned.fill(child: ColoredBox(color: AppColors.bg)),
      if (_locked) Positioned.fill(child: _LockScreen(onUnlock: _unlock)),
    ]);
  }
}

BuildContext? appNavigatorKeyContext() =>
    appNavigatorKey.currentState?.overlay?.context;

class _LockScreen extends StatefulWidget {
  final VoidCallback onUnlock;
  const _LockScreen({required this.onUnlock});

  @override
  State<_LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<_LockScreen> {
  // Kein BackButtonListener: der braucht einen Router (gibt es hier nicht)
  // und ließ die Sperrseite mit einem Fehler leer. Stattdessen schluckt die
  // Sperre die Zurück-Taste der Fernbedienung, solange sie sichtbar ist.
  KeyEventResult _swallowBack(KeyEvent e) =>
      e.logicalKey == LogicalKeyboardKey.goBack ||
              e.logicalKey == LogicalKeyboardKey.escape
          ? KeyEventResult.handled
          : KeyEventResult.ignored;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addEarlyKeyEventHandler(_swallowBack);
  }

  @override
  void dispose() {
    FocusManager.instance.removeEarlyKeyEventHandler(_swallowBack);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FocusScope(
        // Eigener Fokusbereich: „Entsperren“ bekommt den Fokus (OK genügt),
        // obwohl die App darunter zuletzt etwas anderes fokussiert hatte.
        child: Material(
          color: AppColors.bg,
          child: Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Wordmark(size: 26),
              const SizedBox(height: 36),
              const Icon(Icons.lock_rounded, size: 48, color: AppColors.accent),
              const SizedBox(height: 16),
              Text(tr('App gesperrt'),
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 24),
              FilledButton.icon(
                autofocus: true,
                onPressed: widget.onUnlock,
                icon: const Icon(Icons.fingerprint_rounded),
                label: Text(tr('Entsperren')),
              ),
            ]),
          ),
        ),
      );
}

class _TamperedScreen extends StatelessWidget {
  const _TamperedScreen();

  @override
  Widget build(BuildContext context) => Material(
        color: AppColors.bg,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.gpp_bad_rounded,
                    size: 64, color: AppColors.live),
                const SizedBox(height: 20),
                Text(tr('Veränderte App erkannt'),
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 12),
                Text(
                  tr('Diese Kopie von Jason Stream Player wurde verändert und '
                      'ist nicht vom Entwickler signiert. Sie könnte deine '
                      'Zugangsdaten stehlen. Bitte deinstallieren und nur die '
                      'Original-APK verwenden.'),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 24),
                FilledButton(
                  autofocus: true,
                  onPressed: () => SystemNavigator.pop(),
                  child: Text(tr('Beenden')),
                ),
              ]),
            ),
          ),
        ),
      );
}

/// Für die Einstellungen: App-Sperre an/aus (mit Bestätigung).
Future<bool> toggleAppLock(WidgetRef ref, bool on) async {
  if (on) {
    if (!await AppLock.available()) return false;
    if (!await AppLock.authenticate()) return false;
  }
  final st = await ref.read(storageProvider.future);
  await st.setFlag('applock', on);
  return true;
}
