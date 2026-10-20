import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';

import '../../core/security.dart';
import '../../l10n/strings.dart';
import '../../models/models.dart';
import '../../state/providers.dart';
import 'recording_files_stub.dart'
    if (dart.library.io) 'recording_files_io.dart';

export 'recording_files_stub.dart'
    if (dart.library.io) 'recording_files_io.dart';

/// Geplante oder laufende Aufnahme.
class Recording {
  final String id;
  final String channelId;
  final String channelName;
  final String title;
  final DateTime start;
  final DateTime end;
  final String status; // geplant | läuft | fertig | fehler
  final String? path;
  final String? error;

  /// Läuft über den Android-Hintergrunddienst (auch bei geschlossener App).
  final bool native;

  const Recording({
    required this.id,
    required this.channelId,
    required this.channelName,
    required this.title,
    required this.start,
    required this.end,
    this.status = 'geplant',
    this.path,
    this.error,
    this.native = false,
  });

  Recording copy({String? status, String? path, String? error, bool? native}) =>
      Recording(
        id: id,
        channelId: channelId,
        channelName: channelName,
        title: title,
        start: start,
        end: end,
        status: status ?? this.status,
        path: path ?? this.path,
        error: error ?? this.error,
        native: native ?? this.native,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'ch': channelId,
        'cn': channelName,
        't': title,
        's': start.millisecondsSinceEpoch,
        'e': end.millisecondsSinceEpoch,
        'st': status,
        'p': path,
        'er': error,
        'n': native,
      };

  factory Recording.fromJson(Map<String, dynamic> j) => Recording(
        id: j['id'] as String,
        channelId: j['ch'] as String,
        channelName: j['cn'] as String,
        title: j['t'] as String,
        start: DateTime.fromMillisecondsSinceEpoch(j['s'] as int),
        end: DateTime.fromMillisecondsSinceEpoch(j['e'] as int),
        status: j['st'] as String,
        path: j['p'] as String?,
        error: j['er'] as String?,
        native: j['n'] == true,
      );
}

/// Dateiname aus Sender, Titel und Zeit (ohne problematische Zeichen).
String recordingFileName(String channel, String title, DateTime start) {
  String clean(String s) =>
      s.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  String two(int n) => n.toString().padLeft(2, '0');
  final d = '${start.year}-${two(start.month)}-${two(start.day)} '
      '${two(start.hour)}${two(start.minute)}';
  final name = '${clean(channel)} – ${clean(title)} – $d';
  return '${name.length > 120 ? name.substring(0, 120) : name}.ts';
}

/// Zeitgesteuerte Aufnahmen. Läuft, solange die App geöffnet ist (auf
/// TV-Boxen üblich). Nimmt den Stream unverändert auf (keine Neukodierung).
class RecordingsNotifier extends Notifier<List<Recording>> {
  Timer? _timer;
  final _players = <String, Player>{};

  @override
  List<Recording> build() {
    _timer = Timer.periodic(const Duration(seconds: 20), (_) => _tick());
    ref.onDispose(() {
      _timer?.cancel();
      for (final p in _players.values) {
        p.dispose();
      }
    });
    Future.microtask(_load);
    return const [];
  }

  Future<void> _load() async {
    final st = await ref.read(storageProvider.future);
    final raw = st.option('recordings', '[]');
    final list = (jsonDecode(raw) as List)
        .map((e) => Recording.fromJson(e as Map<String, dynamic>))
        // Beim App-Neustart abgebrochene Aufnahmen als fertig markieren.
        .map((r) => r.status == 'läuft' && !r.native ? r.copy(status: 'fertig') : r)
        .toList();
    state = list;
    if (state.any((r) => r.native)) {
      await _native.restore();
      await _syncNative();
    }
    _tick();
  }

  Future<void> _save() async {
    final st = await ref.read(storageProvider.future);
    await st.setOption('recordings', jsonEncode([for (final r in state) r.toJson()]));
  }

  final _native = NativeRecorder();

