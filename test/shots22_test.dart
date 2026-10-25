import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:jason_stream_player/core/secret_store.dart';
import 'package:jason_stream_player/core/theme.dart';
import 'package:jason_stream_player/data/recordings/recordings.dart';
import 'package:jason_stream_player/data/storage.dart';
import 'package:jason_stream_player/l10n/strings.dart';
import 'package:jason_stream_player/models/models.dart';
import 'package:jason_stream_player/player/engine_choice.dart';
import 'package:jason_stream_player/player/media_session.dart';
import 'package:jason_stream_player/state/downloads.dart';
import 'package:jason_stream_player/state/playback_session.dart';
import 'package:jason_stream_player/state/providers.dart';
import 'package:jason_stream_player/ui/downloads/downloads_screen.dart';
import 'package:jason_stream_player/ui/nav.dart';
import 'package:jason_stream_player/ui/player/mini_player.dart';
import 'package:jason_stream_player/ui/player/player_screen.dart';
import 'package:jason_stream_player/ui/settings/settings_screen.dart';
import 'package:jason_stream_player/ui/shell/reminder_host.dart'
    show appNavigatorKey;
import 'package:jason_stream_player/ui/tv/tv_safe.dart';
import 'package:jason_stream_player/ui/vod/movie_detail_screen.dart';
import 'package:jason_stream_player/ui/vod/series_detail_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/app_fonts.dart';
import 'helpers/fake_engine.dart';
import 'helpers/tv_harness.dart';

/// 2.2: Bildschirmfotos – Download-Knopf (Film/Serie), Downloads-Seite
/// (Handy, TV), Aufnahme-Blatt und „● REC“ im Player.
/// Nur mit `TV_SHOTS=ordner`.
final _shotDir = Platform.environment['TV_SHOTS'];

Future<void> _shot(WidgetTester tester, String name) =>
    writeShot(tester, tvShotKey, name);

const _portal = Portal(
    id: 'px',
    name: 'Anbieter X',
    type: PortalType.xtream,
    url: 'http://srv',
    username: 'hans',
    password: 'geheim');

const _film = VodItem(
    id: '101',
    name: 'Nebelgrenze',
    categoryId: 'm1',
    streamUrl: 'http://srv/movie/hans/geheim/101.mkv',
    year: 2021,
    genre: 'Drama',
    duration: Duration(minutes: 112),
    rating: 7.4,
    plot: 'Eine Grenzpolizistin folgt im Nebel einer Spur, die sie '
        'zurück in ihr Heimatdorf führt.',
    director: 'Lea Hartmann',
    cast: 'Anna Wolff, David Kern');
const _serie = VodItem(
    id: 's9',
    name: 'Die Küste',
    categoryId: 's1',
    streamUrl: '',
    isSeries: true,
    year: 2025,
    genre: 'Krimi',
    plot: 'Ein Ermittlerteam an der Nordsee.');
const _eps = [
  Episode(id: '201', season: 1, number: 1, title: 'Ankunft',
      streamUrl: 'http://srv/series/hans/geheim/201.mkv',
      duration: Duration(minutes: 48)),
  Episode(id: '202', season: 1, number: 2, title: 'Sturmflut',
      streamUrl: 'http://srv/series/hans/geheim/202.mkv',
      duration: Duration(minutes: 51)),
  Episode(id: '203', season: 1, number: 3, title: 'Leuchtfeuer',
      streamUrl: 'http://srv/series/hans/geheim/203.mkv',
      duration: Duration(minutes: 47)),
];

Channel _ch(int i) => Channel(
      id: 'c$i',
      name: ['Das Erste HD', 'ZDF HD', 'RTL HD', 'arte HD'][i % 4],
      categoryId: 'de',
      streamUrl: 'http://srv/live/hans/geheim/$i.ts',
      epgId: 'c$i',
      number: i + 1,
    );
final _channels = [for (var i = 0; i < 4; i++) _ch(i)];

