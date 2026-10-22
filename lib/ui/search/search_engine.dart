import '../../data/epg_matcher.dart' show epgKeyOf;
import '../../data/people_index.dart';
import '../../models/models.dart';
import '../../state/discover.dart' show People, peopleOf;

typedef SearchShow = ({Channel channel, EpgEntry entry});

/// Schauspieler/in oder Regie mit allen (sichtbaren) Titeln.
class PersonHit {
  final String name;
  final List<VodItem> titles;
  final bool director;
  const PersonHit(this.name, this.titles, {this.director = false});
}

class SearchResults {
  final List<Channel> channels;
  final List<SearchShow> shows;
  final List<VodItem> films;
  final List<VodItem> series;
  final List<PersonHit> persons;
  const SearchResults(this.channels, this.shows, this.films, this.series,
      [this.persons = const []]);

  static const empty = SearchResults([], [], [], []);

  bool get isEmpty =>
      channels.isEmpty &&
      shows.isEmpty &&
      films.isEmpty &&
      series.isEmpty &&
      persons.isEmpty;
}

/// Suche über Sender, EPG-Sendungen, Filme und Serien – für große Anbieter
/// (50 000 Sender, 1 Mio. Sendungen, 100 000 Filme) ausgelegt:
/// - Kleinbuchstaben werden je Liste einmal berechnet (beim ersten Suchen),
///   gleiche Sendungstitel nur einmal (Serien wiederholen sich oft).
/// - Tippt man weiter („ta“ → „tat“ → „tatort“), wird nur noch in den
///   bisherigen Treffern gesucht.
class SearchEngine {
  final List<Channel> _channels;
  Map<String, List<EpgEntry>> _epg;
  final List<VodItem> _movies;
  final List<VodItem> _series;
  final Map<String, People> _people;

  SearchEngine({
    required List<Channel> channels,
    required Map<String, List<EpgEntry>> epg,
    required List<VodItem> movies,
    required List<VodItem> series,
    Map<String, People> people = const {},
    PeopleIndex? personIndex,
    bool buildPeople = true,
  })  : _channels = channels,
        _epg = epg,
        _movies = movies,
        _series = series,
        _people = people,
        _pidx = personIndex,
        _buildPeople = buildPeople;

  static const maxChannels = 40;
  static const maxShows = 60;
  static const maxVod = 30;
  static const maxPersons = 20;

  _Lane? _ch, _mv, _sr, _ti, _pe;

  /// Personen-Verzeichnis: fertig übergeben ([personIndex], im Hintergrund
  /// gebaut) oder – nur wenn [buildPeople] – hier sofort gebaut.
  PeopleIndex? _pidx;
  final bool _buildPeople;

  /// Personen aus Besetzung/Regie aller Titel (Listen + gemerkte
  /// Detailseiten).
  static PeopleIndex peopleIndexOf(
      List<VodItem> movies, List<VodItem> series, Map<String, People> cache) {
    final all = [...movies, ...series];
    final cast = List<String?>.filled(all.length, null);
    final director = List<String?>.filled(all.length, null);
    var any = false;
    for (var i = 0; i < all.length; i++) {
      final m = all[i];
      final p = cache.isEmpty ? null : peopleOf(m, cache);
      final c = p == null ? m.cast : p.cast;
      final d = p == null ? m.director : p.director;
      if (c == null && d == null) continue;
      cast[i] = c;
      director[i] = d;
      any = true;
    }
    if (!any) return PeopleIndex.empty;
    return PeopleIndex.buildSync(all, cast: cast, director: director);
  }

  /// Im Hintergrund fertig gewordenes Verzeichnis nachreichen (die
  /// übrigen Suchlisten bleiben erhalten).
  set personIndex(PeopleIndex? idx) {
    if (identical(idx, _pidx)) return;
    _pidx = idx;
    _pe = null;
  }

  List<PersonHit> _persons(String q) {
    final idx = _pidx;
    if (idx == null || idx.length == 0) return const [];
    _pe ??= _lane(idx.lower);
    final hits = _pe!.find(q);
    // Wortanfang vor Wortinnerem, dann mehr Titel zuerst.
    final top = hits.length > 5000 ? hits.sublist(0, 5000) : [...hits];
    final rank = <int, int>{
      for (final i in top)
        i: idx.lower[i].startsWith(q) || idx.lower[i].contains(' $q') ? 0 : 1,
    };
    top.sort((a, b) {
      final r = rank[a]!.compareTo(rank[b]!);
      if (r != 0) return r;
      return idx.countAt(b).compareTo(idx.countAt(a));
    });
    return [
      for (final i in top.take(maxPersons))
        PersonHit(idx.names[i], idx.titlesAt(i), director: idx.directorAt(i)),
    ];
  }

