import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:jason_stream_player/core/secret_store.dart';
import 'package:jason_stream_player/core/theme.dart';
import 'package:jason_stream_player/data/storage.dart';
import 'package:jason_stream_player/l10n/strings.dart';
import 'package:jason_stream_player/models/models.dart';
import 'package:jason_stream_player/state/content_filter.dart';
import 'package:jason_stream_player/state/providers.dart';
import 'package:jason_stream_player/ui/guide/guide_days.dart';
import 'package:jason_stream_player/ui/player/player_screen.dart';
import 'package:jason_stream_player/ui/portals/portal_advanced.dart';
import 'package:jason_stream_player/ui/settings/country_filter_screen.dart';
import 'package:jason_stream_player/ui/settings/epg_sources_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Neue Oberflächen aus 1.3 nur mit der Fernbedienung: Startfokus, Pfeile,
/// OK, und Zurück (Escape) schließt ohne Falle bzw. verlässt die Seite.

const _portal = Portal(
    id: 'p1', name: 'Test', type: PortalType.xtream, url: 'http://srv.example');

class _Active extends ActivePortalNotifier {
  @override
  Future<Portal?> build() async => _portal;
}

class _Portals extends PortalsNotifier {
  @override
  Future<List<Portal>> build() async => const [_portal];
}

class _Epg extends EpgNotifier {
  @override
  Future<Map<String, List<EpgEntry>>> build() async => const {};
  @override
  void want(Channel c) {}
}

const _channels = [
  Channel(id: 'a', name: 'DE: ZDF HD', categoryId: 'de', streamUrl: 'http://s/a'),
  Channel(id: 'b', name: 'DE: Das Erste', categoryId: 'de', streamUrl: 'http://s/b'),
  Channel(id: 'c', name: 'TR: TRT 1', categoryId: 'tr', streamUrl: 'http://s/c'),
  Channel(id: 'd', name: 'Sender ohne Land', categoryId: 'x', streamUrl: 'http://s/d'),
];

class _Live extends LiveNotifier {
  @override
  Future<LiveData> build() async => const LiveData([
        Category(id: 'de', name: 'DE | Deutschland'),
        Category(id: 'tr', name: 'TR | Türkiye'),
        Category(id: 'x', name: 'Mix'),
      ], _channels);
}

class _Vod extends VodNotifier {
  _Vod(super.series);
  @override
  Future<VodData> build() async => const VodData([], []);
}

class _Flags extends ChannelFlagsNotifier {
  @override
  Future<ChannelFlags> build() async => ChannelFlags.empty;
}

late Storage _storage;

List<Object> _overrides({Future<Storage>? storage}) => [
      isTvProvider.overrideWithValue(true),
      storageProvider.overrideWith((ref) => storage ?? Future.value(_storage)),
      activePortalProvider.overrideWith(_Active.new),
      portalsProvider.overrideWith(_Portals.new),
      repositoryProvider.overrideWith((ref) async => null),
      epgProvider.overrideWith(_Epg.new),
      liveDataProvider.overrideWith(_Live.new),
      moviesProvider.overrideWith(() => _Vod(false)),
      seriesProvider.overrideWith(() => _Vod(true)),
      channelFlagsProvider.overrideWith(_Flags.new),
      minuteTickProvider.overrideWith((ref) => Stream.value(DateTime.now())),
    ];

