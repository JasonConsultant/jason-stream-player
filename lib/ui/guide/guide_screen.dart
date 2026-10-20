import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/security.dart';
import '../../core/theme.dart';
import '../../data/recordings/recordings.dart';
import '../../data/reminders/reminders.dart';
import '../../models/models.dart';
import '../../state/my_groups.dart';
import '../../state/providers.dart';
import '../nav.dart';
import '../settings/recordings_screen.dart' show showRecFeedback;
import '../widgets/artwork.dart';
import '../widgets/common.dart';
import '../widgets/focusable_tile.dart';
import '../widgets/live_preview.dart';

/// TV-Guide: Programmraster über alle Sender. Vergangene Sendungen mit
/// Archiv sind türkis markiert und direkt abspielbar (Catch-up).
class GuideScreen extends ConsumerStatefulWidget {
  const GuideScreen({super.key});

  @override
  ConsumerState<GuideScreen> createState() => _GuideScreenState();
}

class _GuideScreenState extends ConsumerState<GuideScreen> {
  late DateTime _start;
  late DateTime _end;
  final _offset = ValueNotifier<double>(0);
  /// Sender der fokussierten Zeile (für die Live-Vorschau).
  final _previewChannel = ValueNotifier<Channel?>(null);
  String _categoryId = '__all';
  bool _initialised = false;

