import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

/// Daten stückweise an ein Hintergrund-Isolate liefern.
///
/// Statt eine große Antwort (z. B. 30 MB Filmliste) erst komplett im
/// Haupt-Isolate zu sammeln und dann am Stück ins Isolate zu kopieren
/// (≈ 20 ms Stillstand je 22 MB auf dem Desktop, auf TV-Boxen ein Vielfaches),
/// wird jedes Netzwerk-Stück sofort weitergereicht (je ~64 KB, kaum messbar).
/// Das Isolate setzt die Bytes zusammen und führt [work] aus; zurück kommt
/// nur das fertige Ergebnis (per `Isolate.exit`, ohne Kopie).
class IsolateFeed {
  IsolateFeed._();

  /// [feeds] Datenströme; [produce] schreibt sie über [FeedSink] und liefert
  /// am Ende das Argument für [work] (z. B. erst dann bekannte Adresse).
  /// [work] muss eine statische/top-level Funktion sein.
  static Future<R> run<A, R>({
    required int feeds,
    required Future<A> Function(FeedSink sink) produce,
    required R Function(List<Uint8List> data, A arg) work,
  }) async {
    final rp = ReceivePort();
    final portReady = Completer<SendPort>();
    rp.listen((m) {
      if (m is SendPort && !portReady.isCompleted) portReady.complete(m);
    });
    final result = Isolate.run(_task(rp.sendPort, feeds, work));
    // Fehler des Isolates nicht unbehandelt lassen, falls produce zuerst wirft.
    result.ignore();
    try {
      final port = await portReady.future;
      final sink = FeedSink._(port);
      A arg;
      try {
        arg = await produce(sink);
      } catch (_) {
        port.send(const ('abort', 0, null));
        rethrow;
      }
      port.send(('go', 0, arg));
      return await result;
    } finally {
      rp.close();
    }
  }

  static FutureOr<R> Function() _task<A, R>(SendPort main, int feeds,
          R Function(List<Uint8List> data, A arg) work) =>
      () => _worker(main, feeds, work);

  static Future<R> _worker<A, R>(SendPort main, int feeds,
      R Function(List<Uint8List> data, A arg) work) async {
    final rp = ReceivePort();
    main.send(rp.sendPort);
    final parts = List.generate(feeds, (_) => BytesBuilder(copy: false));
    final done = Completer<A>();
    final sub = rp.listen((m) {
      final (String kind, int i, Object? v) = m as (String, int, Object?);
      switch (kind) {
        case 'chunk':
          parts[i].add(v as Uint8List);
        case 'reset':
          parts[i].clear();
        case 'go':
          if (!done.isCompleted) done.complete(v as A);
        case 'abort':
          if (!done.isCompleted) done.completeError(StateError('abgebrochen'));
      }
    });
    try {
      final arg = await done.future;
      return work([for (final p in parts) p.takeBytes()], arg);
    } finally {
      await sub.cancel();
      rp.close();
    }
  }
}

/// Schreibseite von [IsolateFeed.run].
class FeedSink {
  final SendPort _port;
  FeedSink._(this._port);

  void add(int feed, List<int> chunk) {
    // Nur eigenständige Puffer senden: eine Sicht (sublistView) auf einen
    // großen Puffer würde sonst samt ganzem Puffer kopiert.
    final whole = chunk is Uint8List &&
        chunk.offsetInBytes == 0 &&
        chunk.lengthInBytes == chunk.buffer.lengthInBytes;
    _port.send(('chunk', feed, whole ? chunk : Uint8List.fromList(chunk)));
  }

  /// Bisher gelieferte Daten verwerfen (z. B. Neuversuch auf anderer Adresse).
  void reset(int feed) => _port.send(('reset', feed, null));
}
