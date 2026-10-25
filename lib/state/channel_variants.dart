import 'dart:convert';
import '../ui/widgets/action_sheet.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme.dart';
import '../data/channel_variants.dart';
import '../l10n/strings.dart';
import '../models/models.dart';
import '../ui/widgets/focusable_tile.dart';
import 'providers.dart';

export '../data/channel_variants.dart' show VariantGroup, VariantIndex;

// ---------- Einstellung: Varianten zusammenfassen ----------
/// „Sender-Varianten zusammenfassen“ (Speicher: `set_mergevariants`,
/// Standard an).
class MergeVariantsNotifier extends Notifier<bool> {
  static const key = 'mergevariants';

  @override
  bool build() {
    final st = ref.watch(storageProvider).value;
    return st?.flag(key, fallback: true) ?? true;
  }

  Future<void> set(bool on) async {
    state = on;
    final st = await ref.read(storageProvider.future);
    await st.setFlag(key, on);
  }
}

final mergeVariantsProvider =
    NotifierProvider<MergeVariantsNotifier, bool>(MergeVariantsNotifier.new);

/// Fertiger Schalter für die Einstellungen (im Stil der Einstellungsseite:
/// der ganze Eintrag schaltet, der Schalter selbst ist nicht fokussierbar).
class MergeVariantsTile extends ConsumerWidget {
  const MergeVariantsTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final on = ref.watch(mergeVariantsProvider);
    return SettingsEntry(
      icon: Icons.layers_outlined,
      title: tr('Sender-Varianten zusammenfassen'),
      subtitle: tr(
          'Gleiche Sender in HD, FHD, 4K usw. als einen Sender zeigen – die Qualität ist im Player wählbar'),
      onTap: () => ref.read(mergeVariantsProvider.notifier).set(!on),
      trailing: IgnorePointer(
        child: ExcludeFocus(
          child: Switch(
              value: on,
              onChanged: (_) {},
              activeThumbColor: AppColors.accent),
        ),
      ),
    );
  }
}

/// Eintrag wie auf der Einstellungsseite (Symbol, Titel, Untertitel, rechts
/// ein Wert). Fokus/OK über [FocusableTile].
class SettingsEntry extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  const SettingsEntry({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return FocusableTile(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: Row(children: [
          Icon(icon, color: AppColors.textDim, size: 22),
          const SizedBox(width: 16),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: t.titleSmall?.copyWith(fontSize: 15)),
              if (subtitle != null && subtitle!.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(subtitle!, style: t.bodySmall),
              ],
            ]),
          ),
          if (trailing != null) trailing!,
        ]),
      ),
    );
  }
}

// ---------- Gruppen und Index ----------
/// Alle Variantengruppen der (unveränderten) Senderliste des aktiven Portals.
/// Rechenintensiv, hängt deshalb nur an der Liste und der Einstellung.
final variantGroupsProvider = Provider<List<VariantGroup>>((ref) {
  if (!ref.watch(mergeVariantsProvider)) return const [];
  final live = ref.watch(liveDataProvider).value;
  if (live == null || live.channels.isEmpty) return const [];
  // Kleine Listen sofort, große im Hintergrund (siehe _bgGroupsProvider).
  if (live.channels.length < variantBackgroundThreshold) {
    return groupVariants(live.channels);
  }
  return ref.watch(_bgGroupsProvider).value ?? const [];
});

/// Große Senderlisten: Gruppierung in einem eigenen Isolate. Beim
/// Neuladen bleibt das vorige Ergebnis bis zum neuen sichtbar.
final _bgGroupsProvider = FutureProvider<List<VariantGroup>>((ref) async {
  final live = ref.watch(liveDataProvider).value;
  if (live == null || live.channels.length < variantBackgroundThreshold) {
    return const [];
  }
  return groupVariantsInBackground(live.channels);
});

/// Gruppierung einer großen Liste läuft noch (erstes Mal, ohne altes
/// Ergebnis) – dann lieber kurz „lädt“ als erst alle Varianten einzeln.
bool _groupsPending(Ref ref, LiveData? live) {
  if (live == null || live.channels.length < variantBackgroundThreshold) {
    return false;
  }
  if (!ref.watch(mergeVariantsProvider)) return false;
  final bg = ref.watch(_bgGroupsProvider);
  return bg.isLoading && !bg.hasValue;
}

