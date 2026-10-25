import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;
import 'package:flutter_test/flutter_test.dart';
import 'package:jason_stream_player/core/secret_store.dart';
import 'package:jason_stream_player/data/db/catalog.dart';
import 'package:jason_stream_player/data/list_cache.dart';
import 'package:jason_stream_player/data/storage.dart';
import 'package:jason_stream_player/models/models.dart';
import 'package:jason_stream_player/state/channel_variants.dart';
import 'package:jason_stream_player/state/content_filter.dart';
import 'package:jason_stream_player/state/my_groups.dart';
import 'package:jason_stream_player/state/profile_mode.dart';
import 'package:jason_stream_player/state/providers.dart';
import 'package:jason_stream_player/ui/search/search_engine.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/stress_data.dart';

/// 2.0: Listen aus der Datenbank verhalten sich exakt wie die Listen im
/// Speicher – Varianten, Favoriten, Verstecken, Länder-/Kinderfilter,
/// Reihenfolge und damit Zapping (CH±, Ziffern) sind identisch.

const portal = Portal(
  id: 'dbl',
  name: 'DB',
  type: PortalType.xtream,
  url: 'http://srv.example:8080',
  username: 'u1',
  password: 'p1',
);

final _live = () {
  final d = stressLive(channels: 4500, groups: 60, seed: 7);
  // Zugangsdaten in den Adressen, Kopfzeilen, Catch-up wie bei Xtream.
  return LiveData(d.categories, [
    for (final c in d.channels)
      Channel(
        id: c.id,
        name: c.name,
        categoryId: c.categoryId,
        streamUrl: c.streamUrl.replaceFirst('/u/p/', '/u1/p1/'),
        logoUrl: c.logoUrl,
        epgId: c.epgId,
        number: c.number,
        catchupDays: c.number % 9 == 0 ? 3 : 0,
        headers: c.number % 50 == 0 ? const {'User-Agent': 'Box'} : null,
      ),
  ]);
}();

class _Active extends ActivePortalNotifier {
  @override
  Future<Portal?> build() async => portal;
}

class _MemLive extends LiveNotifier {
  @override
  Future<LiveData> build() async => _live;
}

class _Groups extends MyGroupsNotifier {
  @override
  Future<List<MyGroup>> build() async => const [
        MyGroup('my_1', 'Meine', ['c3', 'c40', 'c41']),
      ];
}

class _NoVod extends VodNotifier {
  _NoVod(super.series);
  @override
  Future<VodData> build() async => const VodData([], []);
}

