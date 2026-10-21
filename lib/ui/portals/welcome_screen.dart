import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app.dart';
import '../../core/platform_info.dart';
import '../../core/theme.dart';
import '../../models/models.dart';
import '../../state/providers.dart';
import '../widgets/artwork.dart';
import '../widgets/common.dart';
import '../widgets/focusable_tile.dart';
import 'add_portal_screen.dart';
import 'pair_screen.dart';
import '../../l10n/strings.dart';

/// Startbildschirm ohne aktives Portal: gespeicherte Portale wählen,
/// neues anlegen oder die Demo ausprobieren.
class WelcomeScreen extends ConsumerStatefulWidget {
  const WelcomeScreen({super.key});

  @override
  ConsumerState<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends ConsumerState<WelcomeScreen> {
  /// Zurück beendet die App nicht sofort: zweimal drücken (wie auf Start).
  final _exit = BackToExit();

  @override
  void dispose() {
    _exit.reset();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    // Web-Vorschau: direkt die Login-Maske öffnen (?screen=addportal).
    if (PlatformInfo.launchParams['screen'] == 'addportal') {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => const AddPortalScreen(previewFill: true)));
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final sz = MediaQuery.sizeOf(context);
    // Querformat ab ~700 Breite = zweispaltig (auch Fernseher mit
    // vergrößerter Oberfläche, die dann „nur“ 800 breit sind).
    final landscape = sz.width > sz.height && sz.width >= 700;
    final tv = ref.watch(isTvProvider) || sz.width >= 900 || landscape;
    final portals = ref.watch(portalsProvider).value ?? const <Portal>[];
    final t = Theme.of(context).textTheme;
    final wide = sz.width >= 900 || landscape;

    final content = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 520),
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(24, 40, 24, 32),
        children: [
          const Wordmark(size: 26),
          const SizedBox(height: 36),
          Text(tr('Willkommen.'),
              style: t.displaySmall?.copyWith(fontFamily: 'InterDisplay')),
          const SizedBox(height: 10),
          Text(
            tr('Live-TV, TV-Guide mit Catch-up, Filme und Serien – aus deinem eigenen IPTV-Zugang.'),
            style: t.bodyLarge?.copyWith(color: AppColors.textDim, height: 1.45),
          ),
          const SizedBox(height: 32),
          if (portals.isNotEmpty) ...[
            Text(tr('DEINE PORTALE'), style: t.labelSmall),
            const SizedBox(height: 10),
            for (var i = 0; i < portals.length; i++) ...[
              _PortalTile(portal: portals[i], autofocus: i == 0),
              const SizedBox(height: 8),
            ],
            const SizedBox(height: 20),
          ],
          // Auf dem Fernseher ist der QR-Code der bequemste Weg.
          if (tv) ...[
            FilledButton.icon(
              autofocus: portals.isEmpty,
              onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const PairScreen())),
              icon: const Icon(Icons.qr_code_2_rounded),
              label: Text(tr('Mit dem Handy einrichten (QR-Code)')),
            ),
            const SizedBox(height: 12),
          ],
          (tv ? OutlinedButton.icon : FilledButton.icon)(
            autofocus: !tv && portals.isEmpty,
            onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const AddPortalScreen())),
            icon: const Icon(Icons.add),
            label: Text(tv ? tr('Mit Fernbedienung eingeben') : tr('Portal hinzufügen')),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
              side: const BorderSide(color: AppColors.line),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: () =>
                ref.read(activePortalProvider.notifier).select(Portal.demo),
            icon: const Icon(Icons.play_circle_outline),
            label: Text(tr('Demo ausprobieren')),
          ),
          const SizedBox(height: 28),
          Text(
            tr('Jason Stream Player ist ein reiner Player und liefert keine Inhalte. Du brauchst einen Zugang (Xtream Codes oder M3U) von deinem Anbieter.'),
            style: t.bodySmall?.copyWith(color: AppColors.textFaint, height: 1.5),
          ),
        ],
      ),
    );

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _exit.press(context);
      },
      child: Scaffold(
      body: Row(children: [
        Expanded(child: Center(child: content)),
        if (wide)
          const Expanded(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: ClipRRect(
                borderRadius: BorderRadius.all(Radius.circular(24)),
                child: _Collage(),
              ),
            ),
          ),
      ]),
    ),
    );
  }
}

class _PortalTile extends ConsumerWidget {
  final Portal portal;
  final bool autofocus;
  const _PortalTile({required this.portal, this.autofocus = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FocusableTile(
      autofocus: autofocus,
      selected: true,
      onTap: () => ref.read(activePortalProvider.notifier).select(portal),
      onLongPress: () => _confirmDelete(context, ref),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: AppColors.surface3,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              portal.type == PortalType.m3u
                  ? Icons.playlist_play_rounded
                  : Icons.dns_rounded,
              color: AppColors.accent,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(portal.name,
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 2),
                Text(
                  '${switch (portal.type) { PortalType.m3u => 'M3U', PortalType.stalker => tr('MAC-Portal'), _ => 'Xtream' }} · '
                  '${Uri.tryParse(portal.url)?.host ?? portal.url}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          const Icon(Icons.chevron_right, color: AppColors.textFaint),
        ]),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(trf('„{0}“ entfernen?', [portal.name])),
        actions: [
          TextButton(
              autofocus: true, // D-Pad: sicher starten
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr('Abbrechen'))),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr('Entfernen'))),
        ],
      ),
    );
    if (ok == true) await ref.read(portalsProvider.notifier).remove(portal.id);
  }
}

/// Dekorative Poster-Collage für breite Bildschirme.
class _Collage extends StatelessWidget {
  const _Collage();

  static const _seeds = [
    'Orbit 9', 'Kaltes Land', 'Nebelgrenze', 'Station Hyperion',
    'Wie Sand im Wind', 'Die Glasstadt', 'Spur 17', 'Neuland',
    'Die Stunde der Wölfe', 'Hafenkrimi', 'Signal aus der Tiefe', 'Die Brandts',
  ];

  @override
  Widget build(BuildContext context) {
    return Stack(fit: StackFit.expand, children: [
      Container(color: AppColors.surface),
      Transform.rotate(
        angle: -0.12,
        child: Transform.scale(
          scale: 1.35,
          child: GridView.count(
            physics: const NeverScrollableScrollPhysics(),
            crossAxisCount: 4,
            mainAxisSpacing: 14,
            crossAxisSpacing: 14,
            childAspectRatio: 2 / 3,
            padding: const EdgeInsets.all(20),
            children: [
              for (final s in [..._seeds, ..._seeds])
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: GeneratedArt(
                    seed: s,
                    child: Align(
                      alignment: Alignment.bottomLeft,
                      child: Padding(
                        padding: const EdgeInsets.all(10),
                        child: Text(s,
                            style: const TextStyle(
                                fontFamily: 'InterDisplay',
                                fontWeight: FontWeight.w800,
                                fontSize: 15,
                                height: 1.05,
                                color: Colors.white)),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      const DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [AppColors.bg, Color(0x00090B10)],
            stops: [0, 0.45],
          ),
        ),
      ),
    ]);
  }
}
