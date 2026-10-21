import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Sicherer Bereich auf dem Fernseher (Overscan): Viele Fernseher schneiden
/// ringsum bis zu ~5 % des Bildes ab. Bedienelemente und Text gehören
/// deshalb nicht näher als [TvSafe.insets] an den Bildschirmrand
/// (960×540 dp → 48 dp links/rechts, 27 dp oben/unten).
///
/// Umgesetzt an zentraler Stelle:
/// - [TvSafeMediaQuery] (App-Builder) meldet die Ränder als
///   `MediaQuery.padding` – jede [SafeArea] (Blätter, Player-Overlays,
///   Detailseiten) hält sie damit automatisch ein.
/// - [TvSafePageTransitionsBuilder] (Theme) rückt den Inhalt aller
///   `MaterialPageRoute`-Seiten ein.
/// - Die Hauptnavigation (HomeShell) rückt ihren Inhalt selbst ein.
///
/// Das Video im Player bleibt randlos; nur dessen Overlays sollen
/// [TvSafe.insets] einhalten.
class TvSafe {
  TvSafe._();

  static const double horizontal = 48;
  static const double vertical = 27;

  /// Mindestabstand zum Bildschirmrand auf dem Fernseher.
  static const EdgeInsets insets =
      EdgeInsets.symmetric(horizontal: horizontal, vertical: vertical);

  static EdgeInsets _max(EdgeInsets a, EdgeInsets b) => EdgeInsets.fromLTRB(
        math.max(a.left, b.left),
        math.max(a.top, b.top),
        math.max(a.right, b.right),
        math.max(a.bottom, b.bottom),
      );

  /// [mq] mit mindestens [insets] als padding/viewPadding.
  static MediaQueryData apply(MediaQueryData mq) => mq.copyWith(
        padding: _max(mq.padding, insets),
        viewPadding: _max(mq.viewPadding, insets),
      );
}

/// App-Builder: meldet auf dem Fernseher die Overscan-Ränder als
/// `MediaQuery.padding`. Ohne Fernseher unverändert.
class TvSafeMediaQuery extends StatelessWidget {
  final bool enabled;
  final Widget child;
  const TvSafeMediaQuery(
      {super.key, required this.enabled, required this.child});

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    final mq = MediaQuery.maybeOf(context);
    if (mq == null) return child;
    return MediaQuery(data: TvSafe.apply(mq), child: child);
  }
}

/// Rückt [child] auf dem Fernseher um mindestens [TvSafe.insets] (bzw. das
/// gemeldete MediaQuery.padding) ein; der Rand bekommt die
/// Hintergrundfarbe. Darunterliegende [SafeArea]s polstern nicht doppelt
/// (das padding ist für sie verbraucht).
class TvSafeArea extends StatelessWidget {
  final bool enabled;
  final Widget child;

  /// Zusätzlich zu [TvSafe.insets] erzwungene Mindestränder.
  final EdgeInsets minimum;
  const TvSafeArea({
    super.key,
    required this.enabled,
    required this.child,
    this.minimum = TvSafe.insets,
  });

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    return ColoredBox(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: SafeArea(minimum: minimum, child: child),
    );
  }
}

/// Seitenübergang, der den Inhalt jeder `MaterialPageRoute` auf dem
/// Fernseher in den sicheren Bereich rückt. Die erste Seite (Hauptnavigation,
/// „/“) regelt ihre Ränder selbst; der Player nutzt eine eigene Route und
/// bleibt randlos.
class TvSafePageTransitionsBuilder extends PageTransitionsBuilder {
  /// Eigentlicher Übergang; null = Standard der Plattform.
  final PageTransitionsBuilder? inner;
  const TvSafePageTransitionsBuilder({this.inner});

  /// Theme-Einstellung: alle Plattformen über diesen Builder.
  static PageTransitionsTheme theme() => PageTransitionsTheme(builders: {
        for (final p in TargetPlatform.values)
          p: TvSafePageTransitionsBuilder(
              inner: const PageTransitionsTheme().builders[p]),
      });

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final first = route.settings.name == Navigator.defaultRouteName;
    final b = inner ?? const ZoomPageTransitionsBuilder();
    return b.buildTransitions(route, context, animation, secondaryAnimation,
        first ? child : TvSafeArea(enabled: true, child: child));
  }
}
