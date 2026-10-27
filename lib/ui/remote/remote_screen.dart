import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/remote/nsd.dart';
import '../../core/remote/peers.dart';
import '../../core/remote/protocol.dart';
import '../../core/remote/transport.dart';
import '../../core/theme.dart';
import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../../state/remote.dart';
import '../../state/remote_link.dart';

/// Handy: Bereich „Fernbedienung“ öffnen.
Future<void> openRemote(BuildContext context) => Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => const RemoteScreen()));

/// Fernbedienung für die TV-App (gleiches WLAN): ohne gekoppelten
/// Fernseher die Suche/Kopplung, sonst Tasten, Sender und Guide.
class RemoteScreen extends ConsumerStatefulWidget {
  const RemoteScreen({super.key});

  @override
  ConsumerState<RemoteScreen> createState() => _RemoteScreenState();
}

class _RemoteScreenState extends ConsumerState<RemoteScreen> {
  late final RemoteLink _link = ref.read(remoteLinkProvider.notifier);
  bool _adding = false;

  @override
  void initState() {
    super.initState();
    _link.hold();
  }

  @override
  void dispose() {
    _link.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(remoteLinkProvider);
    if (s.phase == LinkPhase.none || _adding) {
      return RemotePairPage(
        canCancel: s.phase != LinkPhase.none,
        onDone: () => setState(() => _adding = false),
      );
    }
    return _ControlPage(onAdd: () => setState(() => _adding = true));
  }
}

// =================================================================== Koppeln

/// Fernseher im WLAN suchen und koppeln.
class RemotePairPage extends ConsumerStatefulWidget {
  final bool canCancel;
  final VoidCallback onDone;
  const RemotePairPage(
      {super.key, required this.onDone, this.canCancel = false});

  @override
  ConsumerState<RemotePairPage> createState() => _RemotePairPageState();
}

class _RemotePairPageState extends ConsumerState<RemotePairPage> {
  final _found = <String, FoundTv>{};
  StreamSubscription<FoundTv>? _sub;
  StreamSubscription<String>? _lost;
  Timer? _slowTimer;
  bool _slow = false;
  late final RemoteDiscovery _disco = ref.read(remoteDiscoveryProvider);

  @override
  void initState() {
    super.initState();
    _sub = _disco.discover().listen((t) {
      if (mounted) setState(() => _found[t.name] = t);
    });
    _lost = _disco.lost.listen((n) {
      if (mounted) setState(() => _found.remove(n));
    });
    _slowTimer = Timer(const Duration(seconds: 8), () {
      if (mounted) setState(() => _slow = true);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _lost?.cancel();
    _slowTimer?.cancel();
    unawaited(_disco.stopDiscover());
    super.dispose();
  }

  Future<void> _pair(String host, int port, String name) async {
    final peer = await showDialog<RemotePeer>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PairCodeDialog(host: host, port: port, name: name),
    );
    if (peer == null || !mounted) return;
    await ref.read(remoteLinkProvider.notifier).paired(peer);
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
        content: Text(trf('Mit „{0}“ gekoppelt.', [peer.name]))));
    widget.onDone();
  }

  Future<void> _manual() async {
    final ctl = TextEditingController();
    final addr = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Adresse des Fernsehers')),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(
              tr('Steht am Fernseher unter Einstellungen → „Handy als '
                  'Fernbedienung“, z. B. 192.168.178.40.'),
              style: Theme.of(ctx).textTheme.bodySmall),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('remote-manual-address'),
            controller: ctl,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(hintText: '192.168.178.40'),
            onSubmitted: (v) => Navigator.pop(ctx, v),
          ),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(tr('Abbrechen'))),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctl.text),
              child: Text(tr('Verbinden'))),
        ],
      ),
    );
    ctl.dispose();
    final p = parseTvAddress(addr ?? '');
    if (p == null) {
      if (addr != null && addr.trim().isNotEmpty && mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
            content: Text(tr('Bitte eine Adresse aus dem Heimnetz eingeben '
                '(z. B. 192.168.178.40).'))));
      }
      return;
    }
    await _pair(p.$1, p.$2, p.$1);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final paired = {for (final p in ref.watch(remoteTvsProvider)) p.id};
    final list = _found.values.toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('Fernseher koppeln')),
        leading: widget.canCancel
            ? IconButton(
                icon: const Icon(Icons.close_rounded),
                tooltip: tr('Abbrechen'),
                onPressed: widget.onDone)
            : null,
      ),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Row(children: [
            Icon(Icons.settings_remote_rounded,
                size: 40, color: AppColors.accent),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(tr('Handy als Fernbedienung'), style: t.titleMedium),
                    const SizedBox(height: 4),
                    Text(
                        tr('Öffne die App auf dem Fernseher. Handy und '
                            'Fernseher müssen im selben WLAN sein.'),
                        style: t.bodySmall),
                  ]),
            ),
          ]),
        ),
        const SizedBox(height: 20),
        Row(children: [
          Text(tr('Gefundene Fernseher'), style: t.labelLarge),
          const SizedBox(width: 10),
          if (!_slow || list.isEmpty)
            const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2)),
        ]),
        const SizedBox(height: 8),
        for (final tv in list)
          Card.filled(
            margin: const EdgeInsets.only(bottom: 8),
            color: AppColors.surface2,
            child: ListTile(
              key: ValueKey('remote-found-${tv.name}'),
              leading: Icon(Icons.tv_rounded, color: AppColors.accent),
              title: Text(tv.name),
              subtitle: Text(tv.host),
              trailing: paired.contains(tv.id)
                  ? Text(tr('Gekoppelt'),
                      style: t.labelMedium
                          ?.copyWith(color: AppColors.catchup))
                  : FilledButton.tonal(
                      onPressed: () => _pair(tv.host, tv.port, tv.name),
                      child: Text(tr('Koppeln'))),
              onTap: () => _pair(tv.host, tv.port, tv.name),
            ),
          ),
        if (list.isEmpty && !_slow)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(tr('Suche im WLAN …'), style: t.bodyMedium),
          ),
        if (list.isEmpty && _slow) const RemoteNotFoundHints(),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const ValueKey('remote-manual'),
            onPressed: _manual,
            icon: const Icon(Icons.edit_rounded),
            label: Text(tr('Adresse manuell eingeben')),
          ),
        ),
      ]),
    );
  }
}