  Future<RecResult> schedule(Channel c, EpgEntry e) async {
    if (state.any((r) =>
        r.channelId == c.id && r.start == e.start && r.status != 'fehler')) {
      return RecResult.duplicate;
    }
    final now = DateTime.now();
    final startNow = !e.start.subtract(const Duration(minutes: 2)).isAfter(now);
    var r = Recording(
      id: '${c.id}_${e.start.millisecondsSinceEpoch}',
      channelId: c.id,
      channelName: c.name,
      title: e.title,
      // 2 Min. Vorlauf, 5 Min. Nachlauf – Sender sind selten pünktlich.
      start: startNow ? now : e.start.subtract(const Duration(minutes: 2)),
      end: e.end.add(const Duration(minutes: 5)),
    );
    var result = RecResult.inAppOnly;
    if (_native.available) {
      try {
        final portal = ref.read(activePortalProvider).value;
        final url = c.streamUrl;
        // Stalker-Links sind kurzlebig, HLS braucht einen Player → in der App.
        if (portal?.type != PortalType.stalker &&
            UrlPolicy.isStream(url) &&
            !url.toLowerCase().contains('.m3u8')) {
          final path =
              '${await recordingsDir()}/${recordingFileName(r.channelName, r.title, e.start)}';
          await _native.requestNotify();
          final ok = await _native.schedule(r, url, path);
          // Ohne Wecker-Erlaubnis bleibt der Eintrag beim Dienst gespeichert:
          // Wird die Erlaubnis erteilt, setzt Android die Wecker automatisch.
          r = r.copy(native: true, path: path);
          result = ok ? RecResult.background : RecResult.needsAlarmPermission;
        }
      } catch (_) {
        result = RecResult.inAppOnly;
      }
    }
    state = [...state, r];
    await _save();
    _tick();
    return result;
  }

  /// Sofort aufnehmen: laufende Sendung bis zum Ende, sonst 60 Minuten.
  Future<RecResult> recordNow(Channel c, EpgEntry? now) {
    final t = DateTime.now();
    return schedule(
        c,
        now ??
            EpgEntry(
                channelEpgId: c.epgId ?? c.id,
                title: tr('Aufnahme'),
                start: t,
                end: t.add(const Duration(minutes: 60))));
  }

  bool isScheduled(Channel c, EpgEntry e) => state.any((r) =>
      r.channelId == c.id &&
      r.title == e.title &&
      (r.status == 'geplant' || r.status == 'läuft') &&
      r.end.isAfter(e.start));

  Future<void> cancel(String id) async {
    if (state.any((r) => r.id == id && r.native)) await _native.cancel(id);
    await _players.remove(id)?.dispose();
    state = [for (final r in state) if (r.id != id) r];
    await _save();
  }

  void _update(String id, Recording Function(Recording) f) {
    state = [for (final r in state) r.id == id ? f(r) : r];
    _save();
  }

  Future<void> _syncNative() async {
    final st = await _native.status();
    if (st.isEmpty) return;
    var changed = false;
    final next = [
      for (final r in state)
        if (r.native && st[r.id] != null)
          () {
            final (status, err) = st[r.id]!;
            if (status == r.status && err == r.error) return r;
            changed = true;
            return r.copy(status: status, error: err);
          }()
        else
          r
    ];
    if (changed) {
      state = next;
      await _save();
    }
  }

  Future<void> _tick() async {
    if (state.any((r) =>
        r.native && (r.status == 'geplant' || r.status == 'läuft'))) {
      await _syncNative();
    }
    final now = DateTime.now();
    // Hat der Dienst eine Minute nach Start nicht angefangen (z. B. Wecker-
    // Erlaubnis fehlt), übernimmt die geöffnete App.
    for (final r in [...state]) {
      if (r.native &&
          r.status == 'geplant' &&
          now.isAfter(r.start.add(const Duration(minutes: 1))) &&
          now.isBefore(r.end)) {
        await _native.cancel(r.id);
        _update(r.id, (x) => x.copy(native: false));
      }
    }
    for (final r in state.where((r) => !r.native)) {
      if (r.status == 'geplant' && !now.isBefore(r.start) && now.isBefore(r.end)) {
        await _start(r);
      } else if (r.status == 'geplant' && !now.isBefore(r.end)) {
        _update(r.id, (x) => x.copy(status: 'fehler', error: tr('App war geschlossen')));
      } else if (r.status == 'läuft' && !now.isBefore(r.end)) {
        await _stop(r.id);
      }
    }
  }

