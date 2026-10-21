import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/repository.dart';
import '../../l10n/strings.dart';
import '../../models/models.dart';
import '../../state/providers.dart';
import '../../state/profile_mode.dart';
import '../live/parental.dart' show kidsGuard;
import '../settings/profile_modes.dart' show toggleGuestMode;
import 'add_portal_screen.dart';
import '../widgets/dpad_text_field.dart';

/// Zustand eines Portals für die Liste.
enum PortalHealth { ok, warn, bad, unknown }

typedef PortalStatus = ({PortalHealth health, String text});

/// Prüft ein Portal (Anmeldung + Kontodaten). Ergebnis 10 Min. gemerkt,
/// damit das Öffnen der Liste nicht jedes Mal alle Server anfragt.
final portalStatusProvider =
    FutureProvider.autoDispose.family<PortalStatus, String>((ref, id) async {
  final link = ref.keepAlive();
  final t = Timer(const Duration(minutes: 10), link.close);
  ref.onDispose(t.cancel);

  final active = ref.read(activePortalProvider).value;
  final list = await ref.read(portalsProvider.future);
  final p = active?.id == id
      ? active!
      : list.firstWhere((x) => x.id == id, orElse: () => Portal.demo);
  if (p.type == PortalType.demo) {
    return (health: PortalHealth.ok, text: tr('Demo-Inhalte'));
  }
  AccountInfo? acc;
  if (active?.id == p.id) {
    // Aktives Portal: vorhandene Verbindung nutzen, keine neue Anfrage.
    try {
      final repo = await ref.read(repositoryProvider.future);
      acc = repo?.account;
    } catch (_) {
      return (health: PortalHealth.bad, text: tr('Nicht erreichbar'));
    }
  } else if (p.type == PortalType.m3u) {
    // M3U hat keine Kontodaten; Playlist nicht extra herunterladen.
    return (health: PortalHealth.unknown, text: tr('M3U-Playlist'));
  } else {
    try {
      acc = await IptvRepository.forPortal(p)
          .login()
          .timeout(const Duration(seconds: 8));
    } on TimeoutException {
      return (health: PortalHealth.bad, text: tr('Nicht erreichbar'));
    } catch (_) {
      return (health: PortalHealth.bad, text: tr('Anmeldung fehlgeschlagen'));
    }
  }
  return describeAccount(acc, DateTime.now());
});

/// Text und Ampel aus den Kontodaten.
PortalStatus describeAccount(AccountInfo? acc, DateTime now) {
  if (acc == null) return (health: PortalHealth.ok, text: tr('Verbunden'));
  final st = acc.status.toLowerCase();
  if (st != 'active' && st.isNotEmpty) {
    return (
      health: PortalHealth.bad,
      text: st == 'expired'
          ? tr('Abo abgelaufen')
          : trf('Status: {0}', [acc.status])
    );
  }
  final conns = acc.maxConnections > 1
      ? ' · ${trf('{0}/{1} Verbindungen', [
              acc.activeConnections,
              acc.maxConnections
            ])}'
      : '';
  final exp = acc.expires;
  if (exp == null) {
    return (health: PortalHealth.ok, text: '${tr('Unbegrenzt gültig')}$conns');
  }
  if (!exp.isAfter(now)) {
    return (health: PortalHealth.bad, text: tr('Abo abgelaufen'));
  }
  final days = exp.difference(now).inDays;
  if (days < 7) {
    return (
      health: PortalHealth.warn,
      text: days == 0
          ? tr('Läuft heute ab')
          : trf('Läuft in {0} Tagen ab', [days])
    );
  }
  String two(int n) => n.toString().padLeft(2, '0');
  return (
    health: PortalHealth.ok,
    text: '${trf('Gültig bis {0}', [
          '${two(exp.day)}.${two(exp.month)}.${exp.year}'
        ])}$conns'
  );
}

