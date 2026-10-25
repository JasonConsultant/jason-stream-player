import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Ziel eines Downloads (Datei im App-Ordner oder SAF-Dokument).
abstract class DownloadSink {
  /// Bereits vorhandene Bytes (0 = nichts/neu).
  Future<int> length();

  /// Zum Schreiben öffnen: [append] = am Ende weiterschreiben, sonst leeren.
  Future<void> open({required bool append});
  Future<void> write(Uint8List data);
  Future<void> close();
  Future<void> delete();
}

/// Das Ziel kann nicht am Ende weiterschreiben (manche SAF-Anbieter).
class NoAppendException implements Exception {
  const NoAppendException();
}

/// Ergebnis einer Übertragung.
enum TransferEnd {
  /// Datei vollständig.
  complete,

  /// Abgebrochen (Pause/Abbruch/Netzregel) – Teildatei bleibt.
  stopped,

  /// Fehler (siehe [TransferOutcome.error]).
  failed,
}

class TransferOutcome {
  final TransferEnd end;
  final int bytes;
  final int total;

  /// Server liefert Teilbereiche (206).
  final bool? rangeOk;

  /// Fehlercode: network, server, busy, auth, forbidden, notfound, notfile,
  /// incomplete, storage.
  final String? error;
  const TransferOutcome(this.end,
      {required this.bytes, required this.total, this.rangeOk, this.error});
}

/// Abbruch-Signal für eine laufende Übertragung.
class TransferToken {
  bool _stopped = false;
  final _done = Completer<void>();
  bool get stopped => _stopped;
  Future<void> get onStop => _done.future;
  void stop() {
    if (_stopped) return;
    _stopped = true;
    _done.complete();
  }
}

/// Lädt eine Datei per HTTP – mit Fortsetzen über `Range`, wenn der Server
/// es kann (206), sonst von vorne (200). Schreibt in Blöcken (für SAF
/// über den Plattform-Kanal sparsam).
///
/// Die Adresse enthält Zugangsdaten: Sie wird hier weder geloggt noch in
/// Fehlertexte übernommen – nur Fehlercodes.
class DownloadTransfer {
  final http.Client client;

  /// Ohne Daten so lange → Netzfehler.
  final Duration idleTimeout;

  /// Blockgröße fürs Schreiben.
  final int blockSize;

  DownloadTransfer(this.client,
      {this.idleTimeout = const Duration(seconds: 30),
      this.blockSize = 512 * 1024});