  static const _rowH = 66.0;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _start = DateTime(now.year, now.month, now.day, now.hour)
        .subtract(const Duration(hours: 6));
    _end = _start.add(const Duration(hours: 30));
  }

  @override
  void dispose() {
    _offset.dispose();
    _previewChannel.dispose();
    super.dispose();
  }

  double _ppm(bool tv) => tv ? 6.0 : 5.0; // Pixel pro Minute
  double _x(DateTime t, double ppm) =>
      t.difference(_start).inSeconds / 60 * ppm;

  void _jumpToNow(double ppm) {
    _offset.value = math.max(
        0, _x(DateTime.now().subtract(const Duration(minutes: 30)), ppm));
  }

  @override
  Widget build(BuildContext context) {
    final tv = ref.watch(isTvProvider);
    final live = ref.watch(liveDataProvider);
    final epg = ref.watch(epgProvider).value ?? const {};
    final flags = ref.watch(channelFlagsProvider).value ?? ChannelFlags.empty;
    final order = ref.watch(sortOrderProvider).value ?? SortOrder.empty;
    final recents = ref.watch(recentProvider).value ?? const <String>[];
    final myGroups = ref.watch(myGroupsProvider).value ?? const <MyGroup>[];
    ref.watch(minuteTickProvider);
    final size = MediaQuery.sizeOf(context);
    final narrow = size.width < 600;
    // Live-Vorschau nur auf breiten Layouts (TV/Tablet), nicht auf dem Handy.
    final showPreview = !narrow &&
        (tv || size.width >= 900) &&
        size.height >= 480 &&
        (ref.watch(livePreviewEnabledProvider).value ?? true);
    final previewW = size.height >= 720 ? 320.0 : 240.0;
    final ppm = _ppm(tv);
    final labelW = narrow ? 76.0 : (tv ? 230.0 : 210.0);
    if (!_initialised) {
      _initialised = true;
      _jumpToNow(ppm);
    }

    return live.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => EmptyState(
          icon: Icons.cloud_off_rounded,
          title: tr('Keine Verbindung'),
          message: Redactor.friendly(e)),
      data: (data) {
        final filtered = data.channels
            .where((c) => !flags.isHidden(c.id))
            .where((c) => !order.hiddenGroups.contains(c.categoryId))
            .where((c) => _categoryId == '__all'
                ? true
                : _categoryId == '__fav'
                    ? flags.favorites.contains(c.id)
                    : _categoryId == '__recent'
                        ? recents.contains(c.id)
                        : MyGroup.isMy(_categoryId)
                            ? true
                            : c.categoryId == _categoryId)
            .toList();
        final List<Channel> channels;
        if (MyGroup.isMy(_categoryId)) {
          final g = myGroups.where((x) => x.id == _categoryId).firstOrNull;
          final byId = {for (final c in filtered) c.id: c};
          channels = order.sortChannels(_categoryId, [
            for (final id in g?.channels ?? const <String>[])
              if (byId[id] != null) byId[id]!,
          ]);
        } else if (_categoryId == '__recent') {
          // Neueste zuerst.
          final byId = {for (final c in filtered) c.id: c};
          channels = [
            for (final id in recents)
              if (byId[id] != null) byId[id]!,
          ];
        } else {
          channels = _categoryId == '__all'
              ? filtered
              : order.sortChannels(_categoryId, filtered);
        }
        final cats = [
          Category(id: '__all', name: tr('Alle')),
          Category(id: '__fav', name: tr('★ Favoriten')),
          if (recents.isNotEmpty || _categoryId == '__recent')
            Category(id: '__recent', name: tr('Zuletzt gesehen')),
          for (final g in myGroups) Category(id: g.id, name: g.name),
          ...order
              .sortGroups(data.categories)
              .where((c) => !order.hiddenGroups.contains(c.id)),
        ];

        final header = Column(children: [
          PageHeader(
            tr('TV-Guide'),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              if (!narrow) ...[
                _Legend(color: AppColors.catchup, text: tr('Catch-up')),
                const SizedBox(width: 14),
                _Legend(color: AppColors.accent, text: tr('Läuft')),
                const SizedBox(width: 20),
              ],
              FilledButton.tonalIcon(
                onPressed: () => _jumpToNow(ppm),
                icon: const Icon(Icons.my_location_rounded, size: 18),
                label: Text(tr('Jetzt')),
              ),
            ]),
          ),
          const _EpgProgressBanner(),
          SizedBox(
            height: 44,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.symmetric(horizontal: narrow ? 16 : 28),
              itemCount: cats.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (_, i) {
                final c = cats[i];
                final sel = c.id == _categoryId;
                return ChoiceChip(
                  avatar: c.id == '__recent' || MyGroup.isMy(c.id)
                      ? Icon(
                          MyGroup.isMy(c.id)
                              ? Icons.folder_special_rounded
                              : Icons.history_rounded,
                          size: 16,
                          color:
                              sel ? const Color(0xFF1A0B04) : AppColors.textDim)
                      : null,
                  label: Text(c.name),
                  selected: sel,
                  showCheckmark: false,
                  labelStyle: TextStyle(
                      color: sel ? const Color(0xFF1A0B04) : AppColors.text,
                      fontWeight: FontWeight.w600),
                  onSelected: (_) => setState(() => _categoryId = c.id),
                );
              },
            ),
          ),
        ]);

        return Column(children: [
          if (showPreview)
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: header),
              Padding(
                padding: const EdgeInsets.fromLTRB(0, 16, 28, 0),
                child: SizedBox(
                  width: previewW,
                  child: ValueListenableBuilder<Channel?>(
                    valueListenable: _previewChannel,
                    builder: (context, c, _) {
                      final ch = c != null && channels.contains(c)
                          ? c
                          : (channels.isEmpty ? null : channels.first);
                      return LivePreview(
                        channel: ch,
                        radius: const BorderRadius.all(Radius.circular(10)),
                        onOpen: ch == null
                            ? null
                            : () => withPreviewPaused(ref,
                                () => playChannel(context, ref, ch, channels)),
                      );
                    },
                  ),
                ),
              ),
            ])
          else
            header,
          const SizedBox(height: 10),
          Expanded(
            child: LayoutBuilder(builder: (context, box) {
              final viewW = box.maxWidth - labelW;
              final totalW = _x(_end, ppm);
              void clamp() => _offset.value =
                  _offset.value.clamp(0, math.max(0, totalW - viewW));
              return GestureDetector(
                onHorizontalDragUpdate: (d) {
                  _offset.value -= d.delta.dx;
                  clamp();
                },
                child: Column(children: [
                  _TimeRuler(
                    start: _start,
                    end: _end,
                    ppm: ppm,
                    labelW: labelW,
                    offset: _offset,
                  ),
                  Expanded(
                    child: Stack(children: [
                      ListView.builder(
                        padding: const EdgeInsets.only(bottom: 24),
                        itemCount: channels.length,
                        itemExtent: _rowH,
                        itemBuilder: (context, i) {
                          final c = channels[i];
                          final entries = epgOf(epg, c);
                          if (entries.isEmpty) {
                            ref.read(epgProvider.notifier).want(c);
                          }
                          return _GuideRow(
                            channel: c,
                            entries: entries,
                            labelW: labelW,
                            narrow: narrow,
                            ppm: ppm,
                            start: _start,
                            end: _end,
                            offset: _offset,
                            autofocusNow: i == 0,
                            onFocusX: (x0, x1) {
                              _previewChannel.value = c;
                              if (x0 < _offset.value + 8 ||
                                  x0 > _offset.value + viewW - 120) {
                                _offset.value = x0 - 24;
                                clamp();
                              }
                            },
                            onOpen: (e) => _open(context, c, e, channels),
                            onMenu: (e) => _details(context, c, e, channels),
                          );
                        },
                      ),
                      // Jetzt-Linie
                      ValueListenableBuilder<double>(
                        valueListenable: _offset,
                        builder: (_, off, __) {
                          final x = labelW + _x(DateTime.now(), ppm) - off;
                          if (x < labelW || x > box.maxWidth) {
                            return const SizedBox.shrink();
                          }
                          return Positioned(
                            left: x - 1,
                            top: 0,
                            bottom: 0,
                            child: IgnorePointer(
                              child: Container(width: 2, color: AppColors.live),
                            ),
                          );
                        },
                      ),
                    ]),
                  ),
                ]),
              );
            }),
          ),
        ]);
      },
    );
  }

  Future<void> _open(
      BuildContext context, Channel c, EpgEntry e, List<Channel> list) async {
    final now = DateTime.now();
    if (e.isNowAt(now)) {
      return withPreviewPaused(
          ref, () => playChannel(context, ref, c, list));
    }
    await _details(context, c, e, list);
  }

  Future<void> _details(
      BuildContext context, Channel c, EpgEntry e, List<Channel> list) async {
    await showModalBottomSheet<void>(
      context: context,
      constraints: const BoxConstraints(maxWidth: 640),
      builder: (_) => _ProgrammeSheet(channel: c, entry: e, channels: list),
    );
  }
}