class _StatusLine extends ConsumerWidget {
  final Portal portal;
  const _StatusLine(this.portal);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(portalStatusProvider(portal.id));
    final type = portalTypeLabel(portal.type);
    final style = Theme.of(context).textTheme.bodySmall;
    return st.when(
      loading: () => Row(children: [
        const SizedBox(
            width: 10,
            height: 10,
            child: CircularProgressIndicator(strokeWidth: 1.5)),
        const SizedBox(width: 8),
        Flexible(child: Text('$type · ${tr('Prüfe …')}', style: style)),
      ]),
      error: (_, __) => Text(type, style: style),
      data: (s) {
        final color = switch (s.health) {
          PortalHealth.ok => AppColors.catchup,
          PortalHealth.warn => AppColors.gold,
          PortalHealth.bad => AppColors.live,
          PortalHealth.unknown => AppColors.textFaint,
        };
        return Row(children: [
          Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              s.health == PortalHealth.unknown ? s.text : '$type · ${s.text}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style?.copyWith(
                  color: s.health == PortalHealth.ok ||
                          s.health == PortalHealth.unknown
                      ? null
                      : color),
            ),
          ),
        ]);
      },
    );
  }
}

/// Feste Farbe pro Portal (aus der ID) – so erkennt man Portale auf einen
/// Blick wieder, auch auf dem Fernseher aus 3 m Entfernung.
Color portalColor(Portal p) {
  const palette = [
    Color(0xFF4F8CFF),
    Color(0xFF2EC4A6),
    Color(0xFFFFB547),
    Color(0xFFFF6B8B),
    Color(0xFFA77BFF),
    Color(0xFF52C1F2),
    Color(0xFF8BD450),
    Color(0xFFFF8A4C),
  ];
  var h = 0;
  for (final c in p.id.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return palette[h % palette.length];
}

String portalInitials(String name) {
  final parts =
      name.trim().split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
  if (parts.isEmpty) return '?';
  if (parts.length == 1) {
    return parts.first.characters.take(2).toString().toUpperCase();
  }
  return (parts[0].characters.first + parts[1].characters.first).toUpperCase();
}

String portalTypeLabel(PortalType t) => switch (t) {
      PortalType.xtream => 'Xtream Codes',
      PortalType.m3u => 'M3U',
      PortalType.stalker => tr('MAC-Portal'),
      PortalType.demo => tr('Demo'),
    };

class PortalAvatar extends StatelessWidget {
  final Portal portal;
  final double size;
  const PortalAvatar(this.portal, {super.key, this.size = 36});

  @override
  Widget build(BuildContext context) {
    final c = portalColor(portal);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(size * 0.3),
        border: Border.all(color: c.withValues(alpha: 0.7), width: 1.5),
      ),
      child: Text(
        portalInitials(portal.name),
        style: TextStyle(
          color: c,
          fontWeight: FontWeight.w800,
          fontSize: size * 0.36,
          letterSpacing: 0.3,
        ),
      ),
    );
  }
}

/// Portal-Schalter. [compact]: nur das Farb-Kürzel (Handy-Kopfzeile),
/// sonst Kürzel + Name + Typ (Seitenleiste auf Tablet/TV).
class PortalButton extends ConsumerWidget {
  final bool compact;
  const PortalButton({super.key, this.compact = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final portal = ref.watch(activePortalProvider).value;
    if (portal == null) return const SizedBox.shrink();
    final count = ref.watch(portalsProvider).value?.length ?? 0;
    final health = ref.watch(portalStatusProvider(portal.id)).value?.health;
    final alert = health == PortalHealth.bad
        ? AppColors.live
        : health == PortalHealth.warn
            ? AppColors.gold
            : null;

    // Kindermodus: Portalwechsel nur mit PIN. Lange drücken: Gastmodus.
    Future<void> open() async {
      if (await kidsGuard(context, ref) && context.mounted) {
        await showPortalSwitcher(context);
      }
    }

    void guest() {
      if (!ref.read(profileModeProvider).kids) toggleGuestMode(context, ref);
    }

    if (compact) {
      return Tooltip(
        message: tr('Portal wechseln'),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: open,
          onLongPress: guest,
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Stack(clipBehavior: Clip.none, children: [
              PortalAvatar(portal, size: 34),
              if (alert != null)
                Positioned(
                  right: -2,
                  top: -2,
                  child: Container(
                      width: 10,
                      height: 10,
                      decoration:
                          BoxDecoration(color: alert, shape: BoxShape.circle)),
                ),
              if (count > 1)
                Positioned(
                  right: -4,
                  bottom: -4,
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: const BoxDecoration(
                        color: AppColors.surface3, shape: BoxShape.circle),
                    child: const Icon(Icons.swap_horiz_rounded,
                        size: 12, color: AppColors.text),
                  ),
                ),
            ]),
          ),
        ),
      );
    }

    return _FocusBox(
      onTap: open,
      onLongPress: guest,
      child: Row(children: [
        PortalAvatar(portal, size: 36),
        const SizedBox(width: 12),
        Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(portal.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleSmall),
            if (alert != null)
              _StatusLine(portal)
            else
              Text(
                  count > 1
                      ? trf('{0} Portale · wechseln', [count])
                      : portalTypeLabel(portal.type),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall),
          ]),
        ),
        const Icon(Icons.unfold_more_rounded,
            size: 20, color: AppColors.textDim),
      ]),
    );
  }
}

