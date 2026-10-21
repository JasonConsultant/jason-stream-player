import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../core/voice_search.dart';
import '../../l10n/strings.dart';
import 'focusable_tile.dart';

/// Gibt es eine Spracheingabe? (einmal geprüft, dann gemerkt)
final voiceAvailableProvider =
    FutureProvider<bool>((_) => VoiceSearch.available());

/// Suchbegriff für den Such-Tab, z. B. aus der Sprachsuche der Startseite
/// oder der Such-Taste der Fernbedienung. Der Such-Tab übernimmt ihn mit
/// [SearchRequestNotifier.take].
class SearchRequestNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  void request(String query) => state = query;

  String? take() {
    final q = state;
    if (q != null) state = null;
    return q;
  }
}

final searchRequestProvider =
    NotifierProvider<SearchRequestNotifier, String?>(SearchRequestNotifier.new);

/// Startet die Sprachsuche (falls verfügbar) und meldet den Text.
/// false = keine Spracheingabe auf dem Gerät.
Future<bool> startVoiceSearch(
    WidgetRef ref, ValueChanged<String> onResult) async {
  if (!await ref.read(voiceAvailableProvider.future)) return false;
  final text = await VoiceSearch.listen();
  if (text != null) onResult(text);
  return true;
}

/// Mikrofon-Knopf für Suchfelder. Nur sichtbar, wenn das Gerät eine
/// Spracheingabe hat; per D-Pad erreichbar (Fokusrahmen, OK startet).
class VoiceSearchButton extends ConsumerWidget {
  final ValueChanged<String> onResult;
  final double size;
  final double iconSize;
  const VoiceSearchButton({
    super.key,
    required this.onResult,
    this.size = 44,
    this.iconSize = 20,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(voiceAvailableProvider).value != true) {
      return const SizedBox.shrink();
    }
    return Tooltip(
      message: tr('Sprachsuche'),
      child: Semantics(
        button: true,
        label: tr('Sprachsuche'),
        child: FocusableTile(
          radius: BorderRadius.circular(size / 2),
          onTap: () => startVoiceSearch(ref, onResult),
          child: SizedBox(
            width: size,
            height: size,
            child: Icon(Icons.mic_rounded,
                size: iconSize, color: AppColors.textDim),
          ),
        ),
      ),
    );
  }
}
