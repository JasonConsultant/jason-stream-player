import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:jason_stream_player/core/secret_store.dart';
import 'package:jason_stream_player/data/storage.dart';
import 'package:jason_stream_player/l10n/strings.dart';
import 'package:jason_stream_player/models/models.dart';
import 'package:jason_stream_player/state/providers.dart';
import 'package:jason_stream_player/ui/guide/guide_screen.dart';
import 'package:jason_stream_player/ui/home/home_screen.dart';
import 'package:jason_stream_player/ui/live/live_screen.dart';
import 'package:jason_stream_player/ui/vod/vod_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/app_fonts.dart';
import 'helpers/tv_harness.dart';

/// 1.5 „Tempo“: Bildschirmfotos von Live TV, TV-Guide, Startseite und
/// Filmen (TV, 1920×1080, dpr 2, echte Schriften), jeweils mit Fokus –
/// zum Vergleich vorher/nachher (günstigere TV-Effekte sollen fast gleich
/// aussehen). Nur mit `TV_SHOTS=ordner`.

final _shotDir = Platform.environment['TV_SHOTS'];

const _names = [
  'Das Erste HD', 'ZDF HD', 'RTL HD', 'SAT.1 HD', 'ProSieben HD', 'VOX HD',
  'kabel eins HD', 'RTLZWEI HD', 'arte HD', '3sat HD', 'phoenix HD',
  'n-tv HD', 'WELT HD', 'KiKA HD', 'Sky Sport 1 HD', 'DAZN 1 HD',
  'Eurosport 1 HD', 'ORF 1 HD', 'SRF 1 HD', 'TRT 1 HD', 'Show TV', 'ATV HD',
];

final _cats = [
  const Category(id: 'de', name: 'DE · Vollprogramm'),
  const Category(id: 'info', name: 'DE · Info & Doku'),
  const Category(id: 'sport', name: 'Sport'),
  const Category(id: 'int', name: 'AT · CH · TR'),
];

String _cat(int i) => i < 8
    ? 'de'
    : i < 14
        ? 'info'
        : i < 17
            ? 'sport'
            : 'int';

final _channels = [
  for (var i = 0; i < _names.length; i++)
    Channel(
      id: 'c$i',
      name: _names[i],
      categoryId: _cat(i),
      streamUrl: 'http://s/$i',
      number: i + 1,
      catchupDays: i % 3 == 0 ? 7 : 0,
    ),
];

const _titles = [
  'Tagesschau', 'heute journal', 'Wer wird Millionär?', 'Navy CIS',
  'Die Höhle der Löwen', 'Bundesliga Konferenz', 'Markus Lanz',
  'Terra X', 'Tatort', 'Sportschau', 'Der Bergdoktor', 'Galileo',
];

Map<String, List<EpgEntry>> _epg(DateTime now) {
  final base = DateTime(now.year, now.month, now.day, now.hour)
      .subtract(const Duration(hours: 4));
  return {
    for (var i = 0; i < _channels.length; i++)
      if (i != 6) // ein Sender ohne Programm
        '@c$i': [
          for (var p = 0, t = base; p < 16; p++)
            EpgEntry(
              channelEpgId: '@c$i',
              title: _titles[(i + p) % _titles.length],
              genre: p.isEven ? 'Show' : 'Nachrichten',
              description: 'Beschreibung der Sendung mit etwas Text, wie '
                  'sie in echten EPG-Daten vorkommt.',
              start: t = base.add(Duration(minutes: p * 45 + (i % 3) * 15)),
              end: t.add(const Duration(minutes: 45)),
            ),
        ],
  };
}

final _movies = VodData([
  const Category(id: 'm1', name: 'Neu im Kino'),
  const Category(id: 'm2', name: 'Action'),
  const Category(id: 'm3', name: 'Komödie'),
], [
  for (var i = 0; i < 40; i++)
    VodItem(
      id: 'm$i',
      name: [
        'Die Stunde der Wölfe', 'Nebelgrenze', 'Orbit 9', 'Kalter Hafen',
        'Signal aus der Tiefe', 'Die Glasstadt', 'Feuerlinie', 'Funkel',
      ][i % 8],
      categoryId: 'm${1 + i % 3}',
      streamUrl: 'http://s/m$i',
      year: 2015 + i % 10,
      rating: 5 + (i % 5),
      genre: i.isEven ? 'Drama' : 'Action',
    ),
]);

