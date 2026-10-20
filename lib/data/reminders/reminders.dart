import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/models.dart';
import '../../state/providers.dart';

/// Vorlauf: so lange vor Sendungsbeginn wird erinnert.
const reminderLead = Duration(minutes: 2);

/// Erinnerung an eine kommende Sendung (wie TiviMate).
class Reminder {
  final String id;
  final String portalId;
  final String channelId;
  final String channelName;
  final String title;
  final DateTime start;

  const Reminder({
    required this.id,
    required this.portalId,
    required this.channelId,
    required this.channelName,
    required this.title,
    required this.start,
  });

  DateTime get fireAt => start.subtract(reminderLead);

  Map<String, Object?> toJson() => {
        'id': id,
        'p': portalId,
        'ch': channelId,
        'cn': channelName,
        't': title,
        's': start.millisecondsSinceEpoch,
      };

  factory Reminder.fromJson(Map<String, dynamic> j) => Reminder(
        id: j['id'] as String,
        portalId: j['p'] as String? ?? '',
        channelId: j['ch'] as String,
        channelName: j['cn'] as String? ?? '',
        title: j['t'] as String? ?? '',
        start: DateTime.fromMillisecondsSinceEpoch(j['s'] as int),
      );
}

/// Erinnerungen: bei offener App als Hinweis im Bild ([due]), bei
/// geschlossener App als Android-Benachrichtigung (Kotlin: Reminder.kt).
class RemindersNotifier extends Notifier<List<Reminder>> {
  Timer? _timer;
  final _due = StreamController<Reminder>.broadcast();
  final _native = NativeReminders();

  /// Fällige Erinnerungen des aktiven Portals (für den Hinweis in der App).
  Stream<Reminder> get due => _due.stream;

  @override
  List<Reminder> build() {
    _timer = Timer.periodic(const Duration(seconds: 20), (_) => _tick());
    ref.onDispose(() {
      _timer?.cancel();
      _due.close();
    });
    Future.microtask(_load);
    return const [];
  }

  Future<void> _load() async {
    try {
      final st = await ref.read(storageProvider.future);
      final raw = st.option('reminders', '[]');
      state = [
        for (final e in jsonDecode(raw) as List)
          Reminder.fromJson(e as Map<String, dynamic>)
      ];
    } catch (_) {
      state = const [];
    }
    await _cleanup();
    _tick();
  }

  Future<void> _save() async {
    final st = await ref.read(storageProvider.future);
    await st.setOption(
        'reminders', jsonEncode([for (final r in state) r.toJson()]));
  }

  static String idFor(String portalId, Channel c, EpgEntry e) =>
      '${portalId}_${c.id}_${e.start.millisecondsSinceEpoch}';

  String get _portalId => ref.read(activePortalProvider).value?.id ?? '';

  bool isSet(Channel c, EpgEntry e) {
    final id = idFor(_portalId, c, e);
    return state.any((r) => r.id == id);
  }

  /// Erinnerung setzen bzw. entfernen. Liefert true, wenn jetzt gesetzt.
  Future<bool> toggle(Channel c, EpgEntry e) async {
    final portal = _portalId;
    final id = idFor(portal, c, e);
    if (state.any((r) => r.id == id)) {
      await _native.cancel(id);
      state = [
        for (final r in state)
          if (r.id != id) r
      ];
      await _save();
      return false;
    }
    if (!e.start.isAfter(DateTime.now())) return false;
    final r = Reminder(
      id: id,
      portalId: portal,
      channelId: c.id,
      channelName: c.name,
      title: e.title,
      start: e.start,
    );
    state = [...state, r];
    await _save();
    await _native.requestNotify();
    await _native.schedule(r);
    return true;
  }

  /// Vergangene Erinnerungen entfernen.
  Future<void> _cleanup() async {
    final now = DateTime.now();
    final old = state.where((r) => !r.start.isAfter(now)).toList();
    if (old.isEmpty) return;
    for (final r in old) {
      await _native.cancel(r.id);
    }
    state = [
      for (final r in state)
        if (r.start.isAfter(now)) r
    ];
    await _save();
  }

  Future<void> _tick() async {
    final now = DateTime.now();
    final portal = _portalId;
    final fire = state
        .where((r) => r.portalId == portal && !now.isBefore(r.fireAt))
        .toList();
    if (fire.isNotEmpty) {
      state = [
        for (final r in state)
          if (!fire.contains(r)) r
      ];
      await _save();
      for (final r in fire) {
        // App ist offen → Hinweis hier, keine zusätzliche Benachrichtigung.
        await _native.cancel(r.id);
        if (r.start.isAfter(now.subtract(const Duration(minutes: 5))) &&
            !_due.isClosed) {
          _due.add(r);
        }
      }
    }
    await _cleanup();
  }
}

final remindersProvider =
    NotifierProvider<RemindersNotifier, List<Reminder>>(RemindersNotifier.new);

/// Android-Wecker für Erinnerungen (Kotlin: Reminder.kt). Übergibt nur
/// Sendername, Titel, Zeit und IDs – keine Adressen oder Zugangsdaten.
class NativeReminders {
  static const _ch = MethodChannel('de.jasonstream.player/reminders');
  static const _rec = MethodChannel('de.jasonstream.player/rec');

  bool get available =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<void> schedule(Reminder r) async {
    if (!available) return;
    try {
      await _ch.invokeMethod('schedule', {
        'id': r.id,
        'title': r.title,
        'channelName': r.channelName,
        'channel': r.channelId,
        'portal': r.portalId,
        'start': r.start.millisecondsSinceEpoch,
        'at': r.fireAt.millisecondsSinceEpoch,
      });
    } catch (_) {}
  }

  Future<void> cancel(String id) async {
    if (!available) return;
    try {
      await _ch.invokeMethod('cancel', {'id': id});
    } catch (_) {}
  }

  Future<void> requestNotify() async {
    if (!available) return;
    try {
      await _rec.invokeMethod('requestNotify');
    } catch (_) {}
  }
}