/// Nachschlagen: Varianten eines Senders, sichtbarer Vertreter usw.
final variantIndexProvider = Provider<VariantIndex>((ref) {
  final groups = ref.watch(variantGroupsProvider);
  if (groups.isEmpty) return VariantIndex.empty;
  final f = ref.watch(channelFlagsProvider).value;
  return VariantIndex.of(groups,
      favorites: f?.favorites ?? const {},
      hidden: f?.hidden ?? const {},
      locked: f?.locked ?? const {});
});

/// IDs → sichtbare Sender; IDs verdeckter Varianten zählen als ihr
/// Vertreter (Verlauf, eigene Gruppen, Erinnerungen aus der Zeit vor dem
/// Zusammenfassen bleiben so erhalten).
List<Channel> resolveChannelIds(
        WidgetRef ref, Iterable<String> ids, Map<String, Channel> byId) =>
    ref.read(variantIndexProvider).resolve(ids, byId);

/// Senderliste mit zusammengefassten Varianten (Basis der sichtbaren Liste).
final mergedLiveDataProvider = Provider<AsyncValue<LiveData>>((ref) {
  final live = ref.watch(liveDataProvider);
  if (_groupsPending(ref, live.value)) return const AsyncLoading<LiveData>();
  final idx = ref.watch(variantIndexProvider);
  if (idx.isEmpty) return live;
  return live.whenData((d) => LiveData(d.categories, idx.collapse(d.channels)));
});

/// Wie [mergedLiveDataProvider], zum Abwarten.
Future<LiveData> readMergedLive(WidgetRef ref) async {
  final d = await ref.read(liveDataProvider.future);
  try {
    await ref.read(channelFlagsProvider.future);
  } catch (_) {}
  if (d.channels.length >= variantBackgroundThreshold &&
      ref.read(mergeVariantsProvider)) {
    try {
      await ref.read(_bgGroupsProvider.future);
    } catch (_) {}
  }
  final idx = ref.read(variantIndexProvider);
  if (idx.isEmpty) return d;
  return LiveData(d.categories, idx.collapse(d.channels));
}

// ---------- Gewählte Variante ----------
/// Vom Nutzer gewählte Variante je Gruppe (Gruppen-Schlüssel → Sender-ID),
/// pro Portal gespeichert.
class VariantChoiceNotifier extends Notifier<Map<String, String>> {
  String? _portal;

  static String _key(String portalId) => 'varpick_$portalId';

  @override
  Map<String, String> build() {
    final st = ref.watch(storageProvider).value;
    final p = ref.watch(activePortalProvider).value;
    _portal = p?.id;
    if (st == null || p == null) return const {};
    try {
      final m = jsonDecode(st.option(_key(p.id), '{}'));
      if (m is Map) {
        return {
          for (final e in m.entries)
            if (e.value is String) '${e.key}': e.value as String,
        };
      }
    } catch (_) {}
    return const {};
  }

  /// Variante [c] für ihre Gruppe merken.
  Future<void> choose(VariantGroup g, Channel c) async {
    final next = {...state};
    if (g.best.id == c.id) {
      next.remove(g.key); // beste Variante = Standard, nichts merken
    } else {
      next[g.key] = c.id;
    }
    state = next;
    final st = ref.read(storageProvider).value;
    final p = _portal;
    if (st != null && p != null) {
      await st.setOption(_key(p), jsonEncode(next));
    }
  }
}

final variantChoiceProvider =
    NotifierProvider<VariantChoiceNotifier, Map<String, String>>(
        VariantChoiceNotifier.new);

/// Abspielreihenfolge für einen (sichtbaren) Sender: gewählte Variante,
/// dann nach Qualität. Ohne Varianten nur der Sender selbst.
List<Channel> playOrderFor(WidgetRef ref, Channel c) {
  final g = ref.read(variantIndexProvider).groupOf(c.id);
  if (g == null) return [c];
  return g.playOrder(ref.read(variantChoiceProvider)[g.key]);
}

// ---------- Auswahl-Dialog ----------
/// „Qualität/Quelle wählen“: Liste der Varianten, die laufende/gewählte
/// markiert. Liefert die gewählte Variante (bereits gemerkt) oder null.
Future<Channel?> showVariantPicker(
  BuildContext context,
  WidgetRef ref,
  Channel channel, {
  String? playingId,
}) async {
  final g = ref.read(variantIndexProvider).groupOf(channel.id);
  if (g == null) return null;
  final chosen = ref.read(variantChoiceProvider)[g.key] ?? g.best.id;
  final current = playingId ?? chosen;
  final pick = await showActionSheet<Channel>(
    useRootNavigator: true,
    context: context,
    constraints: const BoxConstraints(maxWidth: 520),
    builder: (ctx) => VariantPickerSheet(
        group: g, currentId: current, onPick: (c) => Navigator.pop(ctx, c)),
  );
  if (pick == null) return null;
  await ref.read(variantChoiceProvider.notifier).choose(g, pick);
  return pick;
}

