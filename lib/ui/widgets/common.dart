import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../portals/portal_switcher.dart';
import 'package:intl/intl.dart';

import '../../core/theme.dart';

DateFormat get hm => DateFormat.Hm(L10n.lang);

String fmtDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes % 60;
  if (h == 0) return trf('{0} Min.', [m]);
  return m == 0 ? trf('{0} Std.', [h]) : trf('{0} Std. {1} Min.', [h, m]);
}

String fmtClock(Duration d) {
  String two(int n) => n.toString().padLeft(2, '0');
  final h = d.inHours;
  final m = d.inMinutes % 60;
  final s = d.inSeconds % 60;
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
}

/// Seitenkopf mit großem Titel und optionalen Aktionen rechts.
class PageHeader extends StatelessWidget {
  final String title;
  final Widget? trailing;
  final EdgeInsets padding;
  const PageHeader(this.title,
      {super.key,
      this.trailing,
      this.padding = const EdgeInsets.fromLTRB(28, 26, 28, 14)});

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < 600;
    return Padding(
      padding: narrow ? const EdgeInsets.fromLTRB(16, 14, 16, 10) : padding,
      child: Row(children: [
        Text(title,
            style: (narrow
                    ? Theme.of(context).textTheme.headlineSmall
                    : Theme.of(context).textTheme.headlineMedium)
                ?.copyWith(fontFamily: 'InterDisplay')),
        const Spacer(),
        if (trailing != null) trailing!,
        // Handy: Portal-Schalter in jeder Kopfzeile (Tablet/TV: Seitenleiste).
        if (narrow) ...[
          const SizedBox(width: 6),
          const PortalButton(compact: true),
        ],
      ]),
    );
  }
}

/// Uhrzeit, die sich jede Minute aktualisiert.
class LiveClock extends StatelessWidget {
  final TextStyle? style;
  const LiveClock({super.key, this.style});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DateTime>(
      stream: Stream.periodic(const Duration(seconds: 20), (_) => DateTime.now()),
      initialData: DateTime.now(),
      builder: (context, snap) => Text(
        hm.format(snap.data!),
        style: style ??
            Theme.of(context).textTheme.titleMedium?.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()]),
      ),
    );
  }
}

/// Kompaktes Suchfeld.
class SearchField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final ValueChanged<String> onChanged;
  final double width;
  const SearchField({
    super.key,
    required this.controller,
    required this.hint,
    required this.onChanged,
    this.width = 280,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: 44,
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        style: const TextStyle(fontSize: 14, color: AppColors.text),
        decoration: InputDecoration(
          hintText: hint,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(vertical: 12),
          prefixIcon: const Icon(Icons.search, size: 20, color: AppColors.textFaint),
          suffixIcon: ValueListenableBuilder(
            valueListenable: controller,
            builder: (_, v, __) => v.text.isEmpty
                ? const SizedBox.shrink()
                : IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () {
                      controller.clear();
                      onChanged('');
                    },
                  ),
          ),
        ),
      ),
    );
  }
}

/// Leer- oder Fehlerzustand mit klarer nächster Aktion.
class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? message;
  final String? action;
  final VoidCallback? onAction;
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 48, color: AppColors.textFaint),
            const SizedBox(height: 16),
            Text(title, style: t.titleLarge, textAlign: TextAlign.center),
            if (message != null) ...[
              const SizedBox(height: 8),
              Text(message!, style: t.bodyMedium, textAlign: TextAlign.center),
            ],
            if (action != null) ...[
              const SizedBox(height: 22),
              FilledButton(
                  autofocus: true, onPressed: onAction, child: Text(action!)),
            ],
          ]),
        ),
      ),
    );
  }
}

/// Dünner Fortschrittsbalken mit runden Enden.
class ThinProgress extends StatelessWidget {
  final double value;
  final Color color;
  final double height;
  const ThinProgress(
      {super.key,
      required this.value,
      this.color = AppColors.accent,
      this.height = 3});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(height),
      child: LinearProgressIndicator(
        value: value,
        minHeight: height,
        color: color,
        backgroundColor: Colors.white.withValues(alpha: 0.10),
      ),
    );
  }
}

/// Bewertung mit Stern.
class RatingLabel extends StatelessWidget {
  final double rating;
  final double size;
  const RatingLabel(this.rating, {super.key, this.size = 13});

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.star_rounded, size: size + 3, color: AppColors.gold),
      const SizedBox(width: 3),
      Text(rating.toStringAsFixed(1),
          style: TextStyle(
              fontSize: size,
              fontWeight: FontWeight.w700,
              color: AppColors.text)),
    ]);
  }
}
