import 'sport_detect.dart';

/// Sportart einer EPG-Sendung (Sport-Hub, ab 2.3).
enum SportKind {
  football,
  motorsport,
  tennis,
  basketball,
  combat,
  americanFootball,
  iceHockey,
  handball,
  volleyball,
  winter,
  cycling,
  golf,
  darts,
  other;

  /// Reihenfolge der Abschnitte im Hub.
  static const order = [
    football,
    basketball,
    motorsport,
    tennis,
    combat,
    americanFootball,
    iceHockey,
    handball,
    volleyball,
    winter,
    cycling,
    golf,
    darts,
    other,
  ];
}

/// Ergebnis der Einordnung: Sportart und (falls erkannt) Liga/Wettbewerb.
class SportClass {
  final SportKind kind;
  final String? league;
  const SportClass(this.kind, [this.league]);

  @override
  bool operator ==(Object other) =>
      other is SportClass && other.kind == kind && other.league == league;
  @override
  int get hashCode => Object.hash(kind, league);
  @override
  String toString() => 'SportClass($kind, $league)';
}

/// Ordnet Sendungen einer Sportart und Liga zu – nur über Titel,
/// EPG-Kategorie und (schwach) die Sendergruppe. Deutsch, Englisch,
/// Türkisch. Ohne Ergebnisdienst: keine Spielstände, nur das Programm.
class SportClassifier {
  SportClassifier._();

  static final _word = RegExp(r'[\p{L}\p{N}]+', unicode: true);

  /// Wettbewerbe (Wortfolgen, klein) → Sportart + Anzeigename. Längere
  /// Folgen zuerst prüfen (siehe [_leagueList]).
  static const _leagues = <String, (SportKind, String)>{
    // Fußball
    '2 bundesliga': (SportKind.football, '2. Bundesliga'),
    'zweite bundesliga': (SportKind.football, '2. Bundesliga'),
    '3 liga': (SportKind.football, '3. Liga'),
    'bundesliga': (SportKind.football, 'Bundesliga'),
    'dfb pokal': (SportKind.football, 'DFB-Pokal'),
    'dfb pokals': (SportKind.football, 'DFB-Pokal'),
    'süper lig': (SportKind.football, 'Süper Lig'),
    'super lig': (SportKind.football, 'Süper Lig'),
    'trendyol süper lig': (SportKind.football, 'Süper Lig'),
    '1 lig': (SportKind.football, 'TFF 1. Lig'),
    'türkiye kupası': (SportKind.football, 'Türkiye Kupası'),
    'ziraat türkiye kupası': (SportKind.football, 'Türkiye Kupası'),
    'champions league': (SportKind.football, 'Champions League'),
    'şampiyonlar ligi': (SportKind.football, 'Champions League'),
    'sampiyonlar ligi': (SportKind.football, 'Champions League'),
    'europa league': (SportKind.football, 'Europa League'),
    'avrupa ligi': (SportKind.football, 'Europa League'),
    'conference league': (SportKind.football, 'Conference League'),
    'konferans ligi': (SportKind.football, 'Conference League'),
    'premier league': (SportKind.football, 'Premier League'),
    'la liga': (SportKind.football, 'La Liga'),
    'laliga': (SportKind.football, 'La Liga'),
    'serie a': (SportKind.football, 'Serie A'),
    'ligue 1': (SportKind.football, 'Ligue 1'),
    'eredivisie': (SportKind.football, 'Eredivisie'),
    'fa cup': (SportKind.football, 'FA Cup'),
    'world cup': (SportKind.football, 'WM'),
    'weltmeisterschaft': (SportKind.football, 'WM'),
    'dünya kupası': (SportKind.football, 'WM'),
    'fifa': (SportKind.football, 'FIFA'),
    'nations league': (SportKind.football, 'Nations League'),
    'uluslar ligi': (SportKind.football, 'Nations League'),
    'euro 2028': (SportKind.football, 'EM'),
    'europameisterschaft': (SportKind.football, 'EM'),
    'mls': (SportKind.football, 'MLS'),
    // Motorsport
    'formel 1': (SportKind.motorsport, 'Formel 1'),
    'formula 1': (SportKind.motorsport, 'Formel 1'),
    'formula one': (SportKind.motorsport, 'Formel 1'),
    'formel1': (SportKind.motorsport, 'Formel 1'),
    'formula1': (SportKind.motorsport, 'Formel 1'),
    'f1': (SportKind.motorsport, 'Formel 1'),
    'formel 2': (SportKind.motorsport, 'Formel 2'),
    'formula 2': (SportKind.motorsport, 'Formel 2'),
    'motogp': (SportKind.motorsport, 'MotoGP'),
    'moto gp': (SportKind.motorsport, 'MotoGP'),
    'dtm': (SportKind.motorsport, 'DTM'),
    'nascar': (SportKind.motorsport, 'NASCAR'),
    'indycar': (SportKind.motorsport, 'IndyCar'),
    'wec': (SportKind.motorsport, 'WEC'),
    'rallye': (SportKind.motorsport, 'Rallye'),
    'rally': (SportKind.motorsport, 'Rallye'),
    'wrc': (SportKind.motorsport, 'Rallye'),
    // Basketball
    'nba': (SportKind.basketball, 'NBA'),
    'euroleague': (SportKind.basketball, 'EuroLeague'),
    'euroliga': (SportKind.basketball, 'EuroLeague'),
    'bbl': (SportKind.basketball, 'BBL'),
    'basketbol süper ligi': (SportKind.basketball, 'BSL'),
    // Tennis
    'wimbledon': (SportKind.tennis, 'Wimbledon'),
    'us open': (SportKind.tennis, 'US Open'),
    'french open': (SportKind.tennis, 'French Open'),
    'roland garros': (SportKind.tennis, 'French Open'),
    'australian open': (SportKind.tennis, 'Australian Open'),
    'atp': (SportKind.tennis, 'ATP'),
    'wta': (SportKind.tennis, 'WTA'),
    'davis cup': (SportKind.tennis, 'Davis Cup'),
    // Kampfsport
    'ufc': (SportKind.combat, 'UFC'),
    'wwe': (SportKind.combat, 'WWE'),
    'aew': (SportKind.combat, 'AEW'),
    'bellator': (SportKind.combat, 'Bellator'),
    'pfl': (SportKind.combat, 'PFL'),
    // Andere Ligen
    'nfl': (SportKind.americanFootball, 'NFL'),
    'super bowl': (SportKind.americanFootball, 'NFL'),
    'superbowl': (SportKind.americanFootball, 'NFL'),
    'nhl': (SportKind.iceHockey, 'NHL'),
    'del': (SportKind.iceHockey, 'DEL'),
    'hbl': (SportKind.handball, 'HBL'),
    'tour de france': (SportKind.cycling, 'Tour de France'),
    'giro d italia': (SportKind.cycling, "Giro d'Italia"),
    'pga': (SportKind.golf, 'PGA Tour'),
    'ryder cup': (SportKind.golf, 'Ryder Cup'),
    'pdc': (SportKind.darts, 'PDC'),
  };