class _Legend extends StatelessWidget {
  final Color color;
  final String text;
  const _Legend({required this.color, required this.text});
  @override
  Widget build(BuildContext context) => Row(children: [
        Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
                color: color, borderRadius: BorderRadius.circular(3))),
        const SizedBox(width: 6),
        Text(text, style: Theme.of(context).textTheme.bodySmall),
      ]);
}

class _TimeRuler extends StatelessWidget {
  final DateTime start, end;
  final double ppm, labelW;
  final ValueNotifier<double> offset;
  const _TimeRuler({
    required this.start,
    required this.end,
    required this.ppm,
    required this.labelW,
    required this.offset,
  });

  @override
  Widget build(BuildContext context) {
    final dayFmt = DateFormat('EEE', L10n.lang);
    final marks = <DateTime>[];
    for (var t = start;
        t.isBefore(end);
        t = t.add(const Duration(minutes: 30))) {
      marks.add(t);
    }
    return SizedBox(
      height: 34,
      child: Row(children: [
        SizedBox(
          width: labelW,
          child: Padding(
            padding: const EdgeInsets.only(left: 20),
            child: Align(
              alignment: Alignment.centerLeft,
              child: ValueListenableBuilder<double>(
                valueListenable: offset,
                builder: (_, off, __) {
                  final t = start.add(Duration(minutes: (off / ppm).round()));
                  final now = DateTime.now();
                  final label = t.day == now.day
                      ? tr('Heute')
                      : t.isBefore(now)
                          ? tr('Gestern')
                          : dayFmt.format(t);
                  return Text(label.toUpperCase(),
                      style: Theme.of(context).textTheme.labelSmall);
                },
              ),
            ),
          ),
        ),
        Expanded(
          child: ClipRect(
            child: ValueListenableBuilder<double>(
              valueListenable: offset,
              builder: (_, off, __) =>
                  Stack(clipBehavior: Clip.none, children: [
                for (final m in marks)
                  Positioned(
                    left: m.difference(start).inMinutes * ppm - off,
                    top: 8,
                    child: Text(
                      hm.format(m),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight:
                            m.minute == 0 ? FontWeight.w700 : FontWeight.w500,
                        color: m.minute == 0
                            ? AppColors.textDim
                            : AppColors.textFaint,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
              ]),
            ),
          ),
        ),
      ]),
    );
  }
}

class _GuideRow extends StatelessWidget {
  final Channel channel;
  final List<EpgEntry> entries;
  final double labelW, ppm;
  final bool narrow;
  final DateTime start, end;
  final ValueNotifier<double> offset;
  final bool autofocusNow;
  final void Function(double x0, double x1) onFocusX;
  final ValueChanged<EpgEntry> onOpen;
  final ValueChanged<EpgEntry> onMenu;

  const _GuideRow({
    required this.onMenu,
    required this.channel,
    required this.entries,
    required this.labelW,
    required this.narrow,
    required this.ppm,
    required this.start,
    required this.end,
    required this.offset,
    required this.autofocusNow,
    required this.onFocusX,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final c = channel;
    final now = DateTime.now();
    final visible =
        entries.where((e) => e.end.isAfter(start) && e.start.isBefore(end));

    return Container(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.line, width: 0.5)),
      ),
      child: Row(children: [
        Container(
          width: labelW,
          color: AppColors.bg,
          padding: EdgeInsets.symmetric(horizontal: narrow ? 8 : 16),
          child: Row(children: [
            if (!narrow) ...[
              SizedBox(
                width: 26,
                child: Text('${c.number}',
                    style: const TextStyle(
                        fontSize: 12, color: AppColors.textFaint)),
              ),
            ],
            ChannelLogo(name: c.name, url: c.logoUrl, size: narrow ? 34 : 36),
            if (!narrow) ...[
              const SizedBox(width: 12),
              Expanded(
                child: Text(c.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppColors.text)),
              ),
            ],
          ]),
        ),
        Expanded(
          child: ClipRect(
            child: ValueListenableBuilder<double>(
              valueListenable: offset,
              builder: (_, off, __) => Stack(children: [
                if (visible.isEmpty)
                  Positioned.fill(
                    child: Padding(
                      padding: const EdgeInsets.all(3),
                      child: DecoratedBox(
                        decoration: const BoxDecoration(
                          color: AppColors.surface,
                          borderRadius: BorderRadius.all(Radius.circular(8)),
                        ),
                        child: Center(
                          child: Text(tr('Keine Programminfo'),
                              style: const TextStyle(
                                  fontSize: 12, color: AppColors.textFaint)),
                        ),
                      ),
                    ),
                  ),
                for (final e in visible) _tile(e, now, off),
              ]),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _tile(EpgEntry e, DateTime now, double off) {
    final s = e.start.isBefore(start) ? start : e.start;
    final en = e.end.isAfter(end) ? end : e.end;
    final x0 = s.difference(start).inSeconds / 60 * ppm;
    final w = en.difference(s).inSeconds / 60 * ppm;
    final isNow = e.isNowAt(now);
    final past = e.isPastAt(now);
    final archived = past &&
        channel.hasCatchup &&
        e.start.isAfter(now.subtract(Duration(days: channel.catchupDays)));

    return Positioned(
      left: x0 - off,
      width: w,
      top: 0,
      bottom: 0,
      child: Padding(
        padding: const EdgeInsets.all(3),
        child: FocusableTile(
          autofocus: autofocusNow && isNow,
          radius: BorderRadius.circular(8),
          onFocus: () => onFocusX(x0, x0 + w),
          onTap: () => onOpen(e),
          onLongPress: () => onMenu(e),
          child: Container(
            decoration: BoxDecoration(
              color: isNow
                  ? const Color(0xFF2A1D18)
                  : archived
                      ? const Color(0xFF0F2622)
                      : past
                          ? const Color(0xFF0E1015)
                          : AppColors.surface,
              borderRadius: BorderRadius.circular(8),
              border: isNow
                  ? Border.all(color: AppColors.accent.withValues(alpha: 0.6))
                  : null,
            ),
            padding: EdgeInsets.fromLTRB(
                10 + (off - x0).clamp(0, (w - 90).clamp(0, double.infinity)),
                7,
                8,
                6),
            child: w < 28
                ? const SizedBox.shrink()
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        if (archived) ...[
                          const Icon(Icons.history_rounded,
                              size: 13, color: AppColors.catchup),
                          const SizedBox(width: 4),
                        ],
                        Expanded(
                          child: Text(
                            e.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: past && !archived
                                  ? AppColors.textFaint
                                  : AppColors.text,
                            ),
                          ),
                        ),
                      ]),
                      const SizedBox(height: 3),
                      Text(
                        '${hm.format(e.start)} – ${hm.format(e.end)}',
                        maxLines: 1,
                        overflow: TextOverflow.clip,
                        style: const TextStyle(
                            fontSize: 11, color: AppColors.textFaint),
                      ),
                      const Spacer(),
                      if (isNow)
                        ThinProgress(value: e.progressAt(now), height: 2.5),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

class _ProgrammeSheet extends ConsumerWidget {
  final Channel channel;
  final EpgEntry entry;
  final List<Channel> channels;
  const _ProgrammeSheet(
      {required this.channel, required this.entry, required this.channels});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final e = entry;
    final c = channel;
    final t = Theme.of(context).textTheme;
    final now = DateTime.now();
    final past = e.isPastAt(now);
    final running = e.isNowAt(now);
    final canCatchup = past &&
        c.hasCatchup &&
        e.start.isAfter(now.subtract(Duration(days: c.catchupDays)));
    final day = DateFormat('EEEE, d. MMMM', L10n.lang).format(e.start);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              ChannelLogo(name: c.name, url: c.logoUrl, size: 30),
              const SizedBox(width: 10),
              Text(c.name, style: t.titleSmall),
            ]),
            const SizedBox(height: 14),
            Text(e.title,
                style: t.headlineSmall?.copyWith(fontFamily: 'InterDisplay')),
            const SizedBox(height: 6),
            Text(
                '$day · ${hm.format(e.start)} – ${hm.format(e.end)} · '
                '${fmtDuration(e.duration)}',
                style: t.bodySmall),
            if (e.description != null) ...[
              const SizedBox(height: 14),
              Text(e.description!, style: t.bodyMedium?.copyWith(height: 1.5)),
            ],
            const SizedBox(height: 22),
            if (running)
              Wrap(spacing: 10, runSpacing: 10, children: [
                FilledButton.icon(
                  autofocus: true,
                  onPressed: () {
                    Navigator.pop(context);
                    withPreviewPaused(ref, () => playChannel(context, ref, c, channels));
                  },
                  icon: const Icon(Icons.live_tv_rounded),
                  label: Text(tr('Live ansehen')),
                ),
                if (c.hasCatchup)
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                        backgroundColor: AppColors.catchup,
                        foregroundColor: const Color(0xFF04201A)),
                    onPressed: () {
                      Navigator.pop(context);
                      withPreviewPaused(ref, () => playCatchup(context, ref, c, e, channels: channels));
                    },
                    icon: const Icon(Icons.replay_rounded),
                    label: Text(tr('Von Anfang')),
                  ),
              ])
            else if (canCatchup)
              FilledButton.icon(
                autofocus: true,
                style: FilledButton.styleFrom(
                    backgroundColor: AppColors.catchup,
                    foregroundColor: const Color(0xFF04201A)),
                onPressed: () {
                  Navigator.pop(context);
                  withPreviewPaused(ref, () => playCatchup(context, ref, c, e, channels: channels));
                },
                icon: const Icon(Icons.replay_rounded),
                label: Text(tr('Replay abspielen')),
              )
            else if (past)
              Text(tr('Diese Sendung ist nicht im Archiv.'), style: t.bodySmall)
            else
              FilledButton.icon(
                autofocus: true,
                onPressed: () {
                  Navigator.pop(context);
                  withPreviewPaused(ref, () => playChannel(context, ref, c, channels));
                },
                icon: const Icon(Icons.live_tv_rounded),
                label: Text(tr('Sender einschalten')),
              ),
            if (!past && (!kIsWeb || !running)) ...[
              const SizedBox(height: 10),
              Wrap(spacing: 10, runSpacing: 10, children: [
                if (!kIsWeb)
                  Consumer(builder: (context, ref, _) {
                    final rec = ref.watch(recordingsProvider);
                    final planned = rec.any((r) =>
                        r.channelId == c.id &&
                        r.title == e.title &&
                        (r.status == 'geplant' || r.status == 'läuft') &&
                        r.end.isAfter(e.start));
                    return OutlinedButton.icon(
                      onPressed: planned
                          ? null
                          : () async {
                              final r = await ref
                                  .read(recordingsProvider.notifier)
                                  .schedule(c, e);
                              if (context.mounted) {
                                await showRecFeedback(context, r,
                                    trf('Aufnahme geplant: {0}', [e.title]));
                              }
                              if (context.mounted) Navigator.pop(context);
                            },
                      icon: Icon(planned
                          ? Icons.check_circle_rounded
                          : Icons.fiber_manual_record_rounded),
                      label: Text(
                          planned ? tr('Aufnahme geplant') : tr('Aufnehmen')),
                    );
                  }),
                // Erinnerung kurz vor Beginn (nur für kommende Sendungen).
                if (!running)
                  Consumer(builder: (context, ref, _) {
                    ref.watch(remindersProvider);
                    final on = ref.read(remindersProvider.notifier).isSet(c, e);
                    return OutlinedButton.icon(
                      onPressed: () =>
                          ref.read(remindersProvider.notifier).toggle(c, e),
                      icon: Icon(on
                          ? Icons.notifications_active_rounded
                          : Icons.notifications_none_rounded),
                      label: Text(on ? tr('Erinnerung aktiv') : tr('Erinnern')),
                    );
                  }),
              ]),
            ],
          ],
        ),
      ),
    );
  }
}


/// Während das EPG lädt: Fortschritt direkt im Guide statt leerer Zeilen
/// ohne Erklärung.
class _EpgProgressBanner extends ConsumerWidget {
  const _EpgProgressBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(epgStatusProvider);
    if (!st.updating) return const SizedBox.shrink();
    final narrow = MediaQuery.sizeOf(context).width < 600;
    final p = st.progress;
    double? value;
    if (p != null && !p.$5 && p.$4 != null && p.$4! > 0) {
      value = (p.$3 / p.$4!).clamp(0.0, 1.0);
    }
    return Padding(
      padding: EdgeInsets.fromLTRB(narrow ? 16 : 28, 0, narrow ? 16 : 28, 10),
      child: Row(children: [
        SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2, value: value),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            '${tr('Programm wird geladen')} · ${st.progressText ?? '…'}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ]),
    );
  }
}
