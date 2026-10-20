import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jason_stream_player/state/providers.dart';
import 'package:jason_stream_player/ui/widgets/common.dart';

Widget app({required bool tv, required FocusNode below}) => ProviderScope(
      overrides: [isTvProvider.overrideWithValue(tv)],
      child: MaterialApp(
        home: Scaffold(
          body: Column(children: [
            SearchField(
                controller: TextEditingController(),
                hint: 'Suche',
                onChanged: (_) {}),
            Focus(focusNode: below, child: const SizedBox(height: 40, width: 40)),
          ]),
        ),
      ),
    );

void main() {
  for (final tv in [true, false]) {
    testWidgets('▼ verlässt das Suchfeld (tv=$tv)', (t) async {
      final below = FocusNode();
      await t.pumpWidget(app(tv: tv, below: below));
      await t.tap(find.byType(TextField));
      await t.pump();
      await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await t.pump();
      expect(below.hasFocus, isTrue);
    });

    testWidgets('Zurück im Suchfeld schließt nicht die Seite (tv=$tv)', (t) async {
      final below = FocusNode();
      await t.pumpWidget(app(tv: tv, below: below));
      await t.tap(find.byType(TextField));
      await t.pump();
      // goBack hat im Test-Simulator keine physische Taste – Escape nimmt
      // denselben Weg im Code.
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pump();
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pump();
      expect(find.byType(SearchField), findsOneWidget);
      expect(below.hasFocus, isTrue);
    });
  }
}
