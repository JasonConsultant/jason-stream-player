import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/sport_classify.dart';
import '../data/sport_detect.dart';
import '../models/models.dart';
import 'profile_mode.dart';
import 'providers.dart';

export '../data/sport_classify.dart';

/// Eine Sportübertragung laut EPG.
class SportEvent {
  final Channel channel;
  final EpgEntry entry;
  final SportClass cls;
  const SportEvent(this.channel, this.entry, this.cls);

  bool liveAt(DateTime now) =>
      !entry.start.isAfter(now) && entry.end.isAfter(now);

  double progressAt(DateTime now) {
    final total = entry.end.difference(entry.start).inSeconds;
    if (total <= 0) return 0;
    return (now.difference(entry.start).inSeconds / total).clamp(0.0, 1.0);
  }
}

/// Sport-Hub: laufende und kommende Sportsendungen (nur EPG – keine
/// Spielstände), nach Sportart/Liga gruppierbar.
class SportHub {
  final List<SportEvent> events;
  final DateTime now;
  const SportHub(this.events, this.now);
  static final empty = SportHub(const [], DateTime(0));

  List<SportEvent> get live => [for (final e in events) if (e.liveAt(now)) e];
  List<SportEvent> get upcoming =>
      [for (final e in events) if (e.entry.start.isAfter(now)) e];

  /// Vorhandene Sportarten in Hub-Reihenfolge.
  List<SportKind> get kinds {
    final have = {for (final e in events) e.cls.kind};
    return [for (final k in SportKind.order) if (have.contains(k)) k];
  }

  /// Gefilterte Ereignisse, gruppiert nach (Sportart, Liga). Ligen in der
  /// Reihenfolge ihres ersten Termins; „ohne Liga“ zuletzt je Sportart.
  List<({SportKind kind, String? league, List<SportEvent> events})> groups(
      {SportKind? kind, Set<String>? onlyChannels}) {
    final map = <(SportKind, String?), List<SportEvent>>{};
    for (final e in events) {
      if (kind != null && e.cls.kind != kind) continue;
      if (onlyChannels != null && !onlyChannels.contains(e.channel.id)) {
        continue;
      }
      (map[(e.cls.kind, e.cls.league)] ??= []).add(e);
    }
    final keys = map.keys.toList()
      ..sort((a, b) {
        final ka = SportKind.order.indexOf(a.$1),
            kb = SportKind.order.indexOf(b.$1);
        if (ka != kb) return ka.compareTo(kb);
        if ((a.$2 == null) != (b.$2 == null)) return a.$2 == null ? 1 : -1;
        return map[a]!.first.entry.start.compareTo(map[b]!.first.entry.start);
      });
    return [
      for (final k in keys) (kind: k.$1, league: k.$2, events: map[k]!),
    ];
  }
}

/// Sportereignisse von jetzt bis [horizon] (laufende zuerst, dann nach
/// Beginn). Sender in Sportgruppen: auch Paarungen „A – B“. Je Sender
/// höchstens [perChannel], insgesamt höchstens [max].
List<SportEvent> sportEvents({
  required List<Category> categories,
  required List<Channel> channels,
  required Map<String, List<EpgEntry>> epg,
  required DateTime now,
  Duration horizon = const Duration(hours: 24),
  bool Function(Channel)? hidden,
  int perChannel = 12,
  int max = 400,
}) {
  final sportGroups = {
    for (final c in categories)
      if (SportDetector.isSportGroup(c.name)) c.id,
  };
  final until = now.add(horizon);
  final out = <SportEvent>[];
  for (final c in channels) {
    if (hidden?.call(c) ?? false) continue;
    final list = epg[epgKeyOf(c)];
    if (list == null || list.isEmpty) continue;
    // Erste Sendung, die nach [now] endet (binäre Suche).
    var lo = 0, hi = list.length - 1, i = list.length;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (list[mid].end.isAfter(now)) {
        i = mid;
        hi = mid - 1;
      } else {
        lo = mid + 1;
      }
    }
    final group = sportGroups.contains(c.categoryId);
    var n = 0;
    for (; i < list.length && list[i].start.isBefore(until); i++) {
      final e = list[i];
      final cls =
          SportClassifier.classify(e.title, genre: e.genre, sportGroup: group);
      if (cls == null) continue;
      out.add(SportEvent(c, e, cls));
      if (++n >= perChannel) break;
    }
  }
  out.sort((a, b) {
    final la = a.liveAt(now), lb = b.liveAt(now);
    if (la != lb) return la ? -1 : 1;
    return a.entry.start.compareTo(b.entry.start);
  });
  return out.length > max ? out.sublist(0, max) : out;
}

