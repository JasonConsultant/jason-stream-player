import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:jason_stream_player/core/theme.dart';
import 'package:jason_stream_player/data/storage.dart';
import 'package:jason_stream_player/l10n/strings.dart';
import 'package:jason_stream_player/models/models.dart';
import 'package:jason_stream_player/state/providers.dart';
import 'package:jason_stream_player/ui/player/player_screen.dart';
import 'package:jason_stream_player/ui/widgets/focusable_tile.dart';

/// Player nur mit der Fernbedienung (ohne echten Player: der Speicher
/// antwortet im Test nie, daher wird kein media_kit-Player angelegt –
/// Bedienelemente und Tasten lassen sich trotzdem prüfen).

final _channels = [
  for (var i = 0; i < 30; i++)
    Channel(
        id: 'c$i',
        name: 'Sender $i',
        categoryId: 'x',
        streamUrl: 'http://s/$i',
        number: i + 1),
];

class _Epg extends EpgNotifier {
  @override
  Future<Map<String, List<EpgEntry>>> build() async => const {};
  @override
  void want(Channel c) {}
}

class _Flags extends ChannelFlagsNotifier {
  @override
  Future<ChannelFlags> build() async => ChannelFlags.empty;
}

FocusNode? get _focus => FocusManager.instance.primaryFocus;

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

IconData? _focusedIcon() {
  IconData? out;
  void visit(Element e) {
    final w = e.widget;
    if (w is Icon && out == null) out = w.icon;
    e.visitChildren(visit);
  }

  (_focus?.context as Element?)?.visitChildren(visit);
  return out;
}

bool _focusInTile() {
  var found = false;
  (_focus?.context as Element?)?.visitAncestorElements((e) {
    if (e.widget is FocusableTile) found = true;
    return !found;
  });
  return found;
}

Future<void> _press(WidgetTester tester, LogicalKeyboardKey k) async {
  await tester.sendKeyEvent(k);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _back(WidgetTester tester) async {
  final handled = await tester.sendKeyEvent(LogicalKeyboardKey.escape);
  if (!handled) await tester.binding.handlePopRoute();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    L10n.lang = 'de';
    await initializeDateFormatting('de');
  });

  testWidgets('Live: Bedienelemente, Senderliste und Zurück per D-Pad',
      (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final never = Completer<Storage>();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        isTvProvider.overrideWithValue(true),
        storageProvider.overrideWith((ref) => never.future),
        epgProvider.overrideWith(_Epg.new),
        channelFlagsProvider.overrideWith(_Flags.new),
        minuteTickProvider.overrideWith((ref) => Stream.value(DateTime.now())),
      ],
      child: MaterialApp(
        theme: buildTheme(tv: true),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => PlayerScreen(
                        request: PlayRequest(
                            title: 'Sender 5',
                            url: 'http://s/5',
                            isLive: true,
                            channels: _channels,
                            channel: _channels[5])))),
                child: const Text('Player'),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('Player'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(PlayerScreen), findsOneWidget);
    final player = _focus;
    expect(_focusInTile(), isFalse);

    // Bedienelemente sichtbar: erste Pfeiltaste führt hinein (Senderliste).
    await _press(tester, LogicalKeyboardKey.arrowDown);
    expect(_focusInTile(), isTrue);
    expect(_focusedIcon(), Icons.format_list_bulleted_rounded);
    // ◀ wandert durch die obere Leiste.
    await _press(tester, LogicalKeyboardKey.arrowLeft);
    expect(_focusInTile(), isTrue);
    await _press(tester, LogicalKeyboardKey.arrowRight);
    expect(_focusedIcon(), Icons.format_list_bulleted_rounded);

    // OK öffnet die Senderliste, Fokus auf dem laufenden Sender.
    await _press(tester, LogicalKeyboardKey.select);
    expect(find.text('Sender'), findsOneWidget);
    expect(_focusedTexts(), contains('Sender 5'));
    await _press(tester, LogicalKeyboardKey.arrowDown);
    expect(_focusedTexts(), contains('Sender 6'));

    // Zurück schließt nur die Liste, der Player hat wieder den Fokus.
    await _back(tester);
    expect(find.byType(PlayerScreen), findsOneWidget);
    expect(find.text('Sender'), findsNothing);
    expect(_focus, player);

    // Ausgeblendet (nach 5 s): Knöpfe nicht mehr erreichbar, ◀ = Liste.
    await tester.pump(const Duration(seconds: 6));
    await _press(tester, LogicalKeyboardKey.arrowLeft);
    expect(find.text('Sender'), findsOneWidget);
    expect(_focusedTexts(), contains('Sender 5'));
    await _back(tester);
    expect(_focus, player);

    // Zurück im Player schließt ihn.
    await _back(tester);
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(PlayerScreen), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 6));
  });
}
