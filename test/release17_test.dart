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
import 'package:jason_stream_player/state/providers.dart';
import 'package:jason_stream_player/ui/home/expiry_banner.dart';
import 'package:jason_stream_player/ui/home/home_screen.dart';
import 'package:jason_stream_player/ui/live/live_screen.dart';
import 'package:jason_stream_player/ui/player/player_screen.dart';
import 'package:jason_stream_player/ui/player/subtitle_delay.dart';
import 'package:jason_stream_player/ui/portals/add_portal_screen.dart';
import 'package:jason_stream_player/ui/portals/portal_switcher.dart';
import 'package:jason_stream_player/ui/widgets/common.dart';
import 'package:jason_stream_player/ui/widgets/focusable_tile.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/tv_harness.dart';

/// 1.7: „Einfügen & erkennen“, Abo-Ablauf-Hinweis, Archivfenster,
/// Untertitel-Verzögerung – Logik und Bedienung (Touch und Fernbedienung).

const _portalA = Portal(
    id: 'pa', name: 'Anbieter A', type: PortalType.xtream, url: 'http://a');
const _portalB = Portal(
    id: 'pb', name: 'Anbieter B', type: PortalType.xtream, url: 'http://b');

Channel _ch(int i, {int catchup = 0}) => Channel(
      id: 'c$i',
      name: 'Sender $i',
      categoryId: 'g',
      streamUrl: 'http://s/$i',
      number: i + 1,
      catchupDays: catchup,
    );

Future<void> _key(WidgetTester t, LogicalKeyboardKey k) async {
  await t.sendKeyEvent(k);
  await t.pump();
  await t.pump(const Duration(milliseconds: 300));
}

/// Zurück wie auf dem Gerät.
Future<void> _back(WidgetTester tester) async {
  final handled = await tester.sendKeyEvent(LogicalKeyboardKey.escape);
  if (!handled) await tester.binding.handlePopRoute();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// Fokus auf das (erste) Widget mit [finder] (über ein Text/Icon darin).
Future<void> _focusOn(WidgetTester tester, Finder finder) async {
  var f = finder.first;
  final inner = find.descendant(
      of: f, matching: find.byWidgetPredicate((w) => w is Text || w is Icon));
  if (inner.evaluate().isNotEmpty) f = inner.first;
  Focus.of(tester.element(f)).requestFocus();
  await tester.pump(const Duration(milliseconds: 300));
}

List<String> _focusedTexts() {
  final out = <String>[];
  void visit(Element e) {
    final w = e.widget;
    if (w is Text && w.data != null) out.add(w.data!);
    e.visitChildren(visit);
  }

  (FocusManager.instance.primaryFocus?.context as Element?)
      ?.visitChildren(visit);
  return out;
}

bool _focusUnder(Key key) {
  final ctx = FocusManager.instance.primaryFocus?.context;
  if (ctx == null) return false;
  if (ctx.widget.key == key) return true;
  var found = false;
  ctx.visitAncestorElements((e) {
    if (e.widget.key == key) found = true;
    return !found;
  });
  return found;
}

/// Texte aller Formularfelder der Seite (die Liste baut nur Sichtbares –
/// deshalb erst bis zum Speichern-Knopf blättern).
Future<List<String?>> _formTexts(WidgetTester tester) async {
  final out = <String?>[];
  void collect() {
    for (final f in tester.widgetList<TextFormField>(find.byType(TextFormField))) {
      final t = f.controller?.text;
      if (!out.contains(t)) out.add(t);
    }
  }

  collect();
  final list = find.byType(Scrollable).first;
  for (var i = 0; i < 6; i++) {
    await tester.drag(list, const Offset(0, -300));
    await tester.pump();
    collect();
  }
  for (var i = 0; i < 6; i++) {
    await tester.drag(list, const Offset(0, 300));
    await tester.pump();
  }
  return out;
}

/// Zwischenablage im Test: liefert [text] bei Clipboard.getData.
void _mockClipboard(String text) {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.getData') return {'text': text};
    return null;
  });
  addTearDown(() => TestDefaultBinaryMessengerBinding
      .instance.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, null));
}

