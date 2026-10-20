import 'package:flutter_test/flutter_test.dart';
import 'package:jason_stream_player/l10n/strings.dart';
import 'package:jason_stream_player/core/stream_errors.dart';

StreamErrorKind k(String m) => StreamError.classify(m).kind;

void main() {
  setUp(() => L10n.lang = 'de'); // Tests prüfen deutsche Texte
  group('Standort-Sperre erkennen', () {
    test('HTTP 451 → standortgesperrt', () {
      expect(k('Failed to open: HTTP error 451 Unavailable For Legal Reasons'),
          StreamErrorKind.geoBlocked);
      expect(k('Server returned 451'), StreamErrorKind.geoBlocked);
    });
    test('HTTP 403 → kein Zugriff (Standort/Abo/Verbindungen)', () {
      expect(k('http error 403 Forbidden'), StreamErrorKind.forbidden);
      expect(StreamError.classify('HTTP error 403').isLocationRelated, isTrue);
    });
    test('Sendernummer 451 in der URL ist KEINE Sperre', () {
      expect(k('Failed to open http://srv/live/•••/•••/451.ts.'),
          isNot(StreamErrorKind.geoBlocked));
      expect(k('Failed to open http://srv/live/•••/•••/403.ts.'),
          isNot(StreamErrorKind.forbidden));
    });
    test('andere Fehler', () {
      expect(k('HTTP error 401 Unauthorized'), StreamErrorKind.unauthorized);
      expect(k('HTTP error 404 Not Found'), StreamErrorKind.notFound);
      expect(k('Connection timed out'), StreamErrorKind.unreachable);
      expect(k('Diese Stream-Adresse wurde aus Sicherheitsgründen blockiert.'),
          StreamErrorKind.blockedByApp);
    });
    test('Meldungen sind auf Deutsch und ohne Technik-Kauderwelsch', () {
      final e = StreamError.classify('HTTP error 451');
      expect(e.title, 'An deinem Standort nicht verfügbar');
      expect(e.message, contains('Anbieter'));
    });
  });
}
