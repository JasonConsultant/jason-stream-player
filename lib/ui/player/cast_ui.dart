import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../l10n/strings.dart';
import '../../player/cast.dart';
import '../../state/playback_session.dart';
import '../../state/providers.dart';

/// Aussehen des Cast-Knopfs.
enum CastButtonStyle {
  /// Runder Knopf in der Kopfleiste des Players.
  player,

  /// Schlichtes Symbol im Mini-Player.
  mini,
}

/// Cast-Knopf: nur sichtbar, wenn im Heimnetz ein Cast-Gerät gefunden
/// wurde (bzw. eine Verbindung besteht). Nur Handy/Tablet.
class CastButton extends ConsumerWidget {
  final CastButtonStyle style;

  /// Kontext unter dem Navigator (Mini-Player liegt darüber).
  final BuildContext Function()? dialogContext;
  const CastButton(
      {super.key, this.style = CastButtonStyle.player, this.dialogContext});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(castSupportedProvider)) return const SizedBox.shrink();
    final cast = ref.watch(castProvider);
    if (!cast.available) return const SizedBox.shrink();
    final icon = switch (cast.phase) {
      CastPhase.connected => Icons.cast_connected_rounded,
      _ => Icons.cast_rounded,
    };
    final label = cast.connected
        ? trf('Verbunden mit {0}', [cast.device ?? ''])
        : tr('Auf Fernseher streamen');
    void tap() => showCastSheet(dialogContext?.call() ?? context, ref);
    final connecting = cast.phase == CastPhase.connecting;
    if (style == CastButtonStyle.mini) {
      return Semantics(
        label: label,
        button: true,
        child: IconButton(
          key: const ValueKey('mini-cast'),
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
          onPressed: tap,
          icon: Icon(icon,
              size: 20,
              color: cast.connected ? AppColors.accent : AppColors.text),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Semantics(
        label: label,
        button: true,
        child: Material(
          key: const ValueKey('player-cast'),
          color: cast.connected
              ? AppColors.accent.withValues(alpha: 0.35)
              : Colors.white.withValues(alpha: 0.12),
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: tap,
            child: SizedBox(
              width: 44,
              height: 44,
              child: Stack(alignment: Alignment.center, children: [
                Icon(icon, color: Colors.white, size: 22),
                if (connecting)
                  const SizedBox(
                    width: 38,
                    height: 38,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white70),
                  ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// Einmaliger Hinweis vor dem ersten Cast: Die Stream-Adresse (bei Xtream
/// mit Zugangsdaten) geht an das Gerät im Heimnetz. true = einverstanden.
Future<bool> confirmCastNotice(BuildContext context, WidgetRef ref) async {
  final st = ref.read(storageProvider).value;
  if (st == null) return false;
  if (st.flag(castNoticeFlag)) return true;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      key: const ValueKey('cast-notice'),
      icon: const Icon(Icons.cast_rounded),
      title: Text(tr('Auf Fernseher streamen')),
      content: Text(tr('Die Adresse mit deinen Zugangsdaten wird an das Gerät '
          'im Heimnetz übergeben. Sender, die eigene Kopfzeilen brauchen, '
          'laufen dort eventuell nicht.')),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('Abbrechen'))),
        FilledButton(
            key: const ValueKey('cast-notice-ok'),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('Verstanden'))),
      ],
    ),
  );
  if (ok != true) return false;
  await st.setFlag(castNoticeFlag, true);
  return true;
}

/// Geräteauswahl bzw. – wenn verbunden – „Läuft auf …“ mit Trennen.
Future<void> showCastSheet(BuildContext context, WidgetRef ref) async {
  final cast = ref.read(castProvider);
  final ctl = ref.read(playbackProvider.notifier);
  if (cast.phase != CastPhase.idle) {
    final pick = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        // Quer/viele Geräte: scrollbar statt überlaufen.
        child: ListView(shrinkWrap: true, children: [
          ListTile(
            leading: const Icon(Icons.cast_connected_rounded),
            title: Text(cast.connected
                ? trf('Verbunden mit {0}', [cast.device ?? ''])
                : tr('Verbinde …')),
            subtitle: ctl.casting
                ? Text(trf('Läuft auf {0}', [cast.device ?? '']))
                : null,
          ),
          if (cast.connected && !ctl.casting && ctl.session != null)
            ListTile(
              key: const ValueKey('cast-here'),
              leading: const Icon(Icons.tv_rounded),
              title: Text(trf('Auf {0} abspielen', [cast.device ?? ''])),
              onTap: () => Navigator.pop(ctx, 'cast'),
            ),
          ListTile(
            key: const ValueKey('cast-disconnect'),
            leading: const Icon(Icons.close_rounded),
            title: Text(tr('Trennen')),
            subtitle: ctl.casting
                ? Text(tr('Wiedergabe läuft auf dem Handy weiter'))
                : null,
            onTap: () => Navigator.pop(ctx, 'disconnect'),
          ),
        ]),
      ),
    );
    if (pick == 'disconnect') await ctl.disconnectCast();
    if (pick == 'cast') await ctl.castCurrent();
    return;
  }
  final devices = cast.devices;
  if (devices.isEmpty) return;
  final picked = await showModalBottomSheet<CastDevice>(
    context: context,
    builder: (ctx) => SafeArea(
      // Quer/viele Geräte: scrollbar statt überlaufen.
        child: ListView(shrinkWrap: true, children: [
        ListTile(
          title: Text(tr('Auf Fernseher streamen'),
              style: Theme.of(ctx).textTheme.titleMedium),
        ),
        for (final d in devices)
          ListTile(
            key: ValueKey('cast-device-${d.id}'),
            leading: const Icon(Icons.tv_rounded),
            title: Text(d.name),
            onTap: () => Navigator.pop(ctx, d),
          ),
      ]),
    ),
  );
  if (picked == null || !context.mounted) return;
  if (!await confirmCastNotice(context, ref)) return;
  await ref.read(castProvider.notifier).connect(picked);
}

/// Kleine Anzeige „Datensparmodus aktiv“ in der Kopfleiste des Players.
class DataSaverBadge extends StatelessWidget {
  const DataSaverBadge({super.key});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(right: 8),
        child: Tooltip(
          message: tr('Datensparmodus aktiv'),
          child: Container(
            key: const ValueKey('data-saver-badge'),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.data_saver_on_rounded,
                  size: 16, color: Colors.white),
              // Schmale Bildschirme: nur das Symbol.
              if (MediaQuery.sizeOf(context).width >= 600) ...[
                const SizedBox(width: 4),
                Text(tr('Datensparmodus'),
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600)),
              ],
            ]),
          ),
        ),
      );
}