/// „192.168.1.5“ oder „192.168.1.5:47231“ → (Host, Port). Nur private
/// Adressen (Heimnetz) – sonst null.
(String, int)? parseTvAddress(String raw) {
  final s = raw.trim();
  final m = RegExp(r'^(\d{1,3}(?:\.\d{1,3}){3})(?::(\d{1,5}))?$').firstMatch(s);
  if (m == null) return null;
  final parts = m.group(1)!.split('.').map(int.parse).toList();
  if (parts.any((p) => p > 255)) return null;
  final private = parts[0] == 10 ||
      (parts[0] == 172 && parts[1] >= 16 && parts[1] <= 31) ||
      (parts[0] == 192 && parts[1] == 168) ||
      (parts[0] == 169 && parts[1] == 254);
  if (!private) return null;
  final port = m.group(2) == null ? remoteDefaultPort : int.parse(m.group(2)!);
  if (port < 1 || port > 65535) return null;
  return (m.group(1)!, port);
}

/// Hinweise, wenn kein Fernseher gefunden wird.
class RemoteNotFoundHints extends StatelessWidget {
  final VoidCallback? onRetry;
  const RemoteNotFoundHints({super.key, this.onRetry});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    Widget hint(IconData i, String s) => Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(i, size: 18, color: AppColors.textDim),
            const SizedBox(width: 10),
            Expanded(child: Text(s, style: t.bodySmall)),
          ]),
        );
    return Container(
      key: const ValueKey('remote-hints'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.line),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(tr('Kein Fernseher gefunden'), style: t.titleSmall),
        hint(Icons.wifi_rounded,
            tr('Handy und Fernseher im selben WLAN (kein Gast-WLAN)?')),
        hint(Icons.tv_rounded,
            tr('Ist die App auf dem Fernseher geöffnet? Im Hintergrund ist '
                'die Fernbedienung aus.')),
        hint(Icons.toggle_on_rounded,
            tr('Am Fernseher: Einstellungen → „Handy als Fernbedienung“ an.')),
        hint(Icons.router_rounded,
            tr('Manche Router trennen Geräte im WLAN voneinander – dann die '
                'Adresse manuell eingeben.')),
        if (onRetry != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: FilledButton.tonalIcon(
              key: const ValueKey('remote-retry'),
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
              label: Text(tr('Erneut verbinden')),
            ),
          ),
      ]),
    );
  }
}

/// Code vom Fernseher eingeben (koppelt; bei falschem Code automatisch neuer
/// Versuch mit neuem Code am Fernseher).
class PairCodeDialog extends ConsumerStatefulWidget {
  final String host;
  final int port;
  final String name;
  const PairCodeDialog(
      {super.key, required this.host, required this.port, required this.name});

  @override
  ConsumerState<PairCodeDialog> createState() => _PairCodeDialogState();
}

