import 'dart:async';

import 'package:clock/clock.dart';
import 'package:http/http.dart' as hc;

import 'download_models.dart';
import 'download_rules.dart';
import 'download_transfer.dart';

/// Netz und Einstellungen, wie sie die Warteschlange gerade sieht.
class DownloadEnv {
  final bool connected;
  final bool cellular;
  final bool metered;
  final bool mobileAllowed;
  final bool dataSaverActive;

  /// Einstellung „Gleichzeitige Downloads“ (1 oder 2).
  final int concurrency;
  final bool keepLiveFree;

  /// Anbieter-Verbindungen je Portal (null = unbekannt).
  final int? Function(String scope) maxConnections;

  /// Schon belegte Anbieter-Verbindungen je Portal (laufende Aufnahmen).
  final int Function(String scope) busyConnections;

  const DownloadEnv({
    this.connected = true,
    this.cellular = false,
    this.metered = false,
    this.mobileAllowed = false,
    this.dataSaverActive = false,
    this.concurrency = 1,
    this.keepLiveFree = false,
    this.maxConnections = _unknown,
    this.busyConnections = _none,
  });

  static int? _unknown(String _) => null;
  static int _none(String _) => 0;

  DownloadWait get networkWait => networkRule(
        connected: connected,
        cellular: cellular,
        metered: metered,
        mobileAllowed: mobileAllowed,
        dataSaverActive: dataSaverActive,
      );
}

/// Ziel-Adresse mit Zugangsdaten (nur im Speicher, nie gespeichert).
typedef ResolvedUrl = ({String url, Map<String, String> headers});

/// Alles, was die Warteschlange von außen braucht (Plattform, Speicher,
/// Zugangsdaten). Tests setzen eine Fake-Umgebung ein.
abstract class DownloadHost {
  Future<List<DownloadItem>> load();
  Future<void> save(List<DownloadItem> items);

  /// Platzhalter-Adresse → echte Adresse. null = Zugangsdaten fehlen.
  Future<ResolvedUrl?> resolve(DownloadItem d, String maskedUrl);

  /// Zielort festlegen (Datei im App-Ordner bzw. Dokument im SAF-Ordner).
  /// Liefert das Element mit gesetztem [DownloadItem.path].
  Future<DownloadItem> prepare(DownloadItem d);
  Future<DownloadSink> sinkFor(DownloadItem d);

  /// Ziel für eine Untertitel-Datei; liefert (Pfad, Sink).
  Future<(String, DownloadSink)?> subtitleSink(
      DownloadItem d, DownloadSub s, int index);

  /// Freier Platz am Zielort in Bytes, -1 = unbekannt.
  Future<int> freeSpace(DownloadItem d);
  Future<void> deleteFiles(DownloadItem d);
  DownloadEnv env();
  hc.Client get httpClient;

  /// Zustand geändert (Benachrichtigung/Vordergrunddienst aktualisieren).
  void changed(List<DownloadItem> items) {}
}

/// Download-Warteschlange: startet höchstens so viele Downloads wie
/// erlaubt (Einstellung, Anbieter-Verbindungen), wartet auf WLAN bzw.
/// Platz, setzt nach Fehlern mit wachsender Pause fort (HTTP Range) und
/// speichert den Stand (nur Platzhalter-Adressen).
class DownloadQueue {
  final DownloadHost host;
  DownloadQueue(this.host);

  List<DownloadItem> _items = const [];
  List<DownloadItem> get items => _items;

  final _listeners = <void Function(List<DownloadItem>)>[];
  void addListener(void Function(List<DownloadItem>) f) => _listeners.add(f);
  void removeListener(void Function(List<DownloadItem>) f) =>
      _listeners.remove(f);

  final _tokens = <String, TransferToken>{};

  /// Warum eine laufende Übertragung angehalten wurde.
  final _stopAs = <String, DownloadItem Function(DownloadItem)>{};
  final _retryAt = <String, DateTime>{};
  Timer? _retryTimer;
  bool _loaded = false;
  bool _pumping = false;
  bool _again = false;
  bool _disposed = false;
  DateTime _lastSave = DateTime.fromMillisecondsSinceEpoch(0);

