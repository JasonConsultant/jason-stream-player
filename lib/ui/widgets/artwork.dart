import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/security.dart';
import '../../core/theme.dart';
import '../../data/image_caches.dart';
import '../tv/tv_safe.dart' show TvLook;

/// Farbpaletten für generierte Grafiken (wenn der Anbieter keine Bilder liefert).
const _palettes = <List<Color>>[
  [Color(0xFF1B2A6B), Color(0xFF6A3DE8), Color(0xFFFF7A45)],
  [Color(0xFF0E3B43), Color(0xFF1F8A70), Color(0xFFBEE3A0)],
  [Color(0xFF3B0F2E), Color(0xFFB8336A), Color(0xFFFFB37A)],
  [Color(0xFF101820), Color(0xFF2C5364), Color(0xFF7FD1E8)],
  [Color(0xFF2B1A0E), Color(0xFFA0522D), Color(0xFFFFD580)],
  [Color(0xFF14142B), Color(0xFF3A2E8C), Color(0xFF9D8CFF)],
  [Color(0xFF0B2E1F), Color(0xFF3E7C59), Color(0xFFE4D96F)],
  [Color(0xFF2A0E0E), Color(0xFF8C1C13), Color(0xFFFF6B4A)],
  [Color(0xFF081A2E), Color(0xFF0F4C81), Color(0xFF52B6FF)],
  [Color(0xFF231433), Color(0xFF6B2D5C), Color(0xFFF0A6CA)],
];

int _hash(String s) {
  var h = 0;
  for (final c in s.codeUnits) {
    h = 0x1fffffff & (h * 31 + c);
  }
  return h;
}

List<Color> paletteFor(String seed) => _palettes[_hash(seed) % _palettes.length];

/// Atmosphärischer Farbverlauf als Platzhalter-Grafik.
class GeneratedArt extends StatelessWidget {
  final String seed;
  final Widget? child;
  const GeneratedArt({super.key, required this.seed, this.child});

  @override
  Widget build(BuildContext context) {
    final p = paletteFor(seed);
    final h = _hash(seed);
    final ax = ((h % 100) / 100) * 1.6 - 0.8;
    final ay = (((h ~/ 100) % 100) / 100) * 1.2 - 0.9;
    if (TvLook.of(context)) {
      // Fernseher: ein einziger Verlauf (statt drei übereinander) – Licht-
      // fleck an derselben Stelle, ähnliche Farben, ein Bruchteil der
      // Füllrate auf schwachen GPUs.
      return DecoratedBox(
        decoration: BoxDecoration(
          // Farben/Stopps an die Drei-Schichten-Fassung angepasst
          // (kleinste mittlere Farbabweichung über alle Paletten).
          gradient: RadialGradient(
            center: Alignment(ax, ay),
            radius: 1.3,
            colors: [
              Color.lerp(p[1], p[2], 0.7)!,
              Color.lerp(p[1], p[2], 0.28)!,
              Color.lerp(p[0], p[1], 0.6)!,
              Color.lerp(p[0], p[1], 0.8)!,
            ],
            stops: const [0, 0.25, 0.7, 1],
          ),
        ),
        child: child == null
            ? const SizedBox.expand()
            : Stack(fit: StackFit.expand, children: [child!]),
      );
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [p[0], p[1]],
        ),
      ),
      child: Stack(fit: StackFit.expand, children: [
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: Alignment(ax, ay),
              radius: 0.9,
              colors: [p[2].withValues(alpha: 0.75), p[2].withValues(alpha: 0)],
            ),
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: Alignment(-ax, 1.1),
              radius: 1.0,
              colors: [p[1].withValues(alpha: 0.6), p[1].withValues(alpha: 0)],
            ),
          ),
        ),
        if (child != null) child!,
      ]),
    );
  }
}

/// Bild aus dem Netz mit generierter Grafik als Platzhalter/Fallback.
class NetworkArt extends StatelessWidget {
  final String? url;
  final String seed;
  final BoxFit fit;
  final Widget? fallbackChild;
  const NetworkArt({
    super.key,
    required this.url,
    required this.seed,
    this.fit = BoxFit.cover,
    this.fallbackChild,
  });

