import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/downloads/download_native.dart';
import '../../data/downloads/download_files_stub.dart'
    if (dart.library.io) '../../data/downloads/download_files_io.dart';
import '../../data/recordings/recordings.dart' show RecTree;
import '../../data/smb/smb.dart';
import '../../l10n/strings.dart';
import '../../state/downloads.dart';
import '../../state/providers.dart';
import '../nav.dart' show openOfflineDownload;
import '../widgets/artwork.dart';
import '../widgets/common.dart';
import '../widgets/focusable_tile.dart';
import 'download_button.dart';

/// Speicherort und freier Platz (Kopf der Downloads-Seite).
final _placeProvider = FutureProvider.autoDispose<({String name, int free})>(
    (ref) async {
  ref.watch(downloadsProvider.select((l) => l.length));
  final st = await ref.watch(storageProvider.future);
  final tree = st.option(RecTree.optionKey, '');
  final smb = st.smbConfig();
  if (RecTree.isSmb(tree) && smb != null) {
    try {
      return (name: smb.display, free: await Smb.free(smb));
    } on SmbException {
      return (name: '${smb.display} · ${tr('nicht erreichbar')}', free: -1);
    }
  }
  if (tree.isNotEmpty && !RecTree.isSmb(tree) && RecTree.available) {
    final i = await RecTree.info(tree);
    if (i.granted) return (name: i.name, free: i.free);
  }
  final dir = await downloadsDir();
  return (name: tr('App-Ordner'), free: await DownloadNative.freeSpace(dir));
});

/// Downloads: laufende/wartende oben, fertige darunter. Handy: Antippen
/// spielt ab, Knöpfe rechts; TV: OK öffnet ein Aktionsblatt (D-Pad).
class DownloadsScreen extends ConsumerWidget {
  const DownloadsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tv = ref.watch(isTvProvider);
    final list = ref.watch(visibleDownloadsProvider);
    final active = [
      for (final d in list)
        if (d.state != DownloadState.done) d
    ];
    final done = [
      for (final d in list)
        if (d.state == DownloadState.done) d
    ]..sort((a, b) => (a.seriesName ?? a.title)
        .toLowerCase()
        .compareTo((b.seriesName ?? b.title).toLowerCase()));
    final place = ref.watch(_placeProvider).value;
    final max = ref.watch(maxConnectionsProvider);
    final mobile = ref
            .watch(storageProvider)
            .value
            ?.flag(DownloadSettings.mobileKey) ??
        false;
    final anyPaused = active.any((d) => d.state == DownloadState.paused);
    final anyRunning = active.any((d) => d.state.active);
    final t = Theme.of(context).textTheme;

    final hints = <String>[
      if (!tv && !mobile)
        tr('Downloads laufen nur über WLAN (Einstellungen → Downloads).'),
      if (max == 1)
        tr('Dein Anbieter erlaubt nur 1 Verbindung – während eines Downloads '
            'läuft Live-TV evtl. nicht.'),
    ];

    return Scaffold(
      appBar: AppBar(
        title: Text(tr('Downloads')),
        actions: [
          if (anyRunning)
            IconButton(
              key: const ValueKey('dl-pause-all'),
              tooltip: tr('Alle anhalten'),
              icon: const Icon(Icons.pause_rounded),
              onPressed: () =>
                  ref.read(downloadsProvider.notifier).pauseAll(),
            )
          else if (anyPaused)
            IconButton(
              key: const ValueKey('dl-resume-all'),
              tooltip: tr('Alle fortsetzen'),
              icon: const Icon(Icons.play_arrow_rounded),
              onPressed: () =>
                  ref.read(downloadsProvider.notifier).resumeAll(),
            ),
        ],
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(tv ? 48 : 16, 4, tv ? 48 : 16, 32),
        children: [
          if (place != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
              child: Row(children: [
                const Icon(Icons.sd_storage_outlined,
                    size: 18, color: AppColors.textFaint),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    place.free >= 0
                        ? trf('{0} · {1} frei',
                            [place.name, RecTree.formatFree(place.free)])
                        : place.name,
                    style: t.bodySmall,
                  ),
                ),
              ]),
            ),
          for (final h in hints)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Icon(Icons.info_outline_rounded,
                    size: 18, color: AppColors.textFaint),
                const SizedBox(width: 8),
                Expanded(child: Text(h, style: t.bodySmall)),
              ]),
            ),
          if (list.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 48),
              child: EmptyState(
                icon: Icons.download_for_offline_outlined,
                title: tr('Noch keine Downloads'),
                message: tr('Filme und Folgen über „Herunterladen“ auf der '
                    'Detailseite speichern – dann laufen sie auch ohne Internet.'),
              ),
            ),
          if (active.isNotEmpty) ...[
            _Header(tr('WIRD GELADEN')),
            for (var i = 0; i < active.length; i++)
              _DownloadRow(d: active[i], tv: tv, autofocus: tv && i == 0),
          ],
          if (done.isNotEmpty) ...[
            _Header(tr('AUF DEM GERÄT')),
            for (var i = 0; i < done.length; i++)
              _DownloadRow(
                  d: done[i], tv: tv, autofocus: tv && active.isEmpty && i == 0),
          ],
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final String text;
  const _Header(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
        child: Text(text,
            style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.1,
                color: AppColors.textFaint)),
      );
}