  /// Läuft gerade (für Tests/Anzeige).
  Set<String> get running => {..._tokens.keys};

  Future<void> init() async {
    if (_loaded) return;
    _loaded = true;
    try {
      _items = await host.load();
    } catch (_) {
      _items = const [];
    }
    _emit(save: false);
    await pump();
  }

  void dispose() {
    _disposed = true;
    _retryTimer?.cancel();
    for (final t in _tokens.values) {
      t.stop();
    }
  }

  DownloadItem? byId(String id) {
    for (final d in _items) {
      if (d.id == id) return d;
    }
    return null;
  }

  // ------------------------------------------------------------ Aktionen
  /// Neue Downloads anhängen (schon vorhandene bleiben unverändert; ein
  /// gescheiterter wird neu eingereiht). Liefert die Zahl neuer Einträge.
  Future<int> add(List<DownloadItem> list) async {
    await init();
    var n = 0;
    final next = [..._items];
    for (final d in list) {
      final i = next.indexWhere((x) => x.id == d.id);
      if (i >= 0) {
        if (next[i].state == DownloadState.failed) {
          next[i] = next[i].copyWith(
              state: DownloadState.queued, clearError: true, attempts: 0);
          n++;
        }
        continue;
      }
      next.add(d.copyWith(state: DownloadState.queued));
      n++;
    }
    _items = next;
    _emit();
    await pump();
    return n;
  }

  Future<void> pause(String id) async {
    final d = byId(id);
    if (d == null || d.state == DownloadState.done) return;
    _retryAt.remove(id);
    final t = _tokens[id];
    if (t != null) {
      _stopAs[id] = (x) => x.copyWith(state: DownloadState.paused);
      t.stop();
      return;
    }
    _update(id, (x) => x.copyWith(state: DownloadState.paused));
    await pump();
  }

  Future<void> resume(String id) async {
    final d = byId(id);
    if (d == null ||
        (d.state != DownloadState.paused && d.state != DownloadState.failed &&
            d.state != DownloadState.waiting)) {
      return;
    }
    _retryAt.remove(id);
    _update(
        id,
        (x) => x.copyWith(
            state: DownloadState.queued, clearError: true, attempts: 0));
    await pump();
  }

  Future<void> pauseAll() async {
    for (final d in [..._items]) {
      if (d.state.active) await pause(d.id);
    }
  }

  Future<void> resumeAll() async {
    for (final d in [..._items]) {
      if (d.state == DownloadState.paused) await resume(d.id);
    }
  }

  /// Download abbrechen bzw. löschen (Dateien inklusive).
  Future<void> remove(String id) async {
    final d = byId(id);
    if (d == null) return;
    _retryAt.remove(id);
    final t = _tokens[id];
    if (t != null) {
      final gone = Completer<void>();
      _stopAs[id] = (x) {
        gone.complete();
        return x;
      };
      t.stop();
      await gone.future.timeout(const Duration(seconds: 10), onTimeout: () {});
    }
    _items = [for (final x in _items) if (x.id != id) x];
    _emit();
    try {
      await host.deleteFiles(d);
    } catch (_) {}
    await pump();
  }

  /// Netz/Einstellungen haben sich geändert: laufende Downloads anhalten,
  /// die nicht mehr dürfen; wartende starten, die wieder dürfen.
  Future<void> envChanged() async {
    final wait = host.env().networkWait;
    if (wait != DownloadWait.none) {
      for (final id in [..._tokens.keys]) {
        _stopAs[id] = (x) =>
            x.copyWith(state: DownloadState.waiting, wait: wait);
        _tokens[id]!.stop();
      }
    }
    await pump();
  }

  // ------------------------------------------------------------ Ablauf
  Future<void> pump() async {
    if (_disposed) return;
    if (_pumping) {
      _again = true;
      return;
    }
    _pumping = true;
    try {
      do {
        _again = false;
        await _pumpOnce();
      } while (_again && !_disposed);
    } finally {
      _pumping = false;
    }
  }

