import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/list_cache.dart';
import '../models/models.dart';
import '../player/data_saver.dart' show dataSaverActiveProvider;
import 'providers.dart';

/// Automatische Aktualisierung der Listen (Sender, Filme, Serien) pro Portal
/// ([Portal.autoRefreshHours]: aus / 6 / 12 / 24 h).
///
/// Geprüft wird beim Start, beim Zurückkehren in die App und alle 15 Min.
/// Das Neuladen läuft still im Hintergrund – die bisherigen Listen bleiben
/// sichtbar, Fehler werden ignoriert (nächster Versuch beim nächsten Check).
class AutoRefresh {
  AutoRefresh._();

  static const choices = [0, 6, 12, 24];

  /// Fällig, wenn eingeschaltet und seit [last] mindestens [hours] Stunden
  /// vergangen sind (nie aktualisiert = fällig). Liegt [last] in der
  /// Zukunft (Uhr verstellt), gilt es ebenfalls als fällig.
  static bool isDue(int hours, DateTime? last, DateTime now) {
    if (hours <= 0) return false;
    if (last == null || last.isAfter(now)) return true;
    return now.difference(last) >= Duration(hours: hours);
  }
}

/// Ein Stream wird gerade gestartet (Player geöffnet / Umschalten). In
/// dieser Zeit läuft kein stilles Nachladen der Listen – der Start des
/// Videos hat Vorrang (CPU, Netz, Speicher).
class PlaybackGate {
  PlaybackGate._();
  static DateTime? _startedAt;

  /// Wie lange nach dem Öffnen als „Start läuft“ gilt.
  static const window = Duration(seconds: 8);

  /// Vom Player-Aufruf (openPlayer) zu melden.
  static void starting() => _startedAt = DateTime.now();

  static bool get busy {
    final t = _startedAt;
    return t != null && DateTime.now().difference(t) < window;
  }

  @visibleForTesting
  static void reset() => _startedAt = null;
}

/// Stilles Nachladen nach dem Start: Sender ~8 s, Filme ~45 s, Serien
/// ~60 s nach dem Aufbau der Liste – gestaffelt, damit der Start (erstes
/// Bild, erster Stream) nie mit großen Downloads konkurriert. Läuft gerade
/// ein Stream-Start, wird um einige Sekunden verschoben.
class StartReload {
  StartReload._();
  static Duration liveDelay = const Duration(seconds: 8);
  static Duration moviesDelay = const Duration(seconds: 45);
  static Duration seriesDelay = const Duration(seconds: 60);

  /// Verschiebung, wenn bei Fälligkeit gerade ein Stream startet.
  static Duration retryDelay = const Duration(seconds: 5);

  static StartReloadHandle schedule(Duration delay, void Function() run) =>
      StartReloadHandle._(effective(delay), run);

  /// Zeitpunkt des ersten [schedule] (≈ App-Start: die Senderliste wird
  /// immer gleich beim Start gebaut).
  static DateTime? _appStart;

  /// Fälligkeit gemessen ab dem App-Start, nicht ab dem Aufbau der Liste:
  /// Wird z. B. „Filme“ erst nach 10 Minuten zum ersten Mal gebraucht
  /// (Start-Reiter „Live“), lädt sie gleich nach – nicht erst 45 s später.
  /// Mindestens ein Achtel von [delay] (Bild zuerst; nach Portalwechsel
  /// weiterhin gestaffelt).
  static Duration effective(Duration delay, {DateTime? now}) {
    final n = now ?? DateTime.now();
    final left = delay - n.difference(_appStart ??= n);
    final min = delay ~/ 8;
    return left > min ? left : min;
  }

  @visibleForTesting
  static void resetAppStart([DateTime? at]) => _appStart = at;
}

class StartReloadHandle {
  final void Function() _run;
  Timer? _t;
  int _deferred = 0;
  StartReloadHandle._(Duration delay, this._run) {
    _t = Timer(delay, _fire);
  }

  void _fire() {
    // Höchstens ~1 Minute verschieben, dann trotzdem laden.
    if (PlaybackGate.busy && _deferred < 12) {
      _deferred++;
      _t = Timer(StartReload.retryDelay, _fire);
      return;
    }
    _t = null;
    _run();
  }

  bool get pending => _t != null;

  void cancel() {
    _t?.cancel();
    _t = null;
  }
}

class ListAutoRefresh {
  final Ref ref;
  bool _running = false;
  ListAutoRefresh(this.ref);

  Future<void> check() async {
    if (_running || PlaybackGate.busy) return;
    // Datensparmodus: kein automatisches Portal-Update über Mobilfunk.
    if (ref.read(dataSaverActiveProvider)) return;
    final st = ref.read(storageProvider).value;
    final p = ref.read(activePortalProvider).value;
    if (st == null || p == null || p.type == PortalType.demo) return;
    final now = DateTime.now();
    // Letzte Aktualisierung: gespeicherte oder die vom App-Start.
    var last = st.listRefreshed(p.id);
    final saved = ListCache.lastSaved[p.id];
    if (saved != null && (last == null || saved.isAfter(last))) last = saved;
    if (!AutoRefresh.isDue(p.autoRefreshHours, last, now)) {
      return;
    }
    _running = true;
    final before = ListCache.lastSaved[p.id];
    try {
      await ref.read(liveDataProvider.notifier).reload(silent: true);
      if (p.type != PortalType.m3u) {
        await Future.wait([
          ref.read(moviesProvider.notifier).reload(silent: true),
          ref.read(seriesProvider.notifier).reload(silent: true),
        ]);
      }
      // Nur vermerken, wenn die Senderliste wirklich neu gespeichert wurde
      // (reload ist still und meldet Fehler nicht).
      final after = ListCache.lastSaved[p.id];
      if (after != null && after != before) {
        await st.setListRefreshed(p.id, after);
      }
    } catch (_) {
      // optional
    } finally {
      _running = false;
    }
  }
}

/// Wird von der Senderliste gehalten (ref.listen in LiveNotifier) und
/// prüft beim Start/Zurückkehren/alle 15 Min.
final listAutoRefreshProvider = Provider<ListAutoRefresh>((ref) {
  ref.watch(activePortalProvider.select((p) => p.value?.id));
  final r = ListAutoRefresh(ref);
  final timer = Timer.periodic(const Duration(minutes: 15), (_) => r.check());
  AppLifecycleListener? life;
  try {
    life = AppLifecycleListener(onResume: r.check);
  } catch (_) {
    life = null; // ohne Flutter-Binding (reine Tests)
  }
  // Start: kurz warten, damit der normale Start nicht ausgebremst wird.
  final first = Timer(const Duration(seconds: 20), r.check);
  ref.onDispose(() {
    timer.cancel();
    first.cancel();
    life?.dispose();
  });
  return r;
});
