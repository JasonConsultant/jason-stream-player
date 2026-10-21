import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:jason_stream_player/core/secret_store.dart';
import 'package:jason_stream_player/core/subtitle_style.dart';
import 'package:jason_stream_player/core/theme.dart';
import 'package:jason_stream_player/data/storage.dart';
import 'package:jason_stream_player/l10n/strings.dart';
import 'package:jason_stream_player/models/models.dart';
import 'package:jason_stream_player/state/providers.dart';
import 'package:jason_stream_player/ui/live/my_groups_ui.dart';
import 'package:jason_stream_player/ui/portals/add_portal_screen.dart';
import 'package:jason_stream_player/ui/portals/welcome_screen.dart';
import 'package:jason_stream_player/ui/settings/settings_screen.dart';
import 'package:jason_stream_player/ui/settings/subtitle_style_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Dialoge, Textfelder und Einstellungen nur mit der Fernbedienung:
/// Startfokus, Pfeile verlassen Textfelder, OK startet die Eingabe,
/// Zurück schließt ohne Falle.

class _Active extends ActivePortalNotifier {
  @override
  Future<Portal?> build() async => Portal.demo;
}

class _Portals extends PortalsNotifier {
  @override
  Future<List<Portal>> build() async => const [];
}

class _Epg extends EpgNotifier {
  @override
  Future<Map<String, List<EpgEntry>>> build() async => const {};
  @override
  void want(Channel c) {}
}

Future<void> _pump(WidgetTester tester, Widget home,
    {required bool tv, Storage? storage}) async {
  tester.view.physicalSize = const Size(1920, 1080);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    overrides: [
      isTvProvider.overrideWithValue(tv),
      if (storage != null) storageProvider.overrideWith((ref) async => storage),
      activePortalProvider.overrideWith(_Active.new),
      portalsProvider.overrideWith(_Portals.new),
      repositoryProvider.overrideWith((ref) async => null),
      epgProvider.overrideWith(_Epg.new),
    ],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildTheme(tv: tv),
      home: home,
    ),
  ));
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _press(WidgetTester tester, LogicalKeyboardKey k) async {
  await tester.sendKeyEvent(k);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

/// Zurück wie auf dem Gerät (siehe remote_back_test.dart).
Future<void> _back(WidgetTester tester) async {
  final handled = await tester.sendKeyEvent(LogicalKeyboardKey.escape);
  if (!handled) await tester.binding.handlePopRoute();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

FocusNode? get _focus => FocusManager.instance.primaryFocus;

bool _focusIn(Type t) {
  var found = false;
  (_focus?.context as Element?)?.visitAncestorElements((e) {
    if (e.widget.runtimeType == t) found = true;
    return !found;
  });
  return found;
}

List<String> _focusedTexts() {
  final out = <String>[];
  void visit(Element e) {
    final w = e.widget;
    if (w is Text && w.data != null) out.add(w.data!);
    e.visitChildren(visit);
  }

  (_focus?.context as Element?)?.visitChildren(visit);
  return out;
}

EditableText _editable(WidgetTester tester) =>
    tester.widget<EditableText>(find.byType(EditableText));

/// Knopf, der [open] mit seinem Kontext aufruft.
Widget _opener(void Function(BuildContext) open) => Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: TextButton(
              onPressed: () => open(context), child: const Text('öffnen')),
        ),
      ),
    );