  Future<void> _start(Recording r) async {
    try {
      final live = await ref.read(liveDataProvider.future);
      final c = live.channels.firstWhere((x) => x.id == r.channelId);
      final repo = await ref.read(repositoryProvider.future);
      final url = repo == null ? c.streamUrl : await repo.resolveStreamUrl(c);
      if (!UrlPolicy.isStream(url)) throw Exception(tr('Ungültige Adresse'));
      final path = '${await recordingsDir()}/${recordingFileName(r.channelName, r.title, r.start)}';
      final p = Player();
      _players[r.id] = p;
      final pl = p.platform;
      if (pl is NativePlayer) {
        // Nur mitschneiden, nicht dekodieren/anzeigen.
        await pl.setProperty('vid', 'no');
        await pl.setProperty('aid', 'no');
        await pl.setProperty('sid', 'no');
      }
      await p.setVolume(0);
      await p.open(Media(url));
      if (pl is NativePlayer) await pl.setProperty('stream-record', path);
      _update(r.id, (x) => x.copy(status: 'läuft', path: path));
    } catch (e) {
      _update(r.id, (x) => x.copy(status: 'fehler', error: Redactor.friendly(e)));
    }
  }

  Future<void> _stop(String id) async {
    final p = _players.remove(id);
    final pl = p?.platform;
    if (pl is NativePlayer) await pl.setProperty('stream-record', '');
    await p?.dispose();
    _update(id, (x) => x.copy(status: 'fertig'));
  }
}

enum RecResult {
  /// Läuft im Hintergrund – auch bei geschlossener App.
  background,

  /// Nur solange die App offen ist (MAC-Portal, HLS oder Web).
  inAppOnly,

  /// Erlaubnis „Wecker & Erinnerungen“ fehlt → nur bei offener App.
  needsAlarmPermission,
  duplicate,
}

/// Android-Hintergrunddienst (Kotlin: Recorder.kt).
class NativeRecorder {
  static const _ch = MethodChannel('de.jasonstream.player/rec');
  static const _secure = MethodChannel('de.jasonstream.player/secure');

  bool get available =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<bool> schedule(Recording r, String url, String path) async {
    // Adresse enthält Zugangsdaten → nur verschlüsselt übergeben/speichern.
    final enc = await _secure.invokeMethod<String>('encrypt', {'value': url});
    if (enc == null) return false;
    return await _ch.invokeMethod<bool>('schedule', {
          'id': r.id,
          'title': '${r.channelName} – ${r.title}',
          'enc': enc,
          'path': path,
          'start': r.start.millisecondsSinceEpoch,
          'end': r.end.millisecondsSinceEpoch,
        }) ??
        false;
  }

  Future<void> cancel(String id) async {
    if (!available) return;
    try {
      await _ch.invokeMethod('cancel', {'id': id});
    } catch (_) {}
  }

  Future<void> restore() async {
    if (!available) return;
    try {
      await _ch.invokeMethod('restore');
    } catch (_) {}
  }

  Future<void> requestNotify() async {
    try {
      await _ch.invokeMethod('requestNotify');
    } catch (_) {}
  }

  Future<bool> canExact() async {
    if (!available) return false;
    try {
      return await _ch.invokeMethod<bool>('canExact') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Öffnet die Systemseite „Wecker & Erinnerungen“. false = gibt es nicht.
  Future<bool> requestExact() async {
    try {
      return await _ch.invokeMethod<bool>('requestExact') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// id → (Status, Fehlertext)
  Future<Map<String, (String, String?)>> status() async {
    if (!available) return const {};
    try {
      final m = await _ch.invokeMapMethod<String, dynamic>('status') ?? const {};
      return {
        for (final e in m.entries)
          e.key: () {
            final v = (e.value as Map).cast<String, dynamic>();
            final st = switch (v['state']) {
              'running' => 'läuft',
              'done' => 'fertig',
              'error' => 'fehler',
              _ => 'geplant',
            };
            return (st, st == 'fehler' ? nativeErrorText(v['err'] as String?) : null);
          }(),
      };
    } catch (_) {
      return const {};
    }
  }
}

/// Fehlercodes des Dienstes → verständlicher Text.
String nativeErrorText(String? code) {
  if (code == null) return tr('Aufnahme fehlgeschlagen');
  if (code == 'missed') return tr('Gerät war ausgeschaltet');
  if (code == 'empty') return tr('Keine Daten empfangen');
  if (code == 'HTTP 451' || code == 'HTTP 403') {
    return tr('An deinem Standort nicht verfügbar');
  }
  if (code == 'HTTP 401') return tr('Anmeldung fehlgeschlagen');
  if (code.startsWith('HTTP')) return trf('Server-Fehler ({0})', [code]);
  return tr('Verbindung unterbrochen');
}

final recordingsProvider =
    NotifierProvider<RecordingsNotifier, List<Recording>>(RecordingsNotifier.new);