DownloadItem _d(String id, String title,
        {DownloadState state = DownloadState.done,
        DownloadWait wait = DownloadWait.none,
        int bytes = 0,
        int total = 0,
        bool episode = false,
        int ep = 0,
        bool subs = false}) =>
    DownloadItem(
      id: DownloadItem.idOf('px', id),
      scope: 'px',
      source: VodSource.portal,
      itemId: id,
      title: title,
      categoryId: episode ? 's1' : 'm1',
      isEpisode: episode,
      seriesId: episode ? 's9' : null,
      seriesName: episode ? 'Die Küste' : null,
      season: episode ? 1 : 0,
      episode: ep,
      maskedUrl: 'x',
      ext: 'mkv',
      path: '/dl/$id.mkv',
      bytes: bytes,
      total: total,
      state: state,
      wait: wait,
      added: DateTime(2026, 10, 25),
      subs: subs
          ? const [DownloadSub(maskedUrl: 's', language: 'de', path: '/dl/s.srt')]
          : const [],
    );

const _gb = 1024 * 1024 * 1024;
const _mb = 1024 * 1024;

final _list = [
  _d('202', 'Sturmflut',
      episode: true,
      ep: 2,
      state: DownloadState.running,
      bytes: 412 * _mb,
      total: 1210 * _mb),
  _d('203', 'Leuchtfeuer',
      episode: true,
      ep: 3,
      state: DownloadState.waiting,
      wait: DownloadWait.cellular,
      total: 1150 * _mb),
  _d('104', 'Stille Wasser',
      state: DownloadState.paused, bytes: 980 * _mb, total: 2400 * _mb),
  _d('101', 'Nebelgrenze', total: (2.3 * _gb).round(), bytes: (2.3 * _gb).round(), subs: true),
  _d('201', 'Ankunft',
      episode: true, ep: 1, total: 1180 * _mb, bytes: 1180 * _mb),
];

/// Feste Liste (ohne Warteschlange) für die Bilder.
class _Static extends DownloadsNotifier {
  @override
  List<DownloadItem> build() => _list;
}

class _Recs extends RecordingsNotifier {
  final List<Recording> l;
  _Recs(this.l);
  @override
  List<Recording> build() => l;
}

