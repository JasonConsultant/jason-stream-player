import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../data/smb/smb.dart' show smbErrorText;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/security.dart';
import '../../core/theme.dart';
import '../../l10n/strings.dart';
import '../../models/models.dart';
import '../../state/downloads.dart';
import '../../state/providers.dart';
import '../live/parental.dart';
import '../nav.dart' show openOfflineDownload;
import '../vod/movie_detail_screen.dart' show GhostButton;
import 'downloads_screen.dart';

/// Kann dieser Titel überhaupt geladen werden? (Portal: direkte Datei;
/// Medienserver: Prüfung beim Antippen – `CanDownload`.)
bool downloadSupported(VodItem item, {String? url}) {
  if (kIsWeb) return false;
  if (item.isEmby) return true;
  return isDownloadableUrl(url ?? item.streamUrl);
}

/// Prüft PIN (Erwachsenen-Kategorie), legt die Einträge an und meldet,
/// was passiert. Liefert die Zahl neu eingereihter Downloads.
Future<int> startDownloads(BuildContext context, WidgetRef ref,
    Future<List<DownloadItem>> Function() build) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  List<DownloadItem> items;
  try {
    items = await build();
  } on DownloadRefused catch (e) {
    messenger?.showSnackBar(SnackBar(content: Text(e.message)));
    return 0;
  } catch (e) {
    messenger?.showSnackBar(SnackBar(content: Text(Redactor.friendly(e))));
    return 0;
  }
  if (items.isEmpty) {
    messenger?.showSnackBar(SnackBar(
        content: Text(tr('Dieser Titel kann nicht heruntergeladen werden.'))));
    return 0;
  }
  // Gesperrte Inhalte (Erwachsenen-Kategorie) nur mit PIN.
  if (items.any((d) => d.adult)) {
    if (!context.mounted || !await askPin(context, ref)) return 0;
  }
  final n = await ref.read(downloadsProvider.notifier).add(items);
  final max = ref.read(maxConnectionsProvider);
  final hints = <String>[
    n == 0
        ? tr('Schon in den Downloads')
        : n == 1
            ? tr('Download gestartet')
            : trf('{0} Downloads eingereiht', [n]),
  ];
  // Anbieter mit nur einer Verbindung: Live geht während des Downloads nicht.
  if (n > 0 && max == 1 && items.any((d) => !d.isEmby)) {
    hints.add(tr('Dein Anbieter erlaubt nur 1 Verbindung – während des '
        'Downloads läuft Live-TV evtl. nicht.'));
  }
  messenger?.showSnackBar(SnackBar(
    duration: Duration(seconds: hints.length > 1 ? 6 : 3),
    content: Text(hints.join('\n')),
    action: SnackBarAction(
        label: tr('Downloads'),
        onPressed: () {
          if (context.mounted) openDownloads(context);
        }),
  ));
  return n;
}

void openDownloads(BuildContext context) => Navigator.of(context)
    .push(MaterialPageRoute<void>(builder: (_) => const DownloadsScreen()));

/// Status als kurzer Text („Lädt 34 %“, „Wartet auf WLAN“ …).
String downloadStatusText(DownloadItem d) {
  final p = d.progress;
  // Geschütztes Leerzeichen: „34 %“ nie umbrechen.
  final pct = p == null ? '' : ' ${(p * 100).floor()}\u00a0%';
  return switch (d.state) {
    DownloadState.done => tr('Heruntergeladen'),
    DownloadState.running => '${tr('Lädt')}$pct',
    DownloadState.paused => '${tr('Angehalten')}$pct',
    DownloadState.queued => tr('In der Warteschlange'),
    DownloadState.failed => downloadErrorText(d.error),
    DownloadState.waiting => downloadWaitText(d.wait),
  };
}

String downloadWaitText(DownloadWait w) => switch (w) {
      DownloadWait.network => tr('Wartet auf Internet'),
      DownloadWait.cellular => tr('Wartet auf WLAN'),
      DownloadWait.dataSaver => tr('Wartet – Datensparmodus'),
      DownloadWait.space => tr('Wartet – zu wenig Speicherplatz'),
      DownloadWait.connections => tr('Wartet auf freie Anbieter-Verbindung'),
      DownloadWait.retry => tr('Neuer Versuch gleich …'),
      DownloadWait.none => tr('In der Warteschlange'),
    };

/// Fehlercode → verständlicher Text (ohne Adressen).
String downloadErrorText(String? code) =>
    code != null && code.startsWith('nas:')
        ? trf('{0} – Download angehalten, „Erneut“ setzt fort',
            [smbErrorText(code.substring(4))])
        : _downloadErrorText(code);

String _downloadErrorText(String? code) => switch (code) {
      'auth' || 'forbidden' => tr('Anmeldung beim Anbieter fehlgeschlagen'),
      'credentials' => tr('Zugangsdaten fehlen – Portal/Anmeldung prüfen'),
      'notfound' => tr('Datei auf dem Server nicht gefunden'),
      'notfile' => tr('Dieser Titel ist keine ladbare Datei'),
      'busy' => tr('Anbieter ausgelastet'),
      'storage' => tr('Speichern fehlgeschlagen (Speicherort prüfen)'),
      'nospace' => tr('Zu wenig Speicherplatz'),
      'incomplete' || 'network' => tr('Verbindung unterbrochen'),
      'server' => tr('Server-Fehler'),
      _ => tr('Download fehlgeschlagen'),
    };

/// Download-Knopf für Film-Detailseiten.
class MovieDownloadButton extends ConsumerWidget {
  final VodItem movie;
  const MovieDownloadButton({super.key, required this.movie});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!downloadSupported(movie)) return const SizedBox.shrink();
    final id = DownloadItem.idOf(downloadScopeOf(ref.read, movie), movie.id);
    final d = ref.watch(downloadOfProvider(id));
    return DownloadStateButton(
      key: const ValueKey('download-button'),
      download: d,
      onStart: () =>
          startDownloads(context, ref, () async => [await movieDownload(ref.read, movie)]),
    );
  }
}

