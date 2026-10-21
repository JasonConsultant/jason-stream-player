import 'package:flutter/material.dart';

/// Farbwelt von Jason Stream Player: tiefes Tinten-Blau, warmes Signal-Orange
/// als Akzent, Rot für „Live“, Türkis für „Catch-up“.
class AppColors {
  static const bg = Color(0xFF090B10);
  static const surface = Color(0xFF11141B);
  static const surface2 = Color(0xFF181C25);
  static const surface3 = Color(0xFF222733);
  static const line = Color(0xFF2A303D);
  static const text = Color(0xFFF2F4F8);
  static const textDim = Color(0xFF9AA3B5);
  static const textFaint = Color(0xFF636C7E);

  /// Akzentfarbe – einzige Quelle für die ganze App. Wird aus der
  /// Einstellung „Akzentfarbe“ gesetzt ([setAccent], siehe accentKeyProvider)
  /// und steckt zugleich im Theme (`colorScheme.primary`).
  static Color get accent => _accent;
  static Color get accentSoft => _accent.withValues(alpha: 0x33 / 255);
  static Color _accent = accentPresets[defaultAccent]!;
  static String _accentKey = defaultAccent;
  static String get accentKey => _accentKey;

  static const defaultAccent = 'orange';

  /// Vorgaben – alle mit Kontrast ≥ 4,5:1 (WCAG AA) auf [bg] und [surface3]
  /// sowie für dunkle Schrift auf der Akzentfarbe.
  static const accentPresets = <String, Color>{
    'orange': Color(0xFFFF7A45),
    'blau': Color(0xFF5AA2FF),
    'gruen': Color(0xFF3DD68C),
    'lila': Color(0xFFB48CFF),
    'rot': Color(0xFFFF6470),
    'tuerkis': Color(0xFF22C7D6),
  };

  /// Setzt die Akzentfarbe; true, wenn sie sich geändert hat.
  static bool setAccent(String key) {
    final k = accentPresets.containsKey(key) ? key : defaultAccent;
    if (k == _accentKey) return false;
    _accentKey = k;
    _accent = accentPresets[k]!;
    return true;
  }
  static const live = Color(0xFFFF4D5E);
  static const catchup = Color(0xFF2CC9A6);
  static const gold = Color(0xFFFFC857);
}

ThemeData buildTheme({required bool tv}) {
  final scheme = ColorScheme.dark(
    primary: AppColors.accent,
    onPrimary: Color(0xFF1A0B04),
    secondary: AppColors.catchup,
    surface: AppColors.surface,
    onSurface: AppColors.text,
    surfaceContainerHighest: AppColors.surface3,
    surfaceContainerHigh: AppColors.surface2,
    surfaceContainer: AppColors.surface,
    outline: AppColors.textFaint,
    outlineVariant: AppColors.line,
    error: AppColors.live,
  );

  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    fontFamily: 'Inter',
    scaffoldBackgroundColor: AppColors.bg,
    canvasColor: AppColors.bg,
    dividerColor: AppColors.line,
    splashFactory: InkSparkle.splashFactory,
  );

  final t = base.textTheme;
  final textTheme = t.copyWith(
    displaySmall: t.displaySmall?.copyWith(
        fontWeight: FontWeight.w800, letterSpacing: -1.2, color: AppColors.text),
    headlineMedium: t.headlineMedium?.copyWith(
        fontWeight: FontWeight.w800, letterSpacing: -0.8, color: AppColors.text),
    headlineSmall: t.headlineSmall?.copyWith(
        fontWeight: FontWeight.w700, letterSpacing: -0.5, color: AppColors.text),
    titleLarge: t.titleLarge?.copyWith(
        fontWeight: FontWeight.w700, letterSpacing: -0.3, color: AppColors.text),
    titleMedium: t.titleMedium?.copyWith(
        fontWeight: FontWeight.w600, letterSpacing: -0.1, color: AppColors.text),
    titleSmall: t.titleSmall?.copyWith(
        fontWeight: FontWeight.w600, color: AppColors.text),
    bodyMedium: t.bodyMedium?.copyWith(color: AppColors.textDim),
    bodySmall: t.bodySmall?.copyWith(color: AppColors.textDim),
    labelSmall: t.labelSmall?.copyWith(
        fontWeight: FontWeight.w600, letterSpacing: 0.6, color: AppColors.textDim),
  );

  // Fernseher: deutlicher Fokus für Knöpfe, Listeneinträge und Chips (die
  // Material-Vorgabe – 10 % Aufhellung – ist aus 3 m kaum zu sehen).
  bool focused(Set<WidgetState> s) => s.contains(WidgetState.focused);
  final tvButtons = tv
      ? ButtonStyle(
          side: WidgetStateProperty.resolveWith((s) => focused(s)
              ? const BorderSide(color: AppColors.text, width: 2)
              : null),
          overlayColor: WidgetStateProperty.resolveWith((s) =>
              focused(s) ? AppColors.text.withValues(alpha: 0.16) : null),
        )
      : null;

  final themed = base.copyWith(
    focusColor: tv ? AppColors.accent.withValues(alpha: 0.30) : null,
    textButtonTheme: TextButtonThemeData(style: tvButtons),
    outlinedButtonTheme: OutlinedButtonThemeData(style: tvButtons),
    iconButtonTheme: IconButtonThemeData(style: tvButtons),
    segmentedButtonTheme: SegmentedButtonThemeData(style: tvButtons),
    // Größe auf dem Fernseher regelt die Oberflächengröße (UiScale).
    textTheme: textTheme,
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.bg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surface2,
      hintStyle: const TextStyle(color: AppColors.textFaint),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: AppColors.accent, width: 2),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(
            fontFamily: 'Inter', fontWeight: FontWeight.w700, fontSize: 15),
      ).merge(tvButtons),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: AppColors.surface,
      indicatorColor: AppColors.accentSoft,
      surfaceTintColor: Colors.transparent,
      height: 68,
      labelTextStyle: WidgetStateProperty.resolveWith((s) => TextStyle(
            fontFamily: 'Inter',
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: s.contains(WidgetState.selected)
                ? AppColors.text
                : AppColors.textFaint,
          )),
      iconTheme: WidgetStateProperty.resolveWith((s) => IconThemeData(
            color: s.contains(WidgetState.selected)
                ? AppColors.accent
                : AppColors.textFaint,
          )),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
    ),
    dialogTheme: const DialogThemeData(
      backgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
    ),
    chipTheme: ChipThemeData(
      backgroundColor: AppColors.surface2,
      selectedColor: AppColors.accent,
      side: tv
          ? WidgetStateBorderSide.resolveWith((s) => focused(s)
              ? const BorderSide(color: AppColors.text, width: 2)
              : BorderSide.none)
          : BorderSide.none,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      labelStyle: const TextStyle(
          fontFamily: 'Inter', fontWeight: FontWeight.w600, fontSize: 13),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: AppColors.accent,
      linearTrackColor: AppColors.surface3,
    ),
    listTileTheme: const ListTileThemeData(
      iconColor: AppColors.textDim,
    ),
  );
  return themed;
}
