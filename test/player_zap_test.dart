import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jason_stream_player/state/shell_tab.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:jason_stream_player/core/theme.dart';
import 'package:jason_stream_player/data/recordings/recordings.dart';
import 'package:jason_stream_player/data/storage.dart';
import 'package:jason_stream_player/l10n/strings.dart';
import 'package:jason_stream_player/models/models.dart';
import 'package:jason_stream_player/state/profile_mode.dart';
import 'package:jason_stream_player/state/providers.dart';
import 'package:jason_stream_player/ui/player/channel_digit_entry.dart';
import 'package:jason_stream_player/ui/player/player_screen.dart';
import 'package:jason_stream_player/ui/player/zap_bar.dart';
import 'package:jason_stream_player/ui/widgets/common.dart';

/// Zapping-Leiste, Direktwahl und Farbtasten im Live-Player (ohne echten
/// Player: der Speicher antwortet im Test nie).

final _channels = [
  for (var i = 0; i < 30; i++)
    Channel(
        id: 'c$i',
        name: 'Sender $i',
        categoryId: 'x',
        streamUrl: 'http://s/$i',
        catchupDays: i == 7 ? 3 : 0,
        number: i + 1),
];

/// Nur in der Gesamtliste (Direktwahl-Rückfall).
const _extra = Channel(
    id: 'x500',
    name: 'Extra',
    categoryId: 'y',
    streamUrl: 'http://s/x',
    number: 500);

final _t0 = DateTime.now();
final _epgData = {
  for (final c in [..._channels, _extra])
    '@${c.id}': [
      EpgEntry(
          channelEpgId: '@${c.id}',
          title: 'Show ${c.id}',
          start: _t0.subtract(const Duration(minutes: 30)),
          end: _t0.add(const Duration(minutes: 30))),
      EpgEntry(
          channelEpgId: '@${c.id}',
          title: 'Next ${c.id}',
          start: _t0.add(const Duration(minutes: 30)),
          end: _t0.add(const Duration(minutes: 90))),
    ],
};

class _Epg extends EpgNotifier {
  @override
  Future<Map<String, List<EpgEntry>>> build() async => _epgData;
  @override
  void want(Channel c) {}
}

class _Flags extends ChannelFlagsNotifier {
  @override
  Future<ChannelFlags> build() async => ChannelFlags.empty;
  @override
  Future<void> toggleFavorite(String id) async {
    final f = {...(state.value ?? ChannelFlags.empty).favorites};
    if (!f.remove(id)) f.add(id);
    state = AsyncData(ChannelFlags(f, const {}, const {}));
  }
}

class _Recs extends RecordingsNotifier {
  final calls = <String>[];
  @override
  List<Recording> build() => const [];
  @override
  Future<RecResult> recordNow(Channel c, EpgEntry? now) async {
    calls.add('${c.id}:${now?.title}');
    return RecResult.background;
  }
}

class _Live extends LiveNotifier {
  @override
  Future<LiveData> build() async =>
      LiveData(const [], [..._channels, _extra]);
}

/// Tasten ohne physische Taste im Test-Simulator (Farbtasten, Guide):
/// irgendeine Taste mit Android-Scancode – die logische Taste (PROG_RED …)
/// ergibt sich aus dem Android-Keycode.
final _physical = {
  LogicalKeyboardKey.colorF0Red: PhysicalKeyboardKey.f13,
  LogicalKeyboardKey.colorF1Green: PhysicalKeyboardKey.f14,
  LogicalKeyboardKey.colorF2Yellow: PhysicalKeyboardKey.f15,
  LogicalKeyboardKey.colorF3Blue: PhysicalKeyboardKey.f16,
  LogicalKeyboardKey.guide: PhysicalKeyboardKey.f17,
};

