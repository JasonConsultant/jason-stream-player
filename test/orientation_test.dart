import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jason_stream_player/core/orientation.dart';

/// Nach Player/Multiview muss das Handy wieder ins Hochformat zurück –
/// auch wenn „Automatisch drehen“ aus ist (erst Hochformat, dann frei).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <Object?>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (c) async {
      if (c.method == 'SystemChrome.setPreferredOrientations') {
        calls.add(c.arguments);
      }
      return null;
    });
  });

  testWidgets('vorher Hochformat: erst Hochformat sperren, dann freigeben',
      (tester) async {
    await AppOrientation.restore(portraitBefore: true);
    expect(calls, [
      ['DeviceOrientation.portraitUp']
    ]);
    await tester.pump(const Duration(milliseconds: 700));
    expect(calls.last, isEmpty);
  });

  testWidgets('vorher Querformat: gleich freigeben', (tester) async {
    await AppOrientation.restore(portraitBefore: false);
    expect(calls, [isEmpty]);
  });

  testWidgets('Fernseher: nichts ändern', (tester) async {
    await AppOrientation.restore(portraitBefore: true, tv: true);
    expect(calls, isEmpty);
  });
}