/// „Staffel N herunterladen“ (alle Folgen der Staffel, die noch fehlen).
class SeasonDownloadButton extends ConsumerWidget {
  final VodItem series;
  final int season;
  final List<Episode> episodes;
  const SeasonDownloadButton(
      {super.key,
      required this.series,
      required this.season,
      required this.episodes});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final eps = [
      for (final e in episodes)
        if (series.isEmby || downloadSupported(series, url: e.streamUrl)) e
    ];
    if (kIsWeb || eps.isEmpty) return const SizedBox.shrink();
    final scope = downloadScopeOf(ref.read, series);
    final all = ref.watch(downloadsProvider);
    final have = {
      for (final d in all)
        if (d.scope == scope) d.itemId
    };
    final missing = [for (final e in eps) if (!have.contains(e.id)) e];
    final ids = {for (final e in eps) e.id};
    final allDone = missing.isEmpty &&
        all.every((d) =>
            d.scope != scope ||
            !ids.contains(d.itemId) ||
            d.state == DownloadState.done);
    final label = season == 0
        ? tr('Extras herunterladen')
        : trf('Staffel {0} herunterladen', [season]);
    return GhostButton(
      key: const ValueKey('season-download'),
      icon: allDone
          ? Icons.download_done_rounded
          : missing.isEmpty
              ? Icons.downloading_rounded
              : Icons.download_for_offline_outlined,
      label: allDone
          ? tr('Staffel geladen')
          : missing.isEmpty
              ? tr('Staffel wird geladen')
              : label,
      onTap: missing.isEmpty
          ? () => openDownloads(context)
          : () => startDownloads(context, ref,
              () => episodeDownloads(ref.read, series, missing)),
    );
  }
}

/// Kleines Symbol je Folge (Zeile in der Folgenliste).
class EpisodeDownloadIcon extends ConsumerWidget {
  final VodItem series;
  final Episode episode;
  const EpisodeDownloadIcon(
      {super.key, required this.series, required this.episode});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!series.isEmby && !downloadSupported(series, url: episode.streamUrl)) {
      return const SizedBox.shrink();
    }
    final id =
        DownloadItem.idOf(downloadScopeOf(ref.read, series), episode.id);
    final d = ref.watch(downloadOfProvider(id));
    final p = d?.progress;
    final Widget icon = switch (d?.state) {
      null => const Icon(Icons.download_rounded),
      DownloadState.done =>
        const Icon(Icons.download_done_rounded, color: AppColors.catchup),
      DownloadState.failed =>
        const Icon(Icons.error_outline_rounded, color: AppColors.live),
      DownloadState.paused => const Icon(Icons.pause_circle_outline_rounded),
      DownloadState.queued ||
      DownloadState.waiting =>
        const Icon(Icons.schedule_rounded, color: AppColors.textDim),
      _ => SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(
              strokeWidth: 2.5,
              value: p)),
    };
    return IconButton(
      key: ValueKey('ep-download-${episode.id}'),
      tooltip: d == null ? tr('Folge herunterladen') : downloadStatusText(d),
      icon: icon,
      onPressed: () {
        if (d == null) {
          startDownloads(context, ref,
              () => episodeDownloads(ref.read, series, [episode]));
        } else if (d.state == DownloadState.failed) {
          ref.read(downloadsProvider.notifier).resume(d.id);
        } else {
          openDownloads(context);
        }
      },
    );
  }
}

/// Knopf mit Download-Zustand (Detailseite).
class DownloadStateButton extends ConsumerWidget {
  final DownloadItem? download;
  final VoidCallback onStart;
  const DownloadStateButton(
      {super.key, required this.download, required this.onStart});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = download;
    if (d == null) {
      return GhostButton(
          icon: Icons.download_rounded,
          label: tr('Herunterladen'),
          onTap: onStart);
    }
    switch (d.state) {
      case DownloadState.done:
        return GhostButton(
          icon: Icons.download_done_rounded,
          color: AppColors.catchup,
          label: tr('Heruntergeladen'),
          onTap: () => _doneSheet(context, ref, d),
        );
      case DownloadState.failed:
        return GhostButton(
          icon: Icons.refresh_rounded,
          color: AppColors.live,
          label: tr('Download erneut versuchen'),
          onTap: () => ref.read(downloadsProvider.notifier).resume(d.id),
        );
      default:
        return GhostButton(
          icon: d.state == DownloadState.paused
              ? Icons.pause_circle_outline_rounded
              : Icons.downloading_rounded,
          label: downloadStatusText(d),
          onTap: () => openDownloads(context),
        );
    }
  }

  Future<void> _doneSheet(
      BuildContext context, WidgetRef ref, DownloadItem d) async {
    final pick = await showModalBottomSheet<int>(
      context: context,
      useRootNavigator: true,
      constraints: const BoxConstraints(maxWidth: 480),
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
              autofocus: true,
              leading: const Icon(Icons.play_arrow_rounded),
              title: Text(tr('Offline abspielen')),
              onTap: () => Navigator.pop(ctx, 0)),
          ListTile(
              leading: const Icon(Icons.delete_outline_rounded),
              title: Text(tr('Download löschen')),
              onTap: () => Navigator.pop(ctx, 1)),
        ]),
      ),
    );
    if (!context.mounted) return;
    if (pick == 0) await openOfflineDownload(context, ref, d);
    if (pick == 1) await ref.read(downloadsProvider.notifier).remove(d.id);
    ref.invalidate(storageProvider);
  }
}
