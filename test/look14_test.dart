import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:jason_stream_player/core/audio_passthrough.dart';
import 'package:jason_stream_player/core/secret_store.dart';
import 'package:jason_stream_player/core/theme.dart';
import 'package:jason_stream_player/data/storage.dart';
import 'package:jason_stream_player/l10n/strings.dart';
import 'package:jason_stream_player/models/models.dart';
import 'package:jason_stream_player/state/providers.dart';
import 'package:jason_stream_player/ui/player/zap_bar.dart';
import 'package:jason_stream_player/ui/settings/accent_picker.dart';
import 'package:jason_stream_player/ui/shell/accent.dart';
import 'package:jason_stream_player/ui/shell/home_shell.dart';
import 'package:jason_stream_player/ui/shell/text_size_chooser.dart';
import 'package:jason_stream_player/ui/widgets/a11y.dart';
import 'package:jason_stream_player/ui/widgets/common.dart';
import 'package:jason_stream_player/ui/widgets/focusable_tile.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/tv_harness.dart';

/// Version 1.4: Akzentfarbe, Schriftgröße beim ersten TV-Start,
/// Dolby/DTS-Durchreichung, Bedienungshilfen (TalkBack).

double _lum(Color c) {
  double g(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * g(c.r) + 0.7152 * g(c.g) + 0.0722 * g(c.b);
}

double _contrast(Color a, Color b) {
  final la = _lum(a), lb = _lum(b);
  final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

const _ch = Channel(
    id: '1',
    name: 'Das Erste HD',
    categoryId: 'c',
    streamUrl: 'http://x/1',
    number: 1);

final _now = EpgEntry(
  channelEpgId: '@1',
  title: 'Tagesschau',
  start: DateTime.now().subtract(const Duration(minutes: 5)),
  end: DateTime.now().add(const Duration(minutes: 10)),
);

TvData get _data => TvData(
      live: const LiveData([Category(id: 'c', name: 'Gruppe')], [_ch]),
      epg: {'@1': [_now]},
    );

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    L10n.lang = 'de';
    await initializeDateFormatting('de');
  });
  tearDown(() {
    AppColors.setAccent(AppColors.defaultAccent);
    TextSizeChooser.debugAllowInTests = false;
  });

  group('Akzentfarbe', () {
    test('Vorgaben: Orange Standard, alle AA-Kontrast auf Dunkel', () {
      expect(AppColors.accentPresets.keys,
          ['orange', 'blau', 'gruen', 'lila', 'rot', 'tuerkis']);
      expect(AppColors.accent, const Color(0xFFFF7A45));
      for (final c in AppColors.accentPresets.values) {
        expect(_contrast(c, AppColors.bg), greaterThanOrEqualTo(4.5));
        expect(_contrast(c, AppColors.surface3), greaterThanOrEqualTo(4.5));
        expect(_contrast(c, const Color(0xFF1A0B04)),
            greaterThanOrEqualTo(4.5)); // onPrimary
      }
    });

    test('setAccent wirkt auf Theme und AppColors', () {
      expect(AppColors.setAccent('blau'), isTrue);
      expect(AppColors.setAccent('blau'), isFalse); // unverändert
      final theme = buildTheme(tv: false);
      expect(theme.colorScheme.primary, AppColors.accentPresets['blau']);
      expect(AppColors.accent, AppColors.accentPresets['blau']);
      expect(AppColors.accentSoft.a, closeTo(0x33 / 255, 0.01));
      // Unbekannt → Orange.
      AppColors.setAccent('pink');
      expect(AppColors.accentKey, 'orange');
    });

    testWidgets('live in der App: Einstellung → Theme + direkte Nutzung',
        (tester) async {
      SharedPreferences.setMockInitialValues({'set_accent': 'gruen'});
      final container = ProviderContainer(overrides: [
        storageProvider
            .overrideWith((ref) => Storage.open(store: PreviewSecretStore())),
      ]);
      addTearDown(container.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: Consumer(builder: (context, ref, _) {
          applyAccent(ref.watch(accentKeyProvider));
          return MaterialApp(
            theme: buildTheme(tv: false),
            // const: hängt nicht vom Theme ab – muss trotzdem neu aufbauen.
            home: const Scaffold(body: _AccentProbe()),
          );
        }),
      ));
      LinearProgressIndicator bar() =>
          tester.widget(find.byType(LinearProgressIndicator));
      // Speicher laden lassen; Neuaufbau folgt ein Bild nach applyAccent.
      Future<void> settle(Color want) async {
        await tester.runAsync(() => container.read(storageProvider.future));
        for (var i = 0; i < 10 && bar().color != want; i++) {
          await tester.pump();
        }
        await tester.pump(const Duration(milliseconds: 400)); // AnimatedTheme
      }

      await settle(AppColors.accentPresets['gruen']!);
      expect(bar().color, AppColors.accentPresets['gruen']);
      expect(
          Theme.of(tester.element(find.byType(_AccentProbe)))
              .colorScheme
              .primary,
          AppColors.accentPresets['gruen']);

      // Umschalten wie in den Einstellungen.
      final st = container.read(storageProvider).value!;
      await tester.runAsync(() => st.setOption(accentOptionKey, 'lila'));
      container.invalidate(storageProvider);
      await settle(AppColors.accentPresets['lila']!);
      expect(bar().color, AppColors.accentPresets['lila']);
    });

    testWidgets('Farbfelder: wählbar per D-Pad und mit Vorlesetext',
        (tester) async {
      final handle = tester.ensureSemantics();
      String? picked;
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(tv: true),
        home: Scaffold(
          body: AccentPicker(value: 'orange', onChanged: (k) => picked = k),
        ),
      ));
      expect(find.bySemanticsLabel('Orange, ausgewählt'), findsOneWidget);
      expect(find.bySemanticsLabel('Türkis'), findsOneWidget);
      // Erstes Feld fokussieren, ▶ ▶, OK → Grün.
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();
      expect(picked, 'gruen');
      handle.dispose();
    });
  });

  group('Sicherung', () {
    test('enthält Akzentfarbe und Durchreichung, nicht den Erststart-Merker',
        () async {
      SharedPreferences.setMockInitialValues({
        'set_accent': 'rot',
        'set_passthrough': true,
        'set_textsizeasked': true,
      });
      final st = await Storage.open(store: PreviewSecretStore());
      final prefs = st.exportAll()['prefs'] as Map;
      expect(prefs['set_accent'], 'rot');
      expect(prefs['set_passthrough'], true);
      expect(prefs.containsKey('set_textsizeasked'), isFalse);
    });
  });

  group('Dolby/DTS-Durchreichung', () {
    test('mpv-Eigenschaft audio-spdif je nach Schalter', () async {
      final calls = <String, String>{};
      Future<void> fake(String k, String v) async => calls[k] = v;
      await AudioPassthrough.apply(fake, true);
      expect(calls, {'audio-spdif': 'ac3,eac3,dts,dts-hd,truehd'});
      await AudioPassthrough.apply(fake, false);
      expect(calls, {'audio-spdif': ''});
      // Fehler der libmpv werden geschluckt.
      await AudioPassthrough.apply(
          (_, __) async => throw Exception('unsupported'), true);
    });

    test('Standard aus, Schalter aus der Einstellung', () async {
      SharedPreferences.setMockInitialValues({});
      final st = await Storage.open(store: PreviewSecretStore());
      expect(AudioPassthrough.enabled(st), isFalse);
      await st.setFlag(AudioPassthrough.flagKey, true);
      expect(AudioPassthrough.enabled(st), isTrue);
    });
  });

  group('Schriftgröße beim ersten Start (TV)', () {
    Future<Storage> open(Map<String, Object> prefs) {
      SharedPreferences.setMockInitialValues(prefs);
      return Storage.open(store: PreviewSecretStore());
    }

    testWidgets('erscheint einmal, ▶ + OK wählt „Groß“', (tester) async {
      TextSizeChooser.debugAllowInTests = true;
      final storage = await tester.runAsync(() => open({}));
      await pumpTv(tester, const HomeShell(), _data, Future.value(storage));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(TextSizeChooser), findsOneWidget);
      expect(find.text('Wie groß soll die Schrift sein?'), findsOneWidget);

      await tvKey(tester, LogicalKeyboardKey.arrowRight);
      await tvKey(tester, LogicalKeyboardKey.select);
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(TextSizeChooser), findsNothing);
      expect(storage!.option('uiscale', 'auto'), 'gross');
      expect(storage.flag(TextSizeChooser.askedFlag), isTrue);
      await tvDone(tester);

      // Zweiter Start: nicht mehr.
      await pumpTv(tester, const HomeShell(), _data, Future.value(storage));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(TextSizeChooser), findsNothing);
      await tvDone(tester);
    });

    testWidgets('Zurück behält Normal', (tester) async {
      TextSizeChooser.debugAllowInTests = true;
      final storage = await tester.runAsync(() => open({}));
      await pumpTv(tester, const HomeShell(), _data, Future.value(storage));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(TextSizeChooser), findsOneWidget);
      await tvKey(tester, LogicalKeyboardKey.arrowRight); // Vorschau „Groß“
      await tvKey(tester, LogicalKeyboardKey.escape);
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(TextSizeChooser), findsNothing);
      expect(storage!.option('uiscale', 'auto'), 'auto');
      expect(storage.flag(TextSizeChooser.askedFlag), isTrue);
      await tvDone(tester);
    });

    testWidgets('nicht auf dem Handy', (tester) async {
      TextSizeChooser.debugAllowInTests = true;
      final storage = await tester.runAsync(() => open({}));
      await tester.pumpWidget(ProviderScope(
        overrides: [
          isTvProvider.overrideWithValue(false),
          storageProvider.overrideWith((ref) async => storage!),
        ],
        child: const MaterialApp(home: _ChooserHost()),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(TextSizeChooser), findsNothing);
      expect(storage!.flag(TextSizeChooser.askedFlag), isFalse);
    });
  });

  group('Bedienungshilfen', () {
    test('Texte', () {
      expect(channelSemantics(_ch, _now), '1 Das Erste HD, jetzt: Tagesschau');
      expect(channelSemantics(_ch, null), '1 Das Erste HD');
      expect(posterSemantics('Dune', year: 2021), 'Dune, 2021');
      expect(posterSemantics('Dune'), 'Dune');
      expect(playerButtonSemantics(Icons.arrow_back_rounded), 'Zurück');
      expect(playerButtonSemantics(Icons.pause_rounded), 'Pause');
    });

    testWidgets('Kachel, Zapping-Leiste', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Stack(fit: StackFit.expand, children: [
            Column(children: [
              FocusableTile(
                semanticLabel: 'Film, 2020',
                onTap: () {},
                child: const Text('irrelevant'),
              ),
              FocusableTile(onTap: () {}, child: const Text('Nur Text')),
            ]),
            ZapBar(channel: _ch, now: _now, next: null),
          ]),
        ),
      ));
      expect(find.bySemanticsLabel('Film, 2020'), findsOneWidget);
      expect(find.bySemanticsLabel('irrelevant'), findsNothing);
      expect(find.bySemanticsLabel('Nur Text'), findsOneWidget);
      expect(find.bySemanticsLabel('1 Das Erste HD, jetzt: Tagesschau'),
          findsOneWidget);
      final tile = tester.getSemantics(find.bySemanticsLabel('Film, 2020'));
      expect(tile.flagsCollection.isButton, isTrue);
      handle.dispose();
    });

    testWidgets('TV-Shell: Leiste und Senderzeilen', (tester) async {
      final handle = tester.ensureSemantics();
      SharedPreferences.setMockInitialValues({});
      final storage =
          await tester.runAsync(() => Storage.open(store: PreviewSecretStore()));
      await pumpTv(tester, const HomeShell(), _data, Future.value(storage));
      for (final l in ['Start', 'Live TV', 'Einstellungen']) {
        expect(find.bySemanticsLabel(l), findsWidgets, reason: l);
      }
      // Zum Live-TV über die Leiste (Fokus wechselt den Bereich).
      // ignore: invalid_use_of_visible_for_testing_member
      final nodes = (tester.state(find.byType(HomeShell)) as dynamic)
          .debugRailNodes as List<FocusNode>;
      nodes[1].requestFocus();
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.bySemanticsLabel(RegExp(r'Das Erste HD, jetzt: Tagesschau')),
          findsWidgets);
      handle.dispose();
      await tvDone(tester);
    });
  });
}

class _AccentProbe extends StatelessWidget {
  const _AccentProbe();
  @override
  Widget build(BuildContext context) =>
      const SizedBox(width: 200, child: ThinProgress(value: 0.5));
}

class _ChooserHost extends ConsumerStatefulWidget {
  const _ChooserHost();
  @override
  ConsumerState<_ChooserHost> createState() => _ChooserHostState();
}

class _ChooserHostState extends ConsumerState<_ChooserHost> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
        (_) => TextSizeChooser.maybeShow(context, ref));
  }

  @override
  Widget build(BuildContext context) => const Scaffold();
}