  /// Einzelwörter → Sportart (ohne Liga).
  static const _kinds = <String, SportKind>{
    'fußball': SportKind.football,
    'fussball': SportKind.football,
    'soccer': SportKind.football,
    'futbol': SportKind.football,
    'football': SportKind.football,
    'uefa': SportKind.football,
    'dfb': SportKind.football,
    'sportschau': SportKind.football,
    'derbi': SportKind.football,
    'maç': SportKind.football,
    'tennis': SportKind.tennis,
    'tenis': SportKind.tennis,
    'basketball': SportKind.basketball,
    'basketbol': SportKind.basketball,
    'boxen': SportKind.combat,
    'boxing': SportKind.combat,
    'boks': SportKind.combat,
    'mma': SportKind.combat,
    'kickboxing': SportKind.combat,
    'wrestling': SportKind.combat,
    'güreş': SportKind.combat,
    'motorsport': SportKind.motorsport,
    'motorsporu': SportKind.motorsport,
    'eishockey': SportKind.iceHockey,
    'hockey': SportKind.iceHockey,
    'buz': SportKind.iceHockey, // „Buz Hokeyi“
    'handball': SportKind.handball,
    'hentbol': SportKind.handball,
    'volleyball': SportKind.volleyball,
    'voleybol': SportKind.volleyball,
    'biathlon': SportKind.winter,
    'skispringen': SportKind.winter,
    'wintersport': SportKind.winter,
    'skiing': SportKind.winter,
    'kayak': SportKind.winter,
    'radsport': SportKind.cycling,
    'cycling': SportKind.cycling,
    'bisiklet': SportKind.cycling,
    'golf': SportKind.golf,
    'darts': SportKind.darts,
    'snooker': SportKind.other,
  };

