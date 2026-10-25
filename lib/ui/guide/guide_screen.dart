import 'dart:math' as math;
import '../widgets/action_sheet.dart';

import 'package:flutter/foundation.dart' show ValueListenable, kIsWeb;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/strings.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/security.dart';
import '../../core/theme.dart';
import '../../data/image_caches.dart';
import '../../data/recordings/recordings.dart';
import '../../data/reminders/reminders.dart';
import '../../models/models.dart';
import '../../state/channel_variants.dart' show resolveChannelIds;
import '../../state/epg_select.dart';
import '../../state/my_groups.dart';
import '../../state/providers.dart';
import '../nav.dart';
import '../settings/epg_sources_screen.dart' show suggestPreset, useCountryEpg;
import 'guide_days.dart';
import '../settings/recordings_screen.dart' show showRecFeedback;
import '../widgets/artwork.dart';
import '../widgets/a11y.dart';
import '../widgets/common.dart';
import '../widgets/fine_grained.dart';
import '../widgets/focusable_tile.dart';
import '../widgets/live_preview.dart';
import '../../state/profile_mode.dart';

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

  /// TV: fokussierte Sendung (für den Info-Kopf oben).
  final _focusInfo = ValueNotifier<(Channel, EpgEntry?)?>(null);

  /// TV: sichtbare Zeilen (Sender-ID → Zeile) und Reihenfolge, damit ▲/▼
  /// zur Sendung zur gleichen Uhrzeit in der Nachbarzeile springt (statt
  /// zu einer unsichtbaren, links herausgescrollten Kachel).
  final _rows = <String, _GuideRowState>{};
  List<Channel> _tvChannels = const [];
  final _tvScroll = ScrollController();
  String _categoryId = '__all';

  /// Für welchen Modus (TV ja/nein) zuletzt auf „Jetzt“ gesprungen wurde –
  /// isTvProvider ist im ersten Frame oft noch false.
  bool? _jumpedFor;

  /// Gewählter Tag relativ zu heute (−7 … +7, Tagesauswahl).
  int _day = 0;

  /// Zeitfenster für Tag [d]: heute wie bisher (−6 h … +24 h), sonst der
  /// ganze Tag (00:00 bis 02:00 am Folgetag).
  void _setWindow(int d) {
    final now = DateTime.now();
    _day = d;
    if (d == 0) {
      _start = DateTime(now.year, now.month, now.day, now.hour)
          .subtract(const Duration(hours: 6));
      _end = _start.add(const Duration(hours: 30));
    } else {
      _start = DateTime(now.year, now.month, now.day + d);
      _end = DateTime(now.year, now.month, now.day + d + 1, 2);
    }
  }

  /// Tag wählen; das Raster springt auf dieselbe Uhrzeit wie jetzt.
  Future<void> _chooseDay(double ppm, bool tv) async {
    final epg = ref.read(epgProvider).value ?? const {};
    final d =
        await pickGuideDay(context, _day, guideDayOffsets(epg, DateTime.now()));
    if (d == null || !mounted) return;
    if (d == 0) {
      setState(() => _setWindow(0));
      _jumpToNow(ppm, tv: tv);
      return;
    }
    final now = DateTime.now();
    setState(() => _setWindow(d));
    final at = DateTime(
        now.year, now.month, now.day + d, now.hour, now.minute < 30 ? 0 : 30);
    _offset.value = math.max(0, _x(at, ppm) - 30 * ppm);
  }

  static const _rowH = 66.0;
  static const _tvRowH = 31.0;

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
    _focusInfo.dispose();
    _tvScroll.dispose();
    super.dispose();
  }

  double _ppm(bool tv) => tv ? 5.5 : 5.0; // Pixel pro Minute
  double _x(DateTime t, double ppm) =>
      t.difference(_start).inSeconds / 60 * ppm;

  void _jumpToNow(double ppm, {bool tv = false}) {
    if (_day != 0) setState(() => _setWindow(0)); // zurück zu „Heute“
    final now = DateTime.now();
    // TV: Raster beginnt an der laufenden halben Stunde (wie TiviMate).
    final from = tv
        ? DateTime(
            now.year, now.month, now.day, now.hour, now.minute < 30 ? 0 : 30)
        : now.subtract(const Duration(minutes: 30));
    _offset.value = math.max(0, _x(from, ppm));
  }

  @override
  Widget build(BuildContext context) {
    final tv = ref.watch(isTvProvider);
    final live = ref.watch(visibleLiveDataProvider);
    // Kein EPG und kein Minutentakt hier: jede Zeile beobachtet nur ihren
    // Sender (_GuideRowHost), Uhrzeit/Fortschritt ticken in MinuteBuilder.
    final flags = ref.watch(channelFlagsProvider).value ?? ChannelFlags.empty;
    final order = ref.watch(sortOrderProvider).value ?? SortOrder.empty;
    final recents = ref.watch(recentProvider).value ?? const <String>[];
    final myGroups = ref.watch(visibleMyGroupsProvider);
    final size = MediaQuery.sizeOf(context);
    final narrow = size.width < 600;
    // Live-Vorschau nur auf breiten Layouts (TV/Tablet), nicht auf dem Handy.
    final showPreview = !narrow &&
        (tv || size.width >= 900) &&
        size.height >= 480 &&
        (ref.watch(livePreviewEnabledProvider).value ?? true);
    final previewW = size.height >= 720 ? 320.0 : 240.0;
    final ppm = _ppm(tv);
    final labelW = narrow ? 76.0 : (tv ? 150.0 : 210.0);
    if (_jumpedFor != tv) {
      _jumpedFor = tv;
      _jumpToNow(ppm, tv: tv);
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
                        ? true
                        : MyGroup.isMy(_categoryId)
                            ? true
                            : c.categoryId == _categoryId)
            .toList();
        final List<Channel> channels;
        if (MyGroup.isMy(_categoryId)) {
          final g = myGroups.where((x) => x.id == _categoryId).firstOrNull;
          final byId = {for (final c in filtered) c.id: c};
          channels = order.sortChannels(_categoryId,
              resolveChannelIds(ref, g?.channels ?? const <String>[], byId));
        } else if (_categoryId == '__recent') {
          // Neueste zuerst.
          final byId = {for (final c in filtered) c.id: c};
          channels = resolveChannelIds(ref, recents, byId);
        } else {
          channels = _categoryId == '__all'
              ? filtered
              : order.sortChannels(_categoryId, filtered);
        }
        final cats = [
          Category(id: '__all', name: tr('Alle')),
          // Gastmodus: keine Favoriten (Verlauf ist dort ohnehin leer).
          if (!ref.watch(guestModeProvider))
            Category(id: '__fav', name: tr('★ Favoriten')),
          if (recents.isNotEmpty || _categoryId == '__recent')
            Category(id: '__recent', name: tr('Zuletzt gesehen')),
          for (final g in myGroups) Category(id: g.id, name: g.name),
          ...order
              .sortGroups(data.categories)
              .where((c) => !order.hiddenGroups.contains(c.id)),
        ];

        if (tv) {
          return _tvLayout(context, channels, cats,
              ppm: ppm, labelW: labelW, showPreview: showPreview);
        }

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
              // Tagesauswahl (Gestern / Heute / Morgen / Mi 23.10. …)
              TextButton.icon(
                key: const ValueKey('guide_day_button'),
                onPressed: () => _chooseDay(ppm, false),
                icon: const Icon(Icons.calendar_today_rounded, size: 18),
                label: MinuteBuilder(
                    builder: (_, now) => Text(guideDayLabel(_day, now))),
              ),
              const SizedBox(width: 6),
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
            child: _grid(context, channels,
                ppm: ppm, labelW: labelW, narrow: narrow, tv: false),
          ),
        ]);
      },
    );
  }

  /// Uhrzeit am linken Rand des sichtbaren Rasters.
  DateTime _viewStart(double ppm) =>
      _start.add(Duration(seconds: (_offset.value / ppm * 60).round()));

  /// TV ▲/▼: Sendung zur Uhrzeit [t] in der Zeile über/unter [from].
  /// false = nicht behandelt (z. B. ▲ aus der ersten Zeile → Chips).
  bool _moveVertical(Channel from, int dir, DateTime t) {
    final i = _tvChannels.indexWhere((c) => c.id == from.id);
    if (i < 0) return false;
    final j = i + dir;
    if (j < 0) return false;
    if (j >= _tvChannels.length) return true; // letzte Zeile: stehen bleiben
    final row = _rows[_tvChannels[j].id];
    if (row == null) return false;
    row.focusAt(t);
    return true;
  }

  /// TV ▼ aus der Chip-Zeile: erste sichtbare Zeile, Sendung „jetzt“
  /// (bzw. am linken Rand, falls „jetzt“ nicht im Bild ist).
  bool _enterGrid(double ppm) {
    if (_tvChannels.isEmpty) return false;
    final first = _tvScroll.hasClients
        ? (_tvScroll.offset / _tvRowH).ceil().clamp(0, _tvChannels.length - 1)
        : 0;
    final row = _rows[_tvChannels[first].id];
    if (row == null) return false;
    final now = DateTime.now();
    final left = _viewStart(ppm);
    row.focusAt(now.isAfter(left) ? now : left);
    return true;
  }

  /// Programmraster (Zeitleiste + Senderzeilen + Jetzt-Linie).
  Widget _grid(BuildContext context, List<Channel> channels,
      {required double ppm,
      required double labelW,
      required bool narrow,
      required bool tv}) {
    return LayoutBuilder(builder: (context, box) {
      final viewW = box.maxWidth - labelW;
      final totalW = _x(_end, ppm);
      void clamp() =>
          _offset.value = _offset.value.clamp(0, math.max(0, totalW - viewW));
      final list = ListView.builder(
        controller: tv ? _tvScroll : null,
        padding: const EdgeInsets.only(bottom: 24),
        itemCount: channels.length,
        itemExtent: tv ? _tvRowH : _rowH,
        // Zeilen ohne Zustand, der das Herausscrollen überleben müsste.
        addAutomaticKeepAlives: false,
        itemBuilder: (context, i) {
          final c = channels[i];
          return _GuideRowHost(
            key: tv ? ValueKey(c.id) : null,
            channel: c,
            builder: (entries) => _GuideRow(
              channel: c,
              entries: entries,
              labelW: labelW,
              narrow: narrow,
              tv: tv,
              ppm: ppm,
              start: _start,
              end: _end,
              offset: _offset,
              autofocusNow: i == 0,
              rows: tv ? _rows : null,
              onVertical: tv ? (dir, t) => _moveVertical(c, dir, t) : null,
              onFocusX: (e, x0, x1) {
                _previewChannel.value = c;
                if (tv) {
                  _focusInfo.value = (c, e.channelEpgId == _noEpg ? null : e);
                }
                // TV: nur scrollen, wenn die Sendung gar nicht im Bild ist
                // (Uhrzeit bleibt beim Wechseln der Zeile stehen).
                final off = _offset.value;
                if (tv
                    ? (x1 < off + 8 || x0 > off + viewW - 120)
                    : (x0 < off + 8 || x0 > off + viewW - 120)) {
                  _offset.value = x0 - 24;
                  clamp();
                }
              },
              onOpen: (e) => _open(context, c, e, channels),
              onMenu: (e) => _details(context, c, e, channels),
            ),
          );
        },
      );
      // Jetzt-Linie
      final nowLine = Positioned.fill(
        child: IgnorePointer(
          child: MinuteBuilder(
            builder: (_, now) => ValueListenableBuilder<double>(
              valueListenable: _offset,
              builder: (_, off, __) {
                final x = labelW + _x(now, ppm) - off;
                if (x < labelW || x > box.maxWidth) {
                  return const SizedBox.shrink();
                }
                return Stack(children: [
                  Positioned(
                    left: x - 1,
                    top: 0,
                    bottom: 0,
                    child: Container(
                        width: tv ? 1.5 : 2,
                        color: tv ? const Color(0xFFE5484D) : AppColors.live),
                  ),
                ]);
              },
            ),
          ),
        ),
      );
      final ruler = _TimeRuler(
        start: _start,
        end: _end,
        ppm: ppm,
        labelW: labelW,
        offset: _offset,
        tv: tv,
      );
      return GestureDetector(
        onHorizontalDragUpdate: (d) {
          _offset.value -= d.delta.dx;
          clamp();
        },
        child: tv
            // TV: Linie läuft auch durch die Zeitleiste.
            ? Stack(children: [
                Column(children: [ruler, Expanded(child: list)]),
                nowLine,
              ])
            : Column(children: [
                ruler,
                Expanded(child: Stack(children: [list, nowLine])),
              ]),
      );
    });
  }

  /// TV-Layout (TiviMate-artig): Info zur fokussierten Sendung + kleine
  /// Vorschau oben, darunter Gruppen-Chips und ein dichtes Raster.
  Widget _tvLayout(
      BuildContext context, List<Channel> channels, List<Category> cats,
      {required double ppm,
      required double labelW,
      required bool showPreview}) {
    _tvChannels = channels;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 17, 24, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(
          height: 125,
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: ValueListenableBuilder<(Channel, EpgEntry?)?>(
                valueListenable: _focusInfo,
                builder: (context, f, _) {
                  if (f != null && channels.contains(f.$1)) {
                    return _TvInfo(channel: f.$1, entry: f.$2);
                  }
                  if (channels.isEmpty) return const SizedBox.shrink();
                  final c = channels.first;
                  return Consumer(
                      builder: (_, ref, __) => _TvInfo(
                          channel: c,
                          entry: ref.watch(nowNextProvider(c)).now));
                },
              ),
            ),
            const SizedBox(width: 14),
            SizedBox(
              width: 192,
              child:
                  Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                if (showPreview)
                  SizedBox(
                    height: 108,
                    child: ValueListenableBuilder<Channel?>(
                      valueListenable: _previewChannel,
                      builder: (context, c, _) {
                        final ch = c != null && channels.contains(c)
                            ? c
                            : (channels.isEmpty ? null : channels.first);
                        return LivePreview(
                          channel: ch,
                          radius: const BorderRadius.all(Radius.circular(7)),
                          onOpen: ch == null
                              ? null
                              : () => withPreviewPaused(
                                  ref,
                                  () =>
                                      playChannel(context, ref, ch, channels)),
                        );
                      },
                    ),
                  ),
                const SizedBox(height: 5),
                const _TvEpgStatus(),
              ]),
            ),
          ]),
        ),
        const SizedBox(height: 3),
        SizedBox(
          height: 20,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: cats.length + 2,
            separatorBuilder: (_, __) => const SizedBox(width: 5),
            itemBuilder: (_, i) {
              if (i == 0) {
                return _TvChip(
                  label: tr('Jetzt'),
                  icon: Icons.my_location_rounded,
                  selected: false,
                  onDown: () => _enterGrid(ppm),
                  onTap: () => _jumpToNow(ppm, tv: true),
                );
              }
              if (i == 1) {
                // Tagesauswahl (Gestern / Heute / Morgen / Mi 23.10. …)
                return MinuteBuilder(
                  builder: (_, now) => _TvChip(
                    label: guideDayLabel(_day, now),
                    icon: Icons.calendar_today_rounded,
                    selected: _day != 0,
                    onDown: () => _enterGrid(ppm),
                    onTap: () => _chooseDay(ppm, true),
                  ),
                );
              }
              final c = cats[i - 2];
              return _TvChip(
                label: c.name,
                icon: c.id == '__recent'
                    ? Icons.history_rounded
                    : MyGroup.isMy(c.id)
                        ? Icons.folder_special_rounded
                        : null,
                selected: c.id == _categoryId,
                onDown: () => _enterGrid(ppm),
                onTap: () => setState(() => _categoryId = c.id),
              );
            },
          ),
        ),
        const SizedBox(height: 7),
        Expanded(
          child: DecoratedBox(
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: _TvColors.line)),
            ),
            child: _grid(context, channels,
                ppm: ppm, labelW: labelW, narrow: false, tv: true),
          ),
        ),
      ]),
    );
  }

  Future<void> _open(
      BuildContext context, Channel c, EpgEntry e, List<Channel> list) async {
    final now = DateTime.now();
    if (e.isNowAt(now)) {
      return withPreviewPaused(ref, () => playChannel(context, ref, c, list));
    }
    await _details(context, c, e, list);
  }

  Future<void> _details(
      BuildContext context, Channel c, EpgEntry e, List<Channel> list) async {
    // TV (540 dp hoch): Blatt darf höher werden und scrollt notfalls,
    // sonst ragen die Knöpfe unten heraus.
    final tv = ref.read(isTvProvider);
    final dialog = actionSheetStyleOf(context) == ActionSheetStyle.dialog;
    await showActionSheet<void>(
      useRootNavigator: true,
      context: context,
      constraints: const BoxConstraints(maxWidth: 640),
      isScrollControlled: tv,
      builder: (_) {
        final sheet = _ProgrammeSheet(channel: c, entry: e, channels: list);
        // Tablet-Dialog: begrenzte Höhe, daher ebenfalls scrollbar.
        return tv || dialog ? SingleChildScrollView(child: sheet) : sheet;
      },
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
  final bool tv;
  const _TimeRuler({
    required this.start,
    required this.end,
    required this.ppm,
    required this.labelW,
    required this.offset,
    this.tv = false,
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
    final totalW = end.difference(start).inMinutes * ppm;
    return SizedBox(
      height: tv ? 20 : 34,
      child: Row(children: [
        SizedBox(
          width: labelW,
          child: Padding(
            padding: EdgeInsets.only(left: tv ? 4 : 20),
            child: Align(
              alignment: Alignment.centerLeft,
              child: ValueListenableBuilder<double>(
                valueListenable: offset,
                builder: (_, off, __) => MinuteBuilder(builder: (_, now) {
                  final t = start.add(Duration(minutes: (off / ppm).round()));
                  final label = t.day == now.day
                      ? tr('Heute')
                      : t.isBefore(now)
                          ? tr('Gestern')
                          : dayFmt.format(t);
                  return Text(label.toUpperCase(),
                      style: tv
                          ? const TextStyle(
                              fontSize: 7,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.8,
                              color: _TvColors.faint)
                          : Theme.of(context).textTheme.labelSmall);
                }),
              ),
            ),
          ),
        ),
        Expanded(
          child: ClipRect(
            // Uhrzeiten liegen fest auf einer breiten Ebene, die nur
            // verschoben wird – ◀/▶ baut keine Beschriftung neu.
            child: _HScroll(
              offset: offset,
              width: totalW,
              child: Stack(clipBehavior: Clip.none, children: [
                for (final m in marks)
                  Positioned(
                    left: m.difference(start).inMinutes * ppm,
                    top: tv ? 5 : 8,
                    child: Text(
                      hm.format(m),
                      style: tv
                          ? const TextStyle(
                              fontSize: 7.5,
                              height: 1.2,
                              color: _TvColors.dim2,
                              fontFeatures: [FontFeature.tabularFigures()],
                            )
                          : TextStyle(
                              fontSize: 12,
                              fontWeight: m.minute == 0
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                              color: m.minute == 0
                                  ? AppColors.textDim
                                  : AppColors.textFaint,
                              fontFeatures: const [
                                FontFeature.tabularFigures()
                              ],
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

/// Waagerecht verschiebbare Ebene der Breite [width]: Inhalte liegen an
/// festen Positionen (Minuten × ppm), [offset] verschiebt nur die
/// Darstellung. Ein ◀/▶-Sprung baut damit je Zeile ein einziges
/// Transform-Element neu statt aller Sendungs-Kacheln.
class _HScroll extends StatelessWidget {
  final ValueListenable<double> offset;
  final double width;
  final Widget child;
  const _HScroll(
      {required this.offset, required this.width, required this.child});

  @override
  Widget build(BuildContext context) {
    // Reihenfolge wichtig: OverflowBox (so breit wie das Bild) außen, das
    // Verschieben innen – sonst fielen Treffer rechts vom Bildrand beim
    // Antippen aus der Box.
    return OverflowBox(
      alignment: Alignment.topLeft,
      minWidth: width,
      maxWidth: width,
      child: ValueListenableBuilder<double>(
        valueListenable: offset,
        builder: (_, off, child) =>
            Transform.translate(offset: Offset(-off, 0), child: child),
        child: child,
      ),
    );
  }
}

/// Linker Innenabstand einer Kachel, die links aus dem Bild ragt: Titel
/// bleibt lesbar am Rand stehen („sticky“). Hört selbst auf [offset] und
/// baut nur neu, wenn sich der Abstand wirklich ändert (also fast nur bei
/// der Kachel am linken Rand).
class _StickyInset extends StatefulWidget {
  final ValueListenable<double> offset;
  final double x0;

  /// Höchstens so weit (Kachelbreite minus Mindestbreite des Titels).
  final double maxShift;
  final Widget child;
  const _StickyInset({
    required this.offset,
    required this.x0,
    required this.maxShift,
    required this.child,
  });

  @override
  State<_StickyInset> createState() => _StickyInsetState();
}

class _StickyInsetState extends State<_StickyInset> {
  late double _shift = _calc();

  double _calc() => widget.maxShift <= 0
      ? 0
      : (widget.offset.value - widget.x0).clamp(0, widget.maxShift).toDouble();

  void _changed() {
    final v = _calc();
    if (v != _shift) setState(() => _shift = v);
  }

  @override
  void initState() {
    super.initState();
    widget.offset.addListener(_changed);
  }

  @override
  void didUpdateWidget(_StickyInset old) {
    super.didUpdateWidget(old);
    if (old.offset != widget.offset) {
      old.offset.removeListener(_changed);
      widget.offset.addListener(_changed);
    }
    _shift = _calc();
  }

  @override
  void dispose() {
    widget.offset.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _shift == 0
      ? widget.child
      : Padding(padding: EdgeInsets.only(left: _shift), child: widget.child);
}

/// Zeile im Raster: beobachtet nur das Programm ihres Senders (inkl.
/// Programmwechsel) – EPG-Änderungen anderer Sender und der Minutentakt
/// lassen sie in Ruhe.
class _GuideRowHost extends ConsumerWidget {
  final Channel channel;
  final _GuideRow Function(List<EpgEntry> entries) builder;
  const _GuideRowHost(
      {super.key, required this.channel, required this.builder});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // nowNextProvider meldet sich bei neuem Programm *und* wenn die
    // laufende Sendung wechselt (Farben „läuft“/„vorbei“/Archiv).
    final nn = ref.watch(nowNextProvider(channel));
    if (nn.isEmpty) ref.read(epgProvider.notifier).want(channel);
    return builder(nn.entries);
  }
}

class _GuideRow extends StatefulWidget {
  final Channel channel;
  final List<EpgEntry> entries;
  final double labelW, ppm;
  final bool narrow;
  final bool tv;
  final DateTime start, end;
  final ValueNotifier<double> offset;
  final bool autofocusNow;

  /// TV: Register der sichtbaren Zeilen (für ▲/▼).
  final Map<String, _GuideRowState>? rows;

  /// TV: ▲ (-1) / ▼ (+1) zur Uhrzeit; true = behandelt.
  final bool Function(int dir, DateTime t)? onVertical;
  final void Function(EpgEntry e, double x0, double x1) onFocusX;
  final ValueChanged<EpgEntry> onOpen;
  final ValueChanged<EpgEntry> onMenu;

  const _GuideRow({
    required this.onMenu,
    required this.channel,
    required this.entries,
    required this.labelW,
    required this.narrow,
    this.tv = false,
    required this.ppm,
    required this.start,
    required this.end,
    required this.offset,
    required this.autofocusNow,
    this.rows,
    this.onVertical,
    required this.onFocusX,
    required this.onOpen,
  });

  @override
  State<_GuideRow> createState() => _GuideRowState();
}

class _GuideRowState extends State<_GuideRow> {
  /// TV: Fokus liegt in dieser Zeile (Name und „läuft“-Kachel heben sich
  /// ab). Als Notifier: ▲/▼ baut nicht die ganze Zeile neu.
  final _rowFocus = ValueNotifier(false);

  /// TV: Fokus-Knoten je Sendung (für ◀/▶ zur Nachbarsendung).
  final _nodes = <EpgEntry, FocusNode>{};

  FocusNode _nodeFor(EpgEntry e) =>
      _nodes.putIfAbsent(e, () => FocusNode(debugLabel: e.title));

  /// TV: Platzhalter-„Sendung“ für Sender ohne Programm, damit auch sie
  /// per D-Pad erreichbar und abspielbar sind.
  late final EpgEntry _placeholder = EpgEntry(
      channelEpgId: _noEpg,
      title: tr('Keine Programminfo'),
      start: widget.start,
      end: widget.end);

  List<EpgEntry> get _visible {
    final v = entries
        .where((x) => x.end.isAfter(start) && x.start.isBefore(end))
        .toList();
    return v.isEmpty ? [_placeholder] : v;
  }

  /// Sendung zur Uhrzeit [t] fokussieren (sonst die nächstgelegene).
  void focusAt(DateTime t) {
    final vis = _visible;
    var target = vis.first;
    for (final e in vis) {
      if (!e.start.isAfter(t)) target = e;
      if (e.start.isAfter(t)) break;
    }
    _nodeFor(target).requestFocus();
  }

  @override
  void initState() {
    super.initState();
    widget.rows?[widget.channel.id] = this;
  }

  @override
  void didUpdateWidget(_GuideRow old) {
    super.didUpdateWidget(old);
    if (identical(old.entries, widget.entries)) return;
    final keep = widget.entries.toSet();
    final stale = [
      for (final e in _nodes.keys)
        if (!keep.contains(e)) e,
    ];
    if (stale.isEmpty) return;
    final gone = [for (final e in stale) _nodes.remove(e)!];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final n in gone) {
        n.dispose();
      }
    });
  }

  @override
  void dispose() {
    final rows = widget.rows;
    if (rows != null && rows[widget.channel.id] == this) {
      rows.remove(widget.channel.id);
    }
    for (final n in _nodes.values) {
      n.dispose();
    }
    _rowFocus.dispose();
    super.dispose();
  }

  /// ◀/▶: vorherige/nächste Sendung der Zeile, auch außerhalb des Bildes.
  /// Am Anfang des Rasters bleibt ◀ unbehandelt (→ Leiste).
  bool _step(EpgEntry e, LogicalKeyboardKey k) {
    if (k == LogicalKeyboardKey.arrowUp || k == LogicalKeyboardKey.arrowDown) {
      // Uhrzeit beibehalten: Beginn der Sendung bzw. linker Bildrand.
      final left =
          start.add(Duration(seconds: (offset.value / ppm * 60).round()));
      final t = e.start.isAfter(left) ? e.start : left;
      return widget.onVertical
              ?.call(k == LogicalKeyboardKey.arrowUp ? -1 : 1, t) ??
          false;
    }
    final vis = _visible;
    final i = vis.indexOf(e);
    if (i < 0) return false;
    final j = k == LogicalKeyboardKey.arrowLeft ? i - 1 : i + 1;
    if (j < 0) return false;
    if (j >= vis.length) return true; // Ende des Rasters: stehen bleiben
    _nodeFor(vis[j]).requestFocus();
    return true;
  }

  Channel get channel => widget.channel;
  List<EpgEntry> get entries => widget.entries;
  double get labelW => widget.labelW;
  double get ppm => widget.ppm;
  bool get narrow => widget.narrow;
  DateTime get start => widget.start;
  DateTime get end => widget.end;
  ValueNotifier<double> get offset => widget.offset;
  bool get autofocusNow => widget.autofocusNow;
  void Function(EpgEntry e, double x0, double x1) get onFocusX =>
      widget.onFocusX;
  ValueChanged<EpgEntry> get onOpen => widget.onOpen;
  ValueChanged<EpgEntry> get onMenu => widget.onMenu;

  double get _totalW => end.difference(start).inSeconds / 60 * ppm;

  @override
  Widget build(BuildContext context) {
    if (widget.tv) return _buildTv(context);
    final c = channel;
    // Zeitpunkt des Aufbaus: Die Zeile baut bei jedem Programmwechsel
    // ihres Senders neu (_GuideRowHost), Fortschritt tickt separat.
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
            child: visible.isEmpty
                ? Padding(
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
                  )
                : _HScroll(
                    offset: offset,
                    width: _totalW,
                    child: Stack(children: [
                      for (final e in visible) _tile(e, now),
                    ]),
                  ),
          ),
        ),
      ]),
    );
  }

  Widget _tile(EpgEntry e, DateTime now) {
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
      left: x0,
      width: w,
      top: 0,
      bottom: 0,
      child: Padding(
        padding: const EdgeInsets.all(3),
        child: FocusableTile(
          autofocus: autofocusNow && isNow,
          // TalkBack: „Titel, 20:15 bis 21:00, Sender“.
          semanticLabel:
              programmeSemantics(e, channel, running: isNow, replay: archived),
          radius: BorderRadius.circular(8),
          onFocus: () => onFocusX(e, x0, x0 + w),
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
            padding: const EdgeInsets.fromLTRB(10, 7, 8, 6),
            child: w < 28
                ? const SizedBox.shrink()
                : _StickyInset(
                    offset: offset,
                    x0: x0,
                    maxShift: w - 90,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          if (archived) ...[
                            Semantics(
                              label: archiveLabel(channel.catchupDays),
                              child: const Icon(Icons.history_rounded,
                                  size: 13, color: AppColors.catchup),
                            ),
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
                          MinuteBuilder(
                              builder: (_, t) => ThinProgress(
                                  value: e.progressAt(t), height: 2.5)),
                      ],
                    ),
                  ),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- TV

  Widget _buildTv(BuildContext context) {
    final c = channel;
    final now = DateTime.now();
    final visible =
        entries.where((e) => e.end.isAfter(start) && e.start.isBefore(end));
    return DecoratedBox(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: _TvColors.rowLine)),
      ),
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onFocusChange: (f) => _rowFocus.value = f,
        child: Row(children: [
          SizedBox(
            width: labelW,
            child: Padding(
              padding: const EdgeInsets.only(left: 2, right: 2),
              child: Row(children: [
                SizedBox(
                  width: 15,
                  child: Text('${c.number}',
                      textAlign: TextAlign.right,
                      maxLines: 1,
                      overflow: TextOverflow.clip,
                      style: const TextStyle(
                          fontSize: 7.5, color: _TvColors.number)),
                ),
                const SizedBox(width: 7),
                _TvLogo(channel: c),
                const SizedBox(width: 7),
                Expanded(
                  child: ValueListenableBuilder<bool>(
                    valueListenable: _rowFocus,
                    builder: (_, rowFocus, __) => Text(c.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 8.5,
                            fontWeight: FontWeight.w600,
                            color: rowFocus
                                ? _TvColors.focusName
                                : _TvColors.text)),
                  ),
                ),
              ]),
            ),
          ),
          Expanded(
            child: ClipRect(
              child: visible.isEmpty
                  ? Stack(children: [_tvTile(_placeholder, now)])
                  : _HScroll(
                      offset: offset,
                      width: _totalW,
                      child: Stack(children: [
                        for (final e in visible) _tvTile(e, now),
                      ]),
                    ),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _tvTile(EpgEntry e, DateTime now) {
    final s = e.start.isBefore(start) ? start : e.start;
    final en = e.end.isAfter(end) ? end : e.end;
    final x0 = s.difference(start).inSeconds / 60 * ppm;
    final w = en.difference(s).inSeconds / 60 * ppm;
    final none = identical(e, _placeholder);
    final isNow = e.isNowAt(now);
    final past = e.isPastAt(now);
    final archived = past &&
        channel.hasCatchup &&
        e.start.isAfter(now.subtract(Duration(days: channel.catchupDays)));

    Widget cell(bool focused, bool rowFocus) {
      final bg = focused
          ? AppColors.accent
          : isNow && rowFocus
              ? AppColors.accentSoft
              : isNow || none
                  ? _TvColors.cellNow
                  : archived
                      ? const Color(0xFF0F2622)
                      : past
                          ? _TvColors.cellPast
                          : _TvColors.cell;
      final fg = focused
          ? const Color(0xFF1A0B04)
          : past && !archived
              ? AppColors.textFaint
              : _TvColors.cellText;
      final fg2 = focused ? const Color(0xFF4A2210) : _TvColors.faint;
      final content = w < 20 && !none
          ? const SizedBox.shrink()
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  if (archived) ...[
                    Semantics(
                      label: archiveLabel(channel.catchupDays),
                      child: Icon(Icons.history_rounded,
                          size: 8, color: focused ? fg : AppColors.catchup),
                    ),
                    const SizedBox(width: 3),
                  ],
                  Expanded(
                    child: Text(
                      e.title,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 8,
                          height: 1.2,
                          fontWeight:
                              focused ? FontWeight.w600 : FontWeight.w400,
                          color: fg),
                    ),
                  ),
                ]),
                if (!none) ...[
                  const SizedBox(height: 1.5),
                  Text(
                    '${hm.format(e.start)} – ${hm.format(e.end)}',
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.clip,
                    style: TextStyle(fontSize: 6.5, height: 1.2, color: fg2),
                  ),
                ],
              ],
            );
      return AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(4),
        ),
        padding: EdgeInsets.fromLTRB(7, none ? 8 : 4.5, 5, 0),
        child: none
            ? content
            : _StickyInset(
                offset: offset, x0: x0, maxShift: w - 60, child: content),
      );
    }

    final tile = _TvFocusable(
      focusNode: _nodeFor(e),
      semanticLabel: programmeSemantics(none ? null : e, channel,
          running: isNow, replay: archived),
      onArrow: (k) => _step(e, k),
      autofocus: autofocusNow && isNow,
      // Platzhalter: kein Scrollen, OK schaltet den Sender ein.
      onFocus: () => none
          ? onFocusX(e, offset.value + 8, offset.value + 8)
          : onFocusX(e, x0, x0 + w),
      onTap: () => onOpen(e),
      onLongPress: none ? null : () => onMenu(e),
      // Nur die „läuft“-Kachel hängt an der Zeilen-Hervorhebung.
      builder: (focused) => isNow
          ? ValueListenableBuilder<bool>(
              valueListenable: _rowFocus,
              builder: (_, rowFocus, __) => cell(focused, rowFocus))
          : cell(focused, false),
    );
    return Positioned(
      left: none ? 0 : x0,
      width: none ? null : w,
      right: none ? 0 : null,
      top: 2.5,
      bottom: 2.5,
      child: Padding(padding: const EdgeInsets.only(right: 2), child: tile),
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
                    withPreviewPaused(
                        ref, () => playChannel(context, ref, c, channels));
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
                      withPreviewPaused(
                          ref,
                          () => playCatchup(context, ref, c, e,
                              channels: channels));
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
                  withPreviewPaused(
                      ref,
                      () =>
                          playCatchup(context, ref, c, e, channels: channels));
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
                  withPreviewPaused(
                      ref, () => playChannel(context, ref, c, channels));
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
    final portal = ref.watch(activePortalProvider).value;
    final storage = ref.watch(storageProvider).value;
    final live = ref.watch(visibleLiveDataProvider).value;
    final narrow = MediaQuery.sizeOf(context).width < 600;
    final pad = EdgeInsets.fromLTRB(narrow ? 16 : 28, 0, narrow ? 16 : 28, 10);

    // Nur Anbieter-EPG und das hat schon einmal nicht fertig geladen
    // (oder lädt gerade) → Länder-EPG mit einem Tippen anbieten.
    final onlyProvider = portal != null &&
        portal.type != PortalType.demo &&
        portal.epgSources.length == 1 &&
        portal.epgSources.first == 'portal';
    final attempts = portal == null
        ? 0
        : int.tryParse(
                storage?.option('epgattempt_${portal.id}', '0') ?? '0') ??
            0;
    final suggest =
        onlyProvider && (attempts >= 1 || st.updating) && live != null;

    if (!st.updating && !suggest) return const SizedBox.shrink();
    final p = st.progress;
    double? value;
    if (p != null && !p.$5 && p.$4 != null && p.$4! > 0) {
      value = (p.$3 / p.$4!).clamp(0.0, 1.0);
    }
    final preset = suggest ? suggestPreset(live.channels) : null;
    return Padding(
      padding: pad,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (st.updating)
          Row(children: [
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
        if (preset != null) ...[
          if (st.updating) const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
            decoration: BoxDecoration(
              color: AppColors.accentSoft,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(children: [
              Icon(Icons.bolt_rounded, color: AppColors.accent),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  trf(
                      'Dauert zu lange? Mit dem Länder-EPG {0} ist das '
                      'Programm in Sekunden da.',
                      [tr(preset.label)]),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () => useCountryEpg(ref, portal!, preset),
                child: Text(tr('Verwenden')),
              ),
            ]),
          ),
        ],
      ]),
    );
  }
}

// ------------------------------------------------------------------ TV

/// Farben des TV-Guides (aus dem freigegebenen Entwurf).
class _TvColors {
  static const text = Color(0xFFE9ECF2);
  static const dim = Color(0xFF9AA3B2);
  static const dim2 = Color(0xFF7C8494);
  static const faint = Color(0xFF6B7383);
  static const number = Color(0xFF5C6474);
  static const line = Color(0xFF1A1F29);
  static const rowLine = Color(0xFF141923);
  static const chip = Color(0xFF141923);
  static const logo = Color(0xFF1A2030);
  static const cell = Color(0xFF121722);
  static const cellNow = Color(0xFF1B2130);
  static const cellPast = Color(0xFF0E1015);
  static const cellText = Color(0xFFC9CFDA);
  static const bar = Color(0xFF232A36);
  static const focusName = Color(0xFFFF9A66);
}

/// D-Pad-/Touch-Element, das seinen Fokuszustand an [builder] gibt.
/// OK/Enter (kurz) = [onTap]; OK lang gedrückt, Menü-Taste oder langes
/// Tippen = [onLongPress]. [onArrow] darf Pfeiltasten selbst behandeln (z. B.
/// zur Nachbarsendung, auch wenn sie außerhalb des Bildes liegt).
class _TvFocusable extends StatefulWidget {
  final Widget Function(bool focused) builder;
  final VoidCallback? onTap, onLongPress, onFocus;
  final bool Function(LogicalKeyboardKey key)? onArrow;
  final FocusNode? focusNode;
  final bool autofocus;

  /// Vorlesetext für TalkBack (ersetzt die Texte im Inhalt).
  final String? semanticLabel;
  const _TvFocusable({
    required this.builder,
    this.semanticLabel,
    this.onTap,
    this.onLongPress,
    this.onFocus,
    this.onArrow,
    this.focusNode,
    this.autofocus = false,
  });

  @override
  State<_TvFocusable> createState() => _TvFocusableState();
}

class _TvFocusableState extends State<_TvFocusable> {
  static final _okKeys = {
    LogicalKeyboardKey.select,
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.numpadEnter,
    LogicalKeyboardKey.gameButtonA,
  };

  bool _focused = false;

  /// OK wurde auf diesem Element gedrückt (und noch nicht losgelassen).
  bool _okDown = false;
  bool _longFired = false;

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    final k = e.logicalKey;
    if (_okKeys.contains(k)) {
      if (e is KeyDownEvent) {
        _okDown = true;
        _longFired = false;
      } else if (e is KeyRepeatEvent) {
        // Gehaltenes OK → Kontextaktion (einmal). Die erste Wiederholung
        // kommt vom System erst nach ~0,5 s Halten.
        if (_okDown && !_longFired) {
          _longFired = true;
          widget.onLongPress?.call();
        }
      } else if (e is KeyUpEvent) {
        // Nur auslösen, wenn das Drücken auch hier begann (nicht z. B. das
        // OK, das gerade ein Blatt geschlossen hat).
        final down = _okDown;
        _okDown = false;
        if (down && !_longFired) widget.onTap?.call();
      }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.contextMenu) {
      if (e is KeyDownEvent) widget.onLongPress?.call();
      return KeyEventResult.handled;
    }
    if (e is! KeyUpEvent &&
        (k == LogicalKeyboardKey.arrowLeft ||
            k == LogicalKeyboardKey.arrowRight ||
            k == LogicalKeyboardKey.arrowUp ||
            k == LogicalKeyboardKey.arrowDown) &&
        (widget.onArrow?.call(k) ?? false)) {
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final label = widget.semanticLabel;
    final child = widget.builder(_focused);
    // Wie FocusableTile: ein TalkBack-Eintrag je Element.
    return MergeSemantics(
        child: Semantics(
            button: widget.onTap != null,
            child: Focus(
              focusNode: widget.focusNode,
              autofocus: widget.autofocus,
              onKeyEvent: _onKey,
              onFocusChange: (f) {
                setState(() => _focused = f);
                if (!f) _okDown = false;
                if (f) {
                  widget.onFocus?.call();
                  Scrollable.ensureVisible(context,
                      alignment: 0.5,
                      duration: const Duration(milliseconds: 160));
                }
              },
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: widget.onTap,
                  onLongPress: widget.onLongPress == null
                      ? null
                      : () {
                          Feedback.forLongPress(context);
                          widget.onLongPress!();
                        },
                  child: label == null
                      ? child
                      : Semantics(
                          label: label, excludeSemantics: true, child: child),
                ),
              ),
            )));
  }
}

/// Kleines quadratisches Senderlogo (20 dp) – ohne Logo ein Kürzel.
class _TvLogo extends StatelessWidget {
  final Channel channel;
  const _TvLogo({required this.channel});

  static final _quality =
      RegExp(r'\b(HD|FHD|UHD|4K|TV)\b', caseSensitive: false);
  static final _spaces = RegExp(r'\s+');

  static String _initials(String name) {
    final words = name
        .replaceAll(_quality, '')
        .trim()
        .split(_spaces)
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty) return '?';
    if (words.length == 1) {
      final w = words.first;
      return w.substring(0, math.min(3, w.length)).toUpperCase();
    }
    return '${words[0][0]}${words[1][0]}'.toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final url = channel.logoUrl;
    final mono = Center(
      child: Text(_initials(channel.name),
          maxLines: 1,
          style: const TextStyle(
              fontSize: 6, fontWeight: FontWeight.w700, color: _TvColors.dim)),
    );
    return Container(
      width: 20,
      height: 20,
      decoration: BoxDecoration(
        color: _TvColors.logo,
        borderRadius: BorderRadius.circular(4.5),
      ),
      // Kein Clip nötig: Das Logo liegt 2 dp eingerückt und erreicht die
      // Rundung (4,5 dp) nicht. Schlichtes Image statt CachedNetworkImage
      // (gleicher Cache, weniger Elemente je Zeile).
      padding: UrlPolicy.isWeb(url) ? const EdgeInsets.all(2) : null,
      child: !UrlPolicy.isWeb(url)
          ? mono
          : Image(
              image: ResizeImage.resizeIfNeeded(
                  (20 * MediaQuery.devicePixelRatioOf(context)).round(),
                  null,
                  CachedNetworkImageProvider(url!,
                      cacheManager: ImageCaches.logos)),
              fit: BoxFit.contain,
              excludeFromSemantics: true,
              errorBuilder: (_, __, ___) => mono,
            ),
    );
  }
}

/// Gruppen-Chip der TV-Ansicht (kompakt).
class _TvChip extends StatelessWidget {
  final String label;
  final IconData? icon;
  final bool selected;
  final VoidCallback onTap;
  final bool Function()? onDown;
  const _TvChip(
      {required this.label,
      this.icon,
      required this.selected,
      required this.onTap,
      this.onDown});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: _TvFocusable(
        onTap: onTap,
        onArrow: (k) =>
            k == LogicalKeyboardKey.arrowDown && (onDown?.call() ?? false),
        builder: (focused) {
          final fg = selected
              ? const Color(0xFF0B0D12)
              : focused
                  ? _TvColors.text
                  : _TvColors.dim;
          return AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            height: 18,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: selected
                  ? _TvColors.text
                  : focused
                      ? AppColors.surface3
                      : _TvColors.chip,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                  color: focused ? AppColors.accent : Colors.transparent,
                  width: 1.5),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              if (icon != null) ...[
                Icon(icon, size: 8, color: fg),
                const SizedBox(width: 3),
              ],
              Text(label,
                  style: TextStyle(
                      fontSize: 7.5,
                      height: 1.2,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                      color: fg)),
            ]),
          );
        },
      ),
    );
  }
}

