import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/security.dart';
import '../../core/theme.dart';
import '../../models/models.dart';
import '../../state/channel_variants.dart' show playOrderFor;
import '../../state/providers.dart';
import '../widgets/artwork.dart';
import 'stream_open_headers.dart';
import '../widgets/focusable_tile.dart';
import '../../l10n/strings.dart';
import '../widgets/dpad_text_field.dart';

/// Multiview: bis zu 4 Sender gleichzeitig (z. B. mehrere Fußballspiele).
/// Ton kommt nur vom hervorgehobenen Bild. OK/Tippen = Ton auf dieses Bild,
/// Menü/lange drücken = Sender wechseln, entfernen oder Vollbild.
///
/// Hinweis: Wie viele Bilder flüssig laufen, hängt vom Gerät ab
/// (Anzahl Hardware-Decoder). Die meisten Boxen ab 2020 schaffen 2–4 in HD.
class MultiviewScreen extends ConsumerStatefulWidget {
  final List<Channel> channels;
  final Channel first;
  const MultiviewScreen({super.key, required this.channels, required this.first});

  @override
  ConsumerState<MultiviewScreen> createState() => _MultiviewState();
}

class _Slot {
  Channel? channel;
  Player? player;
  VideoController? video;
  String? error;
}

class _MultiviewState extends ConsumerState<MultiviewScreen> {
  final _slots = List.generate(4, (_) => _Slot());
  int _active = 0;
  int _count = 2;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setPreferredOrientations(
        const [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
    _setChannel(0, widget.first);
  }

  @override
  void dispose() {
    for (final s in _slots) {
      s.player?.dispose();
    }
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations(const []);
    super.dispose();
  }

  Future<void> _setChannel(int i, Channel c) async {
    final slot = _slots[i];
    final flags = ref.read(channelFlagsProvider).value ?? ChannelFlags.empty;
    if (flags.locked.contains(c.id)) {
      // Gesperrte Sender nicht ohne PIN in Multiview.
      setState(() => slot.error = tr('Gesperrt – im Einzelbild mit PIN öffnen'));
      return;
    }
    slot.player ??= Player(
        configuration: const PlayerConfiguration(bufferSize: 16 * 1024 * 1024));
    slot.video ??= VideoController(slot.player!);
    setState(() {
      slot.channel = c;
      slot.error = null;
    });
    try {
      final repo = await ref.read(repositoryProvider.future);
      // Zusammengefasste Sender: die gewählte Variante abspielen.
      final v = playOrderFor(ref, c).first;
      final url = repo == null ? v.streamUrl : await repo.resolveStreamUrl(v);
      if (!UrlPolicy.isStream(url)) throw Exception('Ungültige Adresse');
      await slot.player!.open(Media(url,
          httpHeaders: playerHeadersFor(
              ref.read(activePortalProvider).value, v)));
      await slot.player!.setVolume(i == _active ? 100 : 0);
    } catch (e) {
      if (mounted) setState(() => slot.error = Redactor.friendly(e));
    }
  }

  void _activate(int i) {
    setState(() => _active = i);
    for (var k = 0; k < _slots.length; k++) {
      _slots[k].player?.setVolume(k == i ? 100 : 0);
    }
  }

  Future<void> _remove(int i) async {
    final s = _slots[i];
    await s.player?.dispose();
    setState(() {
      _slots[i] = _Slot();
      if (_active == i) _active = 0;
    });
    _activate(_active);
  }

  Future<Channel?> _pick() => showModalBottomSheet<Channel>(
        context: context,
        isScrollControlled: true,
        constraints: const BoxConstraints(maxWidth: 560),
        builder: (_) => FractionallySizedBox(
            heightFactor: 0.85, child: _ChannelPicker(channels: widget.channels)),
      );

  Future<void> _menu(int i) async {
    final s = _slots[i];
    final pick = await showModalBottomSheet<int>(
      context: context,
      constraints: const BoxConstraints(maxWidth: 480),
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
              autofocus: true,
              leading: const Icon(Icons.swap_horiz_rounded),
              title: Text(tr('Sender wechseln')),
              onTap: () => Navigator.pop(ctx, 0)),
          if (s.channel != null)
            ListTile(
                leading: const Icon(Icons.fullscreen_rounded),
                title: Text(tr('Im Vollbild ansehen')),
                onTap: () => Navigator.pop(ctx, 1)),
          if (s.channel != null)
            ListTile(
                leading: const Icon(Icons.close_rounded),
                title: Text(tr('Bild entfernen')),
                onTap: () => Navigator.pop(ctx, 2)),
        ]),
      ),
    );
    switch (pick) {
      case 0:
        final c = await _pick();
        if (c != null) await _setChannel(i, c);
      case 1:
        if (mounted) Navigator.of(context).pop(s.channel);
      case 2:
        await _remove(i);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tiles = [
      for (var i = 0; i < _count; i++) _tile(i),
    ];
    final grid = _count <= 2
        ? Row(children: [for (final t in tiles) Expanded(child: t)])
        : Column(children: [
            Expanded(child: Row(children: [Expanded(child: tiles[0]), Expanded(child: tiles[1])])),
            Expanded(
              child: Row(children: [
                Expanded(child: tiles[2]),
                Expanded(child: _count > 3 ? tiles[3] : const SizedBox()),
              ]),
            ),
          ]);

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(children: [
        Positioned.fill(child: grid),
        Positioned(
          top: 12,
          left: 12,
          child: Row(children: [
            IconButton.filledTonal(
              onPressed: () => Navigator.maybePop(context),
              icon: const Icon(Icons.arrow_back_rounded),
            ),
            const SizedBox(width: 8),
            SegmentedButton<int>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 2, label: Text('2')),
                ButtonSegment(value: 3, label: Text('3')),
                ButtonSegment(value: 4, label: Text('4')),
              ],
              selected: {_count},
              onSelectionChanged: (v) async {
                final n = v.first;
                for (var i = n; i < 4; i++) {
                  if (_slots[i].player != null) await _remove(i);
                }
                setState(() => _count = n);
              },
            ),
          ]),
        ),
      ]),
    );
  }

  Widget _tile(int i) {
    final s = _slots[i];
    final active = i == _active;
    return Padding(
      padding: const EdgeInsets.all(2),
      child: FocusableTile(
        autofocus: i == 0,
        radius: BorderRadius.circular(6),
        onTap: () async {
          if (s.channel == null) {
            final c = await _pick();
            if (c != null) {
              await _setChannel(i, c);
              _activate(i);
            }
          } else {
            _activate(i);
          }
        },
        onLongPress: () => _menu(i),
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFF05070A),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
                color: active ? AppColors.accent : Colors.transparent, width: 3),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: Stack(fit: StackFit.expand, children: [
              if (s.video != null)
                Video(controller: s.video!, controls: NoVideoControls),
              if (s.channel == null)
                Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.add_circle_outline_rounded,
                        size: 44, color: AppColors.textDim),
                    SizedBox(height: 8),
                    Text(tr('Sender hinzufügen'),
                        style: TextStyle(color: AppColors.textDim)),
                  ]),
                ),
              if (s.error != null)
                Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(s.error!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: AppColors.textDim)),
                  ),
                ),
              if (s.channel != null)
                Positioned(
                  left: 10,
                  bottom: 10,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(
                          active
                              ? Icons.volume_up_rounded
                              : Icons.volume_off_rounded,
                          size: 16,
                          color: active ? AppColors.accent : Colors.white54),
                      const SizedBox(width: 6),
                      Text(s.channel!.name,
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                              fontSize: 13)),
                    ]),
                  ),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _ChannelPicker extends ConsumerStatefulWidget {
  final List<Channel> channels;
  const _ChannelPicker({required this.channels});

  @override
  ConsumerState<_ChannelPicker> createState() => _ChannelPickerState();
}