class _DownloadRow extends ConsumerWidget {
  final DownloadItem d;
  final bool tv;
  final bool autofocus;
  const _DownloadRow(
      {required this.d, required this.tv, this.autofocus = false});

  String get _name => d.isEpisode
      ? '${d.seriesName ?? ''} · S${d.season} F${d.episode}'
      : d.title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final storage = ref.watch(storageProvider).value;
    final r = storage?.resume(d.resumeKey);
    final watched = storage?.isWatched(d.resumeKey) ?? false;
    final done = d.state == DownloadState.done;
    final size = d.total > 0
        ? (done
            ? formatBytes(d.total)
            : '${formatBytes(d.bytes)} / ${formatBytes(d.total)}')
        : (d.bytes > 0 ? formatBytes(d.bytes) : '');
    final info = [
      if (!done) downloadStatusText(d),
      if (size.isNotEmpty) size,
      if (done && watched)
        tr('Gesehen')
      else if (done && r != null && r.total > 0 && r.pos > 30)
        trf('{0} % gesehen', [(r.pos * 100 / r.total).round()]),
      if (d.subs.any((s) => s.path != null)) tr('mit Untertiteln'),
    ];
    final notifier = ref.read(downloadsProvider.notifier);

    Future<void> actions() async {
      final pick = await showModalBottomSheet<String>(
        context: context,
        useRootNavigator: true,
        constraints: const BoxConstraints(maxWidth: 480),
        builder: (ctx) => SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
              child: Text(_name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(ctx).textTheme.titleMedium),
            ),
            if (done)
              ListTile(
                  key: const ValueKey('dl-act-play'),
                  autofocus: true,
                  leading: const Icon(Icons.play_arrow_rounded),
                  title: Text(tr('Offline abspielen')),
                  onTap: () => Navigator.pop(ctx, 'play')),
            if (d.state.active)
              ListTile(
                  key: const ValueKey('dl-act-pause'),
                  autofocus: true,
                  leading: const Icon(Icons.pause_rounded),
                  title: Text(tr('Anhalten')),
                  onTap: () => Navigator.pop(ctx, 'pause')),
            if (d.state == DownloadState.paused ||
                d.state == DownloadState.failed)
              ListTile(
                  key: const ValueKey('dl-act-resume'),
                  autofocus: true,
                  leading: const Icon(Icons.play_arrow_rounded),
                  title: Text(tr('Fortsetzen')),
                  onTap: () => Navigator.pop(ctx, 'resume')),
            ListTile(
                key: const ValueKey('dl-act-delete'),
                leading: const Icon(Icons.delete_outline_rounded),
                title: Text(done ? tr('Download löschen') : tr('Abbrechen')),
                onTap: () => Navigator.pop(ctx, 'delete')),
          ]),
        ),
      );
      if (!context.mounted) return;
      switch (pick) {
        case 'play':
          await openOfflineDownload(context, ref, d);
          ref.invalidate(storageProvider);
        case 'pause':
          await notifier.pause(d.id);
        case 'resume':
          await notifier.resume(d.id);
        case 'delete':
          await notifier.remove(d.id);
      }
    }

    final thumb = SizedBox(
      width: tv ? 120 : 72,
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Stack(fit: StackFit.expand, children: [
            NetworkArt(url: d.posterUrl, seed: d.seriesName ?? d.title),
            if (done)
              const Center(
                  child: Icon(Icons.play_circle_fill_rounded,
                      color: Colors.white70, size: 30)),
          ]),
        ),
      ),
    );

    final body = Padding(
      padding: const EdgeInsets.all(10),
      child: Row(children: [
        thumb,
        SizedBox(width: tv ? 14 : 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: t.titleSmall),
              if (d.isEpisode)
                Text(d.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: t.bodySmall),
              const SizedBox(height: 3),
              Text(info.join('  ·  '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: t.bodySmall?.copyWith(
                      color: d.state == DownloadState.failed
                          ? AppColors.live
                          : null)),
              if (!done) ...[
                const SizedBox(height: 8),
                d.state == DownloadState.running && d.progress == null
                    ? const LinearProgressIndicator(minHeight: 3)
                    : ThinProgress(value: d.progress ?? 0, height: 3),
              ],
            ],
          ),
        ),
        if (!tv) ...[
          const SizedBox(width: 4),
          if (d.state.active)
            IconButton(
                tooltip: tr('Anhalten'),
                icon: const Icon(Icons.pause_rounded),
                onPressed: () => notifier.pause(d.id))
          else if (d.state == DownloadState.paused ||
              d.state == DownloadState.failed)
            IconButton(
                tooltip: tr('Fortsetzen'),
                icon: const Icon(Icons.play_arrow_rounded),
                onPressed: () => notifier.resume(d.id)),
          IconButton(
              key: ValueKey('dl-delete-${d.id}'),
              tooltip: done ? tr('Download löschen') : tr('Abbrechen'),
              icon: Icon(done ? Icons.delete_outline_rounded : Icons.close_rounded),
              onPressed: () => notifier.remove(d.id)),
        ],
      ]),
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: FocusableTile(
        key: ValueKey('dl-${d.id}'),
        autofocus: autofocus,
        semanticLabel: '$_name. ${info.join(', ')}',
        onTap: tv || !done
            ? actions
            : () async {
                await openOfflineDownload(context, ref, d);
                ref.invalidate(storageProvider);
              },
        onLongPress: actions,
        child: body,
      ),
    );
  }
}
