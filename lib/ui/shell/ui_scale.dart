import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart';

/// Oberflächengröße: Die ganze App wird gleichmäßig vergrößert (wie die
/// Android-Einstellung „Anzeigegröße“) – auf dem Fernseher standardmäßig
/// „Groß“, damit alles vom Sofa aus lesbar ist.
const uiScaleOptions = <String, double>{
  'normal': 1.0,
  'gross': 1.2,
  'sehrgross': 1.4,
};

/// Gewählte Größe ('auto' = Fernseher groß, sonst normal).
final uiScaleProvider = Provider<double>((ref) {
  final st = ref.watch(storageProvider).value;
  final tv = ref.watch(isTvProvider);
  final choice = st?.option('uiscale', 'auto') ?? 'auto';
  if (choice == 'auto') return tv ? 1.2 : 1.0;
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
    return MediaQuery(
      data: mq.copyWith(
        size: size,
        devicePixelRatio: mq.devicePixelRatio * s,
        padding: mq.padding / s,
        viewPadding: mq.viewPadding / s,
        viewInsets: mq.viewInsets / s,
      ),
      child: Transform.scale(
        scale: s,
        alignment: Alignment.topLeft,
        child: SizedBox(width: size.width, height: size.height, child: child),
      ),
    );
  }
}
