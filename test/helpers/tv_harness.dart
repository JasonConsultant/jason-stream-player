import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:jason_stream_player/core/theme.dart';
import 'package:jason_stream_player/data/recordings/recordings.dart';
import 'package:jason_stream_player/data/storage.dart';
import 'package:jason_stream_player/models/models.dart';
import 'package:jason_stream_player/state/my_groups.dart';
import 'package:jason_stream_player/state/providers.dart';
import 'package:jason_stream_player/state/vod_library.dart';
import 'package:jason_stream_player/ui/tv/tv_safe.dart';
import 'package:jason_stream_player/ui/widgets/live_preview.dart';

/// Gemeinsamer Aufbau für TV-Oberflächentests mit frei wählbaren Daten
/// (Senderliste, EPG, Filme …) – wie app.dart auf dem Fernseher.

class TvData {
  final LiveData live;
  final Map<String, List<EpgEntry>> epg;
  final ChannelFlags flags;
  final List<String> recent;
  final VodData movies;
  final VodData series;
  final Portal portal;
  const TvData({
    required this.live,
    this.epg = const {},
    this.flags = ChannelFlags.empty,
    this.recent = const [],
    this.movies = const VodData([], []),
    this.series = const VodData([], []),
    this.portal = Portal.demo,
  });
}

class _Live extends LiveNotifier {
  final LiveData d;
  _Live(this.d);
  @override
  Future<LiveData> build() async => d;
}

class _Epg extends EpgNotifier {
  /// Zuletzt gebauter Test-EPG-Notifier (für [tvEpgBump]).
  static _Epg? last;
  final Map<String, List<EpgEntry>> data;
  _Epg(this.data);
  @override
  Future<Map<String, List<EpgEntry>>> build() async {
    last = this;
    return data;
  }

  @override
  void want(Channel c) {}
}

/// Wie ein nachgeladenes Kurz-EPG: neue Map mit zusätzlichem Sender [key],
/// alle übrigen Programmlisten unverändert (gleiche Instanzen).
void tvEpgBump(String key, [List<EpgEntry> entries = const []]) {
  final n = _Epg.last!;
  // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
  final cur = n.state.value ?? const <String, List<EpgEntry>>{};
  // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
  n.state = AsyncData({...cur, key: entries});
}

class _Flags extends ChannelFlagsNotifier {
  final ChannelFlags f;
  _Flags(this.f);
  @override
  Future<ChannelFlags> build() async => f;
}

class _Sort extends SortOrderNotifier {
  @override
  Future<SortOrder> build() async => SortOrder.empty;
}

class _Recent extends RecentNotifier {
  final List<String> r;
  _Recent(this.r);
  @override
  Future<List<String>> build() async => r;
}

class _Groups extends MyGroupsNotifier {
  @override
  Future<List<MyGroup>> build() async => const [];
}

class _Lib extends VodLibraryNotifier {
  @override
  Future<VodLibrary> build() async => VodLibrary.empty;
}

class _Vod extends VodNotifier {
  final VodData d;
  _Vod(super.series, this.d);
  @override
  Future<VodData> build() async => d;
}

class _Active extends ActivePortalNotifier {
  final Portal p;
  _Active(this.p);
  @override
  Future<Portal?> build() async => p;
}

class _Portals extends PortalsNotifier {
  final Portal p;
  _Portals(this.p);
  @override
  Future<List<Portal>> build() async => [p];
}

class _Recs extends RecordingsNotifier {
  @override
  List<Recording> build() => const [];
}

class _NoPreview extends LivePreviewController {
  _NoPreview(super.ref);
  @override
  Future<void> play(Object owner, Channel c) async {}
}

/// [tick]: eigener Minutentakt (Standard: ein einzelner Wert).
/// [tv]: false = Handy/Tablet-Oberfläche mit denselben Daten.
List<Override> tvOverrides(TvData d, Future<Storage> storage,
        {Stream<DateTime>? tick, bool tv = true}) =>
    [
      isTvProvider.overrideWithValue(tv),
      storageProvider.overrideWith((ref) => storage),
      activePortalProvider.overrideWith(() => _Active(d.portal)),
      portalsProvider.overrideWith(() => _Portals(d.portal)),
      repositoryProvider.overrideWith((ref) async => null),
      liveDataProvider.overrideWith(() => _Live(d.live)),
      epgProvider.overrideWith(() => _Epg(d.epg)),
      channelFlagsProvider.overrideWith(() => _Flags(d.flags)),
      sortOrderProvider.overrideWith(_Sort.new),
      recentProvider.overrideWith(() => _Recent(d.recent)),
      myGroupsProvider.overrideWith(_Groups.new),
      vodLibraryProvider.overrideWith(_Lib.new),
      moviesProvider.overrideWith(() => _Vod(false, d.movies)),
      seriesProvider.overrideWith(() => _Vod(true, d.series)),
      recordingsProvider.overrideWith(_Recs.new),
      minuteTickProvider
          .overrideWith((ref) => tick ?? Stream.value(DateTime.now())),
      livePreviewEnabledProvider.overrideWith((ref) async => false),
      livePreviewProvider.overrideWith(_NoPreview.new),
    ];

final tvShotKey = GlobalKey();

/// TV-Oberfläche (1920×1080, dpr 2, sicherer Bereich wie app.dart).
Future<void> pumpTv(WidgetTester tester, Widget home, TvData d,
    Future<Storage> storage,
    {Stream<DateTime>? tick, bool tv = true, Size? size}) async {
  tester.view.physicalSize = size ?? const Size(1920, 1080);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    overrides: tvOverrides(d, storage, tick: tick, tv: tv),
    child: RepaintBoundary(
      key: tvShotKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(tv: tv).copyWith(
            pageTransitionsTheme: TvSafePageTransitionsBuilder.theme()),
        builder: (context, child) =>
            TvSafeMediaQuery(enabled: tv, child: child!),
        home: home,
      ),
    ),
  ));
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> tvKey(WidgetTester tester, LogicalKeyboardKey k) async {
  await tester.sendKeyEvent(k);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> tvDone(WidgetTester tester) async {
  expect(tester.takeException(), isNull);
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 5));
}
