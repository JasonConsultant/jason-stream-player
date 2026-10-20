import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jason_stream_player/l10n/strings.dart';
import 'package:jason_stream_player/l10n/translations.g.dart';

import '../tool/gen_l10n.dart' as gen;

/// Liest Dart-Stringliterale ab [i] (inkl. benachbarter Literale, die Dart
/// zusammenfügt). Liefert null, wenn kein konstantes Literal folgt.
String? _readLiterals(String src, int i) {
  final buf = StringBuffer();
  var found = false;
  while (true) {
    // Leerraum und Kommentare überspringen.
    while (i < src.length) {
      if (src.startsWith('//', i)) {
        i = src.indexOf('\n', i);
        if (i < 0) i = src.length;
      } else if (src.startsWith('/*', i)) {
        i = src.indexOf('*/', i) + 2;
      } else if (src[i].trim().isEmpty) {
        i++;
      } else {
        break;
      }
    }
    if (i >= src.length) break;
    var raw = false;
    if (src[i] == 'r' && i + 1 < src.length && (src[i + 1] == "'" || src[i + 1] == '"')) {
      raw = true;
      i++;
    }
    final q = src[i];
    if (q != "'" && q != '"') break;
    final triple = src.startsWith('$q$q$q', i);
    final end = triple ? '$q$q$q' : q;
    i += end.length;
    while (!src.startsWith(end, i)) {
      final ch = src[i];
      if (ch == r'\' && !raw) {
        final n = src[i + 1];
        const simple = {'n': '\n', 't': '\t', 'r': '\r', 'b': '\b', 'f': '\f', 'v': '\v'};
        if (n == 'u') {
          if (src[i + 2] == '{') {
            final close = src.indexOf('}', i);
            buf.writeCharCode(int.parse(src.substring(i + 3, close), radix: 16));
            i = close + 1;
          } else {
            buf.writeCharCode(int.parse(src.substring(i + 2, i + 6), radix: 16));
            i += 6;
          }
          continue;
        }
        buf.write(simple[n] ?? n);
        i += 2;
        continue;
      }
      if (ch == r'$' && !raw) return null; // Interpolation → nicht konstant.
      buf.write(ch);
      i++;
    }
    i += end.length;
    found = true;
  }
  return found ? buf.toString() : null;
}

void main() {
  final deArb = gen.readArb('de');
  final de = gen.arbMessages(deArb);
  final deTexts = de.values.toSet();

  test('en und tr haben genau die deutschen Quelltexte als Schlüssel', () {
    for (final lang in gen.targetLangs) {
      expect(translations[lang]!.keys.toSet(), deTexts, reason: lang);
      final arbKeys = gen.arbMessages(gen.readArb(lang)).keys.toSet();
      expect(arbKeys, de.keys.toSet(), reason: 'app_$lang.arb');
    }
  });

  test('Platzhalter stimmen überein', () {
    for (final lang in gen.targetLangs) {
      translations[lang]!.forEach((src, value) {
        expect(gen.placeholdersOf(value), gen.placeholdersOf(src),
            reason: '$lang: "$src"');
      });
    }
  });

  test('alle tr()/trf()-Texte im Code sind übersetzt', () {
    // L10n.tables enthält zusätzlich evtl. noch manuell gepflegte Tabellen
    // (z. B. tables_e.dart), die noch nicht in die ARB-Dateien gewandert sind.
    final extra = {for (final m in L10n.tables.values) ...m.keys};
    final call = RegExp(r'(?<![\w.$])trf?\(');
    final missing = <String>[];
    var count = 0;
    for (final f in Directory('lib').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      if (f.path.endsWith('.g.dart')) continue;
      final src = f.readAsStringSync();
      for (final m in call.allMatches(src)) {
        final text = _readLiterals(src, m.end);
        if (text == null) continue;
        count++;
        if (!deTexts.contains(text) && !extra.contains(text)) {
          missing.add('${f.path}: "$text"');
        }
      }
    }
    expect(count, greaterThan(100), reason: 'Scanner findet keine Aufrufe');
    expect(missing, isEmpty, reason: 'Fehlt in app_de.arb');
  });

  test('translations.g.dart ist aktuell', () {
    final expected = gen.generateFromDisk();
    final actual = File(gen.outFile).readAsStringSync();
    expect(actual, expected,
        reason: 'Bitte `dart run tool/gen_l10n.dart` ausführen.');
  });
}
