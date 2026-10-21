import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../state/providers.dart';

/// Gespeicherte Akzentfarbe (Schlüssel aus [AppColors.accentPresets]).
const accentOptionKey = 'accent';

final accentKeyProvider = Provider<String>((ref) {
  final st = ref.watch(storageProvider).value;
  final k = st?.option(accentOptionKey, AppColors.defaultAccent) ??
      AppColors.defaultAccent;
  return AppColors.accentPresets.containsKey(k) ? k : AppColors.defaultAccent;
});

/// Übernimmt [key] als Akzentfarbe. Hat sie sich geändert, werden nach dem
/// Bild alle Widgets neu aufgebaut – auch solche, die [AppColors.accent]
/// direkt lesen und nicht vom Theme abhängen.
void applyAccent(String key) {
  if (!AppColors.setAccent(key)) return;
  final binding = WidgetsBinding.instance;
  binding.addPostFrameCallback((_) {
    final root = binding.rootElement;
    if (root == null) return;
    void mark(Element e) {
      e.markNeedsBuild();
      e.visitChildren(mark);
    }

    root.visitChildren(mark);
  });
}
