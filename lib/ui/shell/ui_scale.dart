import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart';

/// Oberflächengröße: Die ganze App wird gleichmäßig vergrößert (wie die
/// Android-Einstellung „Anzeigegröße“). „Automatisch“ = Normal, auch auf dem
/// Fernseher (die Dichte dort ergibt sich aus dem TV-Layout).
const uiScaleOptions = <String, double>{
  'sehrklein': 0.75,
  'klein': 0.85,
  'normal': 1.0,
  'gross': 1.15,
  'sehrgross': 1.3,
};

/// Gewählte Größe ('auto' = überall Normal).
final uiScaleProvider = Provider<double>((ref) {
  final st = ref.watch(storageProvider).value;
  final choice = st?.option('uiscale', 'auto') ?? 'auto';
  if (choice == 'auto') return 1.0;
  return uiScaleOptions[choice] ?? 1.0;
});

class UiScale extends ConsumerWidget {
  final Widget child;
  const UiScale({super.key, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(uiScaleProvider);
    if (s == 1.0) return child;
    final mq = MediaQuery.of(context);
    final size = Size(mq.size.width / s, mq.size.height / s);
    // Inhalt in der kleineren „logischen“ Größe aufbauen und dann exakt auf
    // den Bildschirm hochskalieren. FittedBox gibt dem Kind lockere Maße
    // (sonst würde es auf Bildschirmgröße gezwungen und ragte nach dem
    // Vergrößern rechts/unten heraus) und rechnet Touch/Fokus korrekt um.
    return MediaQuery(
      data: mq.copyWith(
        size: size,
        devicePixelRatio: mq.devicePixelRatio * s,
        padding: mq.padding / s,
        viewPadding: mq.viewPadding / s,
        viewInsets: mq.viewInsets / s,
      ),
      child: FittedBox(
        fit: BoxFit.fill,
        alignment: Alignment.topLeft,
        child: SizedBox(width: size.width, height: size.height, child: child),
      ),
    );
  }
}
