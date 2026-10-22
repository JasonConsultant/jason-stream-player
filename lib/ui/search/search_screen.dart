import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../state/providers.dart';
import '../nav.dart';
import '../vod/vod_screen.dart' show PosterCard;
import '../widgets/artwork.dart';
import '../widgets/common.dart';
import '../widgets/focusable_tile.dart';
import '../widgets/voice_search.dart';
import 'person_screen.dart';
import 'recent_searches.dart';
import 'search_engine.dart';
import '../tv/tv_focus.dart' show TvTile;
import '../../data/people_index.dart' show PeopleIndex;
import '../../models/models.dart';
import '../../state/discover.dart' show peopleIndexProvider;
import '../../state/profile_mode.dart';

/// Eine Suche für alles: Sender, Sendungen im EPG (jetzt, demnächst und im
/// Archiv), Filme und Serien.
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  /// Entprellung: Fernseher (Tastatur der Fernbedienung, langsames Gerät)
  /// länger als Handy.
  static const debounceTv = Duration(milliseconds: 320);
  static const debouncePhone = Duration(milliseconds: 220);

  /// EPG-Index frühestens [epgIdle] nach der letzten Eingabe und höchstens
  /// alle [epgMinGap] neu bauen (große EPGs melden Teil-Updates laufend).
  static const epgIdle = Duration(seconds: 2);
  static const epgMinGap = Duration(seconds: 90);

  /// Programmtreffer zunächst; mehr per „Mehr anzeigen“.
  static const showsPage = 20;

  /// Ausgeführte Suchen (für Tests/Messungen).
  @visibleForTesting
  static int debugSearches = 0;

  /// Neuaufbauten des EPG-Index (für Tests/Messungen).
  @visibleForTesting
  static int debugEpgReindex = 0;

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

