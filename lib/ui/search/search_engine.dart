import '../../data/db/catalog.dart';
import '../../data/epg_matcher.dart' show epgKeyOf;
import '../../data/people_index.dart';
import '../../data/search_norm.dart';
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

/// Welche Listen die Suche in der Katalog-Datenbank findet (FTS5) statt im
/// Speicher. Gesucht wird dort nach IDs; angezeigt werden nur Treffer, die
/// in den übergebenen (sichtbaren) Listen stehen – in deren Reihenfolge.
class SearchDb {
  /// Portal-ID (Sender, EPG, Portal-Filme/-Serien).
  final String portal;
  final bool live;
  final bool epg;

  /// Quellen (Portal-/Cache-ID, Art) für Filme bzw. Serien; null = im
  /// Speicher suchen.
  final List<(String, String)>? movies;
  final List<(String, String)>? series;

  /// Sender mit eigenem Namen (Anpassung) – deren Name steht nicht in der
  /// Datenbank: ID → Name.
  final Map<String, String> renamed;
  const SearchDb(
      {required this.portal,
      this.live = false,
      this.epg = false,
      this.movies,
      this.series,
      this.renamed = const {}});

  bool get any => live || epg || movies != null || series != null;

  /// Gleiche Quellen (für „Suchindex neu?“).
  String get signature =>
      '$portal|$live|$epg|$movies|$series|${renamed.length}';
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
    this.db,
  })  : _channels = channels,
        _epg = epg,
        _movies = movies,
        _series = series,
        _people = people,
        _pidx = personIndex,
        _buildPeople = buildPeople;

  /// Teile in der Datenbank (ab 2.0); null = alles im Speicher wie bisher.
  final SearchDb? db;

  /// Sucht (teilweise) in der Datenbank → [searchAsync] benutzen.
  bool get usesDb => db?.any ?? false;

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
    final d = db;
    // Teile aus der Datenbank brauchen keinen Index im Speicher.
    _ch ??= _lane(d != null && d.live
        ? const []
        : [for (final c in _channels) c.name.toLowerCase()]);
    _mv ??= _lane(d?.movies != null
        ? const []
        : [for (final m in _movies) m.name.toLowerCase()]);
    _sr ??= _lane(d?.series != null
        ? const []
        : [for (final m in _series) m.name.toLowerCase()]);
    if (_ti == null) {
      if (d != null && d.epg) {
        _ti = _lane(const []);
        _titleHits = const [];
      } else {
        final (lane, hits) = _epgIndexSync(_epg);
        _ti = lane;
        _titleHits = hits;
      }
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

    final d = db;
    if (d != null) {
      // Datenbank-Teile: nichts aufzubauen.
      if (d.live) _ch ??= _lane(const []);
      if (d.movies != null) _mv ??= _lane(const []);
      if (d.series != null) _sr ??= _lane(const []);
      if (d.epg && _ti == null) {
        _ti = _lane(const []);
        _titleHits = const [];
      }
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
    if (db?.epg ?? false) {
      // Programm liegt in der Datenbank: kein Titel-Index im Speicher.
      _epg = epg;
      return true;
    }
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

/// Datenbank-Teil der Suche (siehe [SearchDb]).
extension SearchEngineDb on SearchEngine {
  /// Wie [SearchEngine.search], Teile aus [SearchEngine.db] per FTS5 in der
  /// Datenbank (im Datenbank-Isolate – der UI-Thread wartet nicht).
  Future<SearchResults> searchAsync(String q, DateTime now) async {
    final d = db;
    final mem = search(q, now);
    if (d == null || !d.any || q.length < 2) return mem;
    final f = foldSearch(q);
    final st = _dbState;

    Future<List<Channel>> channels() async {
      if (!d.live) return mem.channels;
      final ids = await Catalog.searchChannelIds(d.portal, f);
      final idx = st.chIndex(_channels);
      final pos = <int>{};
      for (final id in ids) {
        final i = idx[id];
        if (i != null) pos.add(i);
      }
      // Umbenannte Sender: eigener Name statt Name aus der Liste.
      for (final e in d.renamed.entries) {
        final i = idx[e.key];
        if (i == null) continue;
        if (foldSearch(e.value).contains(f)) {
          pos.add(i);
        } else {
          pos.remove(i);
        }
      }
      final sorted = pos.toList()..sort();
      return [
        for (final i in sorted.take(SearchEngine.maxChannels)) _channels[i]
      ];
    }

    Future<List<VodItem>> vod(
        List<(String, String)>? src, List<VodItem> list, bool series) async {
      if (src == null) return series ? mem.series : mem.films;
      final idx = series ? st.srIndex(list) : st.mvIndex(list);
      final pos = <int>{};
      for (final (portal, kind) in src) {
        for (final id in await Catalog.searchVodIds(portal, kind, f)) {
          final i = idx[id];
          if (i != null) pos.add(i);
        }
      }
      final sorted = pos.toList()..sort();
      return [for (final i in sorted.take(SearchEngine.maxVod)) list[i]];
    }

    Future<List<SearchShow>> shows() async {
      if (!d.epg) return mem.shows;
      final byKey = st.byEpg(_channels);
      if (!identical(SearchEngineDb._visFor, byKey)) {
        final ok = await Catalog.setSearchChannels(
            {for (final e in byKey.entries) e.key: e.value.hasCatchup});
        if (!ok) return const [];
        SearchEngineDb._visFor = byKey;
      }
      final t = now.millisecondsSinceEpoch ~/ 1000;
      final hits = await Catalog.searchEpg(d.portal, f,
          now: t,
          from: t - const Duration(days: 7).inSeconds,
          to: t + const Duration(days: 2).inSeconds,
          limit: SearchEngine.maxShows);
      return [
        for (final h in hits ?? const <EpgHit>[])
          if (byKey[h.key] != null) (channel: byKey[h.key]!, entry: h.entry),
      ];
    }

    final r = await (
      channels(),
      shows(),
      vod(d.movies, _movies, false),
      vod(d.series, _series, true),
    ).wait;
    return SearchResults(r.$1, r.$2, r.$3, r.$4, mem.persons);
  }

  _DbState get _dbState => _dbStates[this] ??= _DbState();

  static final _dbStates = Expando<_DbState>('searchDb');

  /// Für welche Senderliste die sichtbaren EPG-Schlüssel im
  /// Datenbank-Isolate stehen.
  static Object? _visFor;
}

/// ID → Position in den sichtbaren Listen (einmal je Liste).
class _DbState {
  Map<String, int>? _ch, _mv, _sr;
  Map<String, Channel>? _epg;

  static Map<String, int> _index<T>(List<T> l, String Function(T) id) => {
        for (var i = l.length - 1; i >= 0; i--) id(l[i]): i,
      };

  Map<String, int> chIndex(List<Channel> l) => _ch ??= _index(l, (c) => c.id);
  Map<String, int> mvIndex(List<VodItem> l) => _mv ??= _index(l, (m) => m.id);
  Map<String, int> srIndex(List<VodItem> l) => _sr ??= _index(l, (m) => m.id);
  Map<String, Channel> byEpg(List<Channel> l) =>
      _epg ??= {for (final c in l) epgKeyOf(c): c};
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