class _ChannelPickerState extends ConsumerState<_ChannelPicker> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final flags = ref.watch(channelFlagsProvider).value ?? ChannelFlags.empty;
    final q = _q.toLowerCase();
    final list = widget.channels
        .where((c) => !flags.isHidden(c.id))
        .where((c) => q.isEmpty || c.name.toLowerCase().contains(q))
        .toList()
      // Favoriten zuerst
      ..sort((a, b) => (flags.favorites.contains(b.id) ? 1 : 0)
          .compareTo(flags.favorites.contains(a.id) ? 1 : 0));
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: DpadTextField(
          builder: (_, dp) => TextField(
            decoration: InputDecoration(
                hintText: tr('Sender suchen'), prefixIcon: Icon(Icons.search)),
            onChanged: (v) => setState(() => _q = v.trim()),
            readOnly: dp.readOnly,
            showCursor: dp.showCursor,
            onTap: dp.onTap,
          ),
        ),
      ),
      Expanded(
        child: ListView.builder(
          itemCount: list.length,
          itemExtent: 60,
          itemBuilder: (_, i) {
            final c = list[i];
            return FocusableTile(
              autofocus: i == 0,
              onTap: () => Navigator.pop(context, c),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(children: [
                  ChannelLogo(name: c.name, url: c.logoUrl, size: 32),
                  const SizedBox(width: 14),
                  Expanded(
                      child: Text(c.name,
                          maxLines: 1, overflow: TextOverflow.ellipsis)),
                  if (flags.favorites.contains(c.id))
                    const Icon(Icons.star_rounded,
                        size: 16, color: AppColors.gold),
                ]),
              ),
            );
          },
        ),
      ),
    ]);
  }
}
