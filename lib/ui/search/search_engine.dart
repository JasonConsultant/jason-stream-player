import '../../data/epg_matcher.dart' show epgKeyOf;
import '../../models/models.dart';

typedef SearchShow = ({Channel channel, EpgEntry entry});

class SearchResults {
  final List<Channel> channels;
  final List<SearchShow> shows;
  final List<VodItem> films;
  final List<VodItem> series;
  const SearchResults(this.channels, this.shows, this.films, this.series);

  static const empty = SearchResults([], [], [], []);

  bool get isEmpty =>
      channels.isEmpty && shows.isEmpty && films.isEmpty && series.isEmpty;
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

  SearchEngine({
    required List<Channel> channels,
    required Map<String, List<EpgEntry>> epg,
    required List<VodItem> movies,
    required List<VodItem> series,
  })  : _channels = channels,
        _epg = epg,
        _movies = movies,
        _series = series;

  static const maxChannels = 40;
  static const maxShows = 60;
  static const maxVod = 30;

  _Lane? _ch, _mv, _sr, _ti;

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