void main() {
  late Storage storage;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await initializeDateFormatting('de');
  });

  setUp(() async {
    L10n.lang = 'de';
    SharedPreferences.setMockInitialValues({'set_applang': 'de'});
    storage = await Storage.open(store: PreviewSecretStore());
  });

  // ---------------------------------------------------------------------------
  group('Abo-Ablauf: Logik', () {
    final now = DateTime(2026, 10, 23, 21, 30);

    test('Hinweis nur bei ≤ 7 Tagen, Texte für morgen/heute/abgelaufen', () {
      ExpiryNotice? n(int days) => expiryNotice(
          AccountInfo(
              status: 'Active',
              expires: DateTime(2026, 10, 23 + days, 3)), // früh am Tag
          now);
      expect(n(8), isNull);
      expect(n(30), isNull);
      expect(n(7)!.title, 'Abo läuft in 7 Tagen ab');
      expect(n(3)!.title, 'Abo läuft in 3 Tagen ab');
      expect(n(3)!.detail, 'Gültig bis 26.10.2026');
      expect(n(1)!.title, 'Abo läuft morgen ab');
      // Heute 03:00 liegt schon hinter 21:30 – zählt trotzdem als „heute“.
      expect(n(0)!.title, 'Abo läuft heute ab');
      expect(n(0)!.expired, isFalse);
      expect(n(-1)!.title, 'Abo abgelaufen');
      expect(n(-1)!.expired, isTrue);
      expect(n(-1)!.detail, 'Abgelaufen am 22.10.2026');
    });

    test('ohne Datum nur bei Status „expired“; ohne Konto nichts', () {
      expect(expiryNotice(null, now), isNull);
      expect(expiryNotice(const AccountInfo(status: 'Active'), now), isNull);
      expect(expiryNotice(const AccountInfo(status: 'Expired'), now)!.expired,
          isTrue);
    });

    test('Englisch', () {
      L10n.lang = 'en';
      final n = expiryNotice(
          AccountInfo(status: 'Active', expires: DateTime(2026, 10, 25)), now)!;
      expect(n.title, 'Subscription expires in 2 days');
      L10n.lang = 'de';
    });

    test('Portal-Zeile: Ablaufdatum bei Warnung und Ablauf', () {
      final warn = describeAccount(
          AccountInfo(status: 'Active', expires: DateTime(2026, 10, 26, 2)),
          now);
      expect(warn.health, PortalHealth.warn);
      expect(warn.text, 'Läuft in 3 Tagen ab (26.10.2026)');
      final today = describeAccount(
          AccountInfo(status: 'Active', expires: DateTime(2026, 10, 23, 23)),
          now);
      expect(today.text, 'Läuft heute ab (23.10.2026)');
      final gone = describeAccount(
          AccountInfo(status: 'Active', expires: DateTime(2026, 10, 1)), now);
      expect(gone.health, PortalHealth.bad);
      expect(gone.text, 'Abo abgelaufen (01.10.2026)');
      final ok = describeAccount(
          AccountInfo(status: 'Active', expires: DateTime(2027, 1, 1)), now);
      expect(ok.health, PortalHealth.ok);
      expect(ok.text, 'Gültig bis 01.01.2027');
    });

    test('dayKey', () {
      expect(dayKey(DateTime(2026, 3, 7)), '2026-03-07');
    });
  });

  group('Abo-Ablauf: Startseite', () {
    TvData data({bool many = true, int days = 3}) => TvData(
          live: LiveData(const [Category(id: 'g', name: 'G')],
              [for (var i = 0; i < 3; i++) _ch(i)]),
          portal: _portalA,
          portals: many ? const [_portalA, _portalB] : const [_portalA],
          account: AccountInfo(
              status: 'Active',
              expires: DateTime.now().add(Duration(days: days))),
        );

    testWidgets('Handy: Banner mit Portalname, OK blendet für heute aus',
        (tester) async {
      await pumpTv(tester, HomeScreen(onOpenTab: (_) {}), data(),
          Future.value(storage),
          tv: false);
      expect(find.byKey(const ValueKey('expiry-banner')), findsOneWidget);
      expect(find.text('Anbieter A · Abo läuft in 3 Tagen ab'), findsOneWidget);
      expect(find.textContaining('Gültig bis'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('expiry-dismiss')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('expiry-banner')), findsNothing);
      expect(storage.expiryDismissedDay('pa'), dayKey(DateTime.now()));
      expect(storage.expiryDismissedDay('pb'), isNull);
      await tvDone(tester);

      // Neu geöffnet: bleibt heute ausgeblendet.
      await pumpTv(tester, HomeScreen(onOpenTab: (_) {}), data(),
          Future.value(storage),
          tv: false);
      expect(find.byKey(const ValueKey('expiry-banner')), findsNothing);
      await tvDone(tester);

      // Gestern ausgeblendet → wieder da; ein Portal → ohne Namen.
      await storage.setExpiryDismissedDay('pa', '2020-01-01');
      await pumpTv(tester, HomeScreen(onOpenTab: (_) {}),
          data(many: false, days: 1), Future.value(storage),
          tv: false);
      expect(find.text('Abo läuft morgen ab'), findsOneWidget);
      await tvDone(tester);
    });

    testWidgets('kein Banner ohne nahes Ablaufdatum', (tester) async {
      await pumpTv(tester, HomeScreen(onOpenTab: (_) {}), data(days: 40),
          Future.value(storage),
          tv: false);
      expect(find.byKey(const ValueKey('expiry-banner')), findsNothing);
      await tvDone(tester);
    });

    testWidgets('Fernseher: OK per D-Pad, Zurück ist keine Falle',
        (tester) async {
      await pumpTv(tester, HomeScreen(onOpenTab: (_) {}), data(days: 0),
          Future.value(storage));
      expect(find.byKey(const ValueKey('expiry-banner')), findsOneWidget);
      expect(find.textContaining('Abo läuft heute ab'), findsOneWidget);
      // Start auf „Live TV“; ▶ bis zur letzten Kachel („Sport“, ab 2.3),
      // ▲ erreicht den OK-Knopf des Hinweises (rechts in der Zeile darüber).
      expect(_focusedTexts(), contains('Live TV'));
      for (var i = 0; i < 4; i++) {
        await _key(tester, LogicalKeyboardKey.arrowRight);
      }
      expect(_focusedTexts(), contains('Sport'));
      await _key(tester, LogicalKeyboardKey.arrowUp);
      expect(_focusUnder(const ValueKey('expiry-dismiss')), isTrue);
      // Zurück: Seite bleibt, nichts stürzt ab.
      await _back(tester);
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
      // OK blendet aus, Fokus bleibt auf der Seite.
      await _focusOn(tester, find.byKey(const ValueKey('expiry-dismiss')));
      await _key(tester, LogicalKeyboardKey.select);
      expect(find.byKey(const ValueKey('expiry-banner')), findsNothing);
      expect(storage.expiryDismissedDay('pa'), dayKey(DateTime.now()));
      await _key(tester, LogicalKeyboardKey.arrowDown);
      expect(FocusManager.instance.primaryFocus, isNotNull);
      await tvDone(tester);
    });
  });

  // ---------------------------------------------------------------------------
  group('Einfügen & erkennen (Portal hinzufügen)', () {
    /// Seite als eigene Route (Zurück muss sie verlassen können).
    Future<void> pump(WidgetTester tester, {required bool tv}) async {
      await pumpTv(
          tester,
          Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                          builder: (_) => const AddPortalScreen())),
                  child: const Text('öffnen'),
                ),
              ),
            ),
          ),
          TvData(live: const LiveData([], [])),
          Future.value(storage),
          tv: tv);
      await tester.tap(find.text('öffnen'));
      await tester.pumpAndSettle();
      expect(find.byType(AddPortalScreen), findsOneWidget);
    }

    testWidgets('Handy: Text einfügen → Felder gefüllt, Hinweis bei Unsinn',
        (tester) async {
      await pump(tester, tv: false);
      expect(find.text('Einfügen & erkennen'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('portal-paste')),
          'Server: tv.example.com\nPort: 8080\nBenutzer: jason77\nPasswort: Geheim!23');
      await tester.tap(find.byKey(const ValueKey('portal-detect')));
      await tester.pump();
      expect(find.text('Erkannt: Xtream · tv.example.com:8080'), findsOneWidget);
      final fields = await _formTexts(tester);
      expect(fields, contains('http://tv.example.com:8080'));
      expect(fields, contains('jason77'));
      expect(fields, contains('Geheim!23'));
      expect(fields, contains('tv.example.com')); // Name vorbelegt
      // Der eingefügte Text steht nirgends sonst (nur im Eingabefeld).
      expect(find.text('Geheim!23'), findsNothing); // Passwort verdeckt

      // MAC-Portal: Art wechselt, MAC-Feld gefüllt.
      await tester.enterText(find.byKey(const ValueKey('portal-paste')),
          'http://mag.example/stalker_portal/c/ 00-1a-79-ab-cd-ef');
      await tester.tap(find.byKey(const ValueKey('portal-detect')));
      await tester.pump();
      expect(find.text('Erkannt: MAC-Portal · mag.example'), findsOneWidget);
      final mac = await _formTexts(tester);
      expect(mac, contains('00:1A:79:AB:CD:EF'));
      expect(mac, contains('http://mag.example/stalker_portal/c/'));

      // Unsinn → freundlicher Hinweis, Felder bleiben.
      await tester.enterText(
          find.byKey(const ValueKey('portal-paste')), 'Viel Spaß!');
      await tester.tap(find.byKey(const ValueKey('portal-detect')));
      await tester.pump();
      expect(find.textContaining('Nichts erkannt'), findsOneWidget);
      expect(find.textContaining('Erkannt:'), findsNothing);
      await tvDone(tester);
    });

    testWidgets('Fernseher: Knopf per D-Pad, leeres Feld liest die Zwischenablage',
        (tester) async {
      _mockClipboard(
          'http://host.example:25461/get.php?username=U1&password=P1&type=m3u_plus');
      await pump(tester, tv: true);
      // Start im Namensfeld; ▲ zur Zugangsart, ▲ zum Knopf „Einfügen & erkennen“.
      for (var i = 0;
          i < 4 && !_focusUnder(const ValueKey('portal-detect'));
          i++) {
        await _key(tester, LogicalKeyboardKey.arrowUp);
      }
      expect(_focusUnder(const ValueKey('portal-detect')), isTrue);
      await _key(tester, LogicalKeyboardKey.select);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Erkannt: Xtream · host.example:25461'), findsOneWidget);
      final fields = await _formTexts(tester);
      expect(fields, contains('http://host.example:25461'));
      expect(fields, contains('U1'));
      expect(fields, contains('P1'));
      // Zurück verlässt die Seite (keine Falle).
      await _back(tester);
      await tester.pumpAndSettle();
      expect(find.byType(AddPortalScreen), findsNothing);
      await tvDone(tester);
    });
  });

  // ---------------------------------------------------------------------------
  group('Archivfenster', () {
    test('archiveLabel', () {
      expect(archiveLabel(7), 'Archiv · 7 Tage');
      expect(archiveLabel(1), 'Archiv · 1 Tag');
      expect(archiveShort(7), '7d');
      L10n.lang = 'en';
      expect(archiveLabel(1), 'Archive · 1 day');
      expect(archiveLabel(3), 'Archive · 3 days');
      L10n.lang = 'de';
    });

    testWidgets('Fernseher: Infobereich zeigt „Archiv · 7 Tage“, Zeile nur Symbol',
        (tester) async {
      final data = TvData(
        live: LiveData(const [Category(id: 'g', name: 'G')],
            [_ch(0, catchup: 7), _ch(1), _ch(2, catchup: 1)]),
      );
      await pumpTv(tester, const Scaffold(body: LiveScreen()), data,
          Future.value(storage));
      // Sender 0 ist gewählt → Infobereich mit Archiv-Chip.
      expect(find.text('Archiv · 7 Tage'), findsOneWidget);
      expect(find.text('7d'), findsNothing);
      // Vorlesetext in der Zeile.
      expect(
          find.bySemanticsLabel(RegExp('Archiv · 7 Tage')), findsWidgets);
      // ▼ auf Sender 2 → „Archiv · 1 Tag“.
      await _key(tester, LogicalKeyboardKey.arrowDown);
      await _key(tester, LogicalKeyboardKey.arrowDown);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Archiv · 1 Tag'), findsOneWidget);
      await tvDone(tester);
    });
  });

  // ---------------------------------------------------------------------------
  group('Untertitel-Verzögerung', () {
    test('Schritte, Grenzen, Rundung, mpv-Eigenschaft', () async {
      final calls = <(String, String)>[];
      final d = SubtitleDelay((k, v) async => calls.add((k, v)));
      expect(d.seconds, 0);
      expect(d.isZero, isTrue);
      expect(d.label, 'Keine Verzögerung');
      await d.reset(); // 0 → 0: nichts senden
      expect(calls, isEmpty);

      await d.adjust(1);
      expect(d.seconds, 0.5);
      expect(calls.last, ('sub-delay', '0.5'));
      await d.adjust(-3);
      expect(d.seconds, -1.0);
      expect(calls.last, ('sub-delay', '-1.0'));
      expect(SubtitleDelay.format(d.seconds), '−1 s');
      await d.adjust(1);
      await d.adjust(1);
      expect(d.seconds, 0);
      expect(calls.last, ('sub-delay', '0.0'));

      for (var i = 0; i < 30; i++) {
        await d.adjust(1);
      }
      expect(d.seconds, 10);
      expect(d.atMax, isTrue);
      final n = calls.length;
      await d.adjust(1); // am Rand: nichts
      expect(calls.length, n);
      await d.setSeconds(-99);
      expect(d.seconds, -10);
      expect(d.atMin, isTrue);
      await d.setSeconds(0.74); // → 0,5
      expect(d.seconds, 0.5);
      await d.reset();
      expect(d.seconds, 0);
      expect(calls.last, ('sub-delay', '0.0'));
    });

    test('Fehler beim Setzen bleibt stumm, Anzeige stimmt', () async {
      final d = SubtitleDelay((_, __) async => throw Exception('unknown'));
      await d.adjust(2);
      expect(d.seconds, 1.0);
      expect(d.label, '+1 s');
    });

    test('Format', () {
      expect(SubtitleDelay.format(0), '0 s');
      expect(SubtitleDelay.format(1.5), '+1,5 s');
      expect(SubtitleDelay.format(-0.5), '−0,5 s');
      expect(SubtitleDelay.format(10), '+10 s');
      L10n.lang = 'en';
      expect(SubtitleDelay.format(-2.5), '−2.5 s');
      L10n.lang = 'tr';
      expect(SubtitleDelay.format(2.5), '+2,5 s');
      L10n.lang = 'de';
    });

    testWidgets('Blatt per D-Pad: Start auf +, ◀ zu −, Zurücksetzen, Zurück schließt',
        (tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      final calls = <(String, String)>[];
      final d = SubtitleDelay((k, v) async => calls.add((k, v)));
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(tv: true),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => SubtitleDelaySheet.show(context, d),
                child: const Text('öffnen'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('öffnen'));
      await tester.pumpAndSettle();
      expect(find.text('Untertitel-Verzögerung'), findsOneWidget);
      expect(find.text('0 s'), findsOneWidget);
      expect(_focusUnder(const ValueKey('subdelay-plus')), isTrue);

      await _key(tester, LogicalKeyboardKey.select);
      expect(find.text('+0,5 s'), findsOneWidget);
      expect(calls.last, ('sub-delay', '0.5'));
      await _key(tester, LogicalKeyboardKey.arrowLeft);
      expect(_focusUnder(const ValueKey('subdelay-minus')), isTrue);
      await _key(tester, LogicalKeyboardKey.select);
      await _key(tester, LogicalKeyboardKey.select);
      expect(find.text('−0,5 s'), findsOneWidget);
      expect(calls.last, ('sub-delay', '-0.5'));

      // ▼ zu „Zurücksetzen“ und OK → 0 s.
      await _key(tester, LogicalKeyboardKey.arrowDown);
      expect(_focusUnder(const ValueKey('subdelay-reset')), isTrue);
      await _key(tester, LogicalKeyboardKey.select);
      expect(find.text('0 s'), findsOneWidget);
      expect(d.seconds, 0);

      // Zurück schließt das Blatt (keine Falle).
      await _back(tester);
      await tester.pumpAndSettle();
      expect(find.text('Untertitel-Verzögerung'), findsNothing);
      expect(find.text('öffnen'), findsOneWidget);
    });

    testWidgets('Player (TV): langes OK auf dem Untertitel-Knopf öffnet das Blatt',
        (tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      final channels = [for (var i = 0; i < 5; i++) _ch(i)];
      final never = Completer<Storage>();
      await tester.pumpWidget(ProviderScope(
        overrides: [
          isTvProvider.overrideWithValue(true),
          storageProvider.overrideWith((ref) => never.future),
          epgProvider.overrideWith(_Epg.new),
          channelFlagsProvider.overrideWith(_Flags.new),
          minuteTickProvider
              .overrideWith((ref) => Stream.value(DateTime.now())),
        ],
        child: MaterialApp(
          theme: buildTheme(tv: true),
          home: PlayerScreen(
              request: PlayRequest(
                  title: 'Sender 2',
                  url: 'http://s/2',
                  isLive: true,
                  channels: channels,
                  channel: channels[2])),
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      final subBtn = find.ancestor(
          of: find.byIcon(Icons.subtitles_outlined),
          matching: find.byType(FocusableTile));
      expect(subBtn, findsOneWidget);
      await _focusOn(tester, find.byIcon(Icons.subtitles_outlined));

      // OK gedrückt halten (≥ 500 ms) → Untertitel-Verzögerung.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
      await tester.pump(const Duration(milliseconds: 700));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Untertitel-Verzögerung'), findsOneWidget);
      expect(_focusUnder(const ValueKey('subdelay-plus')), isTrue);
      await _key(tester, LogicalKeyboardKey.select);
      expect(find.text('+0,5 s'), findsOneWidget);

      // Zurück schließt nur das Blatt, der Player bleibt.
      await _back(tester);
      expect(find.text('Untertitel-Verzögerung'), findsNothing);
      expect(find.byType(PlayerScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 6));
    });
  });
}

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
