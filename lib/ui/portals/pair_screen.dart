import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../core/pairing/pairing.dart';
import '../../core/security.dart';
import '../../core/theme.dart';
import '../../data/repository.dart';
import '../../models/models.dart';
import '../../state/providers.dart';
import '../../l10n/strings.dart';

/// Anmeldung per QR-Code: Fernseher zeigt Code, Handy scannt mit der Kamera,
/// trägt den Zugang im Browser ein – fertig. Kein Tippen mit der Fernbedienung.
class PairScreen extends ConsumerStatefulWidget {
  const PairScreen({super.key});

  @override
  ConsumerState<PairScreen> createState() => _PairScreenState();
}

class _PairScreenState extends ConsumerState<PairScreen> {
  PairingSession? _session;
  String? _error;
  String? _status;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _session?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    setState(() {
      _error = null;
      _status = null;
    });
    try {
      final s = await PairingSession.start();
      if (!mounted) {
        await s.cancel();
        return;
      }
      setState(() => _session = s);
      final r = await s.result;
      await _apply(r);
    } on PairingException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = Redactor.friendly(e));
    }
  }

  Future<void> _apply(PairingResult r) async {
    setState(() => _status = trf('Zugang empfangen – verbinde mit „{0}“ …', [r.name]));
    final type = switch (r.type) {
      'm3u' => PortalType.m3u,
      'stalker' => PortalType.stalker,
      _ => PortalType.xtream,
    };
    final portal = Portal(
      id: const Uuid().v4(),
      name: r.name,
      type: type,
      url: r.url,
      username: type == PortalType.stalker ? r.mac : r.username,
      password: r.password,
      epgUrl: r.epgUrl,
    );
    try {
      await IptvRepository.forPortal(portal).login();
      await ref.read(portalsProvider.notifier).add(portal);
      await ref.read(activePortalProvider.notifier).select(portal);
      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _status = null;
        _error = trf('Verbindung fehlgeschlagen: {0}', [Redactor.friendly(e)]);
        _session = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final url = _session?.url.toString();
    final sz = MediaQuery.sizeOf(context);
    // Fernseher/Querformat: QR rechts, Anleitung links – alles auf einen Blick.
    final wide = sz.width > sz.height || sz.width > 800;
    // QR so groß wie möglich, aber nie höher als der Bildschirm.
    final qrSize = wide
        ? (sz.height * 0.5).clamp(180.0, 300.0)
        : (sz.width * 0.6).clamp(180.0, 260.0);

    final steps = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(tr('Zugang vom Handy übertragen'),
            style: t.headlineMedium?.copyWith(fontFamily: 'InterDisplay')),
        const SizedBox(height: 20),
        for (final (i, s) in [
          tr('Handy und Fernseher sind im selben WLAN.'),
          tr('Kamera-App am Handy öffnen und den Code scannen.'),
          tr('Zugangsdaten im Browser eintragen und „Senden“ tippen.'),
        ].indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              CircleAvatar(
                radius: 14,
                backgroundColor: AppColors.accentSoft,
                child: Text('${i + 1}',
                    style: TextStyle(
                        color: AppColors.accent, fontWeight: FontWeight.w800)),
              ),
              const SizedBox(width: 14),
              Expanded(child: Text(s, style: t.titleMedium)),
            ]),
          ),
        const SizedBox(height: 8),
        if (url != null)
          Text(trf('Oder im Handy-Browser öffnen:\n{0}', [url]),
              style: t.bodySmall?.copyWith(height: 1.5)),
        const SizedBox(height: 14),
        Row(children: [
          Icon(Icons.lock_rounded, size: 16, color: AppColors.catchup),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              tr('Die Daten gehen nur direkt an diesen Fernseher im eigenen Netz. Der Code ist einmalig und 10 Minuten gültig.'),
              style: TextStyle(fontSize: 12, color: AppColors.textFaint),
            ),
          ),
        ]),
      ],
    );

    final Widget qr;
    if (_error != null) {
      qr = Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.wifi_off_rounded, size: 56, color: AppColors.live),
        const SizedBox(height: 12),
        Text(_error!, textAlign: TextAlign.center, style: t.bodyMedium),
        const SizedBox(height: 16),
        FilledButton.icon(
          autofocus: true,
          onPressed: _start,
          icon: const Icon(Icons.refresh_rounded),
          label: Text(tr('Neuer Code')),
        ),
      ]);
    } else if (_status != null) {
      qr = Column(mainAxisSize: MainAxisSize.min, children: [
        const CircularProgressIndicator(),
        const SizedBox(height: 16),
        Text(_status!, textAlign: TextAlign.center, style: t.titleMedium),
      ]);
    } else if (url == null) {
      qr = const CircularProgressIndicator();
    } else {
      qr = Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
            color: Colors.white, borderRadius: BorderRadius.circular(20)),
        child: QrImageView(
          data: url,
          size: qrSize,
          backgroundColor: Colors.white,
          errorCorrectionLevel: QrErrorCorrectLevel.M,
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1000),
            child: wide
                ? Row(children: [
                    Expanded(child: steps),
                    const SizedBox(width: 48),
                    SizedBox(width: qrSize + 40, child: Center(child: qr)),
                  ])
                : Column(children: [qr, const SizedBox(height: 28), steps]),
          ),
        ),
      ),
    );
  }
}
