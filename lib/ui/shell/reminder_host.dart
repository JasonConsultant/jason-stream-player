import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform_info.dart';
import '../../data/reminders/reminders.dart';
import '../../l10n/strings.dart';
import '../../models/models.dart';
import '../../state/providers.dart';
import '../nav.dart';

/// Globaler Navigator (für Hinweise, die auf jedem Bildschirm erscheinen).
final appNavigatorKey = GlobalKey<NavigatorState>();

/// Liegt über der ganzen App (MaterialApp.builder): zeigt fällige
/// Erinnerungen und führt Startaktionen aus Benachrichtigungen aus.
class ReminderHost extends ConsumerStatefulWidget {
  final Widget child;
  const ReminderHost({super.key, required this.child});

  @override
  ConsumerState<ReminderHost> createState() => _ReminderHostState();
}

class _ReminderHostState extends ConsumerState<ReminderHost> {
  StreamSubscription<Reminder>? _sub;
  bool _dialogOpen = false;

  @override
  void initState() {
    super.initState();
    _sub = ref.read(remindersProvider.notifier).due.listen(_show);
    PlatformInfo.listenLaunchActions(_takeLaunch);
    _takeLaunch();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  BuildContext? get _navContext =>
      appNavigatorKey.currentState?.overlay?.context;

  Future<List<Channel>?> _channels(String portalId) async {
    final portal = await ref.read(activePortalProvider.future);
    if (portal == null) return null;
    if (portalId.isNotEmpty && portal.id != portalId) {
      // Sender gehört zu einem anderen Portal → dorthin wechseln.
      final all = await ref.read(portalsProvider.future);
      final target = all.where((p) => p.id == portalId).firstOrNull;
      if (target == null) return null;
      await ref.read(activePortalProvider.notifier).select(target);
    }
    final live = await ref.read(liveDataProvider.future);
    return live.channels;
  }

  Future<void> _play(String channelId, String portalId) async {
    List<Channel>? list;
    try {
      list = await _channels(portalId);
    } catch (_) {
      return;
    }
    if (list == null || !mounted) return;
    final c = list.where((x) => x.id == channelId).firstOrNull;
    if (c == null) return;
    // Warten, bis die Startseite (HomeShell) steht.
    for (var i = 0; i < 50 && _navContext == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final ctx = _navContext;
    if (ctx == null || !ctx.mounted || !mounted) return;
    await playChannel(ctx, ref, c, list);
  }

  Future<void> _takeLaunch() async {
    final a = await PlatformInfo.takeLaunchAction();
    if (a == null || a['action'] != 'play') return;
    final ch = a['channel'] ?? '';
    if (ch.isEmpty) return;
    await _play(ch, a['portal'] ?? '');
  }

  Future<void> _show(Reminder r) async {
    final ctx = _navContext;
    if (ctx == null || _dialogOpen) return;
    _dialogOpen = true;
    final nav = Navigator.of(ctx);
    final timer = Timer(const Duration(seconds: 60), () {
      if (_dialogOpen && nav.mounted) nav.pop(false);
    });
    final go = await showDialog<bool>(
      context: ctx,
      builder: (dctx) => AlertDialog(
        icon: const Icon(Icons.notifications_active_rounded),
        content: Text(
            trf('„{0}“ beginnt gleich auf {1}', [r.title, r.channelName]),
            textAlign: TextAlign.center),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dctx, false),
              child: Text(tr('Schließen'))),
          FilledButton.icon(
              autofocus: true,
              onPressed: () => Navigator.pop(dctx, true),
              icon: const Icon(Icons.live_tv_rounded),
              label: Text(tr('Umschalten'))),
        ],
      ),
    );
    timer.cancel();
    _dialogOpen = false;
    if (go == true) await _play(r.channelId, r.portalId);
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(remindersProvider); // Erinnerungen laden und Takt am Leben halten
    return widget.child;
  }
}
