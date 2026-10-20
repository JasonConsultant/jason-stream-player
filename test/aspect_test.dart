import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jason_stream_player/l10n/strings.dart';
import 'package:jason_stream_player/core/aspect.dart';

void main() {
  setUp(() => L10n.lang = 'de'); // Tests prüfen deutsche Texte
  test('alte gespeicherte Werte werden richtig übernommen', () {
    expect(AspectMode.fromId(null), AspectMode.original);
    expect(AspectMode.fromId('contain'), AspectMode.original);
    expect(AspectMode.fromId('cover'), AspectMode.fill);
    expect(AspectMode.fromId('fill'), AspectMode.stretch);
    expect(AspectMode.fromId('unbekannt'), AspectMode.original);
  });
  test('jede ID ist eindeutig und lässt sich zurücklesen', () {
    final ids = AspectMode.values.map((m) => m.id).toSet();
    expect(ids.length, AspectMode.values.length);
    for (final m in AspectMode.values) {
      if (m.id == 'fill') continue;
      expect(AspectMode.fromId(m.id), m);
    }
  });
  test('Formate machen, was sie sollen', () {
    expect(AspectMode.r4x3.ratio, closeTo(4 / 3, 1e-9));
    expect(AspectMode.stretch.fit, BoxFit.fill);
    expect(AspectMode.cinema.scale, closeTo(1.3125, 1e-9));
  });
  test('Weiterschalten läuft im Kreis', () {
    var m = AspectMode.original;
    for (var i = 0; i < AspectMode.values.length; i++) {
      m = m.next;
    }
    expect(m, AspectMode.original);
  });
}