List<String> ids(Iterable<Channel> l) => [for (final c in l) c.id];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('db20lists_');
    ListCache.debugDirectory = dir.path;
    // Wie nach einem Abruf vom Portal: im Isolate gespeichert.
    final out = ListCache.finishLive(
        await ListCache.spec('live', portal), _live.categories, _live.channels);
    expect(out.stored, isTrue);
  });
  tearDown(() {
    Catalog.closeWorker();
    ListCache.debugDirectory = null;
    dir.deleteSync(recursive: true);
  });

  Future<(ProviderContainer, ProviderContainer)> pair(
      Map<String, Object> prefs) async {
    SharedPreferences.setMockInitialValues(prefs);
    final st = await Storage.open(store: PreviewSecretStore());
    ProviderContainer make(bool fromDb) {
      final c = ProviderContainer(overrides: [
        storageProvider.overrideWith((ref) async => st),
        activePortalProvider.overrideWith(_Active.new),
        if (!fromDb) liveDataProvider.overrideWith(_MemLive.new),
        myGroupsProvider.overrideWith(_Groups.new),
        moviesProvider.overrideWith(() => _NoVod(false)),
        seriesProvider.overrideWith(() => _NoVod(true)),
      ]);
      addTearDown(c.dispose);
      for (final p in <ProviderListenable<Object?>>[
        visibleLiveDataProvider,
        variantIndexProvider,
        channelFlagsProvider,
        sortOrderProvider,
      ]) {
        c.listen(p, (_, __) {});
      }
      return c;
    }

    final db = make(true), mem = make(false);
    for (final c in [db, mem]) {
      await c.read(storageProvider.future);
      await c.read(liveDataProvider.future);
      await c.read(channelFlagsProvider.future);
      await c.read(myGroupsProvider.future);
      await c.read(sortOrderProvider.future);
      // Varianten-Gruppierung großer Listen im Hintergrund abwarten.
      for (var i = 0;
          i < 200 && !c.read(visibleLiveDataProvider).hasValue;
          i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }
    return (db, mem);
  }

  void same(ProviderContainer a, ProviderContainer b, String what) {
    final x = a.read(visibleLiveDataProvider).value!;
    final y = b.read(visibleLiveDataProvider).value!;
    expect(ids(x.channels), ids(y.channels), reason: what);
    expect([for (final c in x.categories) c.id],
        [for (final c in y.categories) c.id], reason: what);
  }

  test('Rohliste aus der DB = Liste im Speicher (alle Felder)', () async {
    final (db, mem) = await pair({});
    expect(ListCache.inDb(portal.id, 'live'), isTrue);
    final a = db.read(liveDataProvider).value!.channels;
    final b = mem.read(liveDataProvider).value!.channels;
    expect(a.length, b.length);
    for (var i = 0; i < a.length; i++) {
      final x = a[i], y = b[i];
      expect([x.id, x.name, x.categoryId, x.streamUrl, x.logoUrl, x.epgId,
        x.number, x.catchupDays, x.headers, x.epgShift],
          [y.id, y.name, y.categoryId, y.streamUrl, y.logoUrl, y.epgId,
        y.number, y.catchupDays, y.headers, y.epgShift], reason: 'Index $i');
    }
  });

  test('Varianten, Favoriten, Verstecken, Länder- und Kinderfilter identisch', () async {
    final (db, mem) = await pair({});
    same(db, mem, 'Standard (Varianten zusammengefasst)');
    // Favoriten + verstecken (Varianten-Vertreter folgt Favorit/Versteck).
    // Gemeinsamer Speicher: einmal ändern, im anderen Container neu lesen.
    await db.read(channelFlagsProvider.notifier).toggleFavorite('c12');
    await db.read(channelFlagsProvider.notifier).toggleHidden('c13');
    await mem.read(channelFlagsProvider.notifier).refresh();
    expect(mem.read(channelFlagsProvider).value!.favorites, contains('c12'));
    same(db, mem, 'Favorit/versteckt');
    for (final c in [db, mem]) {
      await c.read(countryFilterProvider.notifier).set({'TR', 'DE'});
    }
    same(db, mem, 'Länderfilter');
    final st = await db.read(storageProvider.future);
    await st.setKidsGroups(portal.id, {'g3', 'g7', 'my_1'});
    for (final c in [db, mem]) {
      await c.read(profileModeProvider.notifier).setKids(true);
      c.invalidate(profileModeProvider);
    }
    same(db, mem, 'Kindermodus');
    for (final c in [db, mem]) {
      await c.read(mergeVariantsProvider.notifier).set(false);
    }
    same(db, mem, 'ohne Varianten');
  });

  test('Zapping: Gruppenliste, Reihenfolge, CH±, Ziffern identisch', () async {
    final (db, mem) = await pair({});
    for (final c in [db, mem]) {
      final st = await c.read(storageProvider.future);
      await st.setChannelOrder(portal.id, 'g5', ['c3005', 'c5', 'c65']);
      c.invalidate(sortOrderProvider);
      await c.read(sortOrderProvider.future);
    }
    List<Channel> group(ProviderContainer c) {
      final v = c.read(visibleLiveDataProvider).value!;
      final order = c.read(sortOrderProvider).value!;
      return order.sortChannels(
          'g5', v.channels.where((x) => x.categoryId == 'g5').toList());
    }

    final a = group(db), b = group(mem);
    expect(ids(a), ids(b));
    expect(a.length, greaterThan(20));
    // CH+/CH− wie im Player: Index ±1 mit Umlauf.
    for (var i = 0; i < a.length; i++) {
      final n = (i + 1) % a.length, p = (i - 1 + a.length) % a.length;
      expect(a[n].id, b[n].id);
      expect(a[p].id, b[p].id);
    }
    // Zifferneingabe: Sender mit dieser Nummer.
    for (final num in [1, 17, 4500]) {
      Channel? find(List<Channel> l) => l.where((c) => c.number == num).firstOrNull;
      final all = db.read(visibleLiveDataProvider).value!.channels;
      final allMem = mem.read(visibleLiveDataProvider).value!.channels;
      expect(find(all)?.id, find(allMem)?.id);
    }
  });

  test('Suche mit DB-Listen: gleiche Treffer wie im Speicher (plus Faltung)', () async {
    final (db, _) = await pair({});
    final visible = db.read(visibleLiveDataProvider).value!.channels;
    final memEngine = SearchEngine(
        channels: visible, epg: const {}, movies: const [], series: const [],
        buildPeople: false);
    final dbEngine = SearchEngine(
        channels: visible, epg: const {}, movies: const [], series: const [],
        buildPeople: false,
        db: SearchDb(portal: portal.id, live: true));
    final now = DateTime.now();
    for (final q in ['zdf', 'sky sport', 'hd', 'trt', 'kanal d', 'xyz']) {
      final a = (await dbEngine.searchAsync(q, now)).channels;
      final b = memEngine.search(q, now).channels;
      expect(ids(a), ids(b), reason: q);
    }
  });
}

