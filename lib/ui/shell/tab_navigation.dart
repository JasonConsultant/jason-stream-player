import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Handy/Tablet (1.9): je Reiter der Hauptnavigation ein eigener
/// Navigator-Stapel, Material-3-Seitenübergänge mit vorausschauendem
/// Zurück (Android 14+) und Systemleisten randlos. Der Fernseher nutzt nichts
/// davon (eigene Leiste, TvSafePageTransitionsBuilder).

/// Seitenübergang Handy/Tablet: vorausschauendes Zurück (Geste zieht die
/// Seite mit), sonst „Fade forwards“ – kürzer als die Vorgabe. Bei
/// „Animationen entfernen“ (Bedienungshilfen) ohne Animation.
class AppPageTransitionsBuilder extends PredictiveBackPageTransitionsBuilder {
  const AppPageTransitionsBuilder();

  static const duration = Duration(milliseconds: 300);
  static const reverseDuration = Duration(milliseconds: 250);

  @override
  Duration get transitionDuration => duration;

  @override
  Duration get reverseTransitionDuration => reverseDuration;

  /// Für alle Plattformen (Android, Desktop-Fenster beim Entwickeln).
  static PageTransitionsTheme theme() => PageTransitionsTheme(builders: {
        for (final p in TargetPlatform.values)
          p: const AppPageTransitionsBuilder(),
      });

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) return child;
    return super.buildTransitions(
        route, context, animation, secondaryAnimation, child);
  }
}

/// Systemleisten randlos und durchsichtig, helle Symbole (dunkles Design).
const appSystemUiStyle = SystemUiOverlayStyle(
  statusBarColor: Colors.transparent,
  statusBarIconBrightness: Brightness.light,
  statusBarBrightness: Brightness.dark,
  systemNavigationBarColor: Colors.transparent,
  systemNavigationBarDividerColor: Colors.transparent,
  systemNavigationBarIconBrightness: Brightness.light,
  systemNavigationBarContrastEnforced: false,
  systemStatusBarContrastEnforced: false,
);

/// Navigator eines Reiters. [active]: Reiter sichtbar und die Hauptansicht
/// oben (kein Player/Dialog darüber). Nur dann dürfen seine Seiten die
/// Zurück-Geste annehmen – sonst zöge die Geste eine verdeckte Seite mit.
class TabNavigator extends StatefulWidget {
  final GlobalKey<NavigatorState> navigatorKey;
  final ValueListenable<bool> active;
  final Widget child;
  const TabNavigator({
    super.key,
    required this.navigatorKey,
    required this.active,
    required this.child,
  });

  @override
  State<TabNavigator> createState() => _TabNavigatorState();
}

class _TabNavigatorState extends State<TabNavigator> {
  late final _guard = _GestureGuard(widget.active);

  @override
  Widget build(BuildContext context) {
    return Navigator(
      key: widget.navigatorKey,
      observers: [_guard],
      onGenerateInitialRoutes: (_, __) => [
        MaterialPageRoute<void>(
          settings: const RouteSettings(name: Navigator.defaultRouteName),
          builder: (_) => widget.child,
        ),
      ],
    );
  }
}

/// Meldet an jeder Seite des Reiter-Stapels einen [PopEntry] an, der nur
/// bei aktivem Reiter „darf schließen“ meldet.
class _GestureGuard extends NavigatorObserver {
  final ValueListenable<bool> active;
  _GestureGuard(this.active);

  final _entries = <Route<dynamic>, _ActiveEntry>{};

  void _add(Route<dynamic>? r) {
    if (r is! ModalRoute || _entries.containsKey(r)) return;
    final e = _ActiveEntry(active);
    _entries[r] = e;
    r.registerPopEntry(e);
  }

  void _remove(Route<dynamic>? r) {
    final e = _entries.remove(r);
    if (e != null && r is ModalRoute) r.unregisterPopEntry(e);
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _add(route);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _remove(route);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _remove(route);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _remove(oldRoute);
    _add(newRoute);
  }
}

class _ActiveEntry extends PopEntry<Object?> {
  @override
  final ValueListenable<bool> canPopNotifier;
  _ActiveEntry(this.canPopNotifier);

  @override
  void onPopInvokedWithResult(bool didPop, Object? result) {}
}
