import 'package:flutter_test/flutter_test.dart';
import 'package:jason_stream_player/data/recordings/recordings.dart';

void main() {
  test('Dateiname ohne verbotene Zeichen', () {
    final n = recordingFileName('Sky/Sport: 1', 'Spiel "A" vs B?', DateTime(2026, 10, 19, 20, 5));
    expect(n, 'Sky Sport 1 – Spiel A vs B – 2026-10-19 2005.ts');
    expect(n.contains('/'), isFalse);
  });

  test('JSON hin und zurück', () {
    final r = Recording(
      id: 'x', channelId: '1', channelName: 'Das Erste', title: 'Tatort',
      start: DateTime(2026, 10, 19, 20, 13), end: DateTime(2026, 10, 19, 21, 50),
    );
    final b = Recording.fromJson(r.toJson().cast<String, dynamic>());
    expect(b.title, 'Tatort');
    expect(b.start, r.start);
    expect(b.status, 'geplant');
  });
}
