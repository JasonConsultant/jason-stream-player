import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'l10n/strings.dart';
import 'core/security.dart';
import 'core/theme.dart';
import 'data/list_cache.dart';
import 'models/models.dart';
import 'state/providers.dart';
import 'ui/shell/accent.dart';
import 'ui/shell/app_guard.dart';
import 'ui/shell/ui_scale.dart';
import 'ui/shell/home_shell.dart';
import 'ui/player/mini_player.dart';
import 'ui/shell/reminder_host.dart';
import 'ui/tv/tv_focus.dart';
import 'ui/tv/tv_safe.dart';
import 'ui/portals/welcome_screen.dart';

class JasonStreamApp extends ConsumerWidget {
  const JasonStreamApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tv = ref.watch(isTvProvider);
    final activePortal = ref.watch(activePortalProvider);

    final lang = ref.watch(appLangProvider);
    // Akzentfarbe vor dem Theme setzen (eine Quelle für Theme + AppColors).
    applyAccent(ref.watch(accentKeyProvider));
    return MaterialApp(
      key: ValueKey(lang),
      navigatorKey: appNavigatorKey,
      // TV: Overscan-Ränder als MediaQuery.padding (vor UiScale, damit sie
      // unabhängig von der Oberflächengröße ~5 % des Bildes bleiben).
      builder: (context, child) => TvSafeMediaQuery(
          enabled: tv,
          child: UiScale(
              child: AppGuard(
                  child: ReminderHost(
                      child: TvFocusRescue(
                          enabled: tv,
                          navigatorKey: appNavigatorKey,
                          // Mini-Player über allen Seiten (Handy/Tablet).
                          child: MiniPlayerHost(
                              child: child ?? const SizedBox.shrink())))))),
      locale: Locale(lang),
      supportedLocales: const [Locale('de'), Locale('en'), Locale('tr')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      title: 'Jason Stream Player',
      debugShowCheckedModeBanner: false,
      theme: tv
          ? buildTheme(tv: tv).copyWith(
              pageTransitionsTheme: TvSafePageTransitionsBuilder.theme())
          : buildTheme(tv: tv),
      // D-Pad: Zurück-Taste der Fernbedienung schließt Dialoge/Seiten.
      shortcuts: {
        ...WidgetsApp.defaultShortcuts,
        const SingleActivator(LogicalKeyboardKey.select):
            const ActivateIntent(),
      },
      home: !ref.watch(_introProvider).hasValue
          ? const _Splash()
          : activePortal.when(
              loading: () => const _Splash(),
              error: (e, _) =>
                  TvSafeArea(enabled: tv, child: _StartupError(error: e)),
              data: (portal) => portal == null
                  ? TvSafeArea(enabled: tv, child: const WelcomeScreen())
                  : HomeShell(key: ValueKey(portal.id)),
            ),
    );
  }
}

/// Startbild mindestens kurz zeigen (Logo-Animation). Liegen die Listen
/// schon im Zwischenspeicher, reicht ein kurzer Moment ([introQuick]); beim
/// ersten Start bzw. ohne Portal bleibt die volle Animation ([introFull]).
final _introProvider = FutureProvider<void>((ref) async {
  final sw = Stopwatch()..start();
  var quick = false;
  try {
    final p = await ref
        .read(activePortalProvider.future)
        .timeout(introFull, onTimeout: () => null);
    quick = p != null &&
        (p.type == PortalType.demo || await ListCache.exists('live', p));
  } catch (_) {
    quick = false;
  }
  final rest = (quick ? introQuick : introFull) - sw.elapsed;
  if (rest > Duration.zero) await Future<void>.delayed(rest);
});

const introQuick = Duration(milliseconds: 300);
const introFull = Duration(milliseconds: 1400);

/// Startbildschirm. Dauert es länger, steht darunter, worauf gewartet wird –
/// so bleibt nie nur ein stummes Logo stehen.
class _Splash extends StatefulWidget {
  const _Splash();
  @override
  State<_Splash> createState() => _SplashState();
}

class _SplashState extends State<_Splash> {
  bool _slow = false;
  late final _t = Timer(const Duration(seconds: 4), () {
    if (mounted) setState(() => _slow = true);
  });

