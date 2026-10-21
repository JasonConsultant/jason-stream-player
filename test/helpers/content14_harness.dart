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

/// Aufbau für die 1.4-Tests (Entdecken, Serien, Nächste Folge): wie
/// tv_harness.dart, zusätzlich mit Verlauf und Serien-Details.

class C14Data {
  final LiveData live;
  final Map<String, List<EpgEntry>> epg;
  final VodData movies;
  final VodData series;
  final VodLibrary library;
  final Map<String, SeriesDetails> details;
  final bool tv;
  const C14Data({
    this.live = const LiveData([], []),
    this.epg = const {},
    this.movies = const VodData([], []),
    this.series = const VodData([], []),
    this.library = VodLibrary.empty,
    this.details = const {},
    this.tv = true,
  });
}

class _Live extends LiveNotifier {
  final LiveData d;
  _Live(this.d);
  @override
  Future<LiveData> build() async => d;
}

class _Epg extends EpgNotifier {
  final Map<String, List<EpgEntry>> data;
  _Epg(this.data);
  @override
  Future<Map<String, List<EpgEntry>>> build() async => data;
  @override
  void want(Channel c) {}
}

class _Flags extends ChannelFlagsNotifier {
  @override
  Future<ChannelFlags> build() async => ChannelFlags.empty;
}

class _Sort extends SortOrderNotifier {
  @override
  Future<SortOrder> build() async => SortOrder.empty;
}

class _Recent extends RecentNotifier {
  @override
  Future<List<String>> build() async => const [];
}

class _Groups extends MyGroupsNotifier {
  @override
  Future<List<MyGroup>> build() async => const [];
}

/// Verlauf wie im echten Notifier: im Gastmodus leer.
class _Lib extends VodLibraryNotifier {
  final VodLibrary l;
  _Lib(this.l);
  @override
  Future<VodLibrary> build() async {
    final st = await ref.watch(storageProvider.future);
    return st.guestMode ? VodLibrary.empty : l;
  }
}

class _Vod extends VodNotifier {
  final VodData d;
  _Vod(super.series, this.d);
  @override
  Future<VodData> build() async => d;
}

class _Active extends ActivePortalNotifier {
  @override
  Future<Portal?> build() async => Portal.demo;
}

class _Portals extends PortalsNotifier {
  @override
  Future<List<Portal>> build() async => const [Portal.demo];
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

List<Override> c14Overrides(C14Data d, Future<Storage> storage) => [
      isTvProvider.overrideWithValue(d.tv),
      storageProvider.overrideWith((ref) => storage),
      activePortalProvider.overrideWith(_Active.new),
      portalsProvider.overrideWith(_Portals.new),
      repositoryProvider.overrideWith((ref) async => null),
      liveDataProvider.overrideWith(() => _Live(d.live)),
      epgProvider.overrideWith(() => _Epg(d.epg)),
      channelFlagsProvider.overrideWith(_Flags.new),
      sortOrderProvider.overrideWith(_Sort.new),
      recentProvider.overrideWith(_Recent.new),
      myGroupsProvider.overrideWith(_Groups.new),
      vodLibraryProvider.overrideWith(() => _Lib(d.library)),
      moviesProvider.overrideWith(() => _Vod(false, d.movies)),
      seriesProvider.overrideWith(() => _Vod(true, d.series)),
      seriesDetailsProvider.overrideWith((ref, s) async =>
          d.details[s.id] ?? SeriesDetails(series: s, seasons: const {})),
      movieDetailsProvider.overrideWith((ref, m) async => m),
      recordingsProvider.overrideWith(_Recs.new),
      minuteTickProvider.overrideWith((ref) => Stream.value(DateTime.now())),
      livePreviewEnabledProvider.overrideWith((ref) async => false),
      livePreviewProvider.overrideWith(_NoPreview.new),
    ];

final c14ShotKey = GlobalKey();

/// TV (1920×1080, dpr 2) bzw. Handy (1080×2340, dpr 3).
Future<void> pumpC14(WidgetTester tester, Widget home, C14Data d,
    Future<Storage> storage) async {
  tester.view.physicalSize =
      d.tv ? const Size(1920, 1080) : const Size(1080, 2340);
  tester.view.devicePixelRatio = d.tv ? 2 : 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    overrides: c14Overrides(d, storage),
    child: RepaintBoundary(
      key: c14ShotKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(tv: d.tv).copyWith(
            pageTransitionsTheme: TvSafePageTransitionsBuilder.theme()),
        builder: (context, child) =>
            TvSafeMediaQuery(enabled: d.tv, child: child!),
        home: home,
      ),
    ),
  ));
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> c14Key(WidgetTester tester, LogicalKeyboardKey k) async {
  await tester.sendKeyEvent(k);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

/// Texte im fokussierten Element.
List<String> focusedTexts() {
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

/// Liegt der Fokus unter einem Widget mit diesem Schlüssel?
bool focusUnderKey(Key key) {
  final ctx = FocusManager.instance.primaryFocus?.context;
  if (ctx == null) return false;
  if (ctx.widget.key == key) return true;
  var found = false;
  ctx.visitAncestorElements((e) {
    if (e.widget.key == key) {
      found = true;
      return false;
    }
    return true;
  });
  return found;
}

/// Liegt der Fokus in einem Widget dieses Typs?
bool focusInType(String type) {
  final ctx = FocusManager.instance.primaryFocus?.context;
  if (ctx == null) return false;
  var found = false;
  ctx.visitAncestorElements((e) {
    if (e.widget.runtimeType.toString() == type) {
      found = true;
      return false;
    }
    return true;
  });
  return found;
}

/// Fokus auf das Element mit [key] (über einen Text darin).
Future<void> focusKey(WidgetTester tester, Key key) async {
  final text = find.descendant(of: find.byKey(key), matching: find.byType(Text));
  Focus.of(tester.element(text.first)).requestFocus();
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> c14Done(WidgetTester tester) async {
  expect(tester.takeException(), isNull);
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 5));
}
