import 'package:flutter_test/flutter_test.dart';
import 'package:jason_stream_player/core/languages.dart';

void main() {
  final tracks = [
    (id: 'auto', language: null, title: null),
    (id: '1', language: 'eng', title: 'English 5.1'),
    (id: '2', language: 'ger', title: null),
    (id: '3', language: null, title: 'Türkçe'),
  ];

  test('Tonsprache: ger/deu/de werden als Deutsch erkannt', () {
    expect(pickTrack(tracks, 'de'), 2);
    expect(pickTrack(tracks, 'en'), 1);
    expect(pickTrack(tracks, 'tr'), 3); // nur Titel, kein Code
  });

  test('Automatisch greift nicht ein; fehlende Sprache ändert nichts', () {
    expect(pickTrack(tracks, 'auto'), isNull);
    expect(pickTrack(tracks, 'fr'), isNull);
  });

  test('Untertitel: aus bzw. fehlende Sprache → ausschalten', () {
    expect(pickTrack(tracks, 'off', allowOff: true), -1);
    expect(pickTrack(tracks, 'fr', allowOff: true), -1);
    expect(pickTrack(tracks, 'de', allowOff: true), 2);
  });

  test('Lesbare Namen', () {
    expect(TrackLanguage.describe('ger', null, 'x'), 'Deutsch');
    expect(TrackLanguage.describe('eng', 'English 5.1', 'x'), 'English · English 5.1');
    expect(TrackLanguage.describe(null, null, 'Spur 4'), 'Spur 4');
  });
}
