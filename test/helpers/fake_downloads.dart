import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jason_stream_player/data/downloads/download_models.dart';
import 'package:jason_stream_player/data/downloads/download_queue.dart';
import 'package:jason_stream_player/data/downloads/download_transfer.dart';
import 'package:jason_stream_player/data/downloads/url_vault.dart';

/// Fake-Server für Dateien: Range ja/nein, Abbruch nach N Bytes, Anhalten.
class FakeFileServer {
  final Map<String, Uint8List> files = {};
  bool supportsRange = true;

  /// Verbindung nach so vielen Bytes (je Antwort) abreißen lassen.
  int? dropAfter;

  /// Antworten so lange zurückhalten.
  Completer<void>? hold;
  int? status;
  String contentType = 'video/x-matroska';
  final requests = <http.BaseRequest>[];

  /// Bytes je Teilstück der Antwort.
  int chunk = 64 * 1024;

  late final client = MockClient.streaming((req, _) async {
    requests.add(req);
    if (status != null) {
      return http.StreamedResponse(Stream.value(utf8.encode('nein')), status!);
    }
    final key = req.url.path;
    final data = files[key];
    if (data == null) {
      return http.StreamedResponse(const Stream.empty(), 404);
    }
    var from = 0;
    var code = 200;
    final headers = <String, String>{'content-type': contentType};
    final range = req.headers['Range'];
    if (range != null && supportsRange) {
      from = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)![1]!);
      if (from >= data.length) {
        return http.StreamedResponse(const Stream.empty(), 416,
            headers: {'content-range': 'bytes */${data.length}'});
      }
      code = 206;
      headers['content-range'] = 'bytes $from-${data.length - 1}/${data.length}';
    }
    final body = data.sublist(from);
    final drop = dropAfter;
    Stream<List<int>> stream() async* {
      if (hold != null) await hold!.future;
      var sent = 0;
      for (var i = 0; i < body.length; i += chunk) {
        final end = (i + chunk).clamp(0, body.length);
        if (drop != null && sent + (end - i) > drop) {
          yield body.sublist(i, i + (drop - sent));
          throw const SocketExceptionLike();
        }
        sent += end - i;
        yield body.sublist(i, end);
        await Future<void>.delayed(Duration.zero);
      }
    }

    return http.StreamedResponse(stream(), code,
        contentLength: body.length, headers: headers);
  });
}

class SocketExceptionLike implements Exception {
  const SocketExceptionLike();
}

Uint8List fakeBytes(int n) =>
    Uint8List.fromList(List<int>.generate(n, (i) => (i * 7) & 0xff));

/// Fake-Umgebung für die Warteschlange.
class FakeHost extends DownloadHost {
  final FakeFileServer server;
  FakeHost(this.server);

  DownloadEnv envValue = const DownloadEnv();
  int free = 50 * 1024 * 1024 * 1024;
  final sinks = <String, MemorySink>{};
  final deleted = <String>[];
  List<Map<String, Object?>> saved = const [];
  List<DownloadItem> initial = const [];
  Map<String, String> secrets = {'U': 'http://srv/movie/hans/geheim'};

  @override
  Future<List<DownloadItem>> load() async => initial;

  @override
  Future<void> save(List<DownloadItem> items) async {
    saved = [for (final d in items) d.toJson()];
  }

  @override
  Future<ResolvedUrl?> resolve(DownloadItem d, String maskedUrl) async {
    final u = UrlVault.unmask(maskedUrl, secrets);
    return u == null ? null : (url: u, headers: const <String, String>{});
  }

  @override
  Future<DownloadItem> prepare(DownloadItem d) async =>
      d.copyWith(path: '/dl/${d.itemId}.mkv');

  @override
  Future<DownloadSink> sinkFor(DownloadItem d) async =>
      sinks.putIfAbsent(d.id, MemorySink.new);

  @override
  Future<(String, DownloadSink)?> subtitleSink(
          DownloadItem d, DownloadSub s, int index) async =>
      ('/dl/${d.itemId}.$index.srt', sinks.putIfAbsent('${d.id}#$index', MemorySink.new));

  @override
  Future<int> freeSpace(DownloadItem d) async => free;

  @override
  Future<void> deleteFiles(DownloadItem d) async => deleted.add(d.id);

  @override
  DownloadEnv env() => envValue;

  @override
  http.Client get httpClient => server.client;
}

