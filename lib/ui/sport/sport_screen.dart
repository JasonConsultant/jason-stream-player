import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/theme.dart';
import '../../data/reminders/reminders.dart';
import '../../l10n/strings.dart';
import '../../models/models.dart';
import '../../state/profile_mode.dart' show visibleLiveDataProvider;
import '../../state/providers.dart';
import '../../state/sport_hub.dart';
import '../nav.dart';
import '../tv/tv_widgets.dart';
import '../widgets/action_sheet.dart';
import '../widgets/artwork.dart';
import '../widgets/common.dart';
import '../widgets/focusable_tile.dart';

/// Anzeigename einer Sportart.
String sportKindLabel(SportKind k) => switch (k) {
      SportKind.football => tr('Fußball'),
      SportKind.motorsport => tr('Motorsport'),
      SportKind.tennis => tr('Tennis'),
      SportKind.basketball => tr('Basketball'),
      SportKind.combat => tr('Kampfsport'),
      SportKind.americanFootball => tr('American Football'),
      SportKind.iceHockey => tr('Eishockey'),
      SportKind.handball => tr('Handball'),
      SportKind.volleyball => tr('Volleyball'),
      SportKind.winter => tr('Wintersport'),
      SportKind.cycling => tr('Radsport'),
      SportKind.golf => tr('Golf'),
      SportKind.darts => tr('Darts'),
      SportKind.other => tr('Weitere Sportarten'),
    };

IconData sportKindIcon(SportKind k) => switch (k) {
      SportKind.football => Icons.sports_soccer_rounded,
      SportKind.motorsport => Icons.sports_motorsports_rounded,
      SportKind.tennis => Icons.sports_tennis_rounded,
      SportKind.basketball => Icons.sports_basketball_rounded,
      SportKind.combat => Icons.sports_mma_rounded,
      SportKind.americanFootball => Icons.sports_football_rounded,
      SportKind.iceHockey => Icons.sports_hockey_rounded,
      SportKind.handball => Icons.sports_handball_rounded,
      SportKind.volleyball => Icons.sports_volleyball_rounded,
      SportKind.winter => Icons.downhill_skiing_rounded,
      SportKind.cycling => Icons.directions_bike_rounded,
      SportKind.golf => Icons.sports_golf_rounded,
      SportKind.darts => Icons.adjust_rounded,
      SportKind.other => Icons.emoji_events_rounded,
    };

void openSportHub(BuildContext context) => Navigator.of(context)
    .push(MaterialPageRoute(builder: (_) => const SportScreen()));

/// Sport-Hub: laufende und kommende Sportübertragungen aus dem EPG,
/// gruppiert nach Sportart/Liga. Keine Spielstände (kein Ergebnisdienst).
/// Antippen/OK: laufend = einschalten, kommend = Erinnerung oder Sender.
class SportScreen extends ConsumerWidget {
  const SportScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tv = ref.watch(isTvProvider);
    final hub = ref.watch(sportHubProvider);
    final filter = ref.watch(sportFilterProvider);
    final flags = ref.watch(channelFlagsProvider).value ?? ChannelFlags.empty;
    final live = ref.watch(visibleLiveDataProvider).value;
    final channels = live?.channels ?? const <Channel>[];
    ref.watch(remindersProvider);
    final kinds = hub.kinds;
    final kind = kinds.contains(filter.kind) ? filter.kind : null;
    final groups = hub.groups(
        kind: kind,
        onlyChannels: filter.favoritesOnly ? flags.favorites : null);
    final narrow = MediaQuery.sizeOf(context).width < 600;
    final pad = tv ? tvPad : (narrow ? 16.0 : 28.0);
    final t = Theme.of(context).textTheme;
    final setF = ref.read(sportFilterProvider.notifier).set;

    Widget chip(String label, bool selected, VoidCallback onTap,
            {IconData? icon, Key? key, bool autofocus = false}) =>
        tv
            ? TvChip(
                key: key,
                label: label,
                icon: icon,
                selected: selected,
                autofocus: autofocus,
                onTap: onTap)
            : FilterChip(
                key: key,
                label: Text(label),
                avatar: icon == null ? null : Icon(icon, size: 18),
                selected: selected,
                showCheckmark: false,
                onSelected: (_) => onTap());