class _PairCodeDialogState extends ConsumerState<PairCodeDialog> {
  final _code = TextEditingController();
  RemotePairingFlow? _flow;
  RemoteHello? _hello;
  bool _busy = true;
  String? _error;
  bool _fatal = false;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    if (!_done) unawaited(_flow?.cancel());
    _code.dispose();
    super.dispose();
  }

  String _lockedText(Duration? d) {
    final m = ((d?.inSeconds ?? 60) / 60).ceil();
    return trf('Zu viele Fehlversuche. Bitte in {0} Min. erneut versuchen.',
        [m]);
  }

  Future<void> _start() async {
    setState(() {
      _busy = true;
      _fatal = false;
    });
    try {
      final c = await ref.read(remoteConnectorProvider)(widget.host, widget.port);
      final st = await ref.read(storageProvider.future);
      final me = await st.remoteSelfId();
      final name = await ref
          .read(remoteDeviceNameProvider.future)
          .timeout(const Duration(seconds: 3), onTimeout: () => 'Android');
      _hello = c.hello;
      _flow = await c.pair(me, name);
      if (!mounted) return;
      setState(() => _busy = false);
    } on RemoteRejected catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _fatal = true;
        _error = switch (e.reason) {
          'locked' => _lockedText(e.lockedFor),
          'busy' => tr('Am Fernseher läuft gerade eine andere Kopplung.'),
          _ => tr('Fernseher nicht erreichbar.'),
        };
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _fatal = true;
        _error = tr('Fernseher nicht erreichbar.');
      });
    }
  }

  Future<void> _submit() async {
    final code = _code.text.trim();
    final flow = _flow;
    if (code.length != 4 || flow == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final key = await flow.submit(code);
      _done = true;
      final h = _hello!;
      if (!mounted) return;
      Navigator.pop(
          context,
          RemotePeer(
              id: h.tvId,
              name: h.name,
              key: key,
              pairedAt: DateTime.now(),
              host: widget.host,
              port: widget.port));
    } on RemoteRejected catch (e) {
      _flow = null;
      if (!mounted) return;
      _code.clear();
      if (e.reason == 'code') {
        setState(() => _error =
            tr('Falscher Code. Am Fernseher erscheint gleich ein neuer Code.'));
        await _start();
        if (mounted && !_fatal) {
          setState(() => _error =
              tr('Falscher Code. Bitte den neuen Code vom Fernseher eingeben.'));
        }
      } else {
        setState(() {
          _busy = false;
          _fatal = true;
          _error = e.reason == 'locked'
              ? _lockedText(e.lockedFor)
              : tr('Verbindung zum Fernseher unterbrochen.');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final name = _hello?.name ?? widget.name;
    return AlertDialog(
      key: const ValueKey('remote-pair-dialog'),
      title: Text(tr('Code eingeben')),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(
            trf('Am Fernseher „{0}“ wird ein 4-stelliger Code angezeigt.',
                [name]),
            style: t.bodyMedium),
        const SizedBox(height: 16),
        TextField(
          key: const ValueKey('remote-pair-code-field'),
          controller: _code,
          autofocus: true,
          enabled: !_fatal,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          maxLength: 4,
          textAlign: TextAlign.center,
          style: t.headlineMedium?.copyWith(
              letterSpacing: 14,
              fontFeatures: const [FontFeature.tabularFigures()]),
          decoration: const InputDecoration(counterText: '', hintText: '····'),
          onChanged: (v) {
            if (v.length == 4) _submit();
          },
        ),
        if (_busy)
          const Padding(
            padding: EdgeInsets.only(top: 12),
            child: LinearProgressIndicator(),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(_error!,
                key: const ValueKey('remote-pair-error'),
                style: t.bodySmall?.copyWith(color: AppColors.live)),
          ),
      ]),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(tr('Abbrechen'))),
        if (_fatal)
          TextButton(onPressed: _start, child: Text(tr('Erneut versuchen'))),
      ],
    );
  }
}

// =================================================================== Bedienung

class _ControlPage extends ConsumerStatefulWidget {
  final VoidCallback onAdd;
  const _ControlPage({required this.onAdd});

  @override
  ConsumerState<_ControlPage> createState() => _ControlPageState();
}