void main() {
  late Storage storage;
  final skip = _shotDir == null;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    L10n.lang = 'de';
    await initializeDateFormatting('de');
    await loadAppFonts();
    if (_shotDir != null) Directory(_shotDir!).createSync(recursive: true);
  });

  void platform({required bool tv}) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('de.jasonstream.player/platform'),
            (c) async => c.method == 'isTv' ? tv : null);
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    storage = await Storage.open(store: PreviewSecretStore());
    await storage.setOption('applang', 'de');
    await storage.addPortal(_portal);
    await storage.setResume('movie_101', 37 * 60, 112 * 60);
    L10n.lang = 'de';
    FakeEngine.created.clear();
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    m.setMockMethodCallHandler(SystemChannels.platform, (c) async => null);
    for (final ch in [
      'de.jasonstream/cast/events',
      'de.jasonstream/network/events',
      'de.jasonstream.player/dl',
    ]) {
      m.setMockMethodCallHandler(MethodChannel(ch), (c) async => null);
    }
  });

  tearDown(() {
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    m.setMockMethodCallHandler(SystemChannels.platform, null);
    m.setMockMethodCallHandler(
        const MethodChannel('de.jasonstream.player/platform'), null);
  });

  TvData data() => TvData(
        live: LiveData(
            const [Category(id: 'de', name: 'Deutschland')], _channels),
        portal: _portal,
        movies: VodData(const [Category(id: 'm1', name: 'Drama')], const [_film]),
        series: VodData(const [Category(id: 's1', name: 'Krimi')], const [_serie]),
        account: const AccountInfo(status: 'Active', maxConnections: 2),
        epg: {
          for (final c in _channels)
            c.epgId!: [
              EpgEntry(
                  channelEpgId: c.epgId!,
                  title: ['Tagesschau', 'heute journal', 'Explosiv', 'Arte Journal'][c.number - 1],
                  start: DateTime.now().subtract(const Duration(minutes: 12)),
                  end: DateTime.now().add(const Duration(minutes: 33))),
            ],
        },
      );

  Future<void> pump(WidgetTester tester, Widget home,
      {required bool tv,
      bool landscape = false,
      List<Recording> recs = const [],
      bool noDownloads = false}) async {
    tester.view.physicalSize = tv
        ? const Size(1920, 1080)
        : (landscape ? const Size(2280, 1080) : const Size(1080, 2280));
    tester.view.devicePixelRatio = tv ? 2 : 3;
    addTearDown(tester.view.reset);
    platform(tv: tv);
    await tester.pumpWidget(ProviderScope(
      overrides: tvOverrides(data(), Future.value(storage),
          tv: tv,
          recs: () => _Recs(recs),
          extra: [
            downloadsProvider
                .overrideWith(noDownloads ? _Empty.new : _Static.new),
            seriesDetailsProvider.overrideWith((ref, s) async =>
                const SeriesDetails(series: _serie, seasons: {1: _eps})),
            movieDetailsProvider.overrideWith((ref, m) async => m),
            playbackEngineProvider.overrideWithValue(FakeEngine.factory),
            mediaSessionProvider.overrideWithValue(NoopMediaSession()),
            exoAvailableProvider.overrideWithValue(true),
          ]),
      child: RepaintBoundary(
        key: tvShotKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          navigatorKey: appNavigatorKey,
          theme: buildTheme(tv: tv).copyWith(
              pageTransitionsTheme: TvSafePageTransitionsBuilder.theme()),
          builder: (context, child) => tv
              ? TvSafeMediaQuery(enabled: true, child: child!)
              : MiniPlayerHost(child: child!),
          home: home,
        ),
      ),
    ));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> done(WidgetTester tester) async {
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 12));
  }

  testWidgets('Handy: Film-Detail mit Download-Knopf', skip: skip,
      (tester) async {
    await pump(tester, const MovieDetailScreen(movie: _film), tv: false,
        noDownloads: true);
    await tester.pumpAndSettle();
    await _shot(tester, 'phone_movie_detail_download');
    await done(tester);
  });

  testWidgets('Handy: Film-Detail, Download heruntergeladen', skip: skip,
      (tester) async {
    await pump(tester, const MovieDetailScreen(movie: _film), tv: false);
    await tester.pumpAndSettle();
    await _shot(tester, 'phone_movie_detail_downloaded');
    await done(tester);
  });

  testWidgets('TV: Film-Detail mit Download-Knopf', skip: skip,
      (tester) async {
    await pump(tester, const MovieDetailScreen(movie: _film), tv: true,
        noDownloads: true);
    await tester.pumpAndSettle();
    // Fokus vom „Fortsetzen“ zum Download-Knopf.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await _shot(tester, 'tv_movie_detail_download');
    await done(tester);
  });

  testWidgets('Handy: Serie mit Staffel-Download und Folgen-Symbolen',
      skip: skip, (tester) async {
    await pump(tester, const SeriesDetailScreen(series: _serie), tv: false);
    await tester.pump(const Duration(seconds: 1));
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -420));
    await tester.pump(const Duration(seconds: 1));
    await _shot(tester, 'phone_series_detail_download');
    await done(tester);
  });

  testWidgets('Handy: Downloads-Seite', skip: skip, (tester) async {
    await storage.setResume('movie_101', 37 * 60, 112 * 60);
    await pump(tester, const DownloadsScreen(), tv: false);
    await tester.pump(const Duration(seconds: 1));
    await _shot(tester, 'phone_downloads');
    await done(tester);
  });

  testWidgets('TV: Downloads-Seite und Aktionsblatt', skip: skip,
      (tester) async {
    await pump(tester, const DownloadsScreen(), tv: true);
    await tester.pump(const Duration(seconds: 1));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump(const Duration(milliseconds: 400));
    await _shot(tester, 'tv_downloads');
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await _frames(tester, 800);
    await _shot(tester, 'tv_downloads_actions');
    await done(tester);
  });

  testWidgets('Handy: Einstellungen Aufnahmen & Downloads', skip: skip,
      (tester) async {
    await pump(tester, const Scaffold(body: SettingsScreen()), tv: false);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
        find.text('AUFNAHMEN & DOWNLOADS'), 400,
        scrollable: find.byType(Scrollable).first);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -60));
    await tester.pumpAndSettle();
    await _shot(tester, 'phone_settings_downloads');
    await done(tester);
  });

  Recording rec(Channel c) => Recording(
      id: '${c.id}_r',
      channelId: c.id,
      channelName: c.name,
      title: 'heute journal',
      start: DateTime.now().subtract(const Duration(minutes: 3)),
      end: DateTime.now().add(const Duration(minutes: 38)),
      status: 'läuft');

  Future<void> startLive(WidgetTester tester) async {
    unawaited(openPlayerAttached(PlayRequest(
        title: _channels[1].name,
        url: _channels[1].streamUrl,
        isLive: true,
        channels: _channels,
        channel: _channels[1])));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(PlayerScreen), findsOneWidget);
    FakeEngine.created.last.emit(width: 1920, buffering: false, playing: true);
    await tester.pump();
  }

  testWidgets('Handy: Aufnahme-Blatt und ● REC', skip: skip, (tester) async {
    await pump(tester, const Scaffold(body: SizedBox()),
        tv: false, landscape: true);
    await startLive(tester);
    await tester.tap(find.byKey(const ValueKey('record-btn')),
        warnIfMissed: false);
    await _frames(tester, 800);
    await _shot(tester, 'phone_player_record_sheet');
    await done(tester);
  });

  testWidgets('Handy: ● REC im Player', skip: skip, (tester) async {
    await pump(tester, const Scaffold(body: SizedBox()),
        tv: false, landscape: true, recs: [rec(_channels[1])]);
    await startLive(tester);
    await tester.pump(const Duration(milliseconds: 500));
    await _shot(tester, 'phone_player_rec_overlay');
    await _playFor(tester, 6);
    await _shot(tester, 'phone_player_rec');
    await done(tester);
  });

  testWidgets('TV: ● REC und Spuren-Blatt', skip: skip, (tester) async {
    await pump(tester, const Scaffold(body: SizedBox()),
        tv: true, recs: [rec(_channels[1])]);
    await startLive(tester);
    await _playFor(tester, 6);
    await _shot(tester, 'tv_player_rec');
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await _frames(tester, 400);
    await tester.tap(find.byIcon(Icons.subtitles_outlined).first,
        warnIfMissed: false);
    await _frames(tester, 800);
    final item = find.byKey(const ValueKey('track-record'));
    await tester.scrollUntilVisible(item, 80,
        scrollable: find.byType(Scrollable).last);
    await _frames(tester, 300);
    await _shot(tester, 'tv_tracks_record_entry');
    tester.widget<ListTile>(item).onTap!();
    await _frames(tester, 1000);
    await _shot(tester, 'tv_record_sheet_stop');
    await done(tester);
  });
}

Future<void> _frames(WidgetTester tester, int ms) async {
  for (var t = 0; t < ms; t += 50) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Wiedergabe „läuft“ (Position wächst) – sonst meldet der Wachhund ein
/// eingefrorenes Bild.
Future<void> _playFor(WidgetTester tester, int seconds) async {
  final e = FakeEngine.created.last;
  for (var i = 1; i <= seconds * 4; i++) {
    e.emit(position: Duration(milliseconds: 250 * i));
    await tester.pump(const Duration(milliseconds: 250));
  }
}

class _Empty extends DownloadsNotifier {
  @override
  List<DownloadItem> build() => const [];
}
