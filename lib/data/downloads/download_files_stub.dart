import 'dart:typed_data';

import 'download_transfer.dart';

// Web-Vorschau: keine Downloads.
String? downloadsDirOverride;
Future<String> downloadsDir() async => '';
Future<bool> isInDownloadsDir(String path) async => false;
Future<bool> localFileExists(String path) async => false;
Future<void> deleteLocalFile(String path) async {}
Future<String?> readDownloadList() async => null;
Future<void> writeDownloadList(String json) async {}

class FileSink implements DownloadSink {
  final String path;
  FileSink(this.path);
  @override
  Future<int> length() async => 0;
  @override
  Future<void> open({required bool append}) async {}
  @override
  Future<void> write(Uint8List data) async {}
  @override
  Future<void> close() async {}
  @override
  Future<void> delete() async {}
}