class _ControlPageState extends ConsumerState<_ControlPage>
    with SingleTickerProviderStateMixin {
  late final _tabs = TabController(length: 3, vsync: this);
  bool _touchpad = false;

  @override
  void initState() {
    super.initState();
    final st = ref.read(storageProvider).value;
    _touchpad = st?.flag('remote_touchpad') ?? false;
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _menu(String v) async {
    final link = ref.read(remoteLinkProvider.notifier);
    final tv = ref.read(remoteLinkProvider).tv;
    if (v == 'add') return widget.onAdd();
    if (v.startsWith('tv:')) return link.select(v.substring(3));
    if (v == 'forget' && tv != null) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(trf('„{0}“ entfernen?', [tv.name])),
          content: Text(tr('Das Handy vergisst den Fernseher. Zum erneuten '
              'Bedienen muss es wieder gekoppelt werden.')),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(tr('Abbrechen'))),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(tr('Entfernen'))),
          ],
        ),
      );
      if (ok == true) await link.forget(tv.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(remoteLinkProvider);
    final tvs = ref.watch(remoteTvsProvider);
    final t = Theme.of(context).textTheme;
    final phaseText = switch (s.phase) {
      LinkPhase.connected => tr('Verbunden'),
      LinkPhase.connecting => tr('Verbinde …'),
      LinkPhase.unreachable => tr('Nicht erreichbar'),
      LinkPhase.removed => tr('Nicht mehr gekoppelt'),
      _ => tr('Getrennt'),
    };
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(s.tv?.name ?? tr('Fernbedienung'),
              maxLines: 1, overflow: TextOverflow.ellipsis),
          Row(children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: s.connected ? AppColors.catchup : AppColors.textFaint,
              ),
            ),
            const SizedBox(width: 6),
            Text(phaseText, style: t.bodySmall),
          ]),
        ]),
        actions: [
          IconButton(
            key: const ValueKey('remote-touchpad-toggle'),
            tooltip: _touchpad ? tr('Steuerkreuz') : tr('Touchpad'),
            icon: Icon(_touchpad
                ? Icons.gamepad_rounded
                : Icons.touch_app_rounded),
            onPressed: () {
              setState(() => _touchpad = !_touchpad);
              ref.read(storageProvider).value
                  ?.setFlag('remote_touchpad', _touchpad);
            },
          ),
          PopupMenuButton<String>(
            onSelected: _menu,
            itemBuilder: (_) => [
              for (final tv in tvs)
                if (tv.id != s.tv?.id)
                  PopupMenuItem(
                      value: 'tv:${tv.id}',
                      child: Text(trf('Zu „{0}“ wechseln', [tv.name]))),
              PopupMenuItem(
                  value: 'add', child: Text(tr('Weiteren Fernseher koppeln'))),
              PopupMenuItem(
                  value: 'forget', child: Text(tr('Fernseher entfernen'))),
            ],
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(children: [
          if (!s.connected) _ConnectionBanner(state: s, onRepair: widget.onAdd),
          if (s.connected) _NowPlaying(status: s.status),
          if (s.connected && s.text.focus)
            _TextBridge(key: ValueKey('tb-${s.text.hint}-${s.text.obscure}')),
          TabBar(
            controller: _tabs,
            tabs: [
              Tab(text: tr('Tasten')),
              Tab(text: tr('Sender')),
              Tab(text: tr('TV-Guide')),
            ],
          ),
          Expanded(
            // Nicht wischen: Wischen gehört dem Touchpad bzw. den Listen.
            child: TabBarView(
                controller: _tabs,
                physics: const NeverScrollableScrollPhysics(),
                children: [
              _KeysTab(touchpad: _touchpad, volume: s.volume),
              const RemoteChannelList(guide: false),
              const RemoteChannelList(guide: true),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _ConnectionBanner extends ConsumerWidget {
  final RemoteLinkState state;
  final VoidCallback onRepair;
  const _ConnectionBanner({required this.state, required this.onRepair});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final link = ref.read(remoteLinkProvider.notifier);
    switch (state.phase) {
      case LinkPhase.unreachable:
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: RemoteNotFoundHints(onRetry: () => link.retry()),
        );
      case LinkPhase.removed:
        return Container(
          margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('Dieses Handy ist am Fernseher nicht mehr gekoppelt.'),
                style: t.titleSmall),
            const SizedBox(height: 10),
            FilledButton.tonal(onPressed: onRepair, child: Text(tr('Neu koppeln'))),
          ]),
        );
      default:
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Column(children: [
            const LinearProgressIndicator(),
            const SizedBox(height: 6),
            Text(trf('Verbinde mit „{0}“ …', [state.tv?.name ?? '']),
                style: t.bodySmall),
          ]),
        );
    }
  }
}

String _clock(int s) {
  final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(sec)}' : '${two(m)}:${two(sec)}';
}

class _NowPlaying extends StatelessWidget {
  final RemoteStatus status;
  const _NowPlaying({required this.status});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final s = status;
    return Container(
      key: const ValueKey('remote-now-playing'),
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
      ),
      child: !s.active
          ? Row(children: [
              const Icon(Icons.tv_off_rounded, color: AppColors.textFaint),
              const SizedBox(width: 12),
              Text(tr('Am Fernseher läuft gerade nichts.'), style: t.bodyMedium),
            ])
          : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(
                    s.live
                        ? Icons.live_tv_rounded
                        : Icons.movie_creation_outlined,
                    color: s.live ? AppColors.live : AppColors.accent),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                            [
                              if (s.channelNumber != null) '${s.channelNumber}',
                              s.title
                            ].join('  '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: t.titleSmall),
                        if ((s.programme ?? s.subtitle ?? '').isNotEmpty)
                          Text(s.programme ?? s.subtitle!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: t.bodySmall),
                      ]),
                ),
                Icon(
                    s.buffering
                        ? Icons.hourglass_top_rounded
                        : s.playing
                            ? Icons.play_arrow_rounded
                            : Icons.pause_rounded,
                    color: AppColors.textDim),
              ]),
              if (!s.live && s.duration > 0) ...[
                const SizedBox(height: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: (s.position / s.duration).clamp(0.0, 1.0),
                    minHeight: 4,
                    backgroundColor: AppColors.surface3,
                  ),
                ),
                const SizedBox(height: 4),
                Row(children: [
                  Text(_clock(s.position), style: t.labelSmall),
                  const Spacer(),
                  Text(_clock(s.duration), style: t.labelSmall),
                ]),
              ],
            ]),
    );
  }
}

