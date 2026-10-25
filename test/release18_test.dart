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
import 'package:jason_stream_player/player/media_session.dart';
import 'package:jason_stream_player/state/playback_session.dart';
import 'package:jason_stream_player/state/providers.dart';
import 'package:jason_stream_player/ui/nav.dart';
import 'package:jason_stream_player/ui/player/mini_player.dart';
import 'package:jason_stream_player/ui/player/player_screen.dart';
import 'package:jason_stream_player/ui/shell/reminder_host.dart'
    show appNavigatorKey;
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/fake_engine.dart';
import 'helpers/tv_harness.dart';

/// 1.8 Teil 1: Player lebt unabhängig von der Seite (Mini-Player), Nur-Ton,
/// Einstellung „Zurück im Player“, Medien-Sitzung – mit Fake-Engine.

const _portal = Portal(
    id: 'pa', name: 'Anbieter A', type: PortalType.xtream, url: 'http://a');

Channel _ch(int i) => Channel(
      id: 'c$i',
      name: 'Sender $i',
      categoryId: 'de',
      streamUrl: 'http://s/$i',
      number: i + 1,
    );

final _channels = [for (var i = 0; i < 5; i++) _ch(i)];

PlayRequest _movie() => const PlayRequest(
      title: 'Der große Film',
      subtitle: '2024 · 118 Min.',
      url: 'http://s/movie.mp4',
      resumeKey: 'movie-1',
      artworkSeed: 'film',
    );

PlayRequest _live(int i) => PlayRequest(
      title: _channels[i].name,
      url: _channels[i].streamUrl,
      isLive: true,
      channels: _channels,
      channel: _channels[i],
    );

/// Wie app.dart: Navigator-Schlüssel und Mini-Player über allen Seiten.
Future<void> _pumpApp(WidgetTester tester, Storage storage,
    {bool tv = false, NoopMediaSession? media, Size? size}) async {
  tester.view.physicalSize = size ?? const Size(1080, 2280);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    overrides: [
      ...tvOverrides(
          TvData(
              live: LiveData(
                  const [Category(id: 'de', name: 'Deutschland')], _channels),
              portal: _portal),
          Future.value(storage),
          tv: tv),
      playbackEngineProvider.overrideWithValue(FakeEngine.factory),
      mediaSessionProvider.overrideWithValue(media ?? NoopMediaSession()),
    ],
    child: RepaintBoundary(
      key: tvShotKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        navigatorKey: appNavigatorKey,
        theme: buildTheme(tv: tv),
        builder: (context, child) => MiniPlayerHost(child: child!),
        home: Builder(
          builder: (context) => Scaffold(
            appBar: AppBar(title: const Text('Filme')),
            body: ListView(children: [
              for (var i = 0; i < 12; i++)
                ListTile(
                    key: ValueKey('row$i'), title: Text('Film Nr. ${i + 1}')),
            ]),
            floatingActionButton: Column(mainAxisSize: MainAxisSize.min, children: [
              FloatingActionButton(
                key: const ValueKey('open-movie'),
                heroTag: 'movie',
                onPressed: () => openPlayer(context, _movie()),
                child: const Icon(Icons.movie),
              ),
              const SizedBox(height: 8),
              FloatingActionButton(
                key: const ValueKey('open-live'),
                heroTag: 'live',
                onPressed: () => openPlayer(context, _live(2)),
                child: const Icon(Icons.live_tv),
              ),
            ]),
          ),
        ),
      ),
    ),
  ));
  await tester.pump();
}

Future<void> _settle(WidgetTester tester, [int n = 6]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<FakeEngine> _openMovie(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('open-movie')));
  await _settle(tester);
  expect(find.byType(PlayerScreen), findsOneWidget);
  expect(FakeEngine.created, hasLength(1));
  final e = FakeEngine.created.single;
  expect(e.calls, contains('open http://s/movie.mp4'));
  e.emit(width: 1920, buffering: false, duration: const Duration(minutes: 118));
  await tester.pump();
  return e;
}

Future<void> _back(WidgetTester tester) async {
  await tester.binding.handlePopRoute();
  await tester.pump();
  await _settle(tester, 5);
}

