import 'dart:async';

import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/list_cache.dart';
import '../models/models.dart';
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

class ListAutoRefresh {
  final Ref ref;
  bool _running = false;
  ListAutoRefresh(this.ref);

  Future<void> check() async {
    if (_running) return;
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