Future<void> _pump(WidgetTester tester, Widget home,
    {Future<Storage>? storage}) async {
  tester.view.physicalSize = const Size(1920, 1080);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    overrides: _overrides(storage: storage).cast(),
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildTheme(tv: true),
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

/// Zurück wie auf dem Gerät (Escape; unbehandelt → System-Zurück).
Future<void> _back(WidgetTester tester) async {
  final handled = await tester.sendKeyEvent(LogicalKeyboardKey.escape);
  if (!handled) await tester.binding.handlePopRoute();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

FocusNode? get _focus => FocusManager.instance.primaryFocus;

List<String> _focusedTexts() {
  final out = <String>[];
  void visit(Element e) {
    final w = e.widget;
    if (w is Text && w.data != null) out.add(w.data!);
    if (w is RichText) out.add(w.text.toPlainText());
    e.visitChildren(visit);
  }

  (_focus?.context as Element?)?.visitChildren(visit);
  return out;
}

bool _focusUnderKey(Key k) {
  var found = false;
  final el = _focus?.context as Element?;
  if (el?.widget.key == k) return true;
  el?.visitAncestorElements((e) {
    if (e.widget.key == k) found = true;
    return !found;
  });
  return found;
}

/// ▼ (oder [key]) drücken, bis der Fokus [text] enthält.
Future<void> _moveTo(WidgetTester tester, String text,
    {LogicalKeyboardKey key = LogicalKeyboardKey.arrowDown, int max = 25}) async {
  for (var i = 0; i < max && !_focusedTexts().any((t) => t.contains(text)); i++) {
    await _press(tester, key);
  }
  expect(_focusedTexts().any((t) => t.contains(text)), isTrue,
      reason: 'Fokus erreicht „$text“ nicht (fokussiert: ${_focusedTexts()})');
}

/// Knopf, der [open] mit seinem Kontext aufruft.
Widget _opener(void Function(BuildContext) open) => Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: TextButton(
              onPressed: () => open(context), child: const Text('öffnen')),
        ),
      ),
    );

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.text('öffnen'));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    L10n.lang = 'de';
    await initializeDateFormatting('de');
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _storage = await Storage.open(store: PreviewSecretStore());
  });

  testWidgets('Portal „Erweitert“: aufklappen, User-Agent, Ersatz-Adresse, '
      'Aktualisierung – Zurück verlässt die Seite', (tester) async {
    final ctrl = PortalAdvancedController.from(null);
    addTearDown(ctrl.dispose);
    await _pump(
        tester,
        _opener((c) => Navigator.of(c).push(MaterialPageRoute<void>(
            builder: (_) => Scaffold(
                  appBar: AppBar(title: const Text('Portal')),
                  body: ListView(children: [
                    PortalAdvancedSection(
                        controller: ctrl, type: PortalType.xtream),
                    TextButton(
                        autofocus: true,
                        onPressed: () {},
                        child: const Text('Speichern')),
                  ]),
                )))));
    await _open(tester);
    expect(_focusedTexts(), contains('Speichern'));
    // ▲ zum zugeklappten Abschnitt, OK klappt auf.
    await _moveTo(tester, 'Erweitert', key: LogicalKeyboardKey.arrowUp);
    await _press(tester, LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.text('Ersatz-Adressen'), findsOneWidget);
    // ▼ zu „VLC“, OK wählt.
    // ▼ führt in den aufgeklappten Inhalt (nicht zurück zu „Speichern“).
    await _press(tester, LogicalKeyboardKey.arrowDown);
    expect(_focusedTexts(), isNot(contains('Speichern')));
    await _moveTo(tester, 'VLC', key: LogicalKeyboardKey.arrowLeft, max: 4);
    await _press(tester, LogicalKeyboardKey.select);
    expect(ctrl.uaPreset, 'vlc');
    // Weiter nach unten: Ersatz-Adresse eintippen (OK startet Eingabe).
    bool altFocused() => tester
        .widget<EditableText>(find.descendant(
            of: find.byKey(const ValueKey('alt-url')),
            matching: find.byType(EditableText)))
        .focusNode
        .hasFocus;
    for (var i = 0; i < 8 && !altFocused(); i++) {
      await _press(tester, LogicalKeyboardKey.arrowDown);
    }
    expect(altFocused(), isTrue);
    await _press(tester, LogicalKeyboardKey.select); // Eingabe starten
    await tester.enterText(
        find.byKey(const ValueKey('alt-url')), 'http://mirror.example:8080');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(ctrl.altUrls, ['http://mirror.example:8080']);
    // Aktualisierung „Alle 12 Std.“.
    // „Fertig“ beendet die Eingabe und führt weiter nach unten zur
    // Aktualisierung (nicht an ihr vorbei).
    bool onRefreshChip() =>
        _focusedTexts().any((t) => t == 'Aus' || t.startsWith('Alle '));
    for (var i = 0; i < 2 && !onRefreshChip(); i++) {
      await _press(tester, LogicalKeyboardKey.arrowDown);
    }
    expect(onRefreshChip(), isTrue,
        reason: '$_focus ${_focus?.rect} ${_focusedTexts()}');
    for (var i = 0; i < 4; i++) {
      await _press(tester, LogicalKeyboardKey.arrowLeft);
    }
    expect(_focusedTexts(), contains('Aus'));
    await _moveTo(tester, 'Alle 12 Std.', key: LogicalKeyboardKey.arrowRight);
    await _press(tester, LogicalKeyboardKey.select);
    expect(ctrl.autoRefreshHours, 12);
    final p = ctrl.applyTo(_portal);
    expect(p.userAgent, startsWith('VLC/'));
    expect(p.altUrls, ['http://mirror.example:8080']);
    expect(p.autoRefreshHours, 12);
    // Zurück: Tastatur zu bzw. Seite verlassen – nie gefangen.
    for (var i = 0; i < 3 && find.text('Portal').evaluate().isNotEmpty; i++) {
      await _back(tester);
      await tester.pumpAndSettle();
    }
    expect(find.text('Portal'), findsNothing);
    expect(find.text('öffnen'), findsOneWidget);
  });

  test('Eingetippte, nicht übernommene Ersatz-Adresse geht nicht verloren',
      () {
    final ctrl = PortalAdvancedController.from(null);
    ctrl.pendingAlt.text = 'http://pending.example';
    expect(ctrl.applyTo(_portal).altUrls, ['http://pending.example']);
    ctrl.pendingAlt.text = 'kein url';
    expect(ctrl.applyTo(_portal).altUrls, isEmpty);
    ctrl.dispose();
  });

  testWidgets('Länderfilter: Start auf „Alle“, ▼ OK wählt, Zurück verlässt',
      (tester) async {
    late ProviderContainer c;
    await _pump(
        tester,
        _opener((ctx) {
          c = ProviderScope.containerOf(ctx);
          Navigator.of(ctx).push(MaterialPageRoute<void>(
              builder: (_) => const CountryFilterScreen()));
        }));
    await _open(tester);
    expect(find.text('Länder anzeigen'), findsOneWidget);
    expect(_focusedTexts(), contains('Alle Länder'));
    expect(find.text('Deutschland'), findsOneWidget);
    expect(find.text('Türkei'), findsOneWidget);
    expect(find.text('Ohne Länderkennung'), findsOneWidget);
    await _moveTo(tester, 'Deutschland');
    await _press(tester, LogicalKeyboardKey.select);
    await tester.pump(const Duration(milliseconds: 200));
    expect(c.read(countryFilterProvider), {'DE'});
    expect(_storage.countries('p1'), {'DE'});
    // Sichtbare Liste ist gefiltert.
    // Fokus bleibt auf dem Eintrag (kein Fokusverlust nach dem Umschalten).
    expect(_focusedTexts(), contains('Deutschland'));
    await _moveTo(tester, 'Alle Länder', key: LogicalKeyboardKey.arrowUp);
    await _press(tester, LogicalKeyboardKey.select);
    expect(c.read(countryFilterProvider), isEmpty);
    await _back(tester);
    await tester.pumpAndSettle();
    expect(find.byType(CountryFilterScreen), findsNothing);
  });

  testWidgets('EPG-Zeitversatz: Dialog startet beim Wert, Zurück ändert nichts',
      (tester) async {
    await _pump(
        tester,
        _opener((c) => Navigator.of(c).push(MaterialPageRoute<void>(
            builder: (_) => const EpgSourcesScreen(portal: _portal)))));
    await _open(tester);
    expect(find.byType(EpgSourcesScreen), findsOneWidget);
    // Zur Versatz-Zeile „EPG vom Portal  ±0“ (nicht die Quellen-Auswahl).
    for (var i = 0; i < 40 && !_focusedTexts().contains('±0'); i++) {
      await _press(tester, LogicalKeyboardKey.arrowDown);
    }
    expect(_focusedTexts(), containsAll(['EPG vom Portal', '±0']));
    // OK öffnet die Auswahl, Start auf „±0“.
    await _press(tester, LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(_focusUnderKey(const ValueKey('offset_0')), isTrue);
    // Zurück schließt ohne Änderung.
    await _back(tester);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('offset_0')), findsNothing);
    expect(_focusedTexts(), contains('±0'));
    // Wieder öffnen, ▲ zweimal (−1 h), OK übernimmt.
    await _press(tester, LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    await _press(tester, LogicalKeyboardKey.arrowUp);
    await _press(tester, LogicalKeyboardKey.arrowUp);
    expect(_focusUnderKey(const ValueKey('offset_-60')), isTrue);
    await _press(tester, LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.text('−1 h'), findsOneWidget);
    // Zurück verlässt die Seite (ohne Speichern).
    await _back(tester);
    await tester.pumpAndSettle();
    expect(find.byType(EpgSourcesScreen), findsNothing);
  });

  testWidgets('Guide-Tagesauswahl: Start auf „Heute“, ▶ OK = Morgen, Zurück',
      (tester) async {
    int? result = 99;
    await _pump(
        tester,
        _opener((c) async =>
            result = await pickGuideDay(c, 0, const [-2, -1, 0, 1, 2, 3])));
    await _open(tester);
    expect(find.text('Tag wählen'), findsOneWidget);
    expect(_focusUnderKey(const ValueKey('guide_day_0')), isTrue);
    await _back(tester);
    await tester.pumpAndSettle();
    expect(find.text('Tag wählen'), findsNothing);
    expect(result, isNull);

    await _open(tester);
    await _press(tester, LogicalKeyboardKey.arrowRight);
    expect(_focusUnderKey(const ValueKey('guide_day_1')), isTrue);
    await _press(tester, LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(result, 1);
  });

  testWidgets('Live-Pause: „zeitversetzt“, Zurück zu Live per OK, '
      'Zurück schließt den Player', (tester) async {
    PlayerScreen.debugTimeshiftBehind = const Duration(minutes: 1, seconds: 23);
    addTearDown(() => PlayerScreen.debugTimeshiftBehind = null);
    final never = Completer<Storage>();
    await _pump(
        tester,
        _opener((c) => Navigator.of(c).push(MaterialPageRoute<void>(
            builder: (_) => PlayerScreen(
                request: PlayRequest(
                    title: _channels[0].name,
                    url: _channels[0].streamUrl,
                    isLive: true,
                    channels: _channels,
                    channel: _channels[0]))))),
        storage: never.future);
    await tester.tap(find.text('öffnen'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    // Bedienelemente beim Start: Rückstand und „Zurück zu Live“.
    expect(find.text('−1:23 zeitversetzt'), findsOneWidget);
    expect(find.byKey(const ValueKey('go-live')), findsOneWidget);
    expect(find.byKey(const ValueKey('live-pause')), findsOneWidget);
    // Bedienelemente blenden sich nach einigen Sekunden aus: Hinweis oben.
    await _press(tester, LogicalKeyboardKey.arrowDown);
    await tester.pump(const Duration(seconds: 7));
    expect(find.byKey(const ValueKey('timeshift-status')), findsOneWidget);
    // OK zeigt die Bedienelemente wieder (▲▼ würden umschalten); Pfeile
    // erreichen „Zurück zu Live“.
    await _press(tester, LogicalKeyboardKey.select);
    expect(find.byKey(const ValueKey('timeshift-status')), findsNothing);
    await _press(tester, LogicalKeyboardKey.arrowDown);
    for (var i = 0;
        i < 12 && !_focusUnderKey(const ValueKey('go-live'));
        i++) {
      await _press(tester, i < 4 ? LogicalKeyboardKey.arrowDown
          : LogicalKeyboardKey.arrowRight);
    }
    expect(_focusUnderKey(const ValueKey('go-live')), isTrue);
    await _press(tester, LogicalKeyboardKey.select);
    expect(find.byKey(const ValueKey('go-live')), findsNothing);
    expect(find.textContaining('zeitversetzt'), findsNothing);
    // Fokus ist nicht verloren gegangen.
    expect(_focus, isNotNull);
    // Zurück schließt (Overlay, dann Player) – keine Falle.
    for (var i = 0; i < 4 && find.byType(PlayerScreen).evaluate().isNotEmpty; i++) {
      await _back(tester);
    }
    expect(find.byType(PlayerScreen), findsNothing);
    expect(find.text('öffnen'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 6));
  });
}