  /// Gegen-Paarung „A – B“, „A vs. B“, „A v B“ (Teamsport, meist Fußball).
  static final _versus = RegExp(
      r'\S\s+(?:[-–—]|vs\.?|v\.?|x)\s+\S',
      caseSensitive: false);

  /// Erste Wörter aller Ligen/Sportarten – schneller Ausschluss: ohne
  /// eines davon (und ohne Sport-Wort/-Sender) ist es kein Sport.
  static final Set<String> _firstWords = {
    for (final k in _leagues.keys) k.split(' ').first,
    ..._kinds.keys,
    'american',
  };

  static final _cache = <String, SportClass?>{};

  /// Sportart/Liga zu [title]/[genre]. [sportGroup] = Sender aus einer
  /// Sportgruppe (dann zählt auch eine Paarung „A – B“ als Sport).
  /// null = keine Sportsendung.
  static SportClass? classify(String title,
      {String? genre, bool sportGroup = false}) {
    // Schneller Ausschluss ohne Zwischenspeicher (die meisten Sendungen).
    if (!sportGroup && (genre == null || genre.isEmpty) && _quickNo(title)) {
      return null;
    }
    final key = '$title\u0001${genre ?? ''}\u0001$sportGroup';
    if (_cache.containsKey(key)) return _cache[key];
    final r = _classify(title, genre, sportGroup);
    if (_cache.length > 20000) _cache.clear();
    return _cache[key] = r;
  }

  static List<String> _tokens(String s) => [
        for (final m in _word.allMatches(s.toLowerCase().replaceAll('i̇', 'i')))
          m.group(0)!,
      ];

  static bool _quickNo(String title) {
    for (final m in _word.allMatches(title.toLowerCase())) {
      final w = m.group(0)!;
      if (_firstWords.contains(w) ||
          SportDetector.triggerWords.contains(w) ||
          w.contains('spor') ||
          w.startsWith('formel') ||
          w.startsWith('formula')) {
        return false;
      }
    }
    return true;
  }

  /// Längste Wortfolge (bis 3 Wörter), die eine Liga ist.
  static SportClass? _league(List<String> t, bool isSport, bool group) {
    (SportKind, String)? best;
    var bestLen = 0;
    for (var i = 0; i < t.length; i++) {
      for (var n = 3; n >= 1; n--) {
        if (i + n > t.length || n <= bestLen) continue;
        final k = n == 1 ? t[i] : t.sublist(i, i + n).join(' ');
        final hit = _leagues[k];
        if (hit == null) continue;
        // Kurze Kürzel („del“, „wec“, „atp“) nur, wenn sonst Sport erkennbar.
        if (k.length <= 3 &&
            !isSport &&
            !group &&
            !const {'nba', 'nfl', 'nhl', 'ufc', 'wwe', 'f1'}.contains(k)) {
          continue;
        }
        best = hit;
        bestLen = n;
      }
    }
    return best == null ? null : SportClass(best.$1, best.$2);
  }

  static SportClass? _classify(String title, String? genre, bool group) {
    final isSport = SportDetector.isSportText(title) ||
        SportDetector.isSportText(genre);
    final t = _tokens(title);
    final g = genre == null ? const <String>[] : _tokens(genre);
    if (!isSport &&
        !group &&
        !t.any(_firstWords.contains) &&
        !g.any(_firstWords.contains) &&
        !t.any((w) => w.startsWith('formel') || w.startsWith('formula'))) {
      return null;
    }
    final joined = ' ${t.join(' ')} ';
    final joinedG = ' ${g.join(' ')} ';
    final league = _league(t, isSport, group) ?? _league(g, isSport, group);
    if (league != null) return league;
    if (joined.contains(' american football ') ||
        joinedG.contains(' american football ')) {
      return const SportClass(SportKind.americanFootball);
    }
    for (final w in [...t, ...g]) {
      final k = _kinds[w];
      if (k != null) {
        // „football“ allein: in den USA American Football – EPG-Titel
        // wie „NFL Football“ hat schon die Liga erkannt.
        return SportClass(k);
      }
      if (w.startsWith('formel') || w.startsWith('formula')) {
        return const SportClass(SportKind.motorsport);
      }
    }
    if (isSport) return const SportClass(SportKind.other);
    if (group && _versus.hasMatch(title)) {
      return const SportClass(SportKind.football);
    }
    return null;
  }
}
