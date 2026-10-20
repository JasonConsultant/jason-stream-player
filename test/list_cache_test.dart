import 'package:flutter_test/flutter_test.dart';
import 'package:jason_stream_player/data/list_cache.dart';
import 'package:jason_stream_player/models/models.dart';

const portal = Portal(
  id: 'p1',
  name: 'X',
  type: PortalType.xtream,
  url: 'http://srv.example:8080',
  username: 'jason77',
  password: 'Geh eim!',
);

void main() {
  final json = '{"fp":"${ListCache.fingerprintFor(portal)}","ch":['
      '"http://srv.example:8080/live/jason77/Geh%20eim!/123.ts",'
      '"http://srv.example:8080/live/jason77/Geh eim!/124.ts"]}';

  test('Gespeicherte Datei enthält keine Zugangsdaten', () {
    final masked = ListCache.debugMask(json, portal);
    expect(masked, isNot(contains('jason77')));
    expect(masked, isNot(contains('Geh')));
  });

  test('Beim Laden werden die Zugangsdaten wieder eingesetzt', () {
    final restored =
        ListCache.debugRestore(ListCache.debugMask(json, portal), portal);
    expect(restored, json);
  });

  test('Andere Zugangsdaten → Zwischenspeicher wird verworfen', () {
    final masked = ListCache.debugMask(json, portal);
    const other = Portal(
        id: 'p1',
        name: 'X',
        type: PortalType.xtream,
        url: 'http://srv.example:8080',
        username: 'jason77',
        password: 'neu');
    expect(ListCache.debugRestore(masked, other), isNull);
  });
}