Future<void> _shot(WidgetTester tester, String name) =>
    writeShot(tester, tvShotKey, name);

void main() {
  late Storage storage;
  late TvData data;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    L10n.lang = 'de';
    await initializeDateFormatting('de');
    await loadAppFonts();
    if (_shotDir != null) Directory(_shotDir!).createSync(recursive: true);
    data = TvData(
      live: LiveData(_cats, _channels),
      epg: _epg(DateTime.now()),
      recent: const ['c1', 'c4', 'c8', 'c14', 'c2'],
      flags: const ChannelFlags({'c0', 'c3', 'c9'}, {}, {}),
      movies: _movies,
    );
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    storage = await Storage.open(store: PreviewSecretStore());
  });

  final skip = _shotDir == null;

  testWidgets('Live TV', skip: skip, (tester) async {
    await pumpTv(tester, const Scaffold(body: LiveScreen()), data,
        Future.value(storage));
    await tvKey(tester, LogicalKeyboardKey.arrowDown);
    await tvKey(tester, LogicalKeyboardKey.arrowDown);
    await _shot(tester, 's15_live');
    await tvDone(tester);
  });

  testWidgets('TV-Guide', skip: skip, (tester) async {
    await pumpTv(tester, const Scaffold(body: GuideScreen()), data,
        Future.value(storage));
    await tvKey(tester, LogicalKeyboardKey.arrowDown);
    await tvKey(tester, LogicalKeyboardKey.arrowDown);
    await tvKey(tester, LogicalKeyboardKey.arrowRight);
    await tvKey(tester, LogicalKeyboardKey.arrowRight);
    await _shot(tester, 's15_guide');
    // Weiter nach rechts, bis das Raster verschiebt (Titel bleiben am Rand).
    for (var i = 0; i < 4; i++) {
      await tvKey(tester, LogicalKeyboardKey.arrowRight);
    }
    await _shot(tester, 's15_guide_scrolled');
    await tvDone(tester);
  });

  testWidgets('Startseite', skip: skip, (tester) async {
    await pumpTv(tester, Scaffold(body: HomeScreen(onOpenTab: (_) {})), data,
        Future.value(storage));
    await _shot(tester, 's15_home');
    await tvKey(tester, LogicalKeyboardKey.arrowDown);
    await _shot(tester, 's15_home_cards');
    await tvDone(tester);
  });

  // Tablet (kein TV): gleiche Bildschirme mit Touch-/Tastatur-Layout.
  testWidgets('Tablet: Live TV und TV-Guide', skip: skip, (tester) async {
    await pumpTv(tester, const Scaffold(body: LiveScreen()), data,
        Future.value(storage),
        tv: false, size: const Size(2560, 1600));
    await tvKey(tester, LogicalKeyboardKey.arrowDown);
    await tvKey(tester, LogicalKeyboardKey.arrowDown);
    await _shot(tester, 's15_tablet_live');
    await tvDone(tester);
    await pumpTv(tester, const Scaffold(body: GuideScreen()), data,
        Future.value(storage),
        tv: false, size: const Size(2560, 1600));
    // Raster nach links ziehen (Titel bleiben am linken Rand stehen).
    await tester.drag(find.byType(ListView).last, const Offset(-300, 0));
    await tester.pump(const Duration(milliseconds: 300));
    await _shot(tester, 's15_tablet_guide');
    await tvDone(tester);
  });

  testWidgets('Filme', skip: skip, (tester) async {
    await pumpTv(tester, const Scaffold(body: VodScreen(series: false)), data,
        Future.value(storage));
    await tvKey(tester, LogicalKeyboardKey.arrowDown);
    await tvKey(tester, LogicalKeyboardKey.arrowDown);
    await tvKey(tester, LogicalKeyboardKey.arrowRight);
    await _shot(tester, 's15_vod');
    await tvDone(tester);
  });
}
