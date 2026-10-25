import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/theme.dart';
import '../../data/recordings/recordings.dart';
import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../widgets/common.dart';

final _filesProvider = FutureProvider.autoDispose((ref) {
  ref.watch(recordingsProvider); // neu laden, wenn sich Aufnahmen ändern
  return listRecordings();
});

/// Aufnahmen im gewählten Ordner (USB-Stick/Netzlaufwerk), falls gesetzt.
final _treeFilesProvider = FutureProvider.autoDispose((ref) async {
  ref.watch(recordingsProvider);
  final st = await ref.watch(storageProvider.future);
  final tree = st.option(RecTree.optionKey, '');
  if (tree.isEmpty) return const <RecDoc>[];
  return RecTree.list(tree);
});

/// Geplante, laufende und fertige Aufnahmen.
class RecordingsScreen extends ConsumerWidget {
  const RecordingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = S.of(context);
    final recs = ref.watch(recordingsProvider);
    final files = ref.watch(_filesProvider).value ?? const [];
    final treeFiles = ref.watch(_treeFilesProvider).value ?? const <RecDoc>[];
    final planned = recs
        .where((r) => r.status == 'geplant' || r.status == 'läuft' || r.status == 'fehler')
        .toList()
      ..sort((a, b) => a.start.compareTo(b.start));
    String two(int n) => n.toString().padLeft(2, '0');
    String when(DateTime d) =>
        '${two(d.day)}.${two(d.month)}. ${two(d.hour)}:${two(d.minute)}';

    return Scaffold(
      appBar: AppBar(title: Text(s.recordings)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 12, left: 4),
            child: Text(s.recordingsHint,
                style: Theme.of(context).textTheme.bodySmall),
          ),
          for (final r in planned)
            ListTile(
              leading: Icon(
                r.status == 'läuft'
                    ? Icons.fiber_manual_record_rounded
                    : r.status == 'fehler'
                        ? Icons.error_outline_rounded
                        : Icons.schedule_rounded,
                color: r.status == 'läuft'
                    ? AppColors.live
                    : r.status == 'fehler'
                        ? AppColors.textDim
                        : AppColors.accent,
              ),
              title: Text(r.title),
              subtitle: Text('${r.channelName} · ${when(r.start)}–'
                  '${two(r.end.hour)}:${two(r.end.minute)}'
                  '${r.native && r.status != 'fehler' ? ' · ${tr('im Hintergrund')}' : ''}'
                  '${r.error != null ? ' · ${r.error}' : ''}'),
              trailing: r.status == 'läuft' ||
                      (r.status == 'geplant' &&
                          !DateTime.now().isBefore(r.start) &&
                          DateTime.now().isBefore(r.end))
                  // Laufende Aufnahme beenden – die Datei bleibt.
                  ? IconButton(
                      key: ValueKey('rec-stop-${r.id}'),
                      tooltip: tr('Aufnahme stoppen'),
                      icon: const Icon(Icons.stop_circle_outlined,
                          color: AppColors.live),
                      onPressed: () =>
                          ref.read(recordingsProvider.notifier).stop(r.id),
                    )
                  : IconButton(
                      tooltip: s.cancel,
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () =>
                          ref.read(recordingsProvider.notifier).cancel(r.id),
                    ),
            ),
          if (planned.isNotEmpty) const Divider(height: 32),
          if (files.isEmpty && treeFiles.isEmpty && planned.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 60),
              child: EmptyState(
                  icon: Icons.video_library_outlined, title: s.noRecordings),
            ),
          // Aufnahmen auf USB-Stick/Netzlaufwerk (SAF-Dokumente).
          for (final d in treeFiles)
            ListTile(
              leading: const Icon(Icons.usb_rounded),
              title: Text(d.name.replaceAll(RegExp(r'\.(ts|mkv)$'), ''),
                  maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: Text('${(d.bytes / 1048576).toStringAsFixed(0)} MB'),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => _FilePlayer(path: d.uri))),
              trailing: IconButton(
                tooltip: s.delete,
                icon: const Icon(Icons.delete_outline_rounded),
                onPressed: () async {
                  await RecTree.delete(d.uri);
                  ref.invalidate(_treeFilesProvider);
                },
              ),
            ),
          for (final f in files)
            ListTile(
              leading: const Icon(Icons.play_circle_outline_rounded),
              title: Text(f.path.split('/').last.replaceAll('.ts', ''),
                  maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: Text('${(f.bytes / 1048576).toStringAsFixed(0)} MB'),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => _FilePlayer(path: f.path))),
              trailing: IconButton(
                tooltip: s.delete,
                icon: const Icon(Icons.delete_outline_rounded),
                onPressed: () async {
                  await deleteRecording(f.path);
                  ref.invalidate(_filesProvider);
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _FilePlayer extends StatefulWidget {
  final String path;
  const _FilePlayer({required this.path});

  @override
  State<_FilePlayer> createState() => _FilePlayerState();
}

class _FilePlayerState extends State<_FilePlayer> {
  final _player = Player();
  late final _video = VideoController(_player);

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    if (widget.path.startsWith('content://')) {
      // SAF-Dokument (USB/Netz): media_kit öffnet content:// per
      // Dateideskriptor (fd://) selbst.
      _player.open(Media(widget.path));
      return;
    }
    isInRecordingsDir(widget.path).then((ok) {
      if (ok) _player.open(Media(Uri.file(widget.path).toString()));
    });
  }

  @override
  void dispose() {
    _player.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        body: MaterialVideoControlsTheme(
          normal: const MaterialVideoControlsThemeData(),
          fullscreen: const MaterialVideoControlsThemeData(),
          child: Video(controller: _video),
        ),
      );
}

/// Rückmeldung nach dem Planen einer Aufnahme. Fehlt die Android-Erlaubnis
/// „Wecker & Erinnerungen“, wird erklärt, wofür sie gebraucht wird.
Future<void> showRecFeedback(
    BuildContext context, RecResult r, String okText) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  switch (r) {
    case RecResult.duplicate:
      messenger?.showSnackBar(
          SnackBar(content: Text(tr('Diese Sendung ist schon geplant'))));
    case RecResult.background:
      messenger?.showSnackBar(SnackBar(
          content: Text('$okText · ${tr('läuft auch bei geschlossener App')}')));
    case RecResult.inAppOnly:
      messenger?.showSnackBar(SnackBar(
          content: Text('$okText · ${tr('App bitte geöffnet lassen')}')));
    case RecResult.needsAlarmPermission:
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const Icon(Icons.alarm_rounded),
          title: Text(tr('Aufnahme auch bei geschlossener App?')),
          content: Text(tr('Dafür braucht die App die Android-Erlaubnis '
              '„Wecker & Erinnerungen“. Ohne sie wird nur aufgenommen, '
              'solange die App geöffnet ist.')),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(tr('Später'))),
            FilledButton(
                autofocus: true,
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(tr('Erlauben'))),
          ],
        ),
      );
      if (go == true) {
        final opened = await NativeRecorder().requestExact();
        if (!opened) {
          messenger?.showSnackBar(SnackBar(
              content: Text(tr('Dieses Gerät hat keine solche Einstellung – '
                  'bitte App geöffnet lassen'))));
        }
      }
  }
}
