import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/platform_info.dart';
import '../data/storage.dart';
import '../models/models.dart';
import '../state/providers.dart';

/// Verfügbare Wiedergabe-Engines.
enum EngineKind {
  /// Media3/ExoPlayer (Android, Standard).
  exo('exo'),

  /// mpv über media_kit (Rückfall, alle Plattformen).
  mpv('mpv');

  const EngineKind(this.id);
  final String id;

  /// Einstellung „Player-Engine“.
  static const optionKey = 'engine';

  static EngineKind fromId(String? id) => id == 'mpv' ? mpv : exo;

  EngineKind get other => this == exo ? mpv : exo;

  /// Anzeige im Player/Einstellungen (Eigennamen, nicht übersetzt).
  String get label => this == exo ? 'ExoPlayer' : 'mpv';
}

/// Gibt es ExoPlayer auf diesem Gerät? (Android; Tests überschreiben.)
final exoAvailableProvider = Provider<bool>((_) => PlatformInfo.isAndroid);

/// Eingestellte Engine (ohne Merkliste): ExoPlayer, wenn verfügbar und nicht
/// auf mpv gestellt.
EngineKind preferredEngine(Storage? st, {required bool exoAvailable}) {
  if (!exoAvailable) return EngineKind.mpv;
  return EngineKind.fromId(st?.option(EngineKind.optionKey, 'exo'));
}

/// Schlüssel zum Merken der Engine: Sender (Portal + Sender-Kennung) bzw.
/// Film/Folge (Fortsetzen-Schlüssel oder Adresse).
String? engineMemoryKey(PlayRequest req, {String? portalId, Channel? channel}) {
  if (req.isLive) {
    final c = channel ?? req.channel;
    if (c == null) return null;
    return 'ch:${portalId ?? ''}:${c.id}';
  }
  final k = req.resumeKey;
  if (k != null && k.isNotEmpty) return 'vod:$k';
  return req.url.isEmpty ? null : 'url:${req.url.hashCode}';
}

/// Merkt sich Sender/Filme, die mit ExoPlayer nicht liefen (Rückfall auf
/// mpv): für die Sitzung im Speicher, Sender zusätzlich dauerhaft.
class EngineMemory extends Notifier<Set<String>> {
  /// Dauerhafte Liste der Sender (Einstellung, kommagetrennt).
  static const storageKey = 'engine_mpv_channels';
  static const maxPersistent = 300;

  @override
  Set<String> build() => const {};

  Storage? get _st => ref.read(storageProvider).value;

  Set<String> _persistent() {
    final raw = _st?.option(storageKey, '') ?? '';
    return {
      for (final p in raw.split(','))
        if (p.isNotEmpty) Uri.decodeComponent(p)
    };
  }

  /// Soll für [key] gleich mpv genommen werden?
  bool prefersMpv(String? key) {
    if (key == null) return false;
    return state.contains(key) || _persistent().contains(key);
  }

  /// Nach dem Rückfall auf mpv merken ([persist]: auch nach Neustart).
  Future<void> rememberMpv(String? key, {bool persist = false}) async {
    if (key == null) return;
    state = {...state, key};
    if (!persist) return;
    final st = _st;
    if (st == null) return;
    final list = _persistent().toList()..remove(key);
    list.add(key);
    while (list.length > maxPersistent) {
      list.removeAt(0);
    }
    await st.setOption(
        storageKey, list.map(Uri.encodeComponent).join(','));
  }

  /// Wieder mit der eingestellten Engine probieren.
  Future<void> forget(String? key) async {
    if (key == null) return;
    state = {...state}..remove(key);
    final st = _st;
    if (st == null) return;
    final list = _persistent();
    if (!list.remove(key)) return;
    await st.setOption(
        storageKey, list.map(Uri.encodeComponent).join(','));
  }

  /// Dauerhaft gemerkte Sender (Einstellungen: Zahl/Zurücksetzen).
  int get persistentCount => _persistent().length;

  Future<void> clearPersistent() async {
    state = const {};
    await _st?.setOption(storageKey, '');
  }
}

final engineMemoryProvider =
    NotifierProvider<EngineMemory, Set<String>>(EngineMemory.new);