/// Textfeld am Fernseher fokussiert → Eingabe hier, live übertragen.
class _TextBridge extends ConsumerStatefulWidget {
  const _TextBridge({super.key});

  @override
  ConsumerState<_TextBridge> createState() => _TextBridgeState();
}

class _TextBridgeState extends ConsumerState<_TextBridge> {
  late final TextEditingController _ctl;
  DateTime _typed = DateTime(2000);

  @override
  void initState() {
    super.initState();
    final s = ref.read(remoteLinkProvider).text;
    _ctl = TextEditingController(text: s.text);
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(remoteLinkProvider).text;
    // Änderung am Fernseher übernehmen – nicht, während hier getippt wird.
    if (!s.obscure &&
        s.text != _ctl.text &&
        DateTime.now().difference(_typed) > const Duration(milliseconds: 800)) {
      _ctl.value = TextEditingValue(
          text: s.text, selection: TextSelection.collapsed(offset: s.text.length));
    }
    final link = ref.read(remoteLinkProvider.notifier);
    return Container(
      key: const ValueKey('remote-text-bridge'),
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      decoration: BoxDecoration(
        color: AppColors.surface2,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.accent.withValues(alpha: 0.6)),
      ),
      child: Row(children: [
        Icon(Icons.keyboard_rounded, color: AppColors.accent),
        const SizedBox(width: 10),
        Expanded(
          child: TextField(
            key: const ValueKey('remote-text-field'),
            controller: _ctl,
            autofocus: true,
            obscureText: s.obscure,
            keyboardType: s.numeric
                ? TextInputType.number
                : s.multiline
                    ? TextInputType.multiline
                    : TextInputType.text,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              isDense: true,
              border: InputBorder.none,
              hintText: s.hint ?? tr('Text für den Fernseher'),
            ),
            onChanged: (v) {
              _typed = DateTime.now();
              link.text(v);
            },
            onSubmitted: (_) => link.textDone(),
          ),
        ),
        TextButton(
            onPressed: link.textDone, child: Text(tr('Fertig'))),
      ]),
    );
  }
}

// =================================================================== Tasten

class _KeysTab extends ConsumerWidget {
  final bool touchpad;
  final bool volume;
  const _KeysTab({required this.touchpad, required this.volume});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return LayoutBuilder(builder: (context, box) {
      final pad = (box.maxWidth - 32).clamp(200.0, 300.0);
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 28),
        child: Column(children: [
          Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
            RemoteKeyButton(RemoteKey.home,
                icon: Icons.home_rounded, label: tr('Start')),
            RemoteKeyButton(RemoteKey.back,
                icon: Icons.arrow_back_rounded, label: tr('Zurück')),
            RemoteKeyButton(RemoteKey.menu,
                icon: Icons.more_vert_rounded, label: tr('Menü')),
            RemoteKeyButton(RemoteKey.info,
                icon: Icons.info_outline_rounded, label: tr('Info')),
          ]),
          const SizedBox(height: 18),
          SizedBox(
            width: pad,
            height: pad,
            child: touchpad ? const _Touchpad() : const _DPad(),
          ),
          const SizedBox(height: 18),
          Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _Rocker(
                    up: RemoteKey.channelUp,
                    down: RemoteKey.channelDown,
                    label: 'CH'),
                Column(children: [
                  RemoteKeyButton(RemoteKey.playPause,
                      icon: Icons.play_arrow_rounded,
                      icon2: Icons.pause_rounded,
                      size: 64,
                      label: tr('Wiedergabe/Pause')),
                  const SizedBox(height: 10),
                  Row(children: [
                    RemoteKeyButton(RemoteKey.rewind,
                        icon: Icons.fast_rewind_rounded, label: tr('Zurückspulen')),
                    const SizedBox(width: 12),
                    RemoteKeyButton(RemoteKey.fastForward,
                        icon: Icons.fast_forward_rounded, label: tr('Vorspulen')),
                  ]),
                ]),
                if (volume)
                  _Rocker(
                      up: RemoteKey.volumeUp,
                      down: RemoteKey.volumeDown,
                      label: 'VOL',
                      mute: true)
                else
                  const SizedBox(width: 64),
              ]),
          const SizedBox(height: 20),
          Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
            for (final (k, c, l) in [
              (RemoteKey.red, const Color(0xFFE53935), tr('Rot')),
              (RemoteKey.green, const Color(0xFF43A047), tr('Grün')),
              (RemoteKey.yellow, const Color(0xFFFDD835), tr('Gelb')),
              (RemoteKey.blue, const Color(0xFF1E88E5), tr('Blau')),
            ])
              RemoteKeyButton(k, color: c, label: l, width: 64, height: 30),
          ]),
          const SizedBox(height: 22),
          _DigitPad(),
        ]),
      );
    });
  }
}