/// Info-Kopf: Sender · Zeitpunkt, Titel, Zeit/Genre, Fortschritt, Text.
class _TvInfo extends StatelessWidget {
  final Channel channel;
  final EpgEntry? entry;
  const _TvInfo({required this.channel, required this.entry});

  // Minutentakt nur für diesen kleinen Kopf („Jetzt“, Fortschritt).
  @override
  Widget build(BuildContext context) =>
      MinuteBuilder(builder: (context, now) => _build(context, now));

  Widget _build(BuildContext context, DateTime now) {
    final e = entry;
    String when;
    if (e == null) {
      when = '';
    } else if (e.isNowAt(now)) {
      when = tr('Jetzt');
    } else {
      final sameDay = e.start.year == now.year &&
          e.start.month == now.month &&
          e.start.day == now.day;
      when = sameDay
          ? hm.format(e.start)
          : '${DateFormat('EEE', L10n.lang).format(e.start)} '
              '${hm.format(e.start)}';
    }
    final head = when.isEmpty ? channel.name : '${channel.name} · $when';
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(head.toUpperCase(),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
              fontSize: 7.5,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.9,
              color: _TvColors.dim2)),
      const SizedBox(height: 6),
      Text(e?.title ?? tr('Keine Programminfo'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
              fontSize: 17,
              height: 1.2,
              fontWeight: FontWeight.w700,
              color: _TvColors.text)),
      if (e != null) ...[
        const SizedBox(height: 3),
        Text(
            '${hm.format(e.start)} – ${hm.format(e.end)}'
            '${e.genre != null && e.genre!.isNotEmpty ? ' · ${e.genre}' : ''}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 9, color: _TvColors.dim)),
        const SizedBox(height: 8),
        Container(
          width: 260,
          height: 2,
          decoration: BoxDecoration(
            color: _TvColors.bar,
            borderRadius: BorderRadius.circular(1),
          ),
          alignment: Alignment.centerLeft,
          child: FractionallySizedBox(
            widthFactor: e.progressAt(now),
            child: Container(
              decoration: BoxDecoration(
                color: AppColors.accent,
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          ),
        ),
        if (e.description != null && e.description!.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(e.description!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 8.5, height: 1.4, color: _TvColors.dim2)),
        ],
      ],
    ]);
  }
}

/// TV: kleiner Statustext statt Banner, solange das EPG lädt.
class _TvEpgStatus extends ConsumerWidget {
  const _TvEpgStatus();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(epgStatusProvider);
    if (!st.updating) return const SizedBox.shrink();
    return Row(mainAxisSize: MainAxisSize.min, children: [
      const Icon(Icons.sync_rounded, size: 8, color: _TvColors.faint),
      const SizedBox(width: 3),
      Flexible(
        child: Text(st.progressText ?? tr('Programm wird aktualisiert'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 7, color: _TvColors.faint)),
      ),
    ]);
  }
}

/// Kennung der Platzhalter-Sendung (Sender ohne Programm).
const _noEpg = '\u0000noepg';
