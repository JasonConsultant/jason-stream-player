import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/remote/peers.dart';
import '../../core/theme.dart';
import '../../l10n/strings.dart';
import '../../state/remote.dart';
import '../widgets/focusable_tile.dart';

/// „Gekoppelte Geräte“ (Fernseher: Handys) mit Entfernen. Entfernen trennt
/// eine laufende Verbindung sofort und löscht den Schlüssel.
class RemoteDevicesScreen extends ConsumerWidget {
  const RemoteDevicesScreen({super.key});

  Future<void> _remove(
      BuildContext context, WidgetRef ref, RemotePeer p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(trf('„{0}“ entfernen?', [p.name])),
        content: Text(tr('Das Handy kann den Fernseher danach nicht mehr '
            'bedienen, bis es wieder gekoppelt wird.')),
        actions: [
          TextButton(
              autofocus: true,
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr('Abbrechen'))),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr('Entfernen'))),
        ],
      ),
    );
    if (ok == true) await ref.read(remotePhonesProvider.notifier).remove(p.id);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(remotePhonesProvider);
    final t = Theme.of(context).textTheme;
    final fmt = DateFormat.yMMMd(Localizations.localeOf(context).languageCode);
    return Scaffold(
      appBar: AppBar(title: Text(tr('Gekoppelte Geräte'))),
      body: list.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                    tr('Noch kein Handy gekoppelt. Öffne auf dem Handy '
                        '„Mehr“ → „Fernbedienung“ und wähle diesen Fernseher.'),
                    textAlign: TextAlign.center,
                    style: t.bodyLarge),
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
              children: [
                for (final (i, p) in list.indexed)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: FocusableTile(
                      key: ValueKey('remote-device-${p.id}'),
                      autofocus: i == 0,
                      onTap: () => _remove(context, ref, p),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 14),
                        child: Row(children: [
                          const Icon(Icons.smartphone_rounded,
                              color: AppColors.textDim),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(p.name, style: t.titleSmall),
                                  Text(
                                      [
                                        trf('Gekoppelt am {0}',
                                            [fmt.format(p.pairedAt)]),
                                        if (p.lastSeen != null)
                                          trf('zuletzt {0}',
                                              [fmt.format(p.lastSeen!)]),
                                      ].join(' · '),
                                      style: t.bodySmall),
                                ]),
                          ),
                          const Icon(Icons.delete_outline_rounded,
                              color: AppColors.textFaint),
                        ]),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}