/// Eine Taste: drücken = KeyDown, loslassen = KeyUp (Halten wiederholt am
/// Fernseher). Haptisches Feedback beim Drücken.
class RemoteKeyButton extends ConsumerStatefulWidget {
  final RemoteKey k;
  final IconData? icon;

  /// Zweites Symbol daneben (Play/Pause).
  final IconData? icon2;
  final String? text;
  final String label;
  final Color? color;
  final double size;
  final double? width;
  final double? height;
  final BoxShape shape;
  const RemoteKeyButton(this.k,
      {super.key,
      this.icon,
      this.icon2,
      this.text,
      required this.label,
      this.color,
      this.size = 52,
      this.width,
      this.height,
      this.shape = BoxShape.circle});

  @override
  ConsumerState<RemoteKeyButton> createState() => _RemoteKeyButtonState();
}

class _RemoteKeyButtonState extends ConsumerState<RemoteKeyButton> {
  bool _down = false;
  Timer? _repeat;

  RemoteLink get _link => ref.read(remoteLinkProvider.notifier);

  void _press() {
    HapticFeedback.lightImpact();
    setState(() => _down = true);
    final k = widget.k;
    if (k.isVolume) {
      // Lautstärke: Schritte hier wiederholen (am Fernseher je Schritt).
      _link.key(k);
      if (k != RemoteKey.mute) {
        _repeat = Timer.periodic(const Duration(milliseconds: 300), (_) {
          HapticFeedback.selectionClick();
          _link.key(k);
        });
      }
    } else if (k.repeats) {
      _link.key(k, KeyAction.down);
    }
  }

  void _release({bool cancel = false}) {
    if (!_down) return;
    setState(() => _down = false);
    _repeat?.cancel();
    _repeat = null;
    final k = widget.k;
    if (k.isVolume) return;
    if (k.repeats) {
      _link.key(k, KeyAction.up);
    } else if (!cancel) {
      _link.key(k);
    }
  }

  @override
  void dispose() {
    _repeat?.cancel();
    if (_down && widget.k.repeats && !widget.k.isVolume) {
      _link.key(widget.k, KeyAction.up);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final w = widget.width ?? widget.size;
    final h = widget.height ?? widget.size;
    final base = widget.color ?? AppColors.surface2;
    final fg = widget.color == null ? AppColors.text : Colors.white;
    final rect = widget.shape == BoxShape.rectangle || widget.width != null;
    return Semantics(
      button: true,
      label: widget.label,
      child: Tooltip(
        message: widget.label,
        child: GestureDetector(
          key: ValueKey('rk-${widget.k.wire}'),
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => _press(),
          onTapUp: (_) => _release(),
          onTapCancel: () => _release(cancel: true),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 80),
            width: w,
            height: h,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _down
                  ? Color.alphaBlend(Colors.white24, base)
                  : base,
              shape: rect ? BoxShape.rectangle : BoxShape.circle,
              borderRadius: rect ? BorderRadius.circular(h / 2) : null,
              border: widget.color == null
                  ? Border.all(color: AppColors.line)
                  : null,
            ),
            child: widget.text != null
                ? Text(widget.text!,
                    style: TextStyle(
                        color: fg,
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                        fontFeatures: const [FontFeature.tabularFigures()]))
                : widget.icon == null
                    ? null
                    : Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(widget.icon, color: fg, size: h * 0.42),
                        if (widget.icon2 != null)
                          Icon(widget.icon2, color: fg, size: h * 0.36),
                      ]),
          ),
        ),
      ),
    );
  }
}