/// Inhalt der Variantenauswahl (eigenes Widget, für Tests).
class VariantPickerSheet extends StatelessWidget {
  final VariantGroup group;
  final String currentId;
  final ValueChanged<Channel> onPick;
  const VariantPickerSheet({
    super.key,
    required this.group,
    required this.currentId,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    final members = group.members;
    return SafeArea(
      child: ListView(shrinkWrap: true, children: [
        ListTile(
          title: Text(tr('Qualität/Quelle wählen')),
          subtitle: Text(trf('{0} Varianten', [members.length])),
        ),
        for (var i = 0; i < members.length; i++)
          ListTile(
            autofocus: members[i].id == currentId,
            leading: Icon(members[i].id == currentId
                ? Icons.radio_button_checked
                : Icons.radio_button_unchecked),
            title: Text(members[i].name,
                maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(_subtitle(i)),
            onTap: () => onPick(members[i]),
          ),
      ]),
    );
  }

  String _subtitle(int i) {
    final l = group.labelOf(group.members[i]);
    final q = l == group.members[i].name ? '' : l;
    if (i == 0) return q.isEmpty ? tr('Empfohlen') : '$q · ${tr('Empfohlen')}';
    return q;
  }
}

/// Kleiner Hinweis „3 Varianten“ für Senderlisten (nichts bei 1).
class VariantCountBadge extends ConsumerWidget {
  final String channelId;

  /// TV-Senderzeile (32 dp hoch, Schrift 9,5): kleiner, nicht höher als
  /// der Sendername – sonst läuft die Zeile über.
  final bool compact;
  const VariantCountBadge(
      {super.key, required this.channelId, this.compact = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final n = ref.watch(variantIndexProvider).countOf(channelId);
    if (n < 2) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.only(left: compact ? 4 : 6),
      child: Container(
        padding: EdgeInsets.symmetric(
            horizontal: compact ? 3.5 : 6, vertical: compact ? 0 : 1),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(compact ? 3 : 6),
          border: Border.all(color: Colors.white24, width: compact ? 0.6 : 1),
        ),
        child: Text(trf('{0} Varianten', [n]),
            maxLines: 1,
            style: TextStyle(
                fontSize: compact ? 6.5 : 10.5,
                height: compact ? 1.2 : null,
                color: Colors.white60)),
      ),
    );
  }
}

// ---------- Einstellung: Live-Puffer ----------
/// Live-Puffer für Timeshift in Minuten (0 = aus). Speicher: `set_livebuffer`.
class LiveBufferNotifier extends Notifier<int> {
  static const key = 'livebuffer';
  static const choices = [0, 10, 30];

  @override
  int build() {
    final st = ref.watch(storageProvider).value;
    final v = int.tryParse(st?.option(key, '10') ?? '10') ?? 10;
    return choices.contains(v) ? v : 10;
  }

  Future<void> set(int minutes) async {
    state = minutes;
    final st = await ref.read(storageProvider.future);
    await st.setOption(key, '$minutes');
  }
}

final liveBufferProvider =
    NotifierProvider<LiveBufferNotifier, int>(LiveBufferNotifier.new);

String liveBufferLabel(int m) =>
    m == 0 ? tr('Aus') : trf('{0} Minuten', [m]);

/// Fertige Einstellung „Live-Puffer“ (Aus / 10 / 30 Min.); OK schaltet
/// zur nächsten Stufe weiter (wie die anderen Auswahl-Einträge).
class LiveBufferTile extends ConsumerWidget {
  const LiveBufferTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final m = ref.watch(liveBufferProvider);
    const c = LiveBufferNotifier.choices;
    return SettingsEntry(
      icon: Icons.history_toggle_off_rounded,
      title: tr('Live-Puffer'),
      subtitle: tr('Live-TV pausieren und zurückspulen (Arbeitsspeicher)'),
      onTap: () => ref
          .read(liveBufferProvider.notifier)
          .set(c[(c.indexOf(m) + 1) % c.length]),
      trailing: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: AppColors.accentSoft,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(liveBufferLabel(m),
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: AppColors.accent)),
      ),
    );
  }
}