typedef _Show = SearchShow;

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _ctrl = TextEditingController();

  /// Textfeld – Ziel, wenn eine gewählte/entfernte „Letzte Suche“ samt
  /// Fokus verschwindet (Fernseher: Fokus nie verlieren).
  final _fieldNode = FocusNode(debugLabel: 'search field');
  Timer? _debounce;
  String _q = '';

  // Suchindex (Kleinbuchstaben, Weitersuche in Treffern) – neu, sobald sich
  // Senderliste, Filme/Serien oder Ausblendungen ändern. Das EPG wird
  // getrennt (im Hintergrund, nicht beim Tippen) nachgezogen.
  SearchEngine? _engine;
  List<Object?> _engineFor = const [];
  PeopleIndex? _people;
  SearchResults _res = SearchResults.empty;
  bool _allShows = false;

  Map<String, List<EpgEntry>>? _epgLatest;
  bool _epgIndexedEmpty = true;
  bool _epgRunning = false;

  /// Feld ruht noch nicht ([SearchScreen.epgIdle] seit der letzten Eingabe).
  bool _typing = false;
  Timer? _idleTimer;

  /// Seit dem letzten EPG-Aufbau ist [SearchScreen.epgMinGap] vergangen.
  bool _gapOpen = true;
  Timer? _gapTimer;
  bool _visible = true;
  bool _rerunQueued = false;

  @override
  void initState() {
    super.initState();
    // Suchbegriff aus Sprachsuche/Such-Taste übernehmen (Tab neu gebaut).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final q = ref.read(searchRequestProvider.notifier).take();
      if (q != null) _apply(q);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Im IndexedStack versteckt: EPG-Index erst beim Zurückkommen nachziehen.
    final v = Visibility.of(context);
    if (v != _visible) {
      _visible = v;
      if (v) Timer.run(_planEpgRefresh);
    }
  }

  /// Text ins Feld übernehmen und sofort suchen.
  void _apply(String q) {
    _ctrl.value = TextEditingValue(
        text: q, selection: TextSelection.collapsed(offset: q.length));
    _debounce?.cancel();
    setState(() {
      _q = q.trim().toLowerCase();
      _allShows = false;
      _runSearch();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _idleTimer?.cancel();
    _gapTimer?.cancel();
    _engine = null;
    _ctrl.dispose();
    _fieldNode.dispose();
    super.dispose();
  }

  void _onChanged(String v) {
    _typing = true;
    _idleTimer?.cancel();
    _idleTimer = Timer(SearchScreen.epgIdle, () {
      _typing = false;
      _planEpgRefresh();
    });
    _debounce?.cancel();
    final q = v.trim().toLowerCase();
    // Leeren sofort (zeigt „Letzte Suchen“), Tippen entprellt.
    if (q.isEmpty) {
      setState(() {
        _q = '';
        _runSearch();
      });
      return;
    }
    _debounce = Timer(
        ref.read(isTvProvider)
            ? SearchScreen.debounceTv
            : SearchScreen.debouncePhone, () {
      if (!mounted || q == _q) return;
      setState(() {
        _q = q;
        _allShows = false;
        _runSearch();
      });
    });
  }

  /// Suche ausführen (nie im build: dort nur das fertige Ergebnis zeigen).
  void _runSearch() {
    final e = _engine;
    if (_q.length < 2 || e == null) {
      _res = SearchResults.empty;
      return;
    }
    SearchScreen.debugSearches++;
    _res = e.search(_q, DateTime.now());
  }

  /// Nach Änderungen an Listen/Personen einmal nach dem Bild neu suchen.
  void _rerunSoon() {
    if (_rerunQueued) return;
    _rerunQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _rerunQueued = false;
      if (!mounted) return;
      setState(_runSearch);
    });
  }

  /// Suchindex zu den aktuellen Listen; baut ihn neu (in Häppchen, im
  /// Hintergrund) nur, wenn sich eine Liste geändert hat.
  void _syncEngine(LiveData? live, List<VodItem> movies, List<VodItem> series,
      ChannelFlags flags, PeopleIndex? people) {
    if (live == null) {
      if (_engine != null) {
        _engine = null;
        _engineFor = const [];
        _rerunSoon();
      }
      return;
    }
    final inputs = [live, movies, series, flags];
    final same = _engine != null &&
        inputs.length == _engineFor.length &&
        [
          for (var i = 0; i < inputs.length; i++)
            identical(inputs[i], _engineFor[i])
        ].every((x) => x);
    if (!same) {
      final epg = _epgLatest ?? ref.read(epgProvider).value ?? const {};
      final e = SearchEngine(
        channels: live.channels.where((c) => !flags.isHidden(c.id)).toList(),
        epg: epg,
        movies: movies,
        series: series,
        buildPeople: false,
      )..personIndex = people;
      _engine = e;
      _engineFor = inputs;
      _people = people;
      _markEpgIndexed(epg);
      // Index vorab bauen, damit schon der erste Buchstabe schnell ist.
      // (Nicht im build: erst nach dem Bild starten.)
      Timer.run(() {
        if (mounted && identical(_engine, e)) {
          e.warmUp(cancelled: () => !mounted || !identical(_engine, e));
        }
      });
      _rerunSoon();
      return;
    }
    if (!identical(people, _people)) {
      _people = people;
      _engine!.personIndex = people;
      if (_q.length >= 3) _rerunSoon();
    }
  }

  void _onEpg(Map<String, List<EpgEntry>>? epg) {
    if (epg == null) return;
    _epgLatest = epg;
    // Aus ref.listen (im build) → erst danach anfangen.
    Timer.run(_planEpgRefresh);
  }

  void _markEpgIndexed(Map<String, List<EpgEntry>> epg) {
    _epgIndexedEmpty = epg.isEmpty;
    _gapOpen = false;
    _gapTimer?.cancel();
    _gapTimer = Timer(SearchScreen.epgMinGap, () {
      _gapOpen = true;
      _planEpgRefresh();
    });
  }

  /// EPG-Index nicht beim Tippen neu bauen: erst wenn das Feld ruht und
  /// der letzte Aufbau lange genug her ist (oder bisher kein EPG da war).
  void _planEpgRefresh() {
    final e = _engine;
    final next = _epgLatest;
    if (!mounted || e == null || next == null || identical(e.epg, next)) {
      return;
    }
    if (!_visible || _epgRunning || _typing) return;
    if (!_gapOpen && !_epgIndexedEmpty) return;
    _refreshEpg(e, next);
  }

  Future<void> _refreshEpg(
      SearchEngine e, Map<String, List<EpgEntry>> next) async {
    _epgRunning = true;
    final ok = await e.refreshEpg(next,
        cancelled: () => !mounted || !identical(_engine, e));
    _epgRunning = false;
    if (!mounted || !ok) return;
    SearchScreen.debugEpgReindex++;
    _markEpgIndexed(next);
    if (_q.length >= 2) setState(_runSearch);
    _planEpgRefresh(); // inzwischen neueres EPG?
  }

  /// Suchbegriff unter „Letzte Suchen“ merken.
  void _remember() {
    final q = _ctrl.text.trim();
    if (q.length >= 2) ref.read(recentSearchesProvider.notifier).add(q);
  }

  @override
  Widget build(BuildContext context) {
    // Tab war schon offen: neuen Suchbegriff direkt übernehmen.
    ref.listen<String?>(searchRequestProvider, (_, q) {
      if (q == null) return;
      ref.read(searchRequestProvider.notifier).take();
      _apply(q);
    });
    // EPG nicht beobachten (kein Neuaufbau je Teil-Update), nur merken.
    ref.listen(epgProvider, (_, next) => _onEpg(next.value));
    final live = ref.watch(visibleLiveDataProvider).value;
    final movies = ref.watch(visibleMoviesProvider).value?.items ?? const [];
    final series = ref.watch(visibleSeriesProvider).value?.items ?? const [];
    final flags = ref.watch(channelFlagsProvider).value ?? ChannelFlags.empty;
    final recent = ref.watch(recentSearchesProvider);
    // Personen: im Hintergrund gebaut (große Anbieter: Sekunden).
    final pi = ref.watch(peopleIndexProvider).value;
    // Nur passend zu den gerade sichtbaren Listen (Kinder-/Länderfilter).
    final people = pi != null &&
            identical(pi.movies, movies) &&
            identical(pi.series, series)
        ? pi.index
        : null;
    _syncEngine(live, movies, series, flags, people);
    final narrow = MediaQuery.sizeOf(context).width < 600;
    final pad = EdgeInsets.symmetric(horizontal: narrow ? 16 : 28);

    // Ergebnis gehört zu den aktuellen Listen? (sonst gleich neu gesucht)
    final res = _engine == null ? SearchResults.empty : _res;
    final channels = res.channels;
    final shows = res.shows;
    final films = res.films;
    final shows2 = res.series;
    final persons = res.persons;

    final empty = _q.length >= 2 && res.isEmpty;
    final allShows = _allShows || shows.length <= SearchScreen.showsPage;
    final shownShows =
        allShows ? shows : shows.sublist(0, SearchScreen.showsPage);

    return ListView(
      padding: const EdgeInsets.only(bottom: 40),
      children: [
        PageHeader(tr('Suche')),
        Padding(
          padding: pad,
          child: SearchField(
            controller: _ctrl,
            hint: tr('Sender, Sendung, Film, Serie oder Person …'),
            width: double.infinity,
            onChanged: _onChanged,
            onSubmitted: (_) => _remember(),
            tvActions: true,
            focusNode: _fieldNode,
          ),
        ),
        if (recent.isNotEmpty && (_q.length < 2 || empty))
          _RecentSearches(
            items: recent,
            pad: pad,
            onPick: _apply,
            onRemove: (q) =>
                ref.read(recentSearchesProvider.notifier).remove(q),
            focusField: () {
              if (mounted) _fieldNode.requestFocus();
            },
          ),
        if (_q.length < 2)
          Padding(
            padding: const EdgeInsets.only(top: 60),
            child: EmptyState(
              icon: Icons.manage_search_rounded,
              title: tr('Wonach suchst du?'),
              message:
                  tr('Mindestens 2 Buchstaben – z. B. „Tatort“, „Bundesliga“ '
                      'oder einen Sendernamen.'),
            ),
          ),
        if (empty)
          Padding(
            padding: const EdgeInsets.only(top: 60),
            child: EmptyState(
                icon: Icons.search_off_rounded, title: tr('Nichts gefunden')),
          ),
        if (channels.isNotEmpty) ...[
          _Heading(tr('Sender'), channels.length, pad),
          SizedBox(
            height: 112,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: pad,
              itemCount: channels.length,
              separatorBuilder: (_, __) => const SizedBox(width: 10),
              itemBuilder: (_, i) {
                final c = channels[i];
                return SizedBox(
                  width: 130,
                  child: FocusableTile(
                    onTap: () {
                      _remember();
                      playChannel(context, ref, c, live!.channels);
                    },
                    child: Padding(
                      padding: const EdgeInsets.all(10),
                      child: Column(children: [
                        ChannelLogo(name: c.name, url: c.logoUrl, size: 44),
                        const SizedBox(height: 8),
                        Text(c.name,
                            maxLines: 2,
                            textAlign: TextAlign.center,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                                color: AppColors.text)),
                      ]),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
        if (shows.isNotEmpty) ...[
          _Heading(tr('Sendungen'), shows.length, pad),
          for (final s in shownShows)
            Padding(
              padding: pad.copyWith(bottom: 4),
              child: _ShowTile(
                show: s,
                onTap: () {
                  _remember();
                  final now = DateTime.now();
                  if (s.entry.isPastAt(now)) {
                    playCatchup(context, ref, s.channel, s.entry,
                        channels: live!.channels);
                  } else {
                    playChannel(context, ref, s.channel, live!.channels);
                  }
                },
              ),
            ),
          if (!allShows)
            Padding(
              padding: pad.copyWith(top: 4, bottom: 4),
              child: FocusableTile(
                key: const ValueKey('search-more-shows'),
                onTap: () => setState(() => _allShows = true),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  child: Row(children: [
                    const Icon(Icons.expand_more_rounded,
                        color: AppColors.textDim),
                    const SizedBox(width: 12),
                    Text(
                        trf('Mehr anzeigen ({0})',
                            [shows.length - SearchScreen.showsPage]),
                        style: Theme.of(context).textTheme.titleSmall),
                  ]),
                ),
              ),
            ),
        ],
        if (persons.isNotEmpty) ...[
          _Heading(tr('Personen'), persons.length, pad),
          SizedBox(
            height: 132,
            child: ListView.separated(
              key: const ValueKey('search-persons'),
              scrollDirection: Axis.horizontal,
              padding: pad,
              itemCount: persons.length,
              separatorBuilder: (_, __) => const SizedBox(width: 10),
              itemBuilder: (_, i) {
                final p = persons[i];
                return PersonTile(
                  key: ValueKey('person-${p.name}'),
                  name: p.name,
                  count: p.titles.length,
                  director: p.director,
                  onTap: () {
                    _remember();
                    Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => PersonScreen(
                            name: p.name,
                            titles: p.titles,
                            director: p.director)));
                  },
                );
              },
            ),
          ),
        ],
        for (final (title, list) in [
          (tr('Filme'), films),
          (tr('Serien'), shows2)
        ])
          if (list.isNotEmpty) ...[
            _Heading(title, list.length, pad),
            SizedBox(
              height: (narrow ? 118 : 150) / 0.52,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: pad,
                itemCount: list.length,
                separatorBuilder: (_, __) => const SizedBox(width: 14),
                itemBuilder: (_, i) => SizedBox(
                    width: narrow ? 118 : 150,
                    child: PosterCard(item: list[i])),
              ),
            ),
          ],
      ],
    );
  }
}