class _DPad extends StatelessWidget {
  const _DPad();

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        final s = box.maxWidth;
        final k = s * 0.3;
        return Container(
          key: const ValueKey('remote-dpad'),
          decoration: const BoxDecoration(
            color: AppColors.surface,
            shape: BoxShape.circle,
          ),
          child: Stack(children: [
            Align(
                alignment: Alignment.topCenter,
                child: RemoteKeyButton(RemoteKey.up,
                    icon: Icons.keyboard_arrow_up_rounded,
                    size: k,
                    label: tr('Hoch'))),
            Align(
                alignment: Alignment.bottomCenter,
                child: RemoteKeyButton(RemoteKey.down,
                    icon: Icons.keyboard_arrow_down_rounded,
                    size: k,
                    label: tr('Runter'))),
            Align(
                alignment: Alignment.centerLeft,
                child: RemoteKeyButton(RemoteKey.left,
                    icon: Icons.keyboard_arrow_left_rounded,
                    size: k,
                    label: tr('Links'))),
            Align(
                alignment: Alignment.centerRight,
                child: RemoteKeyButton(RemoteKey.right,
                    icon: Icons.keyboard_arrow_right_rounded,
                    size: k,
                    label: tr('Rechts'))),
            Center(
              child: RemoteKeyButton(RemoteKey.ok,
                  text: 'OK',
                  size: s * 0.36,
                  color: AppColors.accent,
                  label: 'OK'),
            ),
          ]),
        );
      });
}

/// Wisch-Touchpad: Wischen = Pfeiltasten (ein Schritt je 40 px), Tippen = OK.
class _Touchpad extends ConsumerStatefulWidget {
  const _Touchpad();

  @override
  ConsumerState<_Touchpad> createState() => _TouchpadState();
}

class _TouchpadState extends ConsumerState<_Touchpad> {
  Offset _acc = Offset.zero;
  static const step = 40.0;

  void _move(Offset d) {
    _acc += d;
    final link = ref.read(remoteLinkProvider.notifier);
    while (true) {
      final dx = _acc.dx, dy = _acc.dy;
      if (dx.abs() >= dy.abs() && dx.abs() >= step) {
        link.key(dx > 0 ? RemoteKey.right : RemoteKey.left);
        _acc = Offset(dx - step * dx.sign, dy * 0.5);
      } else if (dy.abs() > dx.abs() && dy.abs() >= step) {
        link.key(dy > 0 ? RemoteKey.down : RemoteKey.up);
        _acc = Offset(dx * 0.5, dy - step * dy.sign);
      } else {
        break;
      }
      HapticFeedback.selectionClick();
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return GestureDetector(
      key: const ValueKey('remote-touchpad'),
      behavior: HitTestBehavior.opaque,
      onTap: () {
        HapticFeedback.lightImpact();
        ref.read(remoteLinkProvider.notifier).key(RemoteKey.ok);
      },
      onPanStart: (_) => _acc = Offset.zero,
      onPanUpdate: (d) => _move(d.delta),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: AppColors.line),
        ),
        alignment: Alignment.center,
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.swipe_rounded, size: 40, color: AppColors.textFaint),
          const SizedBox(height: 10),
          Text(tr('Wischen zum Bewegen, Tippen für OK'),
              textAlign: TextAlign.center, style: t.bodySmall),
        ]),
      ),
    );
  }
}

class _Rocker extends StatelessWidget {
  final RemoteKey up;
  final RemoteKey down;
  final String label;
  final bool mute;
  const _Rocker(
      {required this.up,
      required this.down,
      required this.label,
      this.mute = false});

  @override
  Widget build(BuildContext context) => Container(
        width: 64,
        padding: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(32),
        ),
        child: Column(children: [
          RemoteKeyButton(up,
              icon: Icons.add_rounded, label: '$label +', size: 50),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: mute
                ? RemoteKeyButton(RemoteKey.mute,
                    icon: Icons.volume_off_rounded,
                    label: tr('Stumm'),
                    size: 34)
                : Text(label,
                    style: Theme.of(context)
                        .textTheme
                        .labelMedium
                        ?.copyWith(color: AppColors.textDim)),
          ),
          RemoteKeyButton(down,
              icon: Icons.remove_rounded, label: '$label −', size: 50),
        ]),
      );
}

class _DigitPad extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Column(children: [
        for (final row in const [
          [1, 2, 3],
          [4, 5, 6],
          [7, 8, 9],
          [null, 0, null],
        ])
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              for (final d in row)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: d == null
                      ? const SizedBox(width: 64, height: 48)
                      : RemoteKeyButton(RemoteKey.digits[d],
                          text: '$d', label: '$d', width: 64, height: 48),
                ),
            ]),
          ),
      ]);
}

// =================================================================== Sender

/// Senderliste bzw. kompakter Guide (jetzt/danach) – Daten vom Fernseher,
/// seitenweise. Antippen schaltet am Fernseher um.
class RemoteChannelList extends ConsumerStatefulWidget {
  final bool guide;
  const RemoteChannelList({super.key, required this.guide});

  @override
  ConsumerState<RemoteChannelList> createState() => _RemoteChannelListState();
}