/// Aufräumen: Stream stoppen, Baum abbauen, Timer auslaufen lassen.
Future<void> _done(WidgetTester tester) async {
  expect(tester.takeException(), isNull);
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 12));
}

void main() {
  late Storage storage;
  final log = <MethodCall>[];
  bool pipOk = true;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    L10n.lang = 'de';
    await initializeDateFormatting('de');
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    storage = await Storage.open(store: PreviewSecretStore());
    await storage.setOption('applang', 'de');
    L10n.lang = 'de';
    FakeEngine.created.clear();
    log.clear();
    pipOk = true;
    // SystemChrome (Ausrichtung, Vollbild) antwortet im Test sonst nie.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (c) async => null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('de.jasonstream.player/platform'), (c) async {
      log.add(c);
      if (c.method == 'enterPip') return pipOk;
      if (c.method == 'isTv') return false;
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('de.jasonstream.player/platform'), null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  group('Player überlebt die Seite', () {
    testWidgets('Zurück → Stream läuft weiter, Mini-Player erscheint',
        (tester) async {
      await _pumpApp(tester, storage);
      final e = await _openMovie(tester);
      await _back(tester);
      expect(find.byType(PlayerScreen), findsNothing);
      expect(find.text('Filme'), findsOneWidget);
      expect(e.disposed, isFalse);
      expect(e.calls, isNot(contains('dispose')));
      expect(find.byKey(const ValueKey('mini-player')), findsOneWidget);
      expect(find.text('Der große Film'), findsOneWidget);
      expect(find.text('2024 · 118 Min.'), findsOneWidget);
      await _done(tester);
      // Nach dem Abbau ist auch die Engine weg.
      expect(e.disposed, isTrue);
    });

    testWidgets('Antippen öffnet das Vollbild mit derselben Instanz',
        (tester) async {
      await _pumpApp(tester, storage);
      final e = await _openMovie(tester);
      await _back(tester);
      final opens = e.calls.where((c) => c.startsWith('open')).length;
      await tester.tap(find.byKey(const ValueKey('mini-player')));
      await _settle(tester);
      expect(find.byType(PlayerScreen), findsOneWidget);
      expect(find.byKey(const ValueKey('mini-player')), findsNothing);
      expect(FakeEngine.created, hasLength(1));
      expect(e.calls.where((c) => c.startsWith('open')).length, opens,
          reason: 'kein Neustart des Streams');
      // Bedienelemente zeigen den Film, Videofläche der Fake-Engine da.
      expect(find.text('Der große Film'), findsWidgets);
      expect(find.byKey(const ValueKey('fake-video')), findsOneWidget);
      await _done(tester);
    });

    testWidgets('Schließen-Knopf stoppt und merkt die Position',
        (tester) async {
      await _pumpApp(tester, storage);
      final e = await _openMovie(tester);
      e.emit(position: const Duration(minutes: 40));
      await _back(tester);
      await tester.tap(find.byKey(const ValueKey('mini-close')));
      await _settle(tester);
      expect(find.byKey(const ValueKey('mini-player')), findsNothing);
      expect(e.disposed, isTrue);
      expect(storage.resume('movie-1')?.pos, 40 * 60);
      await _done(tester);
    });

    testWidgets('Wischen nach unten stoppt', (tester) async {
      await _pumpApp(tester, storage);
      final e = await _openMovie(tester);
      await _back(tester);
      await tester.fling(find.byKey(const ValueKey('mini-player')),
          const Offset(0, 300), 2000);
      await _settle(tester);
      expect(find.byKey(const ValueKey('mini-player')), findsNothing);
      expect(e.disposed, isTrue);
      await _done(tester);
    });

    testWidgets('Ziehen rastet an einer Ecke ein', (tester) async {
      await _pumpApp(tester, storage);
      await _openMovie(tester);
      await _back(tester);
      MiniPlayer.corner = MiniCorner.bottomRight;
      final before = tester.getTopLeft(find.byKey(const ValueKey('mini-player')));
      await tester.drag(find.byKey(const ValueKey('mini-player')),
          const Offset(-200, -500));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      expect(MiniPlayer.corner, MiniCorner.topLeft);
      final after = tester.getTopLeft(find.byKey(const ValueKey('mini-player')));
      expect(after.dx, lessThan(before.dx));
      expect(after.dy, lessThan(before.dy));
      await _done(tester);
    });

    testWidgets('Play/Pause im Mini-Player steuert die Engine',
        (tester) async {
      await _pumpApp(tester, storage);
      final e = await _openMovie(tester);
      e.emit(playing: true);
      await _back(tester);
      await tester.tap(find.byKey(const ValueKey('mini-play-pause')));
      await _settle(tester, 2);
      expect(e.calls.last, 'pause');
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('mini-play-pause')));
      await _settle(tester, 2);
      expect(e.calls.last, 'play');
      await _done(tester);
    });

    testWidgets('Live: Mini-Player zeigt Sender und LIVE', (tester) async {
      // Live-Player läuft quer (Querformat erzwungen), danach wieder hoch.
      await _pumpApp(tester, storage, size: const Size(2280, 1080));
      await tester.tap(find.byKey(const ValueKey('open-live')));
      await _settle(tester);
      expect(FakeEngine.created, hasLength(1));
      final e = FakeEngine.created.single;
      expect(e.calls.any((c) => c.startsWith('open http://s/2')), isTrue);
      e.emit(width: 1280, buffering: false, playing: true);
      await _back(tester);
      tester.view.physicalSize = const Size(1080, 2280);
      await _settle(tester, 3);
      expect(find.byKey(const ValueKey('mini-player')), findsOneWidget);
      expect(find.text('Sender 2'), findsOneWidget);
      expect(find.text('LIVE'), findsOneWidget);
      await _done(tester);
    });

    testWidgets('Neuer Film bei laufendem Mini-Player ersetzt die Instanz',
        (tester) async {
      await _pumpApp(tester, storage);
      final e1 = await _openMovie(tester);
      await _back(tester);
      tester.view.physicalSize = const Size(2280, 1080);
      await tester.tap(find.byKey(const ValueKey('open-live')));
      await _settle(tester);
      expect(FakeEngine.created, hasLength(2));
      expect(e1.disposed, isTrue);
      expect(find.byKey(const ValueKey('mini-player')), findsNothing);
      await _done(tester);
    });

    testWidgets('Fernseher: Zurück stoppt wie bisher, kein Mini-Player',
        (tester) async {
      await _pumpApp(tester, storage, tv: true, size: const Size(1920, 1080));
      final e = await _openMovie(tester);
      await _back(tester);
      expect(find.byType(PlayerScreen), findsNothing);
      expect(find.byKey(const ValueKey('mini-player')), findsNothing);
      expect(e.disposed, isTrue);
      await _done(tester);
    });
  });

  group('Einstellung „Zurück im Player“', () {
    testWidgets('Stopp: Zurück beendet den Stream', (tester) async {
      await storage.setOption(LeaveAction.optionKey, 'stop');
      await _pumpApp(tester, storage);
      final e = await _openMovie(tester);
      await _back(tester);
      expect(find.byKey(const ValueKey('mini-player')), findsNothing);
      expect(e.disposed, isTrue);
      await _done(tester);
    });

    testWidgets('Bild-in-Bild: Zurück verkleinert, Seite bleibt',
        (tester) async {
      await storage.setOption(LeaveAction.optionKey, 'pip');
      await _pumpApp(tester, storage);
      final e = await _openMovie(tester);
      await _back(tester);
      expect(log.any((c) => c.method == 'enterPip'), isTrue);
      expect(find.byType(PlayerScreen), findsOneWidget);
      expect(e.disposed, isFalse);
      await _done(tester);
    });

    testWidgets('Bild-in-Bild nicht möglich: Seite schließt, Stream stoppt',
        (tester) async {
      pipOk = false;
      await storage.setOption(LeaveAction.optionKey, 'pip');
      await _pumpApp(tester, storage);
      final e = await _openMovie(tester);
      await _back(tester);
      expect(find.byType(PlayerScreen), findsNothing);
      expect(find.byKey(const ValueKey('mini-player')), findsNothing);
      expect(e.disposed, isTrue);
      await _done(tester);
    });

    test('LeaveAction: Standard Mini-Player', () {
      expect(LeaveAction.fromId(null), LeaveAction.mini);
      expect(LeaveAction.fromId('quatsch'), LeaveAction.mini);
      expect(LeaveAction.fromId('pip'), LeaveAction.pip);
      expect(LeaveAction.fromId('stop'), LeaveAction.stop);
    });
  });

  group('Nur-Ton', () {
    testWidgets('⋮-Menü schaltet Video ab und wieder an', (tester) async {
      await _pumpApp(tester, storage);
      final e = await _openMovie(tester);
      expect(find.byKey(const ValueKey('fake-video')), findsOneWidget);
      await tester.tap(find.byIcon(Icons.more_vert_rounded));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('menu-audio-only')));
      await tester.pumpAndSettle();
      expect(e.videoEnabled, isFalse);
      expect(e.calls, contains('video off'));
      expect(find.byKey(const ValueKey('audio-only-badge')), findsOneWidget);
      expect(find.byKey(const ValueKey('fake-video')), findsNothing);
      // Auch der Mini-Player zeigt Nur-Ton.
      await _back(tester);
      expect(find.byKey(const ValueKey('mini-audio-only')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('mini-audio-toggle')));
      await _settle(tester, 2);
      expect(e.videoEnabled, isTrue);
      expect(e.calls.last, 'video on');
      expect(find.byKey(const ValueKey('mini-audio-only')), findsNothing);
      await _done(tester);
    });
  });

  group('Medien-Sitzung', () {
    testWidgets('Benachrichtigung bekommt Titel, nie die Stream-Adresse',
        (tester) async {
      final media = NoopMediaSession();
      await _pumpApp(tester, storage, media: media);
      final e = await _openMovie(tester);
      e.emit(playing: true);
      await tester.pump();
      expect(media.callbacks, isNotNull);
      expect(media.updates, isNotEmpty);
      final last = media.updates.last;
      expect(last.title, 'Der große Film');
      expect(last.playing, isTrue);
      for (final u in media.updates) {
        expect('${u.title} ${u.subtitle} ${u.artUrl}', isNot(contains('http://s/')));
      }
      // Pause über die Benachrichtigung/Kopfhörer.
      await media.callbacks!.onPause();
      expect(e.calls.last, 'pause');
      await media.callbacks!.onStop();
      await _settle(tester, 3);
      expect(e.disposed, isTrue);
      expect(media.idles, greaterThan(0));
      await _done(tester);
    });

    test('safeArt lässt nur schlichte Bildadressen durch', () {
      expect(MediaInfo.safeArt('http://logo.example/a.png'),
          'http://logo.example/a.png');
      expect(MediaInfo.safeArt('http://h/img.png?user=a&pass=b'), isNull);
      expect(MediaInfo.safeArt('http://u:p@h/img.png'), isNull);
      expect(MediaInfo.safeArt('file:///x.png'), isNull);
      expect(MediaInfo.safeArt(null), isNull);
    });

    testWidgets('Live: CH+/CH− aus der Benachrichtigung zappen', (tester) async {
      final media = NoopMediaSession();
      await _pumpApp(tester, storage, media: media, size: const Size(2280, 1080));
      await tester.tap(find.byKey(const ValueKey('open-live')));
      await _settle(tester);
      final e = FakeEngine.created.single;
      expect(media.updates.last.canZap, isTrue);
      await media.callbacks!.onZap!(1);
      await _settle(tester);
      expect(e.calls.any((c) => c.startsWith('open http://s/3')), isTrue);
      expect(media.updates.last.title, 'Sender 3');
      await _done(tester);
    });
  });

  group('Stream-Besitzer', () {
    test('canSaveResume wie bisher', () {
      expect(canSaveResume(live: true, opening: false, pos: 100, total: 1000),
          isFalse);
      expect(canSaveResume(live: false, opening: true, pos: 100, total: 1000),
          isFalse);
      expect(canSaveResume(live: false, opening: false, pos: 3, total: 1000),
          isFalse);
      expect(canSaveResume(live: false, opening: false, pos: 100, total: 1000),
          isTrue);
    });

    testWidgets('Film endet im Mini-Player → aufräumen', (tester) async {
      await _pumpApp(tester, storage);
      final e = await _openMovie(tester);
      await _back(tester);
      e.emit(completed: true);
      await _settle(tester, 3);
      expect(find.byKey(const ValueKey('mini-player')), findsNothing);
      expect(e.disposed, isTrue);
      await _done(tester);
    });
  });
}