  /// [knownTotal]: Größe aus einem früheren Versuch (-1 = unbekannt).
  /// [onProgress]: (geladen, gesamt oder -1), höchstens etwa alle 500 ms
  /// bzw. je Block.
  Future<TransferOutcome> run({
    required String url,
    Map<String, String> headers = const {},
    required DownloadSink sink,
    required TransferToken token,
    int knownTotal = -1,
    void Function(int bytes, int total)? onProgress,
    bool allowRange = true,
  }) async {
    var have = 0;
    try {
      have = await sink.length();
    } catch (_) {
      have = 0;
    }
    // Schon komplett (z. B. Abbruch kurz vor dem Abschluss)?
    if (knownTotal > 0 && have >= knownTotal) {
      return TransferOutcome(TransferEnd.complete,
          bytes: have, total: knownTotal);
    }
    final useRange = allowRange && have > 0;
    final req = http.Request('GET', Uri.parse(url))
      ..followRedirects = true
      ..headers.addAll(headers);
    if (useRange) req.headers['Range'] = 'bytes=$have-';

    http.StreamedResponse res;
    try {
      res = await client.send(req).timeout(idleTimeout);
    } catch (_) {
      return TransferOutcome(TransferEnd.failed,
          bytes: have, total: knownTotal, error: 'network');
    }
    if (token.stopped) {
      _drain(res);
      return TransferOutcome(TransferEnd.stopped,
          bytes: have, total: knownTotal);
    }

    final code = res.statusCode;
    if (code == 416 && useRange) {
      _drain(res);
      // Bereich jenseits des Endes: Datei ist schon ganz da – oder der
      // Server kennt die Länge anders → von vorne.
      final t = _totalFromContentRange(res.headers['content-range']);
      if (t != null && have >= t) {
        return TransferOutcome(TransferEnd.complete,
            bytes: have, total: t, rangeOk: true);
      }
      return run(
          url: url,
          headers: headers,
          sink: sink,
          token: token,
          knownTotal: -1,
          onProgress: onProgress,
          allowRange: false);
    }
    if (code < 200 || code >= 300) {
      _drain(res);
      return TransferOutcome(TransferEnd.failed,
          bytes: have, total: knownTotal, error: _errorOf(code));
    }
    final type = (res.headers['content-type'] ?? '').toLowerCase();
    if (type.startsWith('text/html') ||
        type.contains('mpegurl') ||
        type.contains('dash+xml') ||
        type.startsWith('application/json')) {
      _drain(res);
      return TransferOutcome(TransferEnd.failed,
          bytes: have, total: knownTotal, error: 'notfile');
    }

    bool append;
    int start;
    int total;
    bool? rangeOk;
    if (code == 206) {
      final cr = res.headers['content-range'];
      final from = _startFromContentRange(cr);
      if (!useRange || from == null || from != have) {
        // Anderer Bereich als erbeten → sicherheitshalber von vorne.
        _drain(res);
        return run(
            url: url,
            headers: headers,
            sink: sink,
            token: token,
            knownTotal: -1,
            onProgress: onProgress,
            allowRange: false);
      }
      append = true;
      start = have;
      total = _totalFromContentRange(cr) ??
          (res.contentLength != null ? have + res.contentLength! : -1);
      rangeOk = true;
    } else {
      // 200: ganze Datei (Server ignoriert Range oder neuer Download).
      append = false;
      start = 0;
      total = res.contentLength ?? -1;
      if (useRange) rangeOk = false;
    }

    try {
      await sink.open(append: append);
    } on NoAppendException {
      _drain(res);
      return run(
          url: url,
          headers: headers,
          sink: sink,
          token: token,
          knownTotal: -1,
          onProgress: onProgress,
          allowRange: false);
    } catch (_) {
      _drain(res);
      return TransferOutcome(TransferEnd.failed,
          bytes: have, total: total, rangeOk: rangeOk, error: 'storage');
    }

    var bytes = start;
    final buf = BytesBuilder(copy: false);
    var lastReport = DateTime.fromMillisecondsSinceEpoch(0);
    Future<String?> flush() async {
      if (buf.isEmpty) return null;
      try {
        await sink.write(buf.takeBytes());
        return null;
      } catch (_) {
        return 'storage';
      }
    }

    onProgress?.call(bytes, total);
    String? error;
    var stopped = false;
    final sub = res.stream.listen(null);
    final done = Completer<void>();
    Future<void> inflight = Future.value();
    // Eigene Leerlauf-Überwachung (Stream.timeout pausiert nicht sauber
    // mit dem Schreiben mit).
    Timer? idle;
    void arm() {
      idle?.cancel();
      idle = Timer(idleTimeout, () {
        if (done.isCompleted) return;
        error ??= 'network';
        sub.cancel();
        done.complete();
      });
    }

    arm();
    sub.onData((chunk) {
      arm();
      buf.add(chunk);
      bytes += chunk.length;
      if (buf.length >= blockSize) {
        sub.pause();
        final f = flush();
        inflight = f;
        f.then((e) {
          if (e != null) {
            error = e;
            sub.cancel();
            if (!done.isCompleted) done.complete();
            return;
          }
          final now = DateTime.now();
          if (now.difference(lastReport).inMilliseconds >= 500) {
            lastReport = now;
            onProgress?.call(bytes, total);
          }
          if (token.stopped) {
            stopped = true;
            sub.cancel();
            if (!done.isCompleted) done.complete();
          } else {
            arm();
            sub.resume();
          }
        });
      }
    });
    sub.onError((Object e) {
      error ??= 'network';
      sub.cancel();
      if (!done.isCompleted) done.complete();
    });
    sub.onDone(() {
      if (!done.isCompleted) done.complete();
    });
    unawaited(token.onStop.then((_) {
      if (done.isCompleted) return;
      stopped = true;
      sub.cancel();
      done.complete();
    }));
    await done.future;
    idle?.cancel();
    // Nie zwei Schreibvorgänge gleichzeitig.
    await inflight;
    final fe = await flush();
    error ??= fe;
    try {
      await sink.close();
    } catch (_) {
      error ??= 'storage';
    }
    // Abgebrochene Bytes, die nicht geschrieben wurden, zählen nicht.
    if (error == 'storage') {
      try {
        bytes = await sink.length();
      } catch (_) {}
    }
    onProgress?.call(bytes, total);
    if (error != null) {
      return TransferOutcome(TransferEnd.failed,
          bytes: bytes, total: total, rangeOk: rangeOk, error: error);
    }
    if (stopped) {
      return TransferOutcome(TransferEnd.stopped,
          bytes: bytes, total: total, rangeOk: rangeOk);
    }
    if (total > 0 && bytes < total) {
      return TransferOutcome(TransferEnd.failed,
          bytes: bytes, total: total, rangeOk: rangeOk, error: 'incomplete');
    }
    return TransferOutcome(TransferEnd.complete,
        bytes: bytes, total: total > 0 ? total : bytes, rangeOk: rangeOk);
  }

  static void _drain(http.StreamedResponse r) {
    r.stream.listen((_) {}, onError: (_) {}, cancelOnError: true).cancel();
  }

  static String _errorOf(int code) => switch (code) {
        401 => 'auth',
        403 => 'forbidden',
        404 || 410 => 'notfound',
        429 || 458 || 503 => 'busy',
        _ => code >= 500 ? 'server' : 'http$code',
      };

  /// `bytes 100-999/1000` → 100.
  static int? _startFromContentRange(String? cr) {
    final m = RegExp(r'bytes\s+(\d+)-\d+/(\d+|\*)').firstMatch(cr ?? '');
    return m == null ? null : int.tryParse(m[1]!);
  }

  /// `bytes 100-999/1000` bzw. `bytes */1000` → 1000.
  static int? _totalFromContentRange(String? cr) {
    final m = RegExp(r'/(\d+)\s*$').firstMatch(cr ?? '');
    return m == null ? null : int.tryParse(m[1]!);
  }
}

/// Download-Ziel im Speicher – für Tests.
class MemorySink implements DownloadSink {
  final data = BytesBuilder();
  bool opened = false;
  int opens = 0;
  bool? lastAppend;
  bool deleted = false;

  /// Schreibfehler nach so vielen Bytes simulieren.
  int? failAfter;

  /// Ziel kann nicht anhängen (wie manche SAF-Anbieter).
  bool noAppend = false;

  @override
  Future<int> length() async => data.length;

  @override
  Future<void> open({required bool append}) async {
    if (append && noAppend) throw const NoAppendException();
    opens++;
    lastAppend = append;
    if (!append) data.clear();
    opened = true;
  }

  @override
  Future<void> write(Uint8List bytes) async {
    if (failAfter != null && data.length + bytes.length > failAfter!) {
      throw StateError('voll');
    }
    data.add(bytes);
  }

  @override
  Future<void> close() async => opened = false;

  @override
  Future<void> delete() async {
    data.clear();
    deleted = true;
  }
}
