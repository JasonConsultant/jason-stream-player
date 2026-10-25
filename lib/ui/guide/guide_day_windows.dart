import 'package:flutter/foundation.dart';

import '../../data/epg_matcher.dart' show epgKeyOf;
import '../../models/models.dart';

/// Programm eines anderen Tages im TV-Guide, fensterweise aus der
/// Datenbank (ab 2.0 hält der Speicher nur gestern … übermorgen).
///
/// Geladen wird je [window] Zeilen (Standard 200) auf einmal; nähert sich
/// die Anzeige dem Ende eines Fensters (letzte [prefetch] Zeilen), wird das
/// nächste schon vorgeladen. Höchstens [maxKeys] Sender bleiben im Speicher –
/// darüber werden ältere Fenster verworfen (und bei Bedarf neu geladen).
class GuideDayWindows extends ChangeNotifier {
  GuideDayWindows({
    required this.loader,
    required this.from,
    required this.to,
    this.window = 200,
    this.prefetch = 50,
    this.maxKeys = 4000,
  });

  /// Lädt das Programm der EPG-Schlüssel [keys] zwischen [from] und [to]
  /// (Sekunden). null = Fehler.
  final Future<Map<String, List<EpgEntry>>?> Function(
      List<String> keys, int from, int to) loader;
  final int from, to;
  final int window, prefetch, maxKeys;

  final _data = <String, List<EpgEntry>>{};

  /// Geladene Schlüssel in Lade-Reihenfolge (für das Verwerfen).
  final _loaded = <String>{};
  final _pending = <String>{};
  bool _disposed = false;

  /// Abgeschlossene Ladevorgänge (Tests/Messungen).
  int loads = 0;

  /// Programm der Zeile [index] – null, solange es noch geladen wird (das
  /// Fenster wird dann angestoßen).
  List<EpgEntry>? entriesAt(int index, List<Channel> channels) {
    if (index < 0 || index >= channels.length) return const [];
    final key = epgKeyOf(channels[index]);
    final w = index ~/ window;
    if ((index % window) >= window - prefetch) {
      ensureWindow(w + 1, channels);
    }
    if (_loaded.contains(key)) return _data[key] ?? const <EpgEntry>[];
    ensureWindow(w, channels);
    return null;
  }

  /// Ist die Zeile [index] geladen?
  bool isLoaded(int index, List<Channel> channels) =>
      index >= 0 &&
      index < channels.length &&
      _loaded.contains(epgKeyOf(channels[index]));

  /// Fenster [w] laden (fehlende Schlüssel). Fertig, wenn alles da ist.
  Future<void> ensureWindow(int w, List<Channel> channels) async {
    final start = w * window;
    if (w < 0 || start >= channels.length) return;
    final end =
        start + window > channels.length ? channels.length : start + window;
    final keys = <String>[
      for (var i = start; i < end; i++)
        if (!_loaded.contains(epgKeyOf(channels[i])) &&
            !_pending.contains(epgKeyOf(channels[i])))
          epgKeyOf(channels[i]),
    ];
    if (keys.isEmpty) return;
    final unique = keys.toSet().toList();
    _pending.addAll(unique);
    Map<String, List<EpgEntry>>? got;
    try {
      got = await loader(unique, from, to);
    } catch (_) {
      got = null;
    } finally {
      _pending.removeAll(unique);
    }
    if (_disposed) return;
    loads++;
    // Fehler: als leer vermerken (kein Endlos-Nachladen).
    for (final k in unique) {
      _loaded.add(k);
      final l = got?[k];
      if (l != null && l.isNotEmpty) {
        _data[k] = l;
      } else {
        _data.remove(k);
      }
    }
    _trim(unique.toSet());
    notifyListeners();
  }

  void _trim(Set<String> keep) {
    if (_loaded.length <= maxKeys) return;
    final drop = <String>[];
    for (final k in _loaded) {
      if (_loaded.length - drop.length <= maxKeys) break;
      if (!keep.contains(k)) drop.add(k);
    }
    for (final k in drop) {
      _loaded.remove(k);
      _data.remove(k);
    }
  }

  /// Anzahl Sender im Speicher (Tests).
  int get keysInMemory => _loaded.length;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