class _Heading extends StatelessWidget {
  final String title;
  final int count;
  final EdgeInsets pad;
  const _Heading(this.title, this.count, this.pad);

  @override
  Widget build(BuildContext context) => Padding(
        padding: pad.copyWith(top: 24, bottom: 10),
        child: Row(children: [
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(width: 8),
          Text('$count', style: Theme.of(context).textTheme.bodySmall),
        ]),
      );
}

class _ShowTile extends StatelessWidget {
  final _Show show;
  final VoidCallback onTap;
  const _ShowTile({required this.show, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final e = show.entry;
    final now = DateTime.now();
    final (tag, color) = e.isNowAt(now)
        ? (tr('LÄUFT'), AppColors.live)
        : e.isPastAt(now)
            ? (tr('REPLAY'), AppColors.catchup)
            : (tr('DEMNÄCHST'), AppColors.textDim);
    final day = DateUtils.isSameDay(e.start, now)
        ? tr('Heute')
        : DateUtils.isSameDay(e.start, now.add(const Duration(days: 1)))
            ? tr('Morgen')
            : DateUtils.isSameDay(
                    e.start, now.subtract(const Duration(days: 1)))
                ? tr('Gestern')
                : '${e.start.day}.${e.start.month}.';
    return FocusableTile(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        child: Row(children: [
          ChannelLogo(
              name: show.channel.name, url: show.channel.logoUrl, size: 34),
          const SizedBox(width: 14),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(e.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 2),
              Text(
                  '${show.channel.name} · $day ${hm.format(e.start)}–${hm.format(e.end)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall),
            ]),
          ),
          Tag(tag, color: color, filled: color != AppColors.textDim),
        ]),
      ),
    );
  }
}

