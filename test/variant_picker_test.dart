import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:jason_stream_player/core/theme.dart';
import 'package:jason_stream_player/data/channel_variants.dart' show groupVariants;
import 'package:jason_stream_player/data/storage.dart';
import 'package:jason_stream_player/l10n/strings.dart';
import 'package:jason_stream_player/models/models.dart';
import 'package:jason_stream_player/state/channel_variants.dart';
import 'package:jason_stream_player/state/profile_mode.dart';
import 'package:jason_stream_player/state/providers.dart';
import 'package:jason_stream_player/ui/player/player_screen.dart';

/// Sender-Varianten: zusammengefasste Liste, Auswahl im Player und im
/// Sender-Menü (ohne echten Player: der Speicher antwortet im Test nie).

const _raw = [
  Channel(id: 'ard', name: 'Das Erste HD', categoryId: 'de', streamUrl: 'http://s/ard', number: 1),
  Channel(id: 'zsd', name: 'ZDF SD', categoryId: 'de', streamUrl: 'http://s/zsd', number: 2),
  Channel(id: 'zfhd', name: 'ZDF FHD', categoryId: 'de', streamUrl: 'http://s/zfhd', number: 3),
  Channel(id: 'zhd', name: 'ZDF HD', categoryId: 'de', streamUrl: 'http://s/zhd', number: 4),
  Channel(id: 'neo', name: 'ZDFneo', categoryId: 'de', streamUrl: 'http://s/neo', number: 5),
];

class _Live extends LiveNotifier {
  @override
  Future<LiveData> build() async => const LiveData([], _raw);
}

class _Epg extends EpgNotifier {
  @override
  Future<Map<String, List<EpgEntry>>> build() async => const {};
  @override
  void want(Channel c) {}
}

class _Flags extends ChannelFlagsNotifier {
  final Set<String> favs;
  _Flags([this.favs = const {}]);
  @override
  Future<ChannelFlags> build() async => ChannelFlags(favs, const {}, const {});
}

class _MergeOff extends MergeVariantsNotifier {
  @override
  bool build() => false;
}

List<Object> _overrides({Set<String> favs = const {}, bool merge = true}) => [
      isTvProvider.overrideWithValue(true),
      storageProvider.overrideWith((ref) => Completer<Storage>().future),
      epgProvider.overrideWith(_Epg.new),
      channelFlagsProvider.overrideWith(() => _Flags(favs)),
      liveDataProvider.overrideWith(_Live.new),
      minuteTickProvider.overrideWith((ref) => Stream.value(DateTime.now())),
      if (!merge) mergeVariantsProvider.overrideWith(_MergeOff.new),
    ];

Future<ProviderContainer> _container(
    {Set<String> favs = const {}, bool merge = true}) async {
  final c = ProviderContainer(
      overrides: _overrides(favs: favs, merge: merge).cast());
  addTearDown(c.dispose);
  c.listen(visibleLiveDataProvider, (a, b) {});
  await c.read(liveDataProvider.future);
  await c.read(channelFlagsProvider.future);
  return c;
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

List<String> _ids(List<Channel> l) => [for (final c in l) c.id];

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    L10n.lang = 'de';
    await initializeDateFormatting('de');
  });

  group('Zusammengefasste Liste', () {
    test('ZDF-Varianten erscheinen einmal (FHD), ZDFneo bleibt', () async {
      final c = await _container();
      final live = c.read(visibleLiveDataProvider).value!;
      expect(_ids(live.channels), ['ard', 'zfhd', 'neo']);
      final idx = c.read(variantIndexProvider);
      expect(idx.countOf('zfhd'), 3);
      expect(idx.countOf('neo'), 1);
    });

    test('Einstellung aus: alle Varianten einzeln', () async {
      final c = await _container(merge: false);
      expect(_ids(c.read(visibleLiveDataProvider).value!.channels),
          _ids(_raw));
    });

    test('Favorit auf einer Variante markiert die Gruppe', () async {
      final c = await _container(favs: {'zsd'});
      expect(_ids(c.read(visibleLiveDataProvider).value!.channels),
          ['ard', 'zsd', 'neo']);
    });

    test('gemerkte Wahl: zuerst abspielen', () async {
      final c = await _container();
      final g = c.read(variantIndexProvider).groupOf('zfhd')!;
      expect(_ids(g.playOrder(c.read(variantChoiceProvider)[g.key])),
          ['zfhd', 'zhd', 'zsd']);
      await c.read(variantChoiceProvider.notifier).choose(g, _raw[1]);
      expect(_ids(g.playOrder(c.read(variantChoiceProvider)[g.key])),
          ['zsd', 'zfhd', 'zhd']);
      // Beste Variante wählen = Standard (nichts gemerkt).
      await c.read(variantChoiceProvider.notifier).choose(g, _raw[2]);
      expect(c.read(variantChoiceProvider), isEmpty);
    });
  });

  testWidgets('Player: Variantenauswahl im Overlay, Wahl wird gemerkt',
      (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final channels = [_raw[0], _raw[2], _raw[4]];
    await tester.pumpWidget(ProviderScope(
      overrides: _overrides().cast(),
      child: MaterialApp(
        theme: buildTheme(tv: true),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => PlayerScreen(
                        request: PlayRequest(
                            title: 'ZDF FHD',
                            url: 'http://s/zfhd',
                            isLive: true,
                            channels: channels,
                            channel: channels[1])))),
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
    final container =
        ProviderScope.containerOf(tester.element(find.byType(PlayerScreen)));
    container.read(liveDataProvider);
    container.read(channelFlagsProvider);
    await tester.pump();
    await tester.pump();

    // Overlay ist sichtbar: Knopf „Qualität/Quelle wählen“.
    final btn = find.byKey(const ValueKey('variant-btn'));
    expect(btn, findsOneWidget);
    await tester.tap(btn);
    await _settle(tester);
    expect(find.text('Qualität/Quelle wählen'), findsWidgets);
    expect(find.text('3 Varianten'), findsOneWidget);
    expect(find.text('FHD · Empfohlen'), findsOneWidget);
    expect(find.text('ZDF SD'), findsOneWidget);

    // Zurück schließt die Auswahl, nichts gemerkt.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _settle(tester);
    expect(find.text('ZDF SD'), findsNothing);
    expect(find.byType(PlayerScreen), findsOneWidget);
    expect(container.read(variantChoiceProvider), isEmpty);

    // Erneut öffnen und SD wählen → gemerkt.
    await tester.tap(btn);
    await _settle(tester);
    await tester.tap(find.text('ZDF SD'));
    await _settle(tester);
    final g = container.read(variantIndexProvider).groupOf('zfhd')!;
    expect(container.read(variantChoiceProvider)[g.key], 'zsd');
    expect(find.text('Quelle: ZDF SD'), findsOneWidget);

    // Sender ohne Varianten: kein Knopf.
    await tester.sendKeyEvent(LogicalKeyboardKey.channelUp);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(btn, findsNothing);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('Auswahl-Sheet: Fernbedienung startet auf der laufenden Variante',
      (tester) async {
    final g = groupVariants(_raw).single;
    Channel? picked;
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        theme: buildTheme(tv: true),
        home: Scaffold(
          body: VariantPickerSheet(
              group: g, currentId: 'zhd', onPick: (ch) => picked = ch),
        ),
      ),
    ));
    await tester.pump();
    final focused = FocusManager.instance.primaryFocus?.context;
    expect(
        find.descendant(
            of: find.byWidget(focused!.widget), matching: find.text('ZDF HD')),
        findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(picked?.id, 'zsd');
  });
}