/// Merkt sich die zuletzt berechneten Ereignisse: neu gerechnet wird nur bei
/// geänderten Daten (Liste, EPG, Ausblendungen) oder alle 10 Minuten; im
/// Minutentakt fallen nur beendete Sendungen heraus.
class SportHubMemo {
  static const refresh = Duration(minutes: 10);
  Object? _live, _epg, _flags, _hidden;
  DateTime _at = DateTime(0);
  List<SportEvent> _events = const [];
  int fullScans = 0;

  List<SportEvent> compute({
    required LiveData live,
    required Map<String, List<EpgEntry>> epg,
    required ChannelFlags flags,
    required Set<String> hiddenGroups,
    required DateTime now,
  }) {
    final same = identical(live, _live) &&
        identical(epg, _epg) &&
        identical(flags, _flags) &&
        identical(hiddenGroups, _hidden);
    if (!same || now.difference(_at) >= refresh || now.isBefore(_at)) {
      fullScans++;
      _live = live;
      _epg = epg;
      _flags = flags;
      _hidden = hiddenGroups;
      _at = now;
      _events = sportEvents(
          categories: live.categories,
          channels: live.channels,
          epg: epg,
          now: now,
          hidden: (c) =>
              flags.isHidden(c.id) || hiddenGroups.contains(c.categoryId));
      return _events;
    }
    final rest = [for (final e in _events) if (e.entry.end.isAfter(now)) e];
    rest.sort((a, b) {
      final la = a.liveAt(now), lb = b.liveAt(now);
      if (la != lb) return la ? -1 : 1;
      return a.entry.start.compareTo(b.entry.start);
    });
    return rest;
  }
}

final sportHubMemoProvider = Provider<SportHubMemo>((_) => SportHubMemo());

/// Hub-Daten (nur solange die Sport-Seite offen ist).
final sportHubProvider = Provider.autoDispose<SportHub>((ref) {
  final tick = ref.watch(minuteTickProvider).value ?? DateTime.now();
  final live = ref.watch(visibleLiveDataProvider).value;
  final epg = ref.watch(epgProvider).value;
  if (live == null || epg == null || epg.isEmpty) return SportHub.empty;
  final flags = ref.watch(channelFlagsProvider).value ?? ChannelFlags.empty;
  final hiddenGroups =
      ref.watch(sortOrderProvider).value?.hiddenGroups ?? const <String>{};
  final now = DateTime.now().isAfter(tick) ? DateTime.now() : tick;
  return SportHub(
      ref.read(sportHubMemoProvider).compute(
          live: live,
          epg: epg,
          flags: flags,
          hiddenGroups: hiddenGroups,
          now: now),
      now);
});

/// Filter der Sport-Seite (Sportart, nur Favoriten-Sender).
class SportFilter {
  final SportKind? kind;
  final bool favoritesOnly;
  const SportFilter({this.kind, this.favoritesOnly = false});
  SportFilter copyWith({SportKind? kind, bool clearKind = false, bool? fav}) =>
      SportFilter(
          kind: clearKind ? null : (kind ?? this.kind),
          favoritesOnly: fav ?? favoritesOnly);
}

class SportFilterNotifier extends Notifier<SportFilter> {
  @override
  SportFilter build() => const SportFilter();
  void set(SportFilter f) => state = f;
}

final sportFilterProvider =
    NotifierProvider<SportFilterNotifier, SportFilter>(SportFilterNotifier.new);
