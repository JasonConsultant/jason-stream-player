import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Entpackt gzip mit Obergrenze (Schutz vor „Zip-Bomben“ im EPG).
Uint8List gunzipBytes(Uint8List data, {int maxBytes = 600 * 1024 * 1024}) {
  final out = BytesBuilder(copy: false);
  final sink = ByteConversionSink.withCallback((chunk) {
    out.add(chunk);
    if (out.length > maxBytes) {
      throw const FormatException('EPG zu groß');
    }
  });
  final decoder = gzip.decoder.startChunkedConversion(sink);
  const step = 64 * 1024;
  for (var i = 0; i < data.length; i += step) {
    decoder.add(data.sublist(i, i + step > data.length ? data.length : i + step));
  }
  decoder.close();
  return out.takeBytes();
}

/// Entpackt gzip als Datenstrom (Stück für Stück, mit Obergrenze).
Stream<List<int>> gunzipStream(Stream<List<int>> input,
    {int maxBytes = 1024 * 1024 * 1024}) async* {
  var total = 0;
  await for (final chunk in input.transform(gzip.decoder)) {
    total += chunk.length;
    if (total > maxBytes) throw const FormatException('EPG zu groß');
    yield chunk;
  }
}

/// Gzip-Entpacker als Sink (synchron, für die EPG-Pipeline).
Sink<List<int>> gunzipSink(Sink<List<int>> out) =>
    gzip.decoder.startChunkedConversion(out);
