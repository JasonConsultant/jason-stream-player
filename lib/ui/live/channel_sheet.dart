import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/security.dart';
import '../../core/theme.dart';
import '../../models/models.dart';
import '../../state/providers.dart';
import '../nav.dart';
import '../widgets/artwork.dart';
import '../widgets/common.dart';
import '../widgets/focusable_tile.dart';
import 'channel_edit_screen.dart';
import 'my_groups_ui.dart';
import 'parental.dart';

/// Sender-Menü: Favorit, Sperren, Verstecken – und das Catch-up-Archiv
/// mit allen vergangenen Sendungen der letzten Tage.
Future<void> showChannelSheet(BuildContext context, WidgetRef ref, Channel c,
    {bool archiveFirst = false}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    constraints: const BoxConstraints(maxWidth: 640),
    builder: (_) => FractionallySizedBox(
      heightFactor: c.hasCatchup ? 0.86 : null,
      child: _ChannelSheet(channel: c, archiveFirst: archiveFirst),
    ),
  );
}

class _ChannelSheet extends ConsumerWidget {
  final Channel channel;
  final bool archiveFirst;
  const _ChannelSheet({required this.channel, required this.archiveFirst});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = channel;
    final flags = ref.watch(channelFlagsProvider).value ?? ChannelFlags.empty;
    final notifier = ref.read(channelFlagsProvider.notifier);
    final fav = flags.favorites.contains(c.id);
    final locked = flags.locked.contains(c.id);
    final t = Theme.of(context).textTheme;

    final header = Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      child: Row(children: [
        ChannelLogo(name: c.name, url: c.logoUrl, size: 40),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(c.name, style: t.titleLarge),
            Text(
              c.hasCatchup
                  ? trf('Kanal {0} · Catch-up {1} Tage', [c.number, c.catchupDays])
                  : trf('Kanal {0}', [c.number]),
              style: t.bodySmall,
            ),
          ]),
        ),
      ]),
    );

    final actions = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(children: [
        _Action(
          icon: fav ? Icons.star_rounded : Icons.star_outline_rounded,
          label: fav ? tr('Favorit') : tr('Favorisieren'),
          color: fav ? AppColors.gold : null,
          autofocus: !archiveFirst,
          onTap: () => notifier.toggleFavorite(c.id),
        ),
        _Action(
          icon: Icons.playlist_add_rounded,
          label: tr('Gruppen'),
          onTap: () => showGroupPicker(context, ref, c),
        ),
        _Action(
          icon: locked ? Icons.lock_rounded : Icons.lock_open_rounded,
          label: locked ? tr('Gesperrt') : tr('Sperren'),
          color: locked ? AppColors.accent : null,
          onTap: () async {
            if (await ensurePin(context, ref)) notifier.toggleLocked(c.id);
          },
        ),
        _Action(
          icon: Icons.visibility_off_rounded,
          label: tr('Verstecken'),
          onTap: () {
            notifier.toggleHidden(c.id);
            Navigator.pop(context);
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(trf('{0} versteckt', [c.name])),
              action: SnackBarAction(
                  label: tr('Rückgängig'),
                  onPressed: () => notifier.toggleHidden(c.id)),
            ));
          },
        ),
      ]),
    );

    // „Sender bearbeiten“: Name, Logo, EPG-Zuordnung (wie TiviMate).
    final edit = Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      child: FocusableTile(
        onTap: () {
          // Sheet schließen, dann die Seite öffnen – sonst zeigt das Sheet
          // nach dem Zurückkommen veraltete Daten.
          final nav = Navigator.of(context, rootNavigator: true);
          Navigator.pop(context);
          nav.push(MaterialPageRoute<void>(
              builder: (_) => ChannelEditScreen(channel: c)));
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Row(children: [
            const Icon(Icons.edit_rounded, color: AppColors.textDim),
            const SizedBox(width: 14),
            Expanded(
              child: Text(tr('Sender bearbeiten'),
                  style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppColors.text)),
            ),
            const Icon(Icons.chevron_right_rounded, color: AppColors.textDim),
          ]),
        ),
      ),
    );

    if (!c.hasCatchup) {
      return SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          header,
          actions,
          edit,
          const SizedBox(height: 24),
        ]),
      );
    }

    return Column(children: [
      header,
      actions,
      edit,
      const SizedBox(height: 16),
      const Divider(height: 1),
      Expanded(child: _Archive(channel: c, autofocus: archiveFirst)),
    ]);
  }
}

