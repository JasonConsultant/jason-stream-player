import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../l10n/strings.dart';
import '../../models/models.dart';
import '../../state/providers.dart';
import '../tv/tv_widgets.dart';
import '../widgets/focusable_tile.dart';

/// Hinweis auf der Startseite, wenn das Abo des aktiven Portals in
/// höchstens [warnDays] Tagen abläuft (oder schon abgelaufen ist).
/// Ausblenden gilt je Portal für den laufenden Tag.
const warnDays = 7;

/// Was der Hinweis sagt (reine Logik, testbar ohne Widgets).
class ExpiryNotice {
  /// Kalendertage bis zum Ablauf (0 = heute, negativ = abgelaufen).
  final int days;
  final DateTime expires;
  const ExpiryNotice({required this.days, required this.expires});

  bool get expired => days < 0;

  String get title => expired
      ? tr('Abo abgelaufen')
      : days == 0
          ? tr('Abo läuft heute ab')
          : days == 1
              ? tr('Abo läuft morgen ab')
              : trf('Abo läuft in {0} Tagen ab', [days]);

  /// „Gültig bis 30.10.2026“ bzw. „Abgelaufen am …“.
  String get detail {
    String two(int n) => n.toString().padLeft(2, '0');
    final d = '${two(expires.day)}.${two(expires.month)}.${expires.year}';
    return expired ? trf('Abgelaufen am {0}', [d]) : trf('Gültig bis {0}', [d]);
  }
}

/// Hinweis aus den Kontodaten oder null (kein Ablaufdatum, noch > 7 Tage,
/// Konto laut Server nicht aktiv ohne Datum …).
ExpiryNotice? expiryNotice(AccountInfo? acc, DateTime now) {
  if (acc == null) return null;
  final exp = acc.expires;
  if (exp == null) {
    // Vom Server als abgelaufen gemeldet, aber ohne Datum.
    if (acc.status.toLowerCase() == 'expired') {
      return ExpiryNotice(days: -1, expires: now);
    }
    return null;
  }
  final a = DateTime(now.year, now.month, now.day);
  final b = DateTime(exp.year, exp.month, exp.day);
  final days = b.difference(a).inDays;
  if (days > warnDays) return null;
  return ExpiryNotice(days: days, expires: exp);
}

/// yyyy-mm-dd des Tages (Schlüssel für „heute ausgeblendet“).
String dayKey(DateTime t) =>
    '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';

/// Heute ausgeblendete Portale (ID → Tag); hält die Anzeige aktuell, ohne
/// den Speicher zu beobachten.
class ExpiryDismissNotifier extends Notifier<Map<String, String>> {
  @override
  Map<String, String> build() => const {};

  bool isDismissed(String portalId, DateTime now) {
    final st = ref.read(storageProvider).value;
    final day = state[portalId] ?? st?.expiryDismissedDay(portalId);
    return day == dayKey(now);
  }

  Future<void> dismiss(String portalId, DateTime now) async {
    final day = dayKey(now);
    state = {...state, portalId: day};
    final st = ref.read(storageProvider).value;
    await st?.setExpiryDismissedDay(portalId, day);
  }
}

final expiryDismissProvider =
    NotifierProvider<ExpiryDismissNotifier, Map<String, String>>(
        ExpiryDismissNotifier.new);

/// Hinweis für das aktive Portal (null = nichts anzeigen).
typedef ExpiryBannerData = ({Portal portal, ExpiryNotice notice, bool many});

ExpiryBannerData? expiryBannerData(WidgetRef ref, DateTime now) {
  final portal = ref.watch(activePortalProvider).value;
  if (portal == null || portal.type == PortalType.demo) return null;
  final acc = ref.watch(repositoryProvider).value?.account;
  final notice = expiryNotice(acc, now);
  if (notice == null) return null;
  ref.watch(expiryDismissProvider);
  ref.watch(storageProvider);
  if (ref.read(expiryDismissProvider.notifier).isDismissed(portal.id, now)) {
    return null;
  }
  final many = (ref.watch(portalsProvider).value?.length ?? 0) > 1;
  return (portal: portal, notice: notice, many: many);
}

/// Banner für Handy/Tablet (in der Startseiten-Liste).
class ExpiryBanner extends ConsumerWidget {
  final EdgeInsets pad;
  const ExpiryBanner({super.key, required this.pad});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = DateTime.now();
    final d = expiryBannerData(ref, now);
    if (d == null) return const SizedBox.shrink();
    final color = d.notice.expired ? AppColors.live : AppColors.gold;
    final t = Theme.of(context).textTheme;
    final title =
        d.many ? '${d.portal.name} · ${d.notice.title}' : d.notice.title;
    return Padding(
      key: const ValueKey('expiry-banner'),
      padding: pad.copyWith(bottom: 16),
      child: Semantics(
        liveRegion: true,
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: color.withValues(alpha: 0.4)),
          ),
          child: Row(children: [
            Icon(Icons.schedule_rounded, color: color, size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: t.titleSmall?.copyWith(color: AppColors.text)),
                    const SizedBox(height: 2),
                    Text(d.notice.detail,
                        style: t.bodySmall?.copyWith(color: AppColors.textDim)),
                  ]),
            ),
            const SizedBox(width: 8),
            Semantics(
              label: tr('Hinweis ausblenden'),
              child: TextButton(
                key: const ValueKey('expiry-dismiss'),
                onPressed: () => ref
                    .read(expiryDismissProvider.notifier)
                    .dismiss(d.portal.id, now),
                child: Text(tr('OK')),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Banner für den Fernseher: eine Zeile, „OK“ als fokussierbarer Chip.
/// Zurück bleibt der Seite überlassen (keine Fokusfalle).
class TvExpiryBanner extends ConsumerWidget {
  final EdgeInsets pad;
  const TvExpiryBanner({super.key, required this.pad});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = DateTime.now();
    final d = expiryBannerData(ref, now);
    if (d == null) return const SizedBox.shrink();
    final color = d.notice.expired ? AppColors.live : AppColors.gold;
    final title =
        d.many ? '${d.portal.name} · ${d.notice.title}' : d.notice.title;
    return Padding(
      key: const ValueKey('expiry-banner'),
      padding: pad.copyWith(top: 12),
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withValues(alpha: 0.45)),
        ),
        child: Row(children: [
          Icon(Icons.schedule_rounded, color: color, size: 12),
          const SizedBox(width: 8),
          Expanded(
            child: Text('$title · ${d.notice.detail}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TvText.body.copyWith(color: TvColors.text)),
          ),
          const SizedBox(width: 8),
          FocusableTile(
            key: const ValueKey('expiry-dismiss'),
            radius: const BorderRadius.all(Radius.circular(8)),
            semanticLabel: tr('Hinweis ausblenden'),
            onTap: () => ref
                .read(expiryDismissProvider.notifier)
                .dismiss(d.portal.id, now),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
              decoration: BoxDecoration(
                color: TvColors.surface2,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(tr('OK'),
                  style: TvText.body.copyWith(
                      color: TvColors.text, fontWeight: FontWeight.w600)),
            ),
          ),
        ]),
      ),
    );
  }
}