class _FocusBox extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  const _FocusBox({required this.child, required this.onTap, this.onLongPress});

  @override
  State<_FocusBox> createState() => _FocusBoxState();
}

class _FocusBoxState extends State<_FocusBox> {
  bool _focus = false;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        onFocusChange: (f) => setState(() => _focus = f),
        borderRadius: BorderRadius.circular(12),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: AppColors.surface2,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color: _focus ? AppColors.accent : Colors.transparent,
                width: 2),
          ),
          child: widget.child,
        ),
      );
}

/// Liste aller Portale: antippen = wechseln, ⋮ = umbenennen/sortieren/löschen.
Future<void> showPortalSwitcher(BuildContext context) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      constraints: const BoxConstraints(maxWidth: 560),
      builder: (_) => const _SwitcherSheet(),
    );

class _SwitcherSheet extends ConsumerWidget {
  const _SwitcherSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final portals = ref.watch(portalsProvider).value ?? const <Portal>[];
    final active = ref.watch(activePortalProvider).value;
    final t = Theme.of(context).textTheme;
    final maxH = MediaQuery.sizeOf(context).height * 0.8;

    Future<void> select(Portal p) async {
      Navigator.pop(context);
      if (p.id == active?.id) return;
      await ref.read(activePortalProvider.notifier).select(p);
    }

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxH),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
            child: Row(children: [
              Expanded(child: Text(tr('Portale'), style: t.titleLarge)),
              Text(trf('{0} gespeichert', [portals.length]),
                  style: t.bodySmall),
            ]),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                for (final (i, p) in portals.indexed)
                  _PortalRow(
                    portal: p,
                    active: p.id == active?.id,
                    first: i == 0,
                    onTap: () => select(p),
                  ),
                if (active?.type == PortalType.demo)
                  _PortalRow(
                      portal: active!,
                      active: true,
                      first: false,
                      onTap: () {
                        Navigator.pop(context);
                      }),
              ],
            ),
          ),
          const Divider(height: 20),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: ListTile(
              autofocus: portals.isEmpty,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
              leading: const Icon(Icons.add_rounded, color: AppColors.accent),
              title: Text(tr('Portal hinzufügen'),
                  style: const TextStyle(
                      color: AppColors.accent, fontWeight: FontWeight.w700)),
              onTap: () {
                Navigator.pop(context);
                Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const AddPortalScreen()));
              },
            ),
          ),
        ]),
      ),
    );
  }
}