  @override
  void initState() {
    super.initState();
    _t;
  }

  @override
  void dispose() {
    _t.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: AppColors.bg,
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: const Duration(milliseconds: 900),
              curve: Curves.easeOutCubic,
              builder: (_, v, child) => Opacity(
                opacity: v,
                child: Transform.scale(scale: 0.85 + 0.15 * v, child: child),
              ),
              child: const Wordmark(size: 30),
            ),
            const SizedBox(height: 28),
            AnimatedOpacity(
              opacity: _slow ? 1 : 0,
              duration: const Duration(milliseconds: 300),
              child: Column(children: [
                const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2.5)),
                const SizedBox(height: 14),
                Text(tr('Gespeicherte Daten werden geladen …'),
                    style: const TextStyle(
                        color: AppColors.textDim, fontSize: 14)),
              ]),
            ),
          ]),
        ),
      );
}

/// Fehler beim Start: verständlich, mit „Erneut versuchen“ und – als
/// letzter Ausweg – „App-Daten zurücksetzen“.
class _StartupError extends ConsumerWidget {
  final Object error;
  const _StartupError({required this.error});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.error_outline_rounded,
                  size: 48, color: AppColors.live),
              const SizedBox(height: 16),
              Text(tr('Die App konnte nicht starten'),
                  textAlign: TextAlign.center, style: t.titleLarge),
              const SizedBox(height: 8),
              Text(Redactor.friendly(error),
                  textAlign: TextAlign.center, style: t.bodyMedium),
              const SizedBox(height: 8),
              Theme(
                data: Theme.of(context)
                    .copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  title: Text(tr('Technische Details'),
                      style: TextStyle(fontSize: 13)),
                  children: [
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 220),
                      child: SingleChildScrollView(
                        child: SelectableText(
                          Redactor.redact(error.toString()),
                          style: const TextStyle(
                              fontSize: 11, color: AppColors.textFaint),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                autofocus: true,
                onPressed: () {
                  ref.invalidate(storageProvider);
                  ref.invalidate(portalsProvider);
                  ref.invalidate(activePortalProvider);
                },
                icon: const Icon(Icons.refresh_rounded),
                label: Text(tr('Erneut versuchen')),
              ),
              const SizedBox(height: 10),
              TextButton(
                onPressed: () async {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: Text(tr('App-Daten zurücksetzen?')),
                      content: Text(tr(
                          'Portale, Favoriten und Einstellungen werden gelöscht. '
                          'Du musst dein Portal danach neu eintragen.')),
                      actions: [
                        TextButton(
                            onPressed: () => Navigator.pop(ctx, false),
                            child: Text(tr('Abbrechen'))),
                        FilledButton(
                            onPressed: () => Navigator.pop(ctx, true),
                            child: Text(tr('Zurücksetzen'))),
                      ],
                    ),
                  );
                  if (ok != true) return;
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.clear();
                  ref.invalidate(storageProvider);
                  ref.invalidate(portalsProvider);
                  ref.invalidate(activePortalProvider);
                },
                child: Text(tr('App-Daten zurücksetzen')),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Schriftzug „JASON STREAM“ mit Signal-Punkt.
class Wordmark extends StatelessWidget {
  final double size;
  final bool compact;
  const Wordmark({super.key, this.size = 20, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontFamily: 'Inter',
      fontSize: size,
      fontWeight: FontWeight.w800,
      letterSpacing: -0.04 * size,
      color: AppColors.text,
      height: 1,
    );
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(
        width: size * 1.25,
        height: size * 1.25,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(size * 0.34),
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFFFF9A5C), Color(0xFFFF4D5E)],
          ),
        ),
        child: Icon(Icons.play_arrow_rounded,
            color: Colors.white, size: size * 1.0),
      ),
      if (!compact) ...[
        SizedBox(width: size * 0.45),
        Text('Jason', style: style),
        Text('Stream',
            style: style.copyWith(
                fontWeight: FontWeight.w500, color: AppColors.textDim)),
      ],
    ]);
  }
}