/// „Letzte Suchen“ als Chips: OK übernimmt den Begriff, langes OK bzw. die
/// Menü-Taste (Touch: lange tippen) entfernt ihn. Verschwindet dabei der
/// fokussierte Chip, geht der Fokus zum Nachbarn bzw. ins Suchfeld
/// (Fernseher: sonst wäre er verloren).
class _RecentSearches extends StatefulWidget {
  final List<String> items;
  final EdgeInsets pad;
  final ValueChanged<String> onPick;
  final ValueChanged<String> onRemove;
  final VoidCallback focusField;
  const _RecentSearches({
    required this.items,
    required this.pad,
    required this.onPick,
    required this.onRemove,
    required this.focusField,
  });

  @override
  State<_RecentSearches> createState() => _RecentSearchesState();
}

class _RecentSearchesState extends State<_RecentSearches> {
  /// Je Begriff ein Schlüssel am Chip-Inhalt (unterhalb des Fokus-Knotens).
  final _keys = <String, GlobalKey>{};

  GlobalKey _key(String q) => _keys.putIfAbsent(q, GlobalKey.new);

  bool _hasFocus(String q) {
    final ctx = _keys[q]?.currentContext;
    return ctx != null && (Focus.maybeOf(ctx)?.hasFocus ?? false);
  }

