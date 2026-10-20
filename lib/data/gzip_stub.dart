import 'dart:typed_data';

/// Im Web entpackt der Browser gzip selbst (Content-Encoding).
Uint8List gunzipBytes(Uint8List data, {int maxBytes = 0}) => data;

/// Web: der Browser entpackt selbst.
Stream<List<int>> gunzipStream(Stream<List<int>> input, {int maxBytes = 0}) =>
    input;

/// Web: kein gzip (der Browser entpackt selbst) → direkt weiterreichen.
Sink<List<int>> gunzipSink(Sink<List<int>> out) => out;