  Future<void> _pumpOnce() async {
    final env = host.env();
    final netWait = env.networkWait;
    final now = clock.now();
    for (final d in [..._items]) {
      if (_disposed) return;
      if (_tokens.containsKey(d.id)) continue;
      if (d.state != DownloadState.queued && d.state != DownloadState.waiting) {
        continue;
      }
      final retry = _retryAt[d.id];
      if (retry != null && now.isBefore(retry)) continue;
      if (netWait != DownloadWait.none) {
        _setWait(d.id, netWait);
        continue;
      }
      // Gleichzeitig insgesamt höchstens [concurrency].
      if (_tokens.length >= env.concurrency.clamp(1, 2)) {
        _setQueued(d.id);
        continue;
      }
      if (!d.isEmby) {
        final running = _tokens.keys
            .map(byId)
            .where((x) => x != null && !x.isEmby && x.scope == d.scope)
            .length;
        final slots = portalDownloadSlots(
            setting: env.concurrency,
            maxConnections: env.maxConnections(d.scope),
            otherConnections: env.busyConnections(d.scope),
            keepLiveFree: env.keepLiveFree);
        if (running >= slots) {
          if (slots == 0) {
            _setWait(d.id, DownloadWait.connections);
          } else {
            _setQueued(d.id);
          }
          continue;
        }
      }
      int free;
      try {
        free = await host.freeSpace(d);
      } catch (_) {
        free = -1;
      }
      if (!enoughSpace(free, d.total > 0 ? d.remaining : null)) {
        _setWait(d.id, DownloadWait.space);
        continue;
      }
      _start(d);
    }
    _scheduleRetry();
  }

  void _setWait(String id, DownloadWait w) {
    final d = byId(id);
    if (d == null || (d.state == DownloadState.waiting && d.wait == w)) return;
    _update(id, (x) => x.copyWith(state: DownloadState.waiting, wait: w));
  }

  void _setQueued(String id) {
    final d = byId(id);
    if (d == null || d.state == DownloadState.queued) return;
    _update(id, (x) => x.copyWith(state: DownloadState.queued));
  }

  void _scheduleRetry() {
    _retryTimer?.cancel();
    if (_retryAt.isEmpty || _disposed) return;
    final next = _retryAt.values.reduce((a, b) => a.isBefore(b) ? a : b);
    var delay = next.difference(clock.now());
    if (delay.isNegative) delay = Duration.zero;
    _retryTimer = Timer(delay + const Duration(milliseconds: 10), () {
      final now = clock.now();
      _retryAt.removeWhere((_, t) => !now.isBefore(t));
      pump();
    });
  }

  void _start(DownloadItem d) {
    final token = TransferToken();
    _tokens[d.id] = token;
    _retryAt.remove(d.id);
    _update(d.id, (x) => x.copyWith(state: DownloadState.running));
    unawaited(_run(d.id, token));
  }

  Future<void> _run(String id, TransferToken token) async {
    TransferOutcome? out;
    String? error;
    try {
      var d = byId(id)!;
      final resolved = await host.resolve(d, d.maskedUrl);
      if (resolved == null) {
        error = 'credentials';
      } else {
        if (d.path == null) {
          d = await host.prepare(d);
          _update(id, (x) => x.copyWith(path: d.path, tree: d.tree));
        }
        final sink = await host.sinkFor(d);
        out = await DownloadTransfer(host.httpClient).run(
          url: resolved.url,
          headers: resolved.headers,
          sink: sink,
          token: token,
          knownTotal: d.total,
          onProgress: (b, t) => _progress(id, b, t),
        );
        if (out.end == TransferEnd.complete) {
          await _loadSubtitles(id);
        }
      }
    } catch (_) {
      error = 'storage';
    }
    _tokens.remove(id);
    final stopAs = _stopAs.remove(id);
    if (_disposed) return;
    // Inzwischen gelöscht.
    if (byId(id) == null) return;
    if (out != null) {
      _update(
          id,
          (x) => x.copyWith(
              bytes: out!.bytes,
              total: out.total,
              rangeOk: out.rangeOk ?? x.rangeOk));
    }
    if (stopAs != null && (out == null || out.end != TransferEnd.complete)) {
      _update(id, stopAs);
    } else if (out?.end == TransferEnd.complete) {
      // Gleichzeitig angehalten/gelöscht: Signal trotzdem geben.
      stopAs?.call(byId(id)!);
      _update(
          id,
          (x) => x.copyWith(
              state: DownloadState.done, clearError: true, attempts: 0));
    } else {
      final code = error ?? out?.error ?? 'network';
      await _failed(id, code);
    }
    _emit(save: true);
    await pump();
  }

