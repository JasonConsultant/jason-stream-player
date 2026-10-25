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
import '../smb/smb.dart';
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

  /// Ziel Netzlaufwerk (ab 2.3): wird lokal gepuffert und nach dem Ende
  /// aufs NAS verschoben ([path] dann `smb://…`).
  final bool nas;

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
    this.nas = false,
  });

  Recording copy(
          {String? status,
          String? path,
          String? error,
          bool clearError = false,
          bool? native,
          bool? nas}) =>
      Recording(
        id: id,
        channelId: channelId,
        channelName: channelName,
        title: title,
        start: start,
        end: end,
        status: status ?? this.status,
        path: path ?? this.path,
        error: clearError ? null : (error ?? this.error),
        native: native ?? this.native,
        nas: nas ?? this.nas,
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
        if (nas) 'nas': true,
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
        nas: j['nas'] == true,
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

/// Vorlauf/Nachlauf geplanter Aufnahmen (Einstellungen).
abstract final class RecPadding {
  static const preKey = 'recpre';
  static const postKey = 'recpost';
  static const preDefault = '2';
  static const postDefault = '5';
  static const preOptions = [0, 1, 2, 5];
  static const postOptions = [0, 5, 10, 15];

  static Duration pre(String Function(String, String) option) => Duration(
      minutes: int.tryParse(option(preKey, preDefault)) ?? 2);
  static Duration post(String Function(String, String) option) => Duration(
      minutes: int.tryParse(option(postKey, postDefault)) ?? 5);
}

/// Zeitfenster einer geplanten Sendung: [pre] früher, [post] später –
/// läuft sie schon, ab jetzt.
({DateTime start, DateTime end, bool startNow}) scheduledWindow(
    EpgEntry e, DateTime now,
    {Duration pre = const Duration(minutes: 2),
    Duration post = const Duration(minutes: 5)}) {
  final start = e.start.subtract(pre);
  final startNow = !start.isAfter(now);
  return (start: startNow ? now : start, end: e.end.add(post), startNow: startNow);
}

/// „Aufnehmen, was ich sehe“: ab jetzt bis Sendungsende (+ Nachlauf) bzw.
/// feste Dauer. Ohne EPG und ohne Dauer: 60 Minuten.
({DateTime start, DateTime end, String title}) recordWindow(
    {required DateTime now,
    EpgEntry? current,
    Duration? duration,
    Duration post = const Duration(minutes: 5)}) {
  final title = current?.title ?? tr('Aufnahme');
  if (duration != null) return (start: now, end: now.add(duration), title: title);
  if (current != null && current.end.isAfter(now)) {
    return (start: now, end: current.end.add(post), title: title);
  }
  return (start: now, end: now.add(const Duration(minutes: 60)), title: title);
}

/// Darf eine Aufnahme starten? (Anbieter-Verbindungen)
enum RecAllow {
  ok,

  /// Nur, wenn Live-TV dafür beendet wird (Rückfrage).
  stopLive,

  /// Keine Verbindung frei.
  refuse,
}

/// [maxConnections] null = unbekannt (dann immer erlaubt). [busy]: schon
/// belegte Verbindungen durch Aufnahmen/Downloads. [liveActive]: Live-TV
/// läuft gerade. [keepLiveFree]: eine Verbindung für Live frei halten
/// (nur wirksam, wenn der Anbieter mehrere erlaubt).
RecAllow recordingAllowed(
    {required int? maxConnections,
    int busy = 0,
    bool liveActive = false,
    bool keepLiveFree = false}) {
  final max = maxConnections;
  if (max == null || max <= 0) return RecAllow.ok;
  final forRecordings = keepLiveFree && max > 1 ? max - 1 : max;
  if (busy + 1 > forRecordings) return RecAllow.refuse;
  final need = busy + 1 + (liveActive ? 1 : 0);
  if (need <= max) return RecAllow.ok;
  return RecAllow.stopLive;
}

/// Zeitgesteuerte Aufnahmen. Läuft, solange die App geöffnet ist (auf
/// TV-Boxen üblich). Nimmt den Stream unverändert auf (keine Neukodierung).
class RecordingsNotifier extends Notifier<List<Recording>> {
  Timer? _timer;
  final _players = <String, Player>{};
  final _starting = <String>{};

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
    final id = '${c.id}_${e.start.millisecondsSinceEpoch}';
    // Gespeichert wird mit Vorlauf – deshalb über die ID vergleichen,
    // nicht über die Startzeit (sonst ließe sich dieselbe Sendung doppelt
    // planen und beide Einträge teilten sich eine ID).
    if (state.any((r) => r.id == id && r.status != 'fehler')) {
      return RecResult.duplicate;
    }
    // Vorlauf/Nachlauf aus den Einstellungen (Standard 2/5 Min.) – Sender
    // sind selten pünktlich.
    final st = await ref.read(storageProvider.future);
    final w = scheduledWindow(e, DateTime.now(),
        pre: RecPadding.pre(st.option), post: RecPadding.post(st.option));
    return _add(c, id: id, title: e.title, start: w.start, end: w.end,
        fileTime: e.start);
  }

  /// „Aufnehmen, was ich sehe“: ab jetzt bis Sendungsende bzw. für
  /// [duration] (30/60/120 Min.).
  Future<RecResult> recordFor(Channel c,
      {EpgEntry? current, Duration? duration}) async {
    if (duration == null && current != null) return recordNow(c, current);
    final now = DateTime.now();
    if (activeFor(c.id, now) != null) return RecResult.duplicate;
    final st = await ref.read(storageProvider.future);
    final w = recordWindow(
        now: now,
        current: current,
        duration: duration,
        post: RecPadding.post(st.option));
    return _add(c,
        id: '${c.id}_now_${now.millisecondsSinceEpoch}',
        title: w.title,
        start: w.start,
        end: w.end,
        fileTime: now);
  }

  /// Laufende (oder gerade beginnende) Aufnahme eines Senders.
  Recording? activeFor(String channelId, DateTime now) {
    for (final r in state) {
      if (r.channelId != channelId) continue;
      if (r.status == 'läuft' ||
          (r.status == 'geplant' &&
              !now.isBefore(r.start) &&
              now.isBefore(r.end))) {
        return r;
      }
    }
    return null;
  }

  /// Laufende Aufnahme beenden – die Datei bleibt (anders als [cancel]).
  Future<void> stop(String id) async {
    final r = state.where((x) => x.id == id).firstOrNull;
    if (r == null) return;
    if (r.native) await _native.cancel(id);
    if (_players.containsKey(id)) {
      await _stop(id);
      return;
    }
    _update(
        id,
        (x) => x.copy(
            status: x.status == 'geplant' && x.path == null ? 'fehler' : 'fertig',
            error: x.status == 'geplant' && x.path == null
                ? tr('Abgebrochen')
                : null));
  }

  Future<RecResult> _add(Channel c,
      {required String id,
      required String title,
      required DateTime start,
      required DateTime end,
      required DateTime fileTime}) async {
    var r = Recording(
      id: id,
      channelId: c.id,
      channelName: c.name,
      title: title,
      start: start,
      end: end,
    );
    var result = RecResult.inAppOnly;
    // Netzlaufwerk als Speicherort: vorher prüfen – nicht erreichbar →
    // nicht aufnehmen (klare Meldung, kein stiller Rückfall auf intern).
    final st0 = await ref.read(storageProvider.future);
    if (RecTree.isSmb(st0.option(RecTree.optionKey, ''))) {
      final cfg = st0.smbConfig();
      try {
        if (cfg == null) throw const SmbException('path');
        await nasCheck(cfg);
      } on SmbException catch (e) {
        lastNasError = e.code;
        return RecResult.nasUnavailable;
      }
      r = r.copy(nas: true);
    }
    if (_native.available) {
      try {
        final portal = ref.read(activePortalProvider).value;
        final url = c.streamUrl;
        // Stalker-Links sind kurzlebig, HLS braucht einen Player → in der App.
        if (portal?.type != PortalType.stalker &&
            UrlPolicy.isStream(url) &&
            !url.toLowerCase().contains('.m3u8')) {
          final path =
              '${await recordingsDir()}/${recordingFileName(r.channelName, r.title, fileTime)}';
          await _native.requestNotify();
          // Gewählter Speicherort (USB-Stick/Netzlaufwerk, SAF-Baum). Nur der
          // Hintergrunddienst kann dorthin schreiben; die In-App-Aufnahme
          // (_start, mpv stream-record) landet immer im App-Ordner.
          final st = await ref.read(storageProvider.future);
          final tree = st.option('rectree', '');
          // NAS: der Dienst schreibt lokal, verschoben wird danach.
          final ok = await _native.schedule(r, url, path,
              treeUri: tree.isEmpty || RecTree.isSmb(tree) ? null : tree);
          // Ohne Wecker-Erlaubnis bleibt der Eintrag beim Dienst gespeichert:
          // Wird die Erlaubnis erteilt, setzt Android die Wecker automatisch.
          r = r.copy(native: true, path: path);
          result = ok ? RecResult.background : RecResult.needsAlarmPermission;
        }
      } catch (_) {
        result = RecResult.inAppOnly;
      }
    }
    // Fehlgeschlagenen Eintrag mit gleicher ID ersetzen.
    state = [for (final x in state) if (x.id != id) x, r];
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

  /// Prüfung der NAS-Verbindung vor einer Aufnahme (Tests: Fake).
  @visibleForTesting
  Future<void> Function(SmbConfig c) nasCheck = (c) => Smb.test(c);

  /// Letzter NAS-Fehlercode (für die Meldung bei [RecResult.nasUnavailable]).
  String? lastNasError;

  final _moving = <String>{};
  final _moveTried = <String, DateTime>{};

  /// Fertige NAS-Aufnahmen aus dem App-Ordner aufs Netzlaufwerk schieben.
  /// Scheitert es, bleibt die Datei lokal (Hinweis am Eintrag) und es wird
  /// nach 5 Minuten erneut versucht.
  Future<void> _moveFinished() async {
    final now = DateTime.now();
    for (final r in [...state]) {
      final p = r.path;
      if (!r.nas || r.status != 'fertig' || p == null || p.startsWith('smb://')) {
        continue;
      }
      final last = _moveTried[r.id];
      if (last != null && now.difference(last) < const Duration(minutes: 5)) {
        continue;
      }
      if (!_moving.add(r.id)) continue;
      _moveTried[r.id] = now;
      try {
        final st = await ref.read(storageProvider.future);
        final c = st.smbConfig();
        if (c == null) throw const SmbException('path');
        final name = p.split('/').last;
        await nasUpload(c, p, 'Aufnahmen/$name');
        try {
          await deleteRecording(p);
        } catch (_) {
          // Lokale Kopie bleibt liegen – das NAS hat die vollständige Datei.
        }
        _update(r.id,
            (x) => x.copy(path: c.uriFor('Aufnahmen/$name'), clearError: true));
      } on SmbException catch (e) {
        _update(
            r.id,
            (x) => x.copy(
                error: trf('{0} – Aufnahme liegt im App-Ordner, neuer Versuch '
                    'in 5 Min.', [e.message])));
      } catch (_) {
        // Lokale Datei fehlt (z. B. gelöscht) – nichts zu verschieben.
      } finally {
        _moving.remove(r.id);
      }
    }
  }

  @visibleForTesting
  Future<int> Function(SmbConfig c, String local, String rel) nasUpload =
      Smb.upload;

  @visibleForTesting
  Future<void> moveFinishedNow() {
    _moveTried.clear();
    return _moveFinished();
  }

  Future<void> _tick() async {
    unawaited(_moveFinished());
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
        // Ein Takt kann länger als 20 s dauern (Senderliste lädt) – nicht
        // zweimal starten, sonst gäbe es zwei Player auf dieselbe Datei.
        if (!_starting.add(r.id)) continue;
        try {
          await _start(r);
        } finally {
          _starting.remove(r.id);
        }
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

  /// Speicherort Netzlaufwerk nicht erreichbar → nicht aufgenommen.
  nasUnavailable,
}

/// Android-Hintergrunddienst (Kotlin: Recorder.kt).
class NativeRecorder {
  static const _ch = MethodChannel('de.jasonstream.player/rec');
  static const _secure = MethodChannel('de.jasonstream.player/secure');

  bool get available =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// [treeUri]: SAF-Dokumentbaum (USB-Stick/Netzlaufwerk); der Dateiname aus
  /// [path] wird dort angelegt. Scheitert das, schreibt der Dienst nach
  /// [path] und meldet im Status `fallback`.
  Future<bool> schedule(Recording r, String url, String path,
      {String? treeUri}) async {
    // Adresse enthält Zugangsdaten → nur verschlüsselt übergeben/speichern.
    final enc = await _secure.invokeMethod<String>('encrypt', {'value': url});
    if (enc == null) return false;
    return await _ch.invokeMethod<bool>('schedule', {
          'id': r.id,
          'title': '${r.channelName} – ${r.title}',
          'enc': enc,
          'path': path,
          if (treeUri != null && treeUri.isNotEmpty) 'treeUri': treeUri,
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
            if (st == 'fehler') return (st, nativeErrorText(v['err'] as String?));
            // Speicherort (USB/Netz) nicht erreichbar → Aufnahme im App-Ordner.
            return (st, v['fallback'] == true ? nativeErrorText('fallback') : null);
          }(),
      };
    } catch (_) {
      return const {};
    }
  }
}

/// Aufnahme in einem gewählten Ordner (USB-Stick, SD-Karte, Netzlaufwerk)
/// über das Android Storage Access Framework (Kotlin: RecStorage.kt).
/// Netzlaufwerke brauchen eine Anbieter-App (z. B. CX File Explorer,
/// Solid Explorer, auf Android TV die eingebauten SMB-Anbieter).
///
/// Nur Hintergrund-Aufnahmen (Dienst) landen dort; In-App-Aufnahmen
/// (mpv stream-record, z. B. MAC-Portal/HLS) immer im App-Ordner.
class RecTree {
  static const _platform = MethodChannel('de.jasonstream.player/platform');
  static const optionKey = 'rectree';

  /// Wert von [optionKey] für das Netzlaufwerk (SMB, ab 2.3) – Zugang in
  /// Storage.smbConfig.
  static const smbValue = 'smb';

  static bool isSmb(String v) => v == smbValue;

  static bool get available =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Ordner wählen. Liefert (uri, name) oder null (abgebrochen).
  static Future<({String uri, String name})?> pick() async {
    if (!available) return null;
    final m = await _platform.invokeMapMethod<String, dynamic>('pickRecTree');
    if (m == null) return null;
    return (uri: m['uri'] as String, name: (m['name'] as String?) ?? '');
  }

  /// Name, freier Platz (Bytes, -1 = unbekannt) und ob der Zugriff noch gilt.
  static Future<({String name, int free, bool granted})> info(String uri) async {
    if (!available || uri.isEmpty) return (name: '', free: -1, granted: false);
    try {
      final m = await _platform
              .invokeMapMethod<String, dynamic>('recTreeInfo', {'uri': uri}) ??
          const {};
      return (
        name: (m['name'] as String?) ?? '',
        free: (m['free'] as num?)?.toInt() ?? -1,
        granted: m['granted'] == true,
      );
    } catch (_) {
      return (name: '', free: -1, granted: false);
    }
  }

  static Future<List<RecDoc>> list(String uri) async {
    if (!available || uri.isEmpty) return const [];
    try {
      final l = await _platform
              .invokeListMethod<dynamic>('listRecTree', {'uri': uri}) ??
          const [];
      return [
        for (final e in l)
          () {
            final m = (e as Map).cast<String, dynamic>();
            return RecDoc(
              name: m['name'] as String,
              bytes: (m['size'] as num?)?.toInt() ?? 0,
              modified: DateTime.fromMillisecondsSinceEpoch(
                  (m['lastModified'] as num?)?.toInt() ?? 0),
              uri: m['documentUri'] as String,
            );
          }(),
      ];
    } catch (_) {
      return const [];
    }
  }

  static Future<bool> delete(String documentUri) async {
    if (!available) return false;
    try {
      return await _platform
              .invokeMethod<bool>('deleteRecDoc', {'uri': documentUri}) ??
          false;
    } catch (_) {
      return false;
    }
  }

  static String formatFree(int bytes) => bytes < 0
      ? ''
      : bytes >= 10 * 1024 * 1024 * 1024
          ? '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(0)} GB'
          : bytes >= 1024 * 1024 * 1024
              ? '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB'
              : '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB';
}

/// Aufnahme-Datei im gewählten Ordner (SAF-Dokument).
class RecDoc {
  final String name;
  final int bytes;
  final DateTime modified;

  /// content://-Adresse; media_kit öffnet sie direkt (Media(uri)).
  final String uri;
  const RecDoc(
      {required this.name,
      required this.bytes,
      required this.modified,
      required this.uri});
}

/// Aufnahme abgelehnt, weil das Netzlaufwerk nicht erreichbar ist.
String nasRecordingRefusedText(String? code) => trf(
    '{0} – Aufnahme nicht gestartet. Speicherort in den Einstellungen prüfen.',
    [smbErrorText(code ?? 'host')]);

/// Fehlercodes des Dienstes → verständlicher Text.
String nativeErrorText(String? code) {
  if (code == null) return tr('Aufnahme fehlgeschlagen');
  if (code == 'missed') return tr('Gerät war ausgeschaltet');
  if (code == 'empty') return tr('Keine Daten empfangen');
  if (code == 'nospace') return tr('Zu wenig Speicherplatz');
  if (code == 'fallback') {
    return tr('Speicherort nicht erreichbar – Aufnahme im App-Ordner');
  }
  if (code == 'HTTP 451' || code == 'HTTP 403') {
    return tr('An deinem Standort nicht verfügbar');
  }
  if (code == 'HTTP 401') return tr('Anmeldung fehlgeschlagen');
  if (code.startsWith('HTTP')) return trf('Server-Fehler ({0})', [code]);
  return tr('Verbindung unterbrochen');
}

final recordingsProvider =
    NotifierProvider<RecordingsNotifier, List<Recording>>(RecordingsNotifier.new);
