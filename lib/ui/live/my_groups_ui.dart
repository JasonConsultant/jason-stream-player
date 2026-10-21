import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../l10n/strings.dart';
import '../../models/models.dart';
import '../../state/my_groups.dart';
import '../widgets/dpad_text_field.dart';
import 'parental.dart' show kidsGuard;

/// Name für eine neue oder umbenannte Gruppe abfragen.
Future<String?> askGroupName(BuildContext context, {String initial = ''}) {
  final ctrl = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(initial.isEmpty ? tr('Neue Gruppe') : tr('Gruppe umbenennen')),
      content: DpadTextField(
        controller: ctrl,
        builder: (_, dp) => TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: 30,
          decoration: InputDecoration(hintText: tr('z. B. Fußball, Kinder, Türkisch')),
          textInputAction: TextInputAction.done,
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
          readOnly: dp.readOnly,
          showCursor: dp.showCursor,
          onTap: dp.onTap,
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx), child: Text(tr('Abbrechen'))),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: Text(tr('Speichern'))),
      ],
    ),
  ).then((v) => (v == null || v.isEmpty) ? null : v);
}

/// Neue Gruppe anlegen (optional gleich mit einem Sender).
Future<MyGroup?> createGroup(BuildContext context, WidgetRef ref,
    {Channel? withChannel}) async {
  if (!await kidsGuard(context, ref) || !context.mounted) return null;
  final name = await askGroupName(context);
  if (name == null) return null;
  return ref.read(myGroupsProvider.notifier).create(name,
      channels: [if (withChannel != null) withChannel.id]);
}

/// Sender zu eigenen Gruppen hinzufügen/entfernen (Häkchen-Liste).
Future<void> showGroupPicker(
    BuildContext context, WidgetRef ref, Channel channel) async {
  if (!await kidsGuard(context, ref) || !context.mounted) return;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    constraints: const BoxConstraints(maxWidth: 520),
    builder: (_) => _GroupPicker(channel: channel),
  );
}

class _GroupPicker extends ConsumerWidget {
  final Channel channel;
  const _GroupPicker({required this.channel});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groups = ref.watch(myGroupsProvider).value ?? const <MyGroup>[];
    final t = Theme.of(context).textTheme;
    return SafeArea(
      child: ConstrainedBox(
        constraints:
            BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.75),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 4),
            child: Row(children: [
              Expanded(
                  child: Text(trf('„{0}“ in Gruppen', [channel.name]),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.titleLarge)),
            ]),
          ),
          if (groups.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
              child: Text(
                  tr('Noch keine eigenen Gruppen. Lege eine an – z. B. „Fußball“ – '
                      'und sammle dort Sender aus allen Gruppen.'),
                  style: t.bodySmall),
            ),
          Flexible(
            child: ListView(shrinkWrap: true, children: [
              for (final (i, g) in groups.indexed)
                CheckboxListTile(
                  autofocus: i == 0,
                  value: g.channels.contains(channel.id),
                  secondary: const Icon(Icons.folder_special_rounded,
                      color: AppColors.accent),
                  title: Text(g.name),
                  subtitle: Text(trf('{0} Sender', [g.channels.length])),
                  onChanged: (_) => ref
                      .read(myGroupsProvider.notifier)
                      .toggle(g.id, channel.id),
                ),
            ]),
          ),
          ListTile(
            autofocus: groups.isEmpty,
            leading: const Icon(Icons.create_new_folder_rounded,
                color: AppColors.accent),
            title: Text(tr('Neue Gruppe …'),
                style: const TextStyle(
                    color: AppColors.accent, fontWeight: FontWeight.w700)),
            onTap: () => createGroup(context, ref, withChannel: channel),
          ),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }
}

/// Menü einer eigenen Gruppe: umbenennen, löschen.
/// Liefert true, wenn die Gruppe gelöscht wurde.
Future<bool> showMyGroupMenu(
    BuildContext context, WidgetRef ref, MyGroup g) async {
  if (!await kidsGuard(context, ref) || !context.mounted) return false;
  final pick = await showModalBottomSheet<int>(
    context: context,
    constraints: const BoxConstraints(maxWidth: 480),
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(
            autofocus: true,
            leading: const Icon(Icons.edit_rounded),
            title: Text(tr('Umbenennen')),
            onTap: () => Navigator.pop(ctx, 0)),
        ListTile(
            leading:
                const Icon(Icons.delete_outline_rounded, color: AppColors.live),
            title: Text(tr('Gruppe löschen'),
                style: const TextStyle(color: AppColors.live)),
            subtitle: Text(tr('Die Sender selbst bleiben erhalten')),
            onTap: () => Navigator.pop(ctx, 1)),
      ]),
    ),
  );
  if (!context.mounted) return false;
  final n = ref.read(myGroupsProvider.notifier);
  if (pick == 0) {
    final name = await askGroupName(context, initial: g.name);
    if (name != null) await n.rename(g.id, name);
  } else if (pick == 1) {
    await n.delete(g.id);
    return true;
  }
  return false;
}
