import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:jsp_exoplayer/jsp_cast.dart';

import '../core/platform_info.dart';
import '../state/providers.dart';

/// Einstellung „Datensparmodus im Mobilfunk“ (nur Handy/Tablet).
enum DataSaverMode {
  off('off'),

  /// Nur bei Mobilfunk bzw. gemessener (getakteter) Verbindung.
  auto('auto'),
  always('always');

  const DataSaverMode(this.id);
  final String id;

  static const optionKey = 'datasaver';

  static DataSaverMode fromId(String? id) => switch (id) {
        'auto' => auto,
        'always' => always,
        _ => off,
      };
}

/// Ist der Datensparmodus gerade wirksam? (Modus × Verbindung; Fernseher nie.)
bool dataSaverActive(DataSaverMode mode, JspNetState net, {bool tv = false}) {
  if (tv) return false;
  return switch (mode) {
    DataSaverMode.off => false,
    DataSaverMode.always => true,
    DataSaverMode.auto => net.connected && (net.cellular || net.metered),
  };
}

/// Was der Datensparmodus an den Engines ändert.
abstract final class DataSaverTuning {
  /// Höchste Video-Bitrate der HLS/DASH-Stufe (ExoPlayer).
  static const maxVideoBitrate = 1500000;

  /// Höchste Bildhöhe (ExoPlayer; 720p genügt auf dem Handy).
  static const maxVideoHeight = 720;

  /// mpv: niedrigste HLS-Stufe bzw. wieder die beste (mpv-Standard „max“).
  /// ExoPlayer bildet `hls-bitrate` auf [maxVideoBitrate]/[maxVideoHeight] ab.
  static Map<String, String> mpv(bool on) => {'hls-bitrate': on ? 'min' : 'max'};

  /// Bildbreite für Poster/Hintergründe im Datensparmodus (Medienserver).
  static const imageMaxWidth = 240;
  static const imageQuality = 60;

  /// TMDB-Größe (Xtream-Poster kommen oft von image.tmdb.org).
  static const tmdbSize = 'w185';

  static final _tmdb = RegExp(r'(image\.tmdb\.org/t/p/)([^/]+)/');

  /// Bildadresse in reduzierter Größe laden, wo der Server das anbietet
  /// (TMDB-Größen, Emby/Jellyfin `maxWidth`/`quality`). Andere Adressen
  /// bleiben unverändert (die Anzeige verkleinert ohnehin beim Dekodieren).
  static String smallImage(String url) {
    if (_tmdb.hasMatch(url)) {
      return url.replaceFirstMapped(_tmdb, (m) => '${m[1]}$tmdbSize/');
    }
    final u = Uri.tryParse(url);
    if (u == null || !u.path.contains('/Images/')) return url;
    final q = {...u.queryParameters};
    if (!q.containsKey('maxWidth') && !q.containsKey('tag')) return url;
    final w = int.tryParse(q['maxWidth'] ?? '');
    q['maxWidth'] = '${w == null || w > imageMaxWidth ? imageMaxWidth : w}';
    q['quality'] = '$imageQuality';
    return u.replace(queryParameters: q).toString();
  }
}

/// Für Stellen ohne Provider-Zugriff (Bilder in Listen): zuletzt berechneter
/// Zustand.
abstract final class DataSaver {
  static bool active = false;

  /// Bildadresse je nach Zustand.
  static String image(String url) =>
      active ? DataSaverTuning.smallImage(url) : url;
}

/// Verbindungsart (Plugin-Kanal; ohne Android: unbekannt = WLAN-artig).
/// Tests überschreiben mit einem eigenen Stream.
final networkStateProvider = StreamProvider<JspNetState>((ref) {
  if (!PlatformInfo.isAndroid) return Stream.value(JspNetState.unknown);
  return const JspNetwork().watch();
});

/// Eingestellter Modus.
class DataSaverModeNotifier extends Notifier<DataSaverMode> {
  @override
  DataSaverMode build() {
    final st = ref.watch(storageProvider).value;
    return DataSaverMode.fromId(st?.option(DataSaverMode.optionKey, 'off'));
  }

  Future<void> set(DataSaverMode m) async {
    state = m;
    await ref
        .read(storageProvider)
        .value
        ?.setOption(DataSaverMode.optionKey, m.id);
  }
}

final dataSaverModeProvider =
    NotifierProvider<DataSaverModeNotifier, DataSaverMode>(
        DataSaverModeNotifier.new);

/// Datensparmodus gerade wirksam? (Ändert sich live mit der Verbindung.)
final dataSaverActiveProvider = Provider<bool>((ref) {
  final on = dataSaverActive(
    ref.watch(dataSaverModeProvider),
    ref.watch(networkStateProvider).value ?? JspNetState.unknown,
    tv: ref.watch(isTvProvider),
  );
  DataSaver.active = on;
  return on;
});