void main() {
  late Storage storage;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    L10n.lang = 'de';
    await initializeDateFormatting('de');
    SharedPreferences.setMockInitialValues({});
    storage = await Storage.open(store: PreviewSecretStore());
  });

  group('Textfeld im Dialog', () {
    testWidgets('TV: OK tippt, Pfeile verlassen, Zurück schließt',
        (tester) async {
      String? result = 'unberührt';
      await _pump(
          tester,
          _opener((c) async => result = await askGroupName(c)),
          tv: true);
      await tester.tap(find.text('öffnen'));
      await tester.pumpAndSettle();
      expect(find.text('Neue Gruppe'), findsOneWidget);

      // Feld hat den Fokus, aber noch keine Tastatur (nur markiert).
      expect(_focusIn(EditableText), isTrue);
      expect(_editable(tester).readOnly, isTrue);

      // ▼ verlässt das Feld zu den Knöpfen, ▲ zurück.
      await _press(tester, LogicalKeyboardKey.arrowDown);
      expect(_focusIn(EditableText), isFalse);
      expect(_focusedTexts(), anyOf(contains('Speichern'), contains('Abbrechen')));
      await _press(tester, LogicalKeyboardKey.arrowUp);
      expect(_focusIn(EditableText), isTrue);

      // OK startet die Eingabe, Zurück beendet sie – Dialog bleibt offen.
      await _press(tester, LogicalKeyboardKey.select);
      expect(_editable(tester).readOnly, isFalse);
      await _back(tester);
      expect(_editable(tester).readOnly, isTrue);
      expect(find.text('Neue Gruppe'), findsOneWidget);

      // Noch einmal Zurück schließt den Dialog (keine Falle).
      await _back(tester);
      await tester.pumpAndSettle();
      expect(find.text('Neue Gruppe'), findsNothing);
      expect(result, isNull);
    });

    testWidgets('Handy: Feld bleibt sofort beschreibbar', (tester) async {
      await _pump(tester, _opener((c) => askGroupName(c)), tv: false);
      await tester.tap(find.text('öffnen'));
      await tester.pumpAndSettle();
      expect(_editable(tester).readOnly, isFalse);
      await tester.enterText(find.byType(TextField), 'Sport');
      await tester.tap(find.text('Speichern'));
      await tester.pumpAndSettle();
      expect(find.text('Neue Gruppe'), findsNothing);
    });
  });

  testWidgets('Portal hinzufügen: Felder per D-Pad, Zurück verlässt die Seite',
      (tester) async {
    await _pump(
        tester,
        _opener((c) => Navigator.of(c).push(
            MaterialPageRoute<void>(builder: (_) => const AddPortalScreen()))),
        tv: true);
    await tester.tap(find.text('öffnen'));
    await tester.pumpAndSettle();
    expect(find.byType(AddPortalScreen), findsOneWidget);
    // Start im Namensfeld, Tastatur noch zu.
    expect(_focusIn(EditableText), isTrue);
    final name = _focus;
    expect(tester.widget<EditableText>(find.byType(EditableText).first).readOnly,
        isTrue);
    // ▼ ins nächste Feld, ▲ zurück, ▲ zur Zugangsart.
    await _press(tester, LogicalKeyboardKey.arrowDown);
    expect(_focusIn(EditableText), isTrue);
    expect(_focus, isNot(name));
    await _press(tester, LogicalKeyboardKey.arrowUp);
    expect(_focus, name);
    await _press(tester, LogicalKeyboardKey.arrowUp);
    expect(_focusIn(EditableText), isFalse);
    // Bis ganz nach unten: der Speichern-Knopf ist erreichbar.
    for (var i = 0;
        i < 12 && !_focusedTexts().contains(tr('Speichern & verbinden'));
        i++) {
      await _press(tester, LogicalKeyboardKey.arrowDown);
    }
    expect(_focusedTexts(), contains(tr('Speichern & verbinden')));
    // Zurück verlässt die Seite.
    await _back(tester);
    await tester.pumpAndSettle();
    expect(find.byType(AddPortalScreen), findsNothing);
  });

  testWidgets('Untertitel-Aussehen: Start auf gewählter Größe, Zurück',
      (tester) async {
    SubtitleStyle? result = SubtitleStyle.fromOptions((_, f) => f);
    await _pump(
        tester,
        _opener((c) async => result = await showSubtitleStyleDialog(
            c, SubtitleStyle.fromOptions((_, f) => f))),
        tv: true);
    await tester.tap(find.text('öffnen'));
    await tester.pumpAndSettle();
    expect(_focusIn(ChoiceChip), isTrue);
    expect(_focusedTexts(), contains('Normal'));
    await _press(tester, LogicalKeyboardKey.arrowRight);
    expect(_focusIn(ChoiceChip), isTrue);
    await _back(tester);
    await tester.pumpAndSettle();
    expect(find.text('Untertitel-Aussehen'), findsNothing);
    expect(result, isNull);
  });

  testWidgets('Einstellungen: D-Pad erreicht Einträge, nie die Schalter',
      (tester) async {
    await _pump(tester, const Scaffold(body: SettingsScreen()),
        tv: true, storage: storage);
    expect(_focusedTexts(), contains(Portal.demo.name));
    // Sprache kommt aus der App-Einstellung (Gerät im Test: Englisch).

    var sawSwitchRow = false;
    for (var i = 0; i < 30; i++) {
      await _press(tester, LogicalKeyboardKey.arrowDown);
      expect(_focusIn(Switch), isFalse, reason: 'Fokus auf Schalter ($i)');

      if (_focusedTexts().contains(tr('Hardware-Dekodierung'))) {
        sawSwitchRow = true;
        // ▶ darf nicht auf den (nur anzeigenden) Schalter springen –
        // dort täte OK nichts.
        await _press(tester, LogicalKeyboardKey.arrowRight);
        expect(_focusIn(Switch), isFalse);
        expect(_focusedTexts(), contains(tr('Hardware-Dekodierung')));
      }
    }
    expect(sawSwitchRow, isTrue);

    // Untertitel-Sprache: Dialog startet auf der aktuellen Wahl.
    final subs = tr('Aus, automatisch oder bevorzugte Sprache');
    for (var i = 0;
        i < 40 && !_focusedTexts().contains(subs);
        i++) {
      await _press(tester, LogicalKeyboardKey.arrowUp);
    }
    expect(_focusedTexts(), contains(subs));
    await _press(tester, LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.byType(SimpleDialog), findsOneWidget);
    expect(_focusedTexts(), contains(tr('Automatisch')));
    await _back(tester);
    await tester.pumpAndSettle();
    expect(find.byType(SimpleDialog), findsNothing);
    expect(_focusedTexts(), contains(subs));
  });

  testWidgets('Willkommen: Zurück beendet erst beim zweiten Mal',
      (tester) async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    await _pump(tester, const WelcomeScreen(), tv: true);
    await _back(tester);
    expect(find.text(tr('Zum Beenden nochmal Zurück drücken')), findsOneWidget);
    expect(calls.any((c) => c.method == 'SystemNavigator.pop'), isFalse);
    await _back(tester);
    expect(calls.any((c) => c.method == 'SystemNavigator.pop'), isTrue);
    await tester.pump(const Duration(seconds: 3));
  });
}
