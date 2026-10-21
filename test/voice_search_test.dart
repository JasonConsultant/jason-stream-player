import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jason_stream_player/core/theme.dart';
import 'package:jason_stream_player/core/voice_search.dart';
import 'package:jason_stream_player/l10n/strings.dart';
import 'package:jason_stream_player/state/providers.dart';
import 'package:jason_stream_player/ui/widgets/common.dart';

/// Sprachsuche: Mikrofon nur, wenn das Gerät eine Spracheingabe meldet
/// (MethodChannel `voiceAvailable`), per D-Pad erreichbar, startet
/// `voiceSearch` mit der App-Sprache und liefert den erkannten Text.

final _calls = <MethodCall>[];

/// Plattform-Kanal nachbilden. [available]: Antwort auf voiceAvailable
/// (null = Methode fehlt → MissingPluginException).
void _mockChannel({bool? available, String? text, bool fail = false}) {
  _calls.clear();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(VoiceSearch.channel, (call) async {
    _calls.add(call);
    switch (call.method) {
      case 'voiceAvailable':
        if (available == null) throw MissingPluginException();
        return available;
      case 'voiceSearch':
        if (fail) {
          throw PlatformException(code: 'novoice');
        }
        return text;
    }
    return null;
  });
  addTearDown(() => TestDefaultBinaryMessengerBinding
      .instance.defaultBinaryMessenger
      .setMockMethodCallHandler(VoiceSearch.channel, null));
}

/// Suchfeld wie in Live TV/Suche, davor eine Kachel als Startpunkt.
Future<TextEditingController> _pump(WidgetTester tester,
    {bool tv = true}) async {
  final ctrl = TextEditingController();
  addTearDown(ctrl.dispose);
  await tester.pumpWidget(ProviderScope(
    overrides: [isTvProvider.overrideWithValue(tv)],
    child: MaterialApp(
      theme: buildTheme(tv: tv),
      home: Scaffold(
        body: Column(children: [
          TextButton(
              autofocus: true, onPressed: () {}, child: const Text('Oben')),
          SearchField(
            controller: ctrl,
            hint: 'Suchen',
            onChanged: (_) {},
            width: 400,
          ),
        ]),
      ),
    ),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  return ctrl;
}

Finder get _mic => find.byIcon(Icons.mic_rounded);

Future<void> _key(WidgetTester tester, LogicalKeyboardKey k) async {
  await tester.sendKeyEvent(k);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

/// Liegt der Fokus im Mikrofon-Knopf?
bool _micFocused() {
  final c = FocusManager.instance.primaryFocus?.context;
  if (c == null) return false;
  return find
      .descendant(
          of: find.byElementPredicate((e) => e == c), matching: _mic)
      .evaluate()
      .isNotEmpty;
}

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    L10n.lang = 'de';
  });

  setUp(VoiceSearch.debugReset);

  testWidgets('Ohne Android: kein Mikrofon, Kanal wird nicht gefragt',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      _mockChannel(available: true);
      await _pump(tester);
      expect(_mic, findsNothing);
      expect(_calls, isEmpty);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  for (final (label, available) in [
    ('Gerät ohne Spracheingabe', false as bool?),
    ('Kanal ohne Handler', null),
  ]) {
    testWidgets('$label: Mikrofon ausgeblendet, kein Absturz', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        _mockChannel(available: available);
        await _pump(tester);
        expect(_mic, findsNothing);
        expect(_calls.map((c) => c.method), ['voiceAvailable']);
        expect(tester.takeException(), isNull);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  testWidgets('Mit Spracheingabe: per D-Pad erreichbar, OK startet in der '
      'App-Sprache, Text landet im Feld', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      _mockChannel(available: true, text: '  Tagesschau ');
      L10n.lang = 'en';
      final ctrl = await _pump(tester);
      expect(_mic, findsOneWidget);

      // ▼ ins Suchfeld, ▶ zum Mikrofon (Feld ist leer → verlässt es).
      await _key(tester, LogicalKeyboardKey.arrowDown);
      expect(_micFocused(), isFalse);
      for (var i = 0; i < 3 && !_micFocused(); i++) {
        await _key(tester, LogicalKeyboardKey.arrowRight);
      }
      expect(_micFocused(), isTrue);

      await _key(tester, LogicalKeyboardKey.select);
      await tester.pump(const Duration(milliseconds: 100));
      final call = _calls.lastWhere((c) => c.method == 'voiceSearch');
      expect((call.arguments as Map)['lang'], 'en');
      expect((call.arguments as Map)['prompt'], isA<String>());
      expect(ctrl.text, 'Tagesschau');
    } finally {
      L10n.lang = 'de';
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('Abbruch oder Fehler der Erkennung: Feld bleibt unverändert',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      _mockChannel(available: true, fail: true);
      final ctrl = await _pump(tester, tv: false);
      ctrl.text = 'ard';
      await tester.tap(_mic);
      await tester.pump(const Duration(milliseconds: 100));
      expect(_calls.last.method, 'voiceSearch');
      expect(ctrl.text, 'ard');
      expect(tester.takeException(), isNull);

      // Abgebrochen (null) bzw. nur Leerzeichen → ebenfalls nichts.
      _mockChannel(available: true, text: '   ');
      expect(await VoiceSearch.listen(), isNull);
      _mockChannel(available: true);
      expect(await VoiceSearch.listen(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  test('Verfügbarkeit wird nur einmal abgefragt', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      _mockChannel(available: true);
      expect(await VoiceSearch.available(), isTrue);
      expect(await VoiceSearch.available(), isTrue);
      expect(_calls.where((c) => c.method == 'voiceAvailable'), hasLength(1));
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
