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
  final Map<String, List<EpgEntry>> _epg;
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
  static PeopleIndex peopleIndexOf(List<VodItem> movies, List<VodItem> series,
      Map<String, People> cache) {
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

  _Lane _lane(List<String> lower) => _Lane(lower);

  void _ensure() {
    if (_ch != null) return;
    _ch = _lane([for (final c in _channels) c.name.toLowerCase()]);
    _mv = _lane([for (final m in _movies) m.name.toLowerCase()]);
    _sr = _lane([for (final m in _series) m.name.toLowerCase()]);
    final byEpg = <String, Channel>{
      for (final c in _channels) epgKeyOf(c): c,
    };
    final index = <String, int>{};
    final titles = <String>[];
    final hits = <List<SearchShow>>[];
    for (final e in _epg.entries) {
      final c = byEpg[e.key];
      if (c == null) continue;
      for (final p in e.value) {
        final i = index.putIfAbsent(p.title, () {
          titles.add(p.title.toLowerCase());
          hits.add(<SearchShow>[]);
          return titles.length - 1;
        });
        hits[i].add((channel: c, entry: p));
      }
    }
    _ti = _lane(titles);
    _titleHits = hits;
    if (_pidx == null && _buildPeople) {
      _pidx = peopleIndexOf(_movies, _series, _people);
    }
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
    final shows = <SearchShow>[];
    for (final t in _ti!.find(q)) {
      for (final s in _titleHits![t]) {
        final p = s.entry;
        if (p.end.isBefore(from) || p.start.isAfter(to)) continue;
        // Vergangenes nur, wenn es im Archiv liegt.
        if (p.isPastAt(now) && !s.channel.hasCatchup) continue;
        shows.add(s);
      }
    }
    // Läuft gerade → demnächst → vergangen (neueste zuerst)
    int rank(EpgEntry e) => e.isNowAt(now) ? 0 : e.start.isAfter(now) ? 1 : 2;
    shows.sort((a, b) {
      final r = rank(a.entry).compareTo(rank(b.entry));
      if (r != 0) return r;
      return rank(a.entry) == 2
          ? b.entry.start.compareTo(a.entry.start)
          : a.entry.start.compareTo(b.entry.start);
    });
    if (shows.length > maxShows) shows.removeRange(maxShows, shows.length);
    return SearchResults(
      channels,
      shows,
      [for (final i in _mv!.find(q, limit: maxVod)) _movies[i]],
      [for (final i in _sr!.find(q, limit: maxVod)) _series[i]],
      q.length >= 3 ? _persons(q) : const [],
    );
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
    return limit == null || hits.length <= limit ? hits : hits.sublist(0, limit);
  }
}
