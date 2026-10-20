// Web-Vorschau: keine Aufnahmen.
Future<String> recordingsDir() async => '';
Future<List<({String path, int bytes, DateTime modified})>> listRecordings() async =>
    const [];
Future<void> deleteRecording(String path) async {}
Future<bool> isInRecordingsDir(String path) async => false;