  void _pick(String q) {
    final had = _hasFocus(q);
    widget.onPick(q);
    // Chips verschwinden mit dem Ergebnis → Fokus ins Feld.
    if (had) _after(widget.focusField);
  }

  void _remove(String q) {
    final had = _hasFocus(q);
    final i = widget.items.indexOf(q);
    final rest = [...widget.items]..remove(q);
    widget.onRemove(q);
    if (!had) return;
    final next = rest.isEmpty ? null : rest[i.clamp(0, rest.length - 1)];
    final field = widget.focusField;
    _after(() {
      final ctx = next == null || !mounted ? null : _keys[next]?.currentContext;
      final n = ctx == null ? null : Focus.maybeOf(ctx);
      n != null ? n.requestFocus() : field();
    });
  }

  static void _after(VoidCallback f) {
    WidgetsBinding.instance.addPostFrameCallback((_) => f());
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void didUpdateWidget(_RecentSearches old) {
    super.didUpdateWidget(old);
    _keys.removeWhere((q, _) => !widget.items.contains(q));
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: widget.pad.copyWith(top: 18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('Letzte Suchen'),
              style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(tr('Lange OK drücken entfernt einen Eintrag'),
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 10),
          Wrap(spacing: 10, runSpacing: 10, children: [
            for (final q in widget.items)
              TvTile(
                key: ValueKey('recent-search-$q'),
                radius: BorderRadius.circular(18),
                semanticLabel: q,
                onTap: () => _pick(q),
                onLongPress: () => _remove(q),
                child: Container(
                  key: _key(q),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: AppColors.surface3,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.history_rounded,
                        size: 18, color: AppColors.textDim),
                    const SizedBox(width: 8),
                    Text(q,
                        style: const TextStyle(
                            fontSize: 14, color: AppColors.text)),
                  ]),
                ),
              ),
          ]),
        ]),
      );
}