  /// Alle Titel einer Person (genauer Name, Groß/Klein egal).
  List<VodItem> titlesOf(String name) {
    _ensure();
    final idx = _pidx;
    if (idx == null) return const [];
    final i = idx.lower.indexOf(name.toLowerCase());
    return i < 0 ? const [] : idx.titlesAt(i);
  }

  /// Eindeutige Sendungstitel (klein) → Sendungen mit Sender.
  List<List<SearchShow>>? _titleHits;

  /// EPG, aus dem der Titel-Index gebaut ist (für [refreshEpg]).
  Map<String, List<EpgEntry>> get epg => _epg;

  /// Titel-Index gebaut (sonst beim ersten Suchen).
  bool get ready => _ch != null && _ti != null;

  _Lane _lane(List<String> lower) => _Lane(lower);

  void _ensure() {
    _ch ??= _lane([for (final c in _channels) c.name.toLowerCase()]);
    _mv ??= _lane([for (final m in _movies) m.name.toLowerCase()]);
    _sr ??= _lane([for (final m in _series) m.name.toLowerCase()]);
    if (_ti == null) {
      final (lane, hits) = _epgIndexSync(_epg);
      _ti = lane;
      _titleHits = hits;
    }
    if (_pidx == null && _buildPeople) {
      _pidx = peopleIndexOf(_movies, _series, _people);
    }
  }

  Map<String, Channel> _byEpgKey() =>
      {for (final c in _channels) epgKeyOf(c): c};

  (_Lane, List<List<SearchShow>>) _epgIndexSync(
      Map<String, List<EpgEntry>> epg) {
    final b = _EpgIndexBuilder(_byEpgKey());
    for (final e in epg.entries) {
      b.add(e.key, e.value);
    }
    return (_lane(b.titles), b.hits);
  }

  /// Index in Häppchen vorab bauen (Such-Tab geöffnet): Zwischendurch
  /// kommt die Oberfläche dran ([slice] je Stück), der erste Tastendruck
  /// findet den fertigen Index. [cancelled] bricht ab (z. B. neue Listen).
  Future<void> warmUp(
      {Duration slice = const Duration(milliseconds: 8),
      bool Function()? cancelled}) async {
    final sw = Stopwatch()..start();
    Future<bool> yieldIfDue() async {
      if (sw.elapsed < slice) return cancelled?.call() ?? false;
      await Future<void>.delayed(Duration.zero);
      sw.reset();
      return cancelled?.call() ?? false;
    }

    Future<_Lane?> lower(
        List<String> Function(int from, int to) part, int n) async {
      final out = <String>[];
      for (var i = 0; i < n; i += 4000) {
        out.addAll(part(i, i + 4000 > n ? n : i + 4000));
        if (await yieldIfDue()) return null;
      }
      return _lane(out);
    }

    if (_ch == null) {
      final l = await lower(
          (a, b) =>
              [for (var i = a; i < b; i++) _channels[i].name.toLowerCase()],
          _channels.length);
      if (l == null) return;
      _ch ??= l;
    }
    if (_mv == null) {
      final l = await lower(
          (a, b) => [for (var i = a; i < b; i++) _movies[i].name.toLowerCase()],
          _movies.length);
      if (l == null) return;
      _mv ??= l;
    }
    if (_sr == null) {
      final l = await lower(
          (a, b) => [for (var i = a; i < b; i++) _series[i].name.toLowerCase()],
          _series.length);
      if (l == null) return;
      _sr ??= l;
    }
    if (_ti == null) {
      await refreshEpg(_epg, slice: slice, cancelled: cancelled);
    }
  }