  @override
  Widget build(BuildContext context) {
    final fallback = GeneratedArt(seed: seed, child: fallbackChild);
    if (!UrlPolicy.isWeb(url)) return fallback;
    // Nur in Anzeigegröße dekodieren – spart viel Speicher und Zeit bei
    // Postern/Hintergründen (Originale sind oft 2000 px+).
    final tv = TvLook.of(context);
    return LayoutBuilder(builder: (context, box) {
      final dpr = MediaQuery.devicePixelRatioOf(context);
      final w = box.maxWidth.isFinite ? (box.maxWidth * dpr).round() : null;
      if (tv) {
        // Fernseher: schlichtes Image (gleicher Cache) ohne Überblendung –
        // weniger Elemente je Poster und keine Opacity-Animation in Listen.
        return Image(
          image: ResizeImage.resizeIfNeeded(
              w,
              null,
              CachedNetworkImageProvider(url!,
                  cacheManager: ImageCaches.art)),
          fit: fit,
          excludeFromSemantics: true,
          frameBuilder: (_, child, frame, sync) =>
              frame == null && !sync ? GeneratedArt(seed: seed) : child,
          errorBuilder: (_, __, ___) => fallback,
        );
      }
      return CachedNetworkImage(
      imageUrl: url!,
      cacheManager: ImageCaches.art,
      fit: fit,
      memCacheWidth: w,
      placeholder: (_, __) => GeneratedArt(seed: seed),
      errorWidget: (_, __, ___) => fallback,
    );
    });
  }
}

/// Sender-Logo; ohne Logo ein Monogramm in Senderfarbe.
///
/// Ohne ClipRRect: Hintergrund und Monogramm runden über ihre Dekoration,
/// das Logo liegt eingerückt (12 %) und erreicht die Ecken (22 % Radius)
/// nie. Das Bild läuft über ein schlichtes [Image] (gleicher Cache wie
/// CachedNetworkImage, aber ohne dessen Überblend-Widgets) – günstig in
/// langen Listen.
class ChannelLogo extends StatelessWidget {
  final String name;
  final String? url;
  final double size;
  const ChannelLogo({super.key, required this.name, this.url, this.size = 44});

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(size * 0.22);
    final w = size * 1.35;
    if (!UrlPolicy.isWeb(url)) {
      return SizedBox(
        width: w,
        height: size,
        child: _Monogram(name: name, size: size, radius: radius),
      );
    }
    // Logos sind klein – nicht in voller Auflösung dekodieren.
    final cacheW = (w * MediaQuery.devicePixelRatioOf(context)).round();
    return Container(
      width: w,
      height: size,
      padding: EdgeInsets.all(size * 0.12),
      decoration: BoxDecoration(color: AppColors.surface3, borderRadius: radius),
      child: Image(
        image: ResizeImage.resizeIfNeeded(
            cacheW, null,
            CachedNetworkImageProvider(url!, cacheManager: ImageCaches.logos)),
        fit: BoxFit.contain,
        excludeFromSemantics: true,
        errorBuilder: (_, __, ___) => _Monogram(name: name, size: size),
      ),
    );
  }
}

final _qualityWords = RegExp(r'\b(HD|FHD|UHD|4K|TV)\b');
final _spaces = RegExp(r'\s+');

class _Monogram extends StatelessWidget {
  final String name;
  final double size;
  final BorderRadius? radius;
  const _Monogram({required this.name, required this.size, this.radius});

  @override
  Widget build(BuildContext context) {
    final p = paletteFor(name);
    final words = name
        .replaceAll(_qualityWords, '')
        .trim()
        .split(_spaces)
        .where((w) => w.isNotEmpty)
        .toList();
    String initials;
    if (words.length >= 2) {
      initials = '${words[0][0]}${words[1][0]}';
    } else {
      initials = words.isEmpty
          ? '?'
          : words[0].substring(0, words[0].length.clamp(1, 2));
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [p[1], p[0]],
        ),
      ),
      child: Center(
        child: Text(
          initials.toUpperCase(),
          style: TextStyle(
            fontFamily: 'Inter',
            fontWeight: FontWeight.w800,
            fontSize: size * 0.38,
            letterSpacing: -0.5,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}