class _RemoteChannelListState extends ConsumerState<RemoteChannelList>
    with AutomaticKeepAliveClientMixin {
  List<RemoteGroup> _groups = const [];
  String _group = '';
  final _items = <RemoteChannel>[];
  int _total = 0;
  bool _loading = false;
  String? _error;
  final _scroll = ScrollController();
  int _gen = 0;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.extentAfter < 600) _more();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  RemoteLink get _link => ref.read(remoteLinkProvider.notifier);

  Future<void> _reload() async {
    if (!ref.read(remoteLinkProvider).connected) return;
    final gen = ++_gen;
    setState(() {
      _items.clear();
      _total = 0;
      _error = null;
    });
    try {
      final g = await _link.request('groups');
      if (!mounted || gen != _gen) return;
      if (g['err'] is String) {
        setState(() => _error = remoteErrorText(g['err'] as String));
        return;
      }
      setState(() => _groups = [
            for (final j in (g['groups'] as List? ?? const []))
              if (RemoteGroup.fromJson(j) case final x?) x,
          ]);
    } catch (_) {
      if (mounted) setState(() => _error = remoteErrorText('unreachable'));
      return;
    }
    await _more();
  }

  Future<void> _more() async {
    if (_loading || (_total > 0 && _items.length >= _total)) return;
    final gen = _gen;
    setState(() => _loading = true);
    try {
      final r = await _link.request('channels',
          {'g': _group, 'o': _items.length, 'n': remotePageSize});
      if (!mounted || gen != _gen) return;
      if (r['err'] is String) {
        _error = remoteErrorText(r['err'] as String);
      } else {
        _total = r['total'] as int? ?? 0;
        _items.addAll([
          for (final j in (r['items'] as List? ?? const []))
            if (RemoteChannel.fromJson(j) case final c?) c,
        ]);
      }
    } catch (_) {
      if (mounted && gen == _gen) _error = remoteErrorText('unreachable');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _tune(RemoteChannel c) async {
    HapticFeedback.lightImpact();
    final err = await _link.tune(c.id);
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
          duration: const Duration(seconds: 2),
          content: Text(err == null
              ? trf('Umgeschaltet auf {0}', [c.name])
              : remoteErrorText(err))));
  }

  String _hm(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    super.build(context);
    ref.listen(remoteLinkProvider.select((s) => s.connected), (prev, now) {
      if (now && prev != true) _reload();
    });
    final current = ref.watch(remoteLinkProvider.select((s) => s.status.channelId));
    final t = Theme.of(context).textTheme;
    final now = DateTime.now();
    return Column(children: [
      if (_groups.isNotEmpty)
        SizedBox(
          height: 52,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            children: [
              for (final g in [RemoteGroup('', tr('Alle'), 0), ..._groups])
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(g.name),
                    selected: g.id == _group,
                    onSelected: (_) {
                      setState(() => _group = g.id);
                      _gen++;
                      _items.clear();
                      _total = 0;
                      _loading = false;
                      _more();
                    },
                  ),
                ),
            ],
          ),
        ),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(_error!, style: t.bodyMedium),
        ),
      Expanded(
        child: RefreshIndicator(
          onRefresh: _reload,
          child: ListView.builder(
            controller: _scroll,
            physics: const AlwaysScrollableScrollPhysics(),
            itemCount: _items.length + (_loading ? 1 : 0),
            itemBuilder: (context, i) {
              if (i >= _items.length) {
                return const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              final c = _items[i];
              final on = c.id == current;
              final lead = Container(
                width: 46,
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: on ? AppColors.accent : AppColors.surface2,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(c.number > 0 ? '${c.number}' : '–',
                    style: t.labelLarge?.copyWith(
                        color: on ? Colors.white : AppColors.textDim,
                        fontFeatures: const [FontFeature.tabularFigures()])),
              );
              final title = Row(children: [
                Flexible(
                  child: Text(c.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.titleSmall),
                ),
                if (c.locked) ...[
                  const SizedBox(width: 6),
                  const Icon(Icons.lock_rounded,
                      size: 14, color: AppColors.textFaint),
                ],
              ]);
              Widget? sub;
              if (widget.guide) {
                sub = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(
                      c.now == null
                          ? tr('Kein Programm')
                          : '${_hm(c.now!.start)}  ${c.now!.title}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.bodySmall?.copyWith(color: AppColors.text)),
                  if (c.next != null)
                    Text('${_hm(c.next!.start)}  ${c.next!.title}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: t.bodySmall),
                ]);
              } else if (c.now != null) {
                sub = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(c.now!.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.bodySmall),
                  const SizedBox(height: 4),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: c.now!.progress(now),
                      minHeight: 3,
                      backgroundColor: AppColors.surface3,
                    ),
                  ),
                ]);
              }
              return ListTile(
                key: ValueKey('remote-ch-${c.id}'),
                selected: on,
                leading: lead,
                title: title,
                subtitle: sub,
                isThreeLine: widget.guide && c.next != null,
                onTap: () => _tune(c),
              );
            },
          ),
        ),
      ),
    ]);
  }
}
