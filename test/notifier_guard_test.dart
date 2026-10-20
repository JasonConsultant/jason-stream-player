import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jason_stream_player/data/recordings/recordings.dart';
import 'package:jason_stream_player/models/models.dart';
import 'package:jason_stream_player/state/my_groups.dart';
import 'package:jason_stream_player/state/providers.dart';
import 'package:jason_stream_player/state/vod_library.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _ch = Channel(
    id: 'c1', name: 'Das Erste', categoryId: 'g', streamUrl: 'http://x/1.ts');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Aufnahme: dieselbe Sendung nicht doppelt planen', () async {
    SharedPreferences.setMockInitialValues({});
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final n = c.read(recordingsProvider.notifier);
    await c.read(storageProvider.future);
    final start = DateTime.now().add(const Duration(hours: 2));
    final e = EpgEntry(
        channelEpgId: 'c1',
        title: 'Tatort',
        start: start,
        end: start.add(const Duration(minutes: 90)));
    final r1 = await n.schedule(_ch, e);
    expect(r1, isNot(RecResult.duplicate));
    expect(await n.schedule(_ch, e), RecResult.duplicate);
    expect(c.read(recordingsProvider).length, 1);
    // Gespeicherter Start hat 2 Min. Vorlauf
    expect(c.read(recordingsProvider).first.start,
        start.subtract(const Duration(minutes: 2)));
  });

  test('Eigene Gruppen: Anlegen vor dem Laden löscht keine vorhandenen',
      () async {
    SharedPreferences.setMockInitialValues({
      'active_portal': '__demo',
      'set_mygroups___demo': jsonEncode([
        {'id': 'my_alt', 'n': 'Alt', 'c': <String>[]}
      ]),
    });
    final c = ProviderContainer();
    addTearDown(c.dispose);
    // Sofort schreiben, ohne auf den Ladevorgang zu warten.
    final g = await c.read(myGroupsProvider.notifier).create('Neu');
    final list = await c.read(myGroupsProvider.future);
    expect(list.map((x) => x.id), containsAll(['my_alt', g.id]));
  });

  test('Filme-Favoriten: Umschalten vor dem Laden behält den Verlauf',
      () async {
    SharedPreferences.setMockInitialValues({
      'active_portal': '__demo',
      'set_vodfav___demo': jsonEncode(['m:1']),
      'set_vodhist___demo': jsonEncode([
        {'s': false, 'id': '1', 't': 1},
      ]),
    });
    final c = ProviderContainer();
    addTearDown(c.dispose);
    const m = VodItem(id: '2', name: 'Film', categoryId: 'x', streamUrl: 'u');
    await c.read(vodLibraryProvider.notifier).toggleFavorite(m);
    final lib = await c.read(vodLibraryProvider.future);
    expect(lib.favorites, {'m:1', 'm:2'});
    expect(lib.history.length, 1);
  });
}
