import 'dart:isolate';
import 'dart:typed_data';

import '../models/models.dart';
import 'vod_meta.dart' show splitPeople;

/// Personen-Verzeichnis (Besetzung/Regie → Titel) für die Suche.
///
/// Bei großen Anbietern (100 000 Filme mit Besetzung) dauert das Zerlegen
/// der Namen Sekunden – deshalb baut [PeopleIndex.build] im Hintergrund
/// (eigener Isolate). Hinüber gehen nur die Texte, zurück nur Namen und
/// Zahlenlisten; die Titel selbst bleiben im Haupt-Isolate.
class PeopleIndex {
  /// Anzeigename (erste Schreibweise) je Person.
  final List<String> names;

  /// Kleingeschrieben, gleiche Reihenfolge – zum Durchsuchen.
  final List<String> lower;

  /// Positionen der Titel in [_source] je Person.
  final List<Int32List> _refs;

  /// 1 = nur als Regie bekannt.
  final Uint8List _director;
  final List<VodItem> _source;

  PeopleIndex._(this.names, this.lower, this._refs, this._director,
      this._source);

  static final empty = PeopleIndex._(
      const [], const [], const [], Uint8List(0), const []);

  int get length => names.length;
  int countAt(int i) => _refs[i].length;
  bool directorAt(int i) => _director[i] == 1;
  List<VodItem> titlesAt(int i) => [for (final r in _refs[i]) _source[r]];

  /// Sofort (im aufrufenden Isolate) – für kleine Listen und Tests.
  /// [cast]/[director] gehören positionsgleich zu [source].
  factory PeopleIndex.buildSync(List<VodItem> source,
      {required List<String?> cast, required List<String?> director}) {
    final p = _parse(cast, director);
    return PeopleIndex._(p.$1, p.$2, p.$3, p.$4, source);
  }

  /// Im Hintergrund bauen ([isolate] = false: wie [PeopleIndex.buildSync],
  /// z. B. in Widget-Tests ohne echte Isolates).
  static Future<PeopleIndex> build(List<VodItem> source,
      {required List<String?> cast,
      required List<String?> director,
      bool isolate = true}) async {
    if (!isolate || source.length < 2000) {
      return PeopleIndex.buildSync(source, cast: cast, director: director);
    }
    final p = await Isolate.run(() => _parse(cast, director),
        debugName: 'people-index');
    return PeopleIndex._(p.$1, p.$2, p.$3, p.$4, source);
  }
}

/// Zerlegt Besetzung/Regie aller Titel. Gleiche Texte nur einmal.
(List<String>, List<String>, List<Int32List>, Uint8List) _parse(
    List<String?> cast, List<String?> director) {
  final index = <String, int>{};
  final names = <String>[];
  final lower = <String>[];
  final refs = <List<int>>[];
  final dir = <bool>[];
  final memo = <String, List<String>>{};
  void add(String name, int title, bool isDirector) {
    final k = name.toLowerCase();
    final i = index.putIfAbsent(k, () {
      names.add(name);
      lower.add(k);
      refs.add(<int>[]);
      dir.add(isDirector);
      return names.length - 1;
    });
    final t = refs[i];
    if (t.isEmpty || t.last != title) t.add(title);
    if (!isDirector) dir[i] = false;
  }

  for (var m = 0; m < cast.length; m++) {
    final c = cast[m];
    if (c != null) {
      for (final n in memo.putIfAbsent(c, () => splitPeople(c))) {
        add(n, m, false);
      }
    }
    final d = m < director.length ? director[m] : null;
    if (d != null) {
      for (final n in memo.putIfAbsent(d, () => splitPeople(d))) {
        add(n, m, true);
      }
    }
    // Speicher sparen: Texte, die nur einmal vorkommen, nicht merken.
    if (memo.length > 50000) memo.clear();
  }
  return (
    names,
    lower,
    [for (final r in refs) Int32List.fromList(r)],
    Uint8List.fromList([for (final d in dir) d ? 1 : 0]),
  );
}
