import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:jason_stream_player/core/secret_store.dart';
import 'package:jason_stream_player/data/db/catalog.dart';
import 'package:jason_stream_player/data/db/catalog_io.dart' show withCatalog;
import 'package:jason_stream_player/data/db/db_io.dart' as dbi;
import 'package:jason_stream_player/data/epg_cache/epg_cache.dart';
import 'package:jason_stream_player/data/list_cache.dart';
import 'package:jason_stream_player/data/storage.dart';
import 'package:jason_stream_player/l10n/strings.dart';
import 'package:jason_stream_player/models/models.dart';
import 'package:jason_stream_player/state/providers.dart';
import 'package:jason_stream_player/ui/guide/guide_screen.dart';
import 'package:jason_stream_player/ui/search/search_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/tv_harness.dart';

/// 2.0 auf dem Fernseher: TV-Guide „anderer Tag“ und Suche kommen aus der
/// Datenbank – Bedienung per Fernbedienung wie bisher.

const portal = Portal(
    id: 'tvdb',
    name: 'TV',
    type: PortalType.xtream,
    url: 'http://srv.example',
    username: 'u',
    password: 'p');

void main() {
  late Directory dir;
  late Storage storage;
  late TvData data;
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);

  final channels = [
    for (var i = 0; i < 450; i++)
      Channel(
          id: 'c$i',
          name: i == 2 ? 'Şahin TV' : 'Sender $i',
          categoryId: 'g',
          streamUrl: 'http://srv.example/live/u/p/$i.ts',
          epgId: 'e$i',
          number: i + 1,
          catchupDays: 7),
  ];
  // Programm −5 … +5 Tage, Titel mit Tag (z. B. „T-3 Sendung 14“).
  final full = {
    for (var i = 0; i < 450; i++)
      'e$i': [
        for (var h = -5 * 24; h < 5 * 24; h++)
          EpgEntry(
            channelEpgId: 'e$i',
            title: 'T${(h / 24).floor()} Sendung ${(h % 24 + 24) % 24}'
                '${i == 2 ? ' Münster' : ''}',
            start: today.add(Duration(hours: h)),
            end: today.add(Duration(hours: h + 1)),
            hasArchive: h < 0,
          ),
      ],
  };

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    L10n.lang = 'de';
    await initializeDateFormatting('de');
  });

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('db20tv_');
    ListCache.debugDirectory = dir.path;
    final path = '${dir.path}/${Catalog.fileName}';
    final info = withCatalog(path, (db) {
      dbi.writeLive(db, portal.id,
          fp: 'x', hash: 'h', saved: now,
          cats: const [Category(id: 'g', name: 'Alle')], items: channels);
      return dbi.writeEpg(db, portal.id, full, saved: now, hash: 'eh')!;
    });
    ListCache.noteStored(portal.id, 'live', true);
    EpgCache.dbBacked[portal.id] = true;
    EpgCache.info[portal.id] = info;
    SharedPreferences.setMockInitialValues({});
    storage = await Storage.open(store: PreviewSecretStore());
    data = TvData(
      live: LiveData(const [Category(id: 'g', name: 'Alle')], channels),
      // Im Speicher nur gestern … übermorgen (wie ab 2.0).
      epg: EpgCache.memoryWindow(full, now: now),
      portal: portal,
    );
  });

  tearDown(() {
    Catalog.closeWorker();
    ListCache.noteStored(portal.id, 'live', false);
    EpgCache.dbBacked.remove(portal.id);
    EpgCache.info.remove(portal.id);
    ListCache.debugDirectory = null;
    dir.deleteSync(recursive: true);
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('TV-Guide: Tag −3 aus der Datenbank, Fokus und ▼ wie bisher',
      (tester) async {
    await pumpTv(tester, const Scaffold(body: GuideScreen()), data, Future.value(storage));
    await settle(tester);
    final day = find.text('Heute');
    expect(day, findsWidgets);
    Focus.of(tester.element(day.first)).requestFocus();
    await tester.pump(const Duration(milliseconds: 200));
    await tvKey(tester, LogicalKeyboardKey.select);
    await settle(tester);
    expect(find.text('Tag wählen'), findsOneWidget);
    // Tage aus dem Stand der Datenbank (5 zurück … 5 voraus), nicht nur
    // aus dem Speicherfenster.
    expect(find.byKey(const ValueKey('guide_day_-5')), findsOneWidget);
    expect(find.byKey(const ValueKey('guide_day_4')), findsOneWidget);
    // Fernbedienung: Fokus auf „vor 3 Tagen“, OK.
    Focus.of(tester.element(find.descendant(
            of: find.byKey(const ValueKey('guide_day_-3')),
            matching: find.byType(Text))))
        .requestFocus();
    await tester.pump(const Duration(milliseconds: 100));
    await tvKey(tester, LogicalKeyboardKey.select);
    await settle(tester);
    expect(find.text('Tag wählen'), findsNothing);
    // Programm von vor 3 Tagen steht im Raster (aus der Datenbank).
    // (Kopfzeile darf noch die zuvor fokussierte Sendung zeigen.)
    expect(find.textContaining('T-3 Sendung').evaluate().length, greaterThan(10));
    expect(find.textContaining('T0 Sendung').evaluate().length, lessThanOrEqualTo(1));
    // Fernbedienung: ▼ springt in die nächste Zeile, Fokus bleibt im Raster.
    final before = FocusManager.instance.primaryFocus;
    await tvKey(tester, LogicalKeyboardKey.arrowDown);
    await tvKey(tester, LogicalKeyboardKey.arrowDown);
    final after = FocusManager.instance.primaryFocus;
    expect(after, isNotNull);
    expect(identical(before, after), isFalse);
    expect(tester.takeException(), isNull);
    await tvDone(tester);
  });

  testWidgets('Suche: Treffer aus der Datenbank, Türkisch gefaltet, Archiv',
      (tester) async {
    await pumpTv(tester, const Scaffold(body: SearchScreen()), data, Future.value(storage));
    await settle(tester);
    final field = find.byType(TextField);
    await tester.tap(field); // TV: Antippen startet die Eingabe
    await tester.pump();
    await tester.enterText(field, 'sahin');
    await tester.pump(SearchScreen.debounceTv);
    await settle(tester);
    // Sender „Şahin TV“ (ohne ş getippt) …
    expect(find.text('Şahin TV'), findsWidgets);
    await tester.enterText(field, 'munster');
    await tester.pump(SearchScreen.debounceTv);
    await settle(tester);
    // … und Sendungen „… Münster“ auch aus dem Archiv (älter als gestern –
    // das liegt nur in der Datenbank).
    expect(find.textContaining('Münster'), findsWidgets);
    expect(tester.takeException(), isNull);
    await tvDone(tester);
  });
}
