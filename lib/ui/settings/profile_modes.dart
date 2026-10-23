import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../l10n/strings.dart';
import '../../models/models.dart';
import '../../state/emby.dart';
import '../../state/my_groups.dart';
import '../../state/profile_mode.dart';
import '../../state/providers.dart';
import '../live/parental.dart';
import '../widgets/focusable_tile.dart';

/// Kindermodus einschalten: ohne PIN wird erst eine angelegt (Pflicht),
/// sonst wird die vorhandene abgefragt. true = eingeschaltet.
Future<bool> enableKidsMode(BuildContext context, WidgetRef ref) async {
  if (!await ensurePin(context, ref)) return false;
  // ensurePin legt bei zu kurzer Eingabe keine PIN an → nicht einschalten.
  final st = await ref.read(storageProvider.future);
  if (!st.hasPin()) return false;
  await ref.read(profileModeProvider.notifier).setKids(true);
  return true;
}

/// Kindermodus beenden – nur mit PIN. true = beendet.
Future<bool> exitKidsMode(BuildContext context, WidgetRef ref) async {
  if (!await askPin(context, ref)) return false;
  await ref.read(profileModeProvider.notifier).setKids(false);
  return true;
}

/// Gastmodus umschalten (ohne PIN) und kurz Bescheid geben.
Future<void> toggleGuestMode(BuildContext context, WidgetRef ref) async {
  final on = !ref.read(profileModeProvider).guest;
  await ref.read(profileModeProvider.notifier).setGuest(on);
  if (!context.mounted) return;
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
        content: Text(on
            ? tr('Gastmodus an – Verlauf und Favoriten bleiben unberührt')
            : tr('Gastmodus aus'))));
}

/// Einstellungsseite „Kindermodus“: freigegebene Gruppen wählen und den
/// Modus einschalten.
class KidsModeScreen extends ConsumerWidget {
  const KidsModeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(profileModeProvider);
    final live = ref.watch(liveDataProvider).value;
    final order = ref.watch(sortOrderProvider).value ?? SortOrder.empty;
    final myGroups = ref.watch(myGroupsProvider).value ?? const <MyGroup>[];
    final movies = ref.watch(moviesProvider).value?.categories ?? const [];
    final series = ref.watch(seriesProvider).value?.categories ?? const [];
    // Emby-Mediatheken (portalunabhängig, nur wenn angemeldet).
    final embyOn = ref.watch(embySignedInProvider);
    final embyMovies = embyOn
        ? ref.watch(embyMoviesProvider).value?.categories ?? const <Category>[]
        : const <Category>[];
    final embySeries = embyOn
        ? ref.watch(embySeriesProvider).value?.categories ?? const <Category>[]
        : const <Category>[];
    final t = Theme.of(context).textTheme;
    final groups = [
      for (final g in myGroups) Category(id: g.id, name: g.name),
      ...order.sortGroups(live?.categories ?? const []),
    ];

    Future<void> toggleGroup(String id) {
      final s = {...mode.kidsGroups};
      s.contains(id) ? s.remove(id) : s.add(id);
      return ref.read(profileModeProvider.notifier).setKidsGroups(s);
    }

    Future<void> toggleVod(String key) {
      final s = {...mode.kidsVod};
      s.contains(key) ? s.remove(key) : s.add(key);
      return ref.read(profileModeProvider.notifier).setKidsVod(s);
    }

    Future<void> toggleEmby(String key) {
      final s = {...mode.kidsEmby};
      s.contains(key) ? s.remove(key) : s.add(key);
      return ref.read(profileModeProvider.notifier).setKidsEmby(s);
    }

    Widget heading(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(4, 22, 4, 8),
          child: Text(text, style: t.labelSmall),
        );

