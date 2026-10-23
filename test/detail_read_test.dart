import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:jason_stream_player/core/secret_store.dart';
import 'package:jason_stream_player/data/storage.dart';
import 'package:jason_stream_player/l10n/strings.dart';
import 'package:jason_stream_player/models/models.dart';
import 'package:jason_stream_player/state/providers.dart' show VodData;
import 'package:jason_stream_player/ui/vod/movie_detail_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/content14_harness.dart';

/// Fernseher: Beschreibung, Regie und Besetzung müssen mit der
/// Fernbedienung lesbar sein (▼ von den Knöpfen, ▲▼ blättern, ▲ zurück).
void main() {
  setUpAll(() async {
    L10n.lang = 'de';
    await initializeDateFormatting('de');
  });

  final plot = List.filled(40, 'Ein langer Satz der Beschreibung.').join(' ');
  final cast = List.generate(60, (i) => 'Schauspieler $i').join(',');
  final movie = VodItem(
    id: 'm1',
    name: 'Langer Film',
    categoryId: 'c',
    streamUrl: 'http://x/1.mp4',
    plot: plot,
    director: 'Regie Person',
    cast: cast,
    year: 2026,
  );

  Future<Storage> storage() {
    SharedPreferences.setMockInitialValues({'set_applang': 'de'});
    return Storage.open(store: PreviewSecretStore());
  }

  FocusNode? focus() => FocusManager.instance.primaryFocus;

  testWidgets('▼ markiert die Beschreibung, ▲▼ blättern, ▲ zurück zu Abspielen',
      (tester) async {
    final st = (await tester.runAsync(storage))!;
    await pumpC14(tester, MovieDetailScreen(movie: movie),
        C14Data(tv: true, movies: VodData(const [], [movie])), Future.value(st));
    await tester.pump(const Duration(milliseconds: 300));

    // Start: Abspielen hat den Fokus.
    expect(find.text('Abspielen'), findsOneWidget);
    final scroll = tester.state<ScrollableState>(find.byType(Scrollable).first);
    expect(scroll.position.pixels, 0);

    // ▼ (evtl. über weitere Knöpfe in derselben Zeile hinweg) → Textblock.
    for (var i = 0; i < 3 && focus()?.debugLabel != 'detail-info'; i++) {
      await c14Key(tester, LogicalKeyboardKey.arrowDown);
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(focus()?.debugLabel, 'detail-info');

    // Weitere ▼ blättern, bis das Ende der Besetzung sichtbar ist.
    final before = scroll.position.pixels;
    for (var i = 0; i < 12; i++) {
      await c14Key(tester, LogicalKeyboardKey.arrowDown);
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(scroll.position.pixels, greaterThan(before));
    expect(focus()?.debugLabel, 'detail-info', reason: 'bleibt im Text');
    // Besetzung mit Leerzeichen nach den Kommas.
    expect(find.textContaining('Schauspieler 1, Schauspieler 2'), findsOneWidget);

    // ▲ blättert zurück und landet schließlich wieder auf den Knöpfen.
    for (var i = 0; i < 20 && focus()?.debugLabel == 'detail-info'; i++) {
      await c14Key(tester, LogicalKeyboardKey.arrowUp);
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(focus()?.debugLabel, isNot('detail-info'));
    await c14Done(tester);
  });
}