    final header = Padding(
      padding: EdgeInsets.fromLTRB(pad, tv ? 14 : 4, pad, 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(
            tr('Aus dem TV-Programm (EPG) – keine Live-Ergebnisse. Zeiten laut '
                'Anbieter.'),
            key: const ValueKey('sport-honest'),
            style: tv ? TvText.small : t.bodySmall),
        SizedBox(height: tv ? 8 : 10),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: FocusTraversalGroup(
            child: Row(children: [
              chip(tr('Alle'), kind == null,
                  () => setF(filter.copyWith(clearKind: true)),
                  key: const ValueKey('sport-kind-all'), autofocus: true),
              for (final k in kinds) ...[
                SizedBox(width: tv ? 6 : 8),
                chip(sportKindLabel(k), kind == k,
                    () => setF(filter.copyWith(kind: k)),
                    icon: sportKindIcon(k),
                    key: ValueKey('sport-kind-${k.name}')),
              ],
              SizedBox(width: tv ? 12 : 16),
              chip(tr('Nur meine Favoriten-Sender'), filter.favoritesOnly,
                  () => setF(filter.copyWith(fav: !filter.favoritesOnly)),
                  icon: Icons.star_rounded,
                  key: const ValueKey('sport-fav')),
            ]),
          ),
        ),
      ]),
    );

    final rows = <Widget>[];
    for (final g in groups) {
      rows.add(Padding(
        key: ValueKey('sport-group-${g.kind.name}-${g.league ?? ''}'),
        padding: EdgeInsets.fromLTRB(pad, tv ? 14 : 20, pad, tv ? 4 : 6),
        child: Row(children: [
          Icon(sportKindIcon(g.kind),
              size: tv ? 12 : 18, color: AppColors.accent),
          SizedBox(width: tv ? 5 : 8),
          Text(
              g.league == null
                  ? sportKindLabel(g.kind)
                  : '${sportKindLabel(g.kind)} · ${g.league}',
              style: tv ? TvText.caps : t.titleSmall),
        ]),
      ));
      for (final e in g.events) {
        rows.add(Padding(
          padding: EdgeInsets.symmetric(horizontal: pad - (tv ? 4 : 6)),
          child: _SportRow(event: e, now: hub.now, tv: tv, all: channels),
        ));
      }
    }

    final body = hub.events.isEmpty
        ? EmptyState(
            icon: Icons.emoji_events_outlined,
            title: tr('Keine Sportübertragungen gefunden'),
            message: tr('Im TV-Programm der nächsten 24 Stunden wurde kein '
                'Sport erkannt.'))
        : groups.isEmpty
            ? EmptyState(
                icon: Icons.filter_alt_off_rounded,
                title: tr('Nichts für diesen Filter'),
                message: filter.favoritesOnly
                    ? tr('Auf deinen Favoriten-Sendern läuft gerade kein Sport.')
                    : tr('Andere Sportart wählen.'))
            : ListView(
                key: const ValueKey('sport-list'),
                padding: const EdgeInsets.only(bottom: 32),
                children: rows);

    return Scaffold(
      backgroundColor: tv ? TvColors.bg : null,
      appBar: tv
          ? null
          : AppBar(title: Text(tr('Sport'))),
      body: SafeArea(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (tv)
            Padding(
              padding: const EdgeInsets.fromLTRB(tvPad, 18, tvPad, 0),
              child: Text(tr('Sport'), style: TvText.title),
            ),
          header,
          Expanded(child: body),
        ]),
      ),
    );
  }
}

class _SportRow extends ConsumerWidget {
  final SportEvent event;
  final DateTime now;
  final bool tv;
  final List<Channel> all;
  const _SportRow(
      {required this.event,
      required this.now,
      required this.tv,
      required this.all});

  Future<void> _tap(BuildContext context, WidgetRef ref) async {
    final c = event.channel, e = event.entry;
    if (event.liveAt(DateTime.now())) {
      await playChannel(context, ref, c, all);
      return;
    }
    final rem = ref.read(remindersProvider.notifier);
    final on = rem.isSet(c, e);
    final pick = await showActionSheet<int>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            title: Text(e.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(ctx).textTheme.titleMedium),
          ),
          ListTile(
              key: const ValueKey('sport-remind'),
              autofocus: true,
              leading: Icon(on
                  ? Icons.notifications_off_rounded
                  : Icons.notifications_active_rounded),
              title: Text(on ? tr('Erinnerung entfernen') : tr('Erinnern')),
              onTap: () => Navigator.pop(ctx, 0)),
          ListTile(
              key: const ValueKey('sport-tune'),
              leading: const Icon(Icons.live_tv_rounded),
              title: Text(trf('{0} jetzt einschalten', [c.name])),
              onTap: () => Navigator.pop(ctx, 1)),
        ]),
      ),
    );
    if (!context.mounted) return;
    if (pick == 0) {
      final set = await rem.toggle(c, e);
      if (context.mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
            content: Text(set
                ? trf('Erinnerung für „{0}“ gesetzt', [e.title])
                : tr('Erinnerung entfernt'))));
      }
    } else if (pick == 1) {
      await playChannel(context, ref, c, all);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = event.channel, e = event.entry;
    final live = event.liveAt(now);
    final hm = DateFormat.Hm(L10n.lang);
    final reminded = !live &&
        ref.read(remindersProvider.notifier).isSet(c, e);
    final day = DateUtils.isSameDay(e.start, now)
        ? ''
        : '${DateFormat.E(L10n.lang).format(e.start)} ';
    final time = '$day${hm.format(e.start)}–${hm.format(e.end)}';
    final small = tv ? TvText.small : Theme.of(context).textTheme.bodySmall;
    return FocusableTile(
      key: ValueKey('sport-row-${c.id}-${e.start.millisecondsSinceEpoch}'),
      onTap: () => _tap(context, ref),
      semanticLabel: [
        e.title,
        c.name,
        live ? tr('läuft jetzt') : time,
        if (reminded) tr('Erinnerung gesetzt'),
      ].join(', '),
      child: Padding(
        padding: EdgeInsets.symmetric(
            horizontal: tv ? 4 : 6, vertical: tv ? 4 : 8),
        child: Row(children: [
          ChannelLogo(name: c.name, url: c.logoUrl, size: tv ? 26 : 44),
          SizedBox(width: tv ? 8 : 12),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                if (live) ...[
                  const LiveBadge(),
                  SizedBox(width: tv ? 4 : 6),
                ],
                Expanded(
                  child: Text(e.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: tv
                          ? TvText.name
                          : const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: AppColors.text)),
                ),
              ]),
              SizedBox(height: tv ? 1 : 3),
              Text('${c.name} · $time',
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: small),
              if (live) ...[
                SizedBox(height: tv ? 3 : 5),
                ThinProgress(
                    value: event.progressAt(now), height: tv ? 2 : 3),
              ],
            ]),
          ),
          if (reminded)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Icon(Icons.notifications_active_rounded,
                  size: tv ? 12 : 18, color: AppColors.accent),
            ),
          if (!live && !reminded)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Icon(Icons.notifications_none_rounded,
                  size: tv ? 12 : 18, color: AppColors.textFaint),
            ),
        ]),
      ),
    );
  }
}