class _PortalRow extends ConsumerWidget {
  final Portal portal;
  final bool active;
  final bool first;
  final VoidCallback onTap;
  const _PortalRow({
    required this.portal,
    required this.active,
    required this.first,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = portalColor(portal);
    final demo = portal.type == PortalType.demo;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: active ? c.withValues(alpha: 0.10) : AppColors.surface2,
        borderRadius: BorderRadius.circular(14),
        child: ListTile(
          autofocus: active,
          onTap: onTap,
          onLongPress: demo ? null : () => _menu(context, ref),
          contentPadding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(
                color: active ? c.withValues(alpha: 0.8) : Colors.transparent,
                width: 1.5),
          ),
          leading: PortalAvatar(portal, size: 42),
          title: Text(portal.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700)),
          subtitle: _StatusLine(portal),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            if (active)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                    color: c, borderRadius: BorderRadius.circular(6)),
                child: Text(tr('AKTIV'),
                    style: const TextStyle(
                        color: Colors.black,
                        fontSize: 11,
                        fontWeight: FontWeight.w800)),
              ),
            if (!demo)
              IconButton(
                tooltip: tr('Optionen'),
                icon: const Icon(Icons.more_vert_rounded),
                onPressed: () => _menu(context, ref),
              ),
          ]),
        ),
      ),
    );
  }

  Future<void> _menu(BuildContext context, WidgetRef ref) async {
    final pick = await showModalBottomSheet<int>(
      context: context,
      constraints: const BoxConstraints(maxWidth: 480),
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
              autofocus: true,
              leading: const Icon(Icons.tune_rounded),
              title: Text(tr('Bearbeiten')),
              subtitle: Text(tr('Adresse, Benutzername, Passwort')),
              onTap: () => Navigator.pop(ctx, 3)),
          ListTile(
              leading: const Icon(Icons.edit_rounded),
              title: Text(tr('Umbenennen')),
              onTap: () => Navigator.pop(ctx, 0)),
          if (!first)
            ListTile(
                leading: const Icon(Icons.vertical_align_top_rounded),
                title: Text(tr('Ganz nach oben')),
                onTap: () => Navigator.pop(ctx, 1)),
          ListTile(
              leading: const Icon(Icons.delete_outline_rounded,
                  color: AppColors.live),
              title: Text(tr('Portal löschen'),
                  style: const TextStyle(color: AppColors.live)),
              onTap: () => Navigator.pop(ctx, 2)),
        ]),
      ),
    );
    if (!context.mounted) return;
    final n = ref.read(portalsProvider.notifier);
    switch (pick) {
      case 3:
        final nav = Navigator.of(context);
        nav.pop(); // Portal-Liste schließen
        await nav.push(MaterialPageRoute(
            builder: (_) => AddPortalScreen(edit: portal)));
      case 0:
        final name = await _askName(context, portal.name);
        if (name != null && name.isNotEmpty) await n.rename(portal, name);
      case 1:
        await n.moveToTop(portal.id);
      case 2:
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(trf('„{0}“ löschen?', [portal.name])),
            content: Text(tr('Zugangsdaten, Favoriten und Sortierung dieses '
                'Portals werden von diesem Gerät entfernt.')),
            actions: [
              TextButton(
                  autofocus: true,
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(tr('Abbrechen'))),
              FilledButton(
                  style:
                      FilledButton.styleFrom(backgroundColor: AppColors.live),
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(tr('Löschen'))),
            ],
          ),
        );
        if (ok == true) {
          final wasActive =
              ref.read(activePortalProvider).value?.id == portal.id;
          await n.remove(portal.id);
          // Aktives Portal gelöscht → nächstes verfügbares nehmen.
          final rest = ref.read(portalsProvider).value ?? const <Portal>[];
          if (wasActive && rest.isNotEmpty) {
            await ref.read(activePortalProvider.notifier).select(rest.first);
          }
        }
    }
  }

  Future<String?> _askName(BuildContext context, String current) {
    final ctrl = TextEditingController(text: current);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Portal umbenennen')),
        content: DpadTextField(
          controller: ctrl,
          builder: (_, dp) => TextField(
            controller: ctrl,
            autofocus: true,
            maxLength: 40,
            textInputAction: TextInputAction.done,
            onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
            readOnly: dp.readOnly,
            showCursor: dp.showCursor,
            onTap: dp.onTap,
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(tr('Abbrechen'))),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: Text(tr('Speichern'))),
        ],
      ),
    );
  }
}