  /// Neues EPG übernehmen, ohne die Suche zu blockieren: Der Titel-Index
  /// wird in Häppchen gebaut und erst fertig ausgetauscht; bis dahin sucht
  /// die Suche im alten. false = abgebrochen ([cancelled]).
  Future<bool> refreshEpg(Map<String, List<EpgEntry>> epg,
      {Duration slice = const Duration(milliseconds: 8),
      bool Function()? cancelled}) async {
    final sw = Stopwatch()..start();
    final b = _EpgIndexBuilder(_byEpgKey());
    var n = 0;
    for (final e in epg.entries) {
      b.add(e.key, e.value);
      n += e.value.length;
      if (n >= 2000) {
        n = 0;
        if (sw.elapsed >= slice) {
          await Future<void>.delayed(Duration.zero);
          sw.reset();
          if (cancelled?.call() ?? false) return false;
        }
      }
    }
    if (cancelled?.call() ?? false) return false;
    _epg = epg;
    _ti = _lane(b.titles);
    _titleHits = b.hits;
    return true;
  }

  /// [q] bereits klein und getrimmt; unter 2 Zeichen: nichts.
  SearchResults search(String q, DateTime now) {
    if (q.length < 2) return SearchResults.empty;
    _ensure();
    final channels = [
      for (final i in _ch!.find(q, limit: maxChannels)) _channels[i],
    ];
    final from = now.subtract(const Duration(days: 7));
    final to = now.add(const Duration(days: 2));
    // Läuft gerade → demnächst → vergangen (neueste zuerst). Nur die
    // besten [maxShows] behalten (eingefügt statt alles zu sortieren –
    // bei kurzen Begriffen passen sonst Hunderttausende Sendungen).
    int rank(EpgEntry e) => e.isNowAt(now) ? 0 : e.start.isAfter(now) ? 1 : 2;
    int cmp(SearchShow a, SearchShow b) {
      final ra = rank(a.entry), rb = rank(b.entry);
      if (ra != rb) return ra.compareTo(rb);
      return ra == 2
          ? b.entry.start.compareTo(a.entry.start)
          : a.entry.start.compareTo(b.entry.start);
    }

    final shows = <SearchShow>[];
    for (final t in _ti!.find(q)) {
      for (final s in _titleHits![t]) {
        final p = s.entry;
        if (p.end.isBefore(from) || p.start.isAfter(to)) continue;
        // Vergangenes nur, wenn es im Archiv liegt.
        if (p.isPastAt(now) && !s.channel.hasCatchup) continue;
        if (shows.length == maxShows && cmp(s, shows.last) >= 0) continue;
        var lo = 0, hi = shows.length;
        while (lo < hi) {
          final mid = (lo + hi) >> 1;
          if (cmp(shows[mid], s) <= 0) {
            lo = mid + 1;
          } else {
            hi = mid;
          }
        }
        shows.insert(lo, s);
        if (shows.length > maxShows) shows.removeLast();
      }
    }
    return SearchResults(
      channels,
      shows,
      [for (final i in _mv!.find(q, limit: maxVod)) _movies[i]],
      [for (final i in _sr!.find(q, limit: maxVod)) _series[i]],
      q.length >= 3 ? _persons(q) : const [],
    );
  }
}

/// Sendungstitel einmal je Titel (klein) mit allen Sendungen dazu.
class _EpgIndexBuilder {
  final Map<String, Channel> byEpg;
  _EpgIndexBuilder(this.byEpg);
  final index = <String, int>{};
  final titles = <String>[];
  final hits = <List<SearchShow>>[];

  void add(String key, List<EpgEntry> list) {
    final c = byEpg[key];
    if (c == null) return;
    for (final p in list) {
      final i = index.putIfAbsent(p.title, () {
        titles.add(p.title.toLowerCase());
        hits.add(<SearchShow>[]);
        return titles.length - 1;
      });
      hits[i].add((channel: c, entry: p));
    }
  }
}

/// Eine durchsuchbare Liste (Kleinbuchstaben) mit Gedächtnis für die
/// letzte Suche: Wird der Begriff nur verlängert, genügen die alten Treffer.
class _Lane {
  final List<String> lower;
  _Lane(this.lower);

  String? _lastQ;
  List<int>? _last;

  /// Indizes aller Treffer (für die Weitersuche gemerkt); [limit] kürzt nur
  /// das Ergebnis.
  List<int> find(String q, {int? limit}) {
    final prevQ = _lastQ;
    final prev = _last;
    final List<int> hits;
    if (prevQ != null && prev != null && q.startsWith(prevQ)) {
      hits = [
        for (final i in prev)
          if (lower[i].contains(q)) i
      ];
    } else {
      hits = [
        for (var i = 0; i < lower.length; i++)
          if (lower[i].contains(q)) i
      ];
    }
    _lastQ = q;
    _last = hits;
    return limit == null || hits.length <= limit
        ? hits
        : hits.sublist(0, limit);
  }
}