Future<void> _press(WidgetTester tester, LogicalKeyboardKey k) async {
  final phys = _physical[k];
  if (phys == null) {
    await tester.sendKeyEvent(k);
  } else {
    await tester.sendKeyDownEvent(k, physicalKey: phys);
    await tester.sendKeyUpEvent(k, physicalKey: phys);
  }
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _back(WidgetTester tester) async {
  final handled = await tester.sendKeyEvent(LogicalKeyboardKey.escape);
  if (!handled) await tester.binding.handlePopRoute();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// Große Ziffernanzeige oben rechts.
Finder _digitBox(String digits) => find.byWidgetPredicate(
    (w) => w is Text && w.data == digits && w.style?.fontSize == 44);

Finder _inBar(String text) =>
    find.descendant(of: find.byType(ZapBar), matching: find.text(text));

/// Name des in der Leiste gezeigten Senders (oder null).
String? _barName(WidgetTester tester) {
  if (find.byType(ZapBar).evaluate().isEmpty) return null;
  return tester.widget<ZapBar>(find.byType(ZapBar)).channel.name;
}

bool _barPreview(WidgetTester tester) =>
    tester.widget<ZapBar>(find.byType(ZapBar)).preview;

/// Laufender Sender: Info zeigt die Leiste für ihn (danach wieder zu).
Future<String?> _playing(WidgetTester tester) async {
  await _press(tester, LogicalKeyboardKey.info);
  final name = _barName(tester);
  expect(_barPreview(tester), isFalse);
  await _press(tester, LogicalKeyboardKey.info);
  expect(find.byType(ZapBar), findsNothing);
  return name;
}

/// Kindermodus mit freigegebener Gruppe „x“ (die 30 Sender, nicht „Extra“).
class _Kids extends ProfileModeNotifier {
  @override
  ProfileMode build() => const ProfileMode(kids: true, kidsGroups: {'x'});
}

late _Recs _recs;

Future<void> _open(WidgetTester tester, {bool kids = false}) async {
  tester.view.physicalSize = const Size(1920, 1080);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  final never = Completer<Storage>();
  _recs = _Recs();
  await tester.pumpWidget(ProviderScope(
    overrides: [
      isTvProvider.overrideWithValue(true),
      storageProvider.overrideWith((ref) => never.future),
      epgProvider.overrideWith(_Epg.new),
      channelFlagsProvider.overrideWith(_Flags.new),
      recordingsProvider.overrideWith(() => _recs),
      liveDataProvider.overrideWith(_Live.new),
      minuteTickProvider.overrideWith((ref) => Stream.value(DateTime.now())),
      if (kids) profileModeProvider.overrideWith(_Kids.new),
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
  // Gesamtliste und Favoriten laden (wie in der App bereits geschehen).
  final container =
      ProviderScope.containerOf(tester.element(find.byType(PlayerScreen)));
  container.read(liveDataProvider);
  container.read(visibleLiveDataProvider);
  container.read(channelFlagsProvider);
  await tester.pump();
  // Bedienelemente ausblenden: erste Pfeiltaste führt hinein, nach 5 s weg.
  await _press(tester, LogicalKeyboardKey.arrowDown);
  await tester.pump(const Duration(seconds: 6));
  expect(find.byType(ZapBar), findsNothing);
}

Future<void> _close(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 6));
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    L10n.lang = 'de';
    await initializeDateFormatting('de');
  });

  testWidgets('▲▼ und CH± schalten um und zeigen die Zapping-Leiste',
      (tester) async {
    await _open(tester);

    await _press(tester, LogicalKeyboardKey.arrowUp);
    expect(_barName(tester), 'Sender 6');
    expect(_barPreview(tester), isFalse);
    expect(_inBar('7'), findsOneWidget); // Sendernummer
    expect(_inBar('Show c6'), findsOneWidget);
    expect(
        _inBar('Danach: ${hm.format(_t0.add(const Duration(minutes: 30)))} '
            'Next c6'),
        findsOneWidget);
    expect(find.descendant(
            of: find.byType(ZapBar), matching: find.byType(ThinProgress)),
        findsOneWidget);
    expect(find.text('Vorschau · OK schaltet um'), findsNothing);

    await _press(tester, LogicalKeyboardKey.arrowDown);
    await _press(tester, LogicalKeyboardKey.arrowDown);
    expect(_barName(tester), 'Sender 4');
    await _press(tester, LogicalKeyboardKey.channelDown);
    expect(_barName(tester), 'Sender 3');
    await _press(tester, LogicalKeyboardKey.channelUp);
    expect(_barName(tester), 'Sender 4');

    // Nach ~4 s verschwindet die Leiste, der Sender läuft weiter.
    await tester.pump(const Duration(seconds: 4));
    expect(find.byType(ZapBar), findsNothing);
    expect(await _playing(tester), 'Sender 4');
    await _close(tester);
  });

  testWidgets('◀▶ blättern ohne Umschalten, OK schaltet, Zurück bricht ab',
      (tester) async {
    await _open(tester);

    // ▶ öffnet die Leiste beim nächsten Sender (Vorschau).
    await _press(tester, LogicalKeyboardKey.arrowRight);
    expect(_barName(tester), 'Sender 6');
    expect(_barPreview(tester), isTrue);
    expect(find.text('Vorschau · OK schaltet um'), findsOneWidget);
    expect(_inBar('Show c6'), findsOneWidget);
    await _press(tester, LogicalKeyboardKey.arrowRight);
    expect(_barName(tester), 'Sender 7');
    await _press(tester, LogicalKeyboardKey.arrowLeft);
    expect(_barName(tester), 'Sender 6');

    // Zurück schließt nur die Leiste – Player bleibt, Sender 5 läuft.
    await _back(tester);
    expect(find.byType(ZapBar), findsNothing);
    expect(find.byType(PlayerScreen), findsOneWidget);
    expect(await _playing(tester), 'Sender 5');

    // Zeitablauf bricht ebenfalls ab.
    await _press(tester, LogicalKeyboardKey.arrowRight);
    expect(_barName(tester), 'Sender 6');
    await tester.pump(const Duration(seconds: 4));
    expect(find.byType(ZapBar), findsNothing);
    expect(await _playing(tester), 'Sender 5');

    // ◀▶ blättern zyklisch, OK schaltet um.
    await _press(tester, LogicalKeyboardKey.arrowRight);
    await _press(tester, LogicalKeyboardKey.arrowRight);
    expect(_barName(tester), 'Sender 7');
    await _press(tester, LogicalKeyboardKey.select);
    expect(_barName(tester), 'Sender 7');
    expect(_barPreview(tester), isFalse);
    await tester.pump(const Duration(seconds: 4));
    expect(await _playing(tester), 'Sender 7');

    // Senderliste bleibt mit ◀ erreichbar (Leiste geschlossen).
    await _press(tester, LogicalKeyboardKey.arrowLeft);
    expect(find.text('Sender'), findsOneWidget);
    await _back(tester);
    expect(find.text('Sender'), findsNothing);
    await _close(tester);
  });

  testWidgets('Zifferntasten: Direktwahl, OK, Ziffernblock, unbekannt',
      (tester) async {
    await _open(tester);

    await _press(tester, LogicalKeyboardKey.digit1);
    await _press(tester, LogicalKeyboardKey.digit2);
    expect(_digitBox('12'), findsOneWidget);
    expect(_barName(tester), isNull); // noch nicht umgeschaltet
    await tester.pump(const Duration(milliseconds: 1500));
    await tester.pump();
    expect(_digitBox('12'), findsNothing);
    expect(_barName(tester), 'Sender 11');

    // Ziffernblock + OK springt sofort.
    await _press(tester, LogicalKeyboardKey.numpad3);
    expect(_digitBox('3'), findsOneWidget);
    await _press(tester, LogicalKeyboardKey.select);
    expect(_barName(tester), 'Sender 2');
    expect(_barPreview(tester), isFalse);

    // Unbekannte Nummer → kurzer Hinweis.
    await _press(tester, LogicalKeyboardKey.digit9);
    await _press(tester, LogicalKeyboardKey.digit9);
    await tester.pump(const Duration(milliseconds: 1500));
    await tester.pump();
    expect(find.text('Sender 99 nicht gefunden'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Sender 99 nicht gefunden'), findsNothing);

    // Nicht in der Gruppe, aber in der Gesamtliste → Rückfall.
    await tester.pump(const Duration(seconds: 4));
    await _press(tester, LogicalKeyboardKey.digit5);
    await _press(tester, LogicalKeyboardKey.digit0);
    await _press(tester, LogicalKeyboardKey.digit0);
    await _press(tester, LogicalKeyboardKey.enter);
    expect(_barName(tester), 'Extra');
    await tester.pump(const Duration(seconds: 4));
    expect(await _playing(tester), 'Extra');
    await _close(tester);
  });

  testWidgets('Kindermodus: Direktwahl erreicht keine gesperrten Sender',
      (tester) async {
    await _open(tester, kids: true);
    // „Extra“ (500) ist in der Gesamtliste, aber nicht freigegeben.
    for (final k in [
      LogicalKeyboardKey.digit5,
      LogicalKeyboardKey.digit0,
      LogicalKeyboardKey.digit0,
    ]) {
      await _press(tester, k);
    }
    await _press(tester, LogicalKeyboardKey.select);
    expect(_barName(tester), isNull);
    expect(find.text('Sender 500 nicht gefunden'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    expect(await _playing(tester), 'Sender 5');
    // Freigegebene Sender gehen weiter.
    await _press(tester, LogicalKeyboardKey.digit9);
    await _press(tester, LogicalKeyboardKey.select);
    expect(_barName(tester), 'Sender 8');
    await _close(tester);
  });

  testWidgets('Farbtasten: Rot, Grün, Gelb, Blau, Guide', (tester) async {
    await _open(tester);
    final end = hm.format(_t0.add(const Duration(minutes: 30)));

    // Rot: laufende Sendung aufnehmen.
    await _press(tester, LogicalKeyboardKey.colorF0Red);
    expect(_recs.calls, ['c5:Show c5']);
    expect(find.text('Aufnahme bis $end'), findsOneWidget);

    // Grün: Favorit an/aus.
    await _press(tester, LogicalKeyboardKey.colorF1Green);
    expect(find.text('Sender 5 zu Favoriten hinzugefügt'), findsOneWidget);
    await _press(tester, LogicalKeyboardKey.colorF1Green);
    expect(find.text('Sender 5 aus Favoriten entfernt'), findsOneWidget);

    // In der Vorschau gelten Rot/Grün für den gezeigten Sender.
    await _press(tester, LogicalKeyboardKey.arrowRight);
    await _press(tester, LogicalKeyboardKey.colorF1Green);
    expect(find.text('Sender 6 zu Favoriten hinzugefügt'), findsOneWidget);
    expect(find.byIcon(Icons.star_rounded), findsWidgets);
    await _press(tester, LogicalKeyboardKey.colorF0Red);
    expect(_recs.calls.last, 'c6:Show c6');
    await _back(tester);
    expect(find.byType(ZapBar), findsNothing);
    expect(await _playing(tester), 'Sender 5');

    // Gelb ohne Catch-up → Hinweis.
    await tester.pump(const Duration(seconds: 2));
    await _press(tester, LogicalKeyboardKey.colorF2Yellow);
    expect(find.text('Von Anfang ist für diese Sendung nicht verfügbar'),
        findsOneWidget);

    // Gelb mit Catch-up (Sender 7) → Von Anfang.
    await _press(tester, LogicalKeyboardKey.arrowUp);
    await _press(tester, LogicalKeyboardKey.arrowUp);
    expect(_barName(tester), 'Sender 7');
    await tester.pump(const Duration(seconds: 2));
    final before = find.text('Von Anfang').evaluate().length;
    await _press(tester, LogicalKeyboardKey.colorF2Yellow);
    expect(find.text('Von Anfang').evaluate().length, before + 1);
    expect(find.byType(ZapBar), findsNothing);

    // Blau: Player schließen und den TV-Guide anfordern.
    final container = ProviderScope.containerOf(
        tester.element(find.byType(PlayerScreen)));
    await _press(tester, LogicalKeyboardKey.colorF3Blue);
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.byType(PlayerScreen), findsNothing);
    expect(container.read(shellTabRequestProvider), ShellTab.guide);
    container.read(shellTabRequestProvider.notifier).clear();
  });

  testWidgets('Guide-Taste öffnet ebenfalls den TV-Guide', (tester) async {
    await _open(tester);
    final container = ProviderScope.containerOf(
        tester.element(find.byType(PlayerScreen)));
    await _press(tester, LogicalKeyboardKey.guide);
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.byType(PlayerScreen), findsNothing);
    expect(container.read(shellTabRequestProvider), ShellTab.guide);
  });

  testWidgets('Favorit auch ohne Farbtaste über die Bedienelemente',
      (tester) async {
    await _open(tester);
    await _press(tester, LogicalKeyboardKey.select); // Bedienelemente
    await tester.tap(find.byIcon(Icons.star_border_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Sender 5 zu Favoriten hinzugefügt'), findsOneWidget);
    expect(find.byIcon(Icons.star_rounded), findsWidgets);
    await _close(tester);
  });

  testWidgets('Live-TV-Liste: Direktwahl außerhalb des Players',
      (tester) async {
    final picked = <String>[];
    final text = TextEditingController();
    addTearDown(text.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ChannelDigitEntry(
          channels: () => _channels.sublist(0, 10),
          all: () => [..._channels, _extra],
          onPick: (c, list) => picked.add('${c.id}/${list.length}'),
          child: Column(children: [
            ElevatedButton(
                autofocus: true, onPressed: () {}, child: const Text('Tile')),
            TextField(controller: text),
          ]),
        ),
      ),
    ));
    await tester.pump();

    await _press(tester, LogicalKeyboardKey.digit4);
    expect(_digitBox('4'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1500));
    expect(picked, ['c3/10']);

    // Nicht in der Gruppe → Gesamtliste; OK bestätigt sofort.
    await _press(tester, LogicalKeyboardKey.digit2);
    await _press(tester, LogicalKeyboardKey.numpad0);
    await _press(tester, LogicalKeyboardKey.select);
    expect(picked.last, 'c19/31');

    await _press(tester, LogicalKeyboardKey.digit7);
    await _press(tester, LogicalKeyboardKey.digit7);
    await tester.pump(const Duration(milliseconds: 1500));
    expect(find.text('Sender 77 nicht gefunden'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Sender 77 nicht gefunden'), findsNothing);

    // Im Suchfeld werden Ziffern nicht abgefangen.
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await _press(tester, LogicalKeyboardKey.digit5);
    expect(_digitBox('5'), findsNothing);
    await tester.pump(const Duration(seconds: 2));
    expect(picked.length, 2);
  });
}