class _Action extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color? color;
  final bool autofocus;
  final VoidCallback onTap;
  const _Action({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
    this.autofocus = false,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: FocusableTile(
          autofocus: autofocus,
          selected: true,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Column(children: [
              Icon(icon, color: color ?? AppColors.textDim),
              const SizedBox(height: 6),
              Text(label,
                  style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppColors.text)),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Vergangene Sendungen, nach Tagen gruppiert (neueste zuerst).
class _Archive extends ConsumerStatefulWidget {
  final Channel channel;
  final bool autofocus;
  const _Archive({required this.channel, required this.autofocus});

  @override
  ConsumerState<_Archive> createState() => _ArchiveState();
}

class _ArchiveState extends ConsumerState<_Archive> {
  int _day = 0;

  @override
  Widget build(BuildContext context) {
    final c = widget.channel;
    final async = ref.watch(channelEpgProvider(c));
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final days = [
      for (var i = 0; i <= c.catchupDays.clamp(0, 14); i++)
        today.subtract(Duration(days: i)),
    ];
    final dayFmt = DateFormat('EEE d.M.', L10n.lang);

    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => EmptyState(
          icon: Icons.error_outline, title: tr('Archiv nicht verfügbar'), message: Redactor.friendly(e)),
      data: (all) {
        final from = days[_day];
        final to = from.add(const Duration(days: 1));
        final limit = now.subtract(Duration(days: c.catchupDays));
        final items = all
            .where((e) =>
                !e.start.isBefore(from) &&
                e.start.isBefore(to) &&
                e.start.isAfter(limit) &&
                e.start.isBefore(now))
            .toList()
            .reversed
            .toList();

        return Column(children: [
          SizedBox(
            height: 52,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
              itemCount: days.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (_, i) => ChoiceChip(
                label: Text(i == 0
                    ? tr('Heute')
                    : i == 1
                        ? tr('Gestern')
                        : dayFmt.format(days[i])),
                selected: i == _day,
                showCheckmark: false,
                labelStyle: TextStyle(
                    color: i == _day ? const Color(0xFF1A0B04) : AppColors.text,
                    fontWeight: FontWeight.w600),
                onSelected: (_) => setState(() => _day = i),
              ),
            ),
          ),
          Expanded(
            child: items.isEmpty
                ? EmptyState(
                    icon: Icons.history_toggle_off_rounded,
                    title: tr('Nichts im Archiv'),
                    message: tr('Für diesen Tag gibt es keine Aufzeichnungen.'))
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                    itemCount: items.length,
                    itemBuilder: (_, i) {
                      final e = items[i];
                      final running = e.isNowAt(now);
                      return FocusableTile(
                        autofocus: widget.autofocus && i == 0,
                        onTap: () => playCatchup(context, ref, c, e),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 12),
                          child: Row(children: [
                            SizedBox(
                              width: 56,
                              child: Text(hm.format(e.start),
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                      color: AppColors.text,
                                      fontFeatures: [
                                        FontFeature.tabularFigures()
                                      ])),
                            ),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(e.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleSmall),
                                  const SizedBox(height: 2),
                                  Text(
                                      running
                                          ? tr('Läuft gerade · von Anfang an')
                                          : fmtDuration(e.duration),
                                      style:
                                          Theme.of(context).textTheme.bodySmall),
                                ],
                              ),
                            ),
                            Icon(
                                running
                                    ? Icons.replay_rounded
                                    : Icons.play_circle_outline_rounded,
                                color: AppColors.catchup),
                          ]),
                        ),
                      );
                    },
                  ),
          ),
        ]);
      },
    );
  }
}