    return Scaffold(
      appBar: AppBar(title: Text(tr('Kindermodus'))),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
            children: [
              Text(
                tr('Im Kindermodus sind nur die hier freigegebenen Gruppen '
                    'sichtbar – überall, auch in Suche, TV-Guide und beim '
                    'Umschalten. Einstellungen, Portalwechsel und Bearbeiten '
                    'sind gesperrt. Beenden nur mit der PIN.'),
                style: t.bodyMedium,
              ),
              const SizedBox(height: 16),
              FocusableTile(
                key: const ValueKey('kids-enable'),
                autofocus: true,
                onTap: () async {
                  if (await enableKidsMode(context, ref) && context.mounted) {
                    // Zurück zur Hauptnavigation – dort gilt jetzt der Modus.
                    Navigator.of(context).popUntil((r) => r.isFirst);
                  }
                },
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(
                    color: AppColors.accentSoft,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(children: [
                    Icon(Icons.child_care_rounded,
                        color: AppColors.accent),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(tr('Kindermodus starten'),
                              style: t.titleSmall?.copyWith(fontSize: 15)),
                          Text(
                              mode.kidsGroups.isEmpty
                                  ? tr('Noch keine Gruppe freigegeben')
                                  : trf('{0} Gruppen freigegeben',
                                      [mode.kidsGroups.length]),
                              style: t.bodySmall),
                        ],
                      ),
                    ),
                    const Icon(Icons.chevron_right_rounded,
                        color: AppColors.textDim),
                  ]),
                ),
              ),
              heading(tr('FREIGEGEBENE GRUPPEN (LIVE TV)')),
              if (groups.isEmpty)
                Text(tr('Keine Gruppen geladen'), style: t.bodySmall),
              for (final g in groups)
                _CheckTile(
                  key: ValueKey('kids-group-${g.id}'),
                  label: g.name,
                  icon: MyGroup.isMy(g.id)
                      ? Icons.folder_special_rounded
                      : Icons.folder_rounded,
                  checked: mode.kidsGroups.contains(g.id),
                  onTap: () => toggleGroup(g.id),
                ),
              if (movies.isNotEmpty || series.isNotEmpty) ...[
                heading(tr('FREIGEGEBENE FILM- UND SERIEN-KATEGORIEN')),
                for (final c in movies)
                  _CheckTile(
                    label: c.name,
                    icon: Icons.movie_rounded,
                    checked:
                        mode.kidsVod.contains(ProfileMode.vodKey(false, c.id)),
                    onTap: () => toggleVod(ProfileMode.vodKey(false, c.id)),
                  ),
                for (final c in series)
                  _CheckTile(
                    label: c.name,
                    icon: Icons.video_library_rounded,
                    checked:
                        mode.kidsVod.contains(ProfileMode.vodKey(true, c.id)),
                    onTap: () => toggleVod(ProfileMode.vodKey(true, c.id)),
                  ),
              ],
              if (embyMovies.isNotEmpty || embySeries.isNotEmpty) ...[
                heading(tr('FREIGEGEBENE EMBY-MEDIATHEKEN')),
                for (final (series, list) in [
                  (false, embyMovies),
                  (true, embySeries)
                ])
                  for (final c in list)
                    _CheckTile(
                      key: ValueKey(
                          'kids-emby-${ProfileMode.vodKey(series, c.id)}'),
                      label: '${c.name} · ${series ? tr('Serien') : tr('Filme')}',
                      icon: series
                          ? Icons.video_library_rounded
                          : Icons.movie_rounded,
                      checked: mode.kidsEmby
                          .contains(ProfileMode.vodKey(series, c.id)),
                      onTap: () => toggleEmby(ProfileMode.vodKey(series, c.id)),
                    ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _CheckTile extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool checked;
  final VoidCallback onTap;
  const _CheckTile({
    super.key,
    required this.label,
    required this.icon,
    required this.checked,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => Semantics(
        checked: checked,
        child: FocusableTile(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(children: [
              Icon(icon, size: 20, color: AppColors.textDim),
              const SizedBox(width: 14),
              Expanded(
                child: Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: AppColors.text)),
              ),
              Icon(
                  checked
                      ? Icons.check_box_rounded
                      : Icons.check_box_outline_blank_rounded,
                  color: checked ? AppColors.accent : AppColors.textFaint),
            ]),
          ),
        ),
      );
}

/// Einstellungen im Kindermodus: statt aller Optionen nur „Beenden (PIN)“.
class KidsSettingsLock extends ConsumerWidget {
  const KidsSettingsLock({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.child_care_rounded,
                size: 56, color: AppColors.accent),
            const SizedBox(height: 16),
            Text(tr('Kindermodus ist aktiv'),
                style: t.titleLarge, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(
                tr('Einstellungen sind gesperrt. Zum Beenden wird die PIN '
                    'benötigt.'),
                style: t.bodyMedium,
                textAlign: TextAlign.center),
            const SizedBox(height: 22),
            FilledButton.icon(
              key: const ValueKey('kids-exit'),
              autofocus: true,
              onPressed: () => exitKidsMode(context, ref),
              icon: const Icon(Icons.lock_open_rounded),
              label: Text(tr('Kindermodus beenden')),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Kleine Plakette „Kindermodus“ / „Gast“ (nicht bedienbar).
class ProfileBadge extends ConsumerWidget {
  const ProfileBadge({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final m = ref.watch(profileModeProvider);
    if (!m.kids && !m.guest) return const SizedBox.shrink();
    Widget pill(IconData icon, String text, Color color) => Container(
          margin: const EdgeInsets.only(left: 6),
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
          decoration: BoxDecoration(
            color: AppColors.surface2.withValues(alpha: 0.92),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: color.withValues(alpha: 0.6)),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 13, color: color),
            const SizedBox(width: 5),
            Text(text,
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: color,
                    decoration: TextDecoration.none)),
          ]),
        );
    // Liegt in der Shell außerhalb des Scaffolds: Material für Schrift/Stil.
    return IgnorePointer(
      child: ExcludeFocus(
        child: Material(
          type: MaterialType.transparency,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (m.kids)
              pill(Icons.child_care_rounded, tr('Kindermodus'),
                  AppColors.accent),
            if (m.guest)
              pill(Icons.person_outline_rounded, tr('Gast'), AppColors.gold),
          ]),
        ),
      ),
    );
  }
}