  Future<void> _failed(String id, String code) async {
    final d = byId(id);
    if (d == null) return;
    var c = code;
    if (c == 'storage') {
      // Speicher voll? Dann warten, bis wieder Platz ist.
      int free;
      try {
        free = await host.freeSpace(d);
      } catch (_) {
        free = -1;
      }
      if (free >= 0 && !enoughSpace(free, d.remaining)) {
        _update(id,
            (x) => x.copyWith(state: DownloadState.waiting, wait: DownloadWait.space));
        return;
      }
    }
    final attempts = d.attempts + 1;
    if (isPermanentDownloadError(c) || attempts >= downloadMaxAttempts) {
      _update(
          id,
          (x) => x.copyWith(
              state: DownloadState.failed, error: c, attempts: attempts));
      return;
    }
    _retryAt[id] = clock.now().add(retryDelay(attempts));
    _update(
        id,
        (x) => x.copyWith(
            state: DownloadState.waiting,
            wait: DownloadWait.retry,
            error: c,
            attempts: attempts));
  }

  Future<void> _loadSubtitles(String id) async {
    final d = byId(id);
    if (d == null || d.subs.isEmpty) return;
    final subs = [...d.subs];
    for (var i = 0; i < subs.length; i++) {
      final s = subs[i];
      if (s.path != null) continue;
      try {
        final r = await host.resolve(d, s.maskedUrl);
        final target = await host.subtitleSink(d, s, i);
        if (r == null || target == null) continue;
        final (path, sink) = target;
        final o = await DownloadTransfer(host.httpClient).run(
            url: r.url,
            headers: r.headers,
            sink: sink,
            token: TransferToken(),
            allowRange: false);
        if (o.end == TransferEnd.complete) subs[i] = s.withPath(path);
      } catch (_) {
        // Untertitel sind Beiwerk – der Film zählt.
      }
    }
    _update(id, (x) => x.copyWith(subs: subs));
  }

  void _progress(String id, int bytes, int total) {
    _update(id, (x) => x.copyWith(bytes: bytes, total: total), save: false);
    final now = clock.now();
    if (now.difference(_lastSave).inSeconds >= 5) {
      _lastSave = now;
      unawaited(_persist());
    }
  }

  void _update(String id, DownloadItem Function(DownloadItem) f,
      {bool save = true}) {
    _items = [for (final x in _items) x.id == id ? f(x) : x];
    _emit(save: save);
  }

  void _emit({bool save = true}) {
    final snapshot = _items;
    for (final l in [..._listeners]) {
      l(snapshot);
    }
    host.changed(snapshot);
    if (save) unawaited(_persist());
  }

  Future<void>? _saving;
  bool _saveAgain = false;

  Future<void> _persist() async {
    if (_saving != null) {
      _saveAgain = true;
      return _saving;
    }
    final c = Completer<void>();
    _saving = c.future;
    try {
      do {
        _saveAgain = false;
        try {
          await host.save(_items);
        } catch (_) {}
      } while (_saveAgain);
    } finally {
      _saving = null;
      c.complete();
    }
  }

  /// Für Tests: warten, bis alles gespeichert ist.
  Future<void> flush() async {
    while (_saving != null) {
      await _saving;
    }
  }
}
