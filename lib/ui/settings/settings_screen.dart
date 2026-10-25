import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/audio_passthrough.dart';
import '../../core/platform_info.dart';
import '../../core/epg_schedule.dart';
import '../../core/languages.dart';
import '../../core/security.dart';
import '../../core/subtitle_style.dart';
import '../../core/theme.dart';
import '../../core/tv_home.dart';
import '../../l10n/strings.dart';
import '../../data/storage.dart';
import '../../models/models.dart';
import '../../player/data_saver.dart';
import '../../player/engine_choice.dart';
import '../../state/playback_session.dart' show LeaveAction;
import '../../data/epg_cache/epg_cache.dart' show EpgCache;
import '../../state/providers.dart';
import '../live/parental.dart';
import '../player/next_episode.dart' show NextEpisodeTile;
import '../player/mpv_tuning.dart' show VideoOutput;
import '../player/player_debug.dart' show PlayerDebugInfo;
import '../portals/add_portal_screen.dart';
import '../../core/updater.dart';
import '../shell/app_guard.dart' show AppLock, toggleAppLock;
import '../shell/update_dialog.dart' show manualCheckForUpdate;
import '../widgets/aspect_picker.dart';
import '../widgets/common.dart';
import '../shell/accent.dart' show accentOptionKey;
import 'accent_picker.dart';
import 'epg_sources_screen.dart';
import 'backup_screen.dart';
import 'recordings_screen.dart';
import '../../data/recordings/recordings.dart' show RecTree, RecPadding;
import '../../state/downloads.dart'
    show DownloadSettings, downloadsProvider, maxConnectionsProvider;
import '../downloads/downloads_screen.dart';
import 'subtitle_style_dialog.dart';
import 'profile_modes.dart';
import 'emby_settings_screen.dart';
import '../../state/emby.dart' show embyAccountProvider;
import 'country_filter_screen.dart';
import '../../state/channel_variants.dart' show LiveBufferTile, MergeVariantsTile;
import '../../state/content_filter.dart';
import '../../state/profile_mode.dart';
import '../../state/profiles.dart' show activeProfileProvider;
import 'profiles_screen.dart' show ProfilesScreen, profileName;
import '../../state/tmdb.dart' show tmdbSettingsProvider, TmdbSource;
import 'tmdb_settings_screen.dart';
import '../widgets/focusable_tile.dart';
import '../widgets/live_preview.dart' show livePreviewEnabledProvider;

/// Einstellungen: Portal & Konto, Wiedergabe, Kindersicherung, Über.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(appLangProvider); // bei Sprachwechsel neu aufbauen
    final portal = ref.watch(activePortalProvider).value;
    final repo = ref.watch(repositoryProvider).value;
    final storage = ref.watch(storageProvider).value;
    final account = repo?.account;
    final narrow = MediaQuery.sizeOf(context).width < 600;
    final dateFmt = DateFormat(tr('d. MMMM yyyy'), L10n.lang);

    if (storage == null) return const SizedBox.shrink();
    // Kindermodus: Einstellungen gesperrt – nur „Beenden (PIN)“.
    if (ref.watch(kidsModeProvider)) return const KidsSettingsLock();

    void refresh() => ref.invalidate(storageProvider);

    return ListView(
      padding: EdgeInsets.fromLTRB(0, 0, 0, 40),
      children: [
        PageHeader(tr('Einstellungen')),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: narrow ? 16 : 28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Section(tr('PORTAL'), [
                    _Item(
                      icon: Icons.dns_rounded,
                      title: portal?.name ?? '–',
                      subtitle: switch (portal?.type) {
                        PortalType.xtream =>
                          'Xtream Codes · ${Uri.tryParse(portal!.url)?.host ?? ''}',
                        PortalType.m3u => tr('M3U-Playlist'),
                        PortalType.stalker =>
                          '${tr('MAC-Portal')} · ${Uri.tryParse(portal!.url)?.host ?? ''}',
                        PortalType.demo => tr('Demo mit erfundenen Inhalten'),
                        null => '',
                      },
                      autofocus: true,
                      trailing: portal != null && portal.type != PortalType.demo
                          ? const Icon(Icons.edit_rounded, size: 20)
                          : null,
                      onTap: portal != null && portal.type != PortalType.demo
                          ? () => Navigator.of(context).push(MaterialPageRoute(
                              builder: (_) => AddPortalScreen(edit: portal)))
                          : null,
                    ),
                    if (account != null) ...[
                      _Item(
                        icon: Icons.verified_user_rounded,
                        title: trf('Status: {0}', [
                          account.status == 'Active'
                              ? tr('Aktiv')
                              : account.status
                        ]),
                        subtitle: account.expires == null
                            ? tr('Unbegrenzt gültig')
                            : trf('Gültig bis {0}',
                                [dateFmt.format(account.expires!)]),
                        trailing: _Pill(trf('{0}/{1} Verbindungen', [
                          account.activeConnections,
                          account.maxConnections
                        ])),
                      ),
                    ],
                    _Item(
                      icon: Icons.refresh_rounded,
                      title: tr('Sender & EPG neu laden'),
                      subtitle:
                          tr('Holt Listen und Programm frisch vom Server'),
                      onTap: () async {
                        final messenger = ScaffoldMessenger.of(context);
                        messenger.showSnackBar(
                            SnackBar(content: Text(tr('Wird neu geladen …'))));
                        ref.invalidate(repositoryProvider); // neu anmelden
                        await Future.wait([
                          ref.read(liveDataProvider.notifier).reload(),
                          ref
                              .read(moviesProvider.notifier)
                              .reload(silent: true),
                          ref
                              .read(seriesProvider.notifier)
                              .reload(silent: true),
                        ]);
                        await ref.read(epgProvider.notifier).refresh();
                        messenger.showSnackBar(SnackBar(
                            content: Text(tr('Sender und EPG sind aktuell.'))));
                      },
                    ),
                    _Item(
                      icon: Icons.swap_horiz_rounded,
                      title: tr('Portal wechseln'),
                      subtitle:
                          tr('Anderes Portal wählen oder neues hinzufügen'),
                      onTap: () =>
                          ref.read(activePortalProvider.notifier).select(null),
                    ),
                  ]),
                  _EmbySection(),
                  const _TmdbSection(),
                  _LanguageSection(storage: storage, onChanged: refresh),
                  _EpgSection(storage: storage, onChanged: refresh),
                  _Section(tr('DARSTELLUNG'), [
                    AccentPicker(
                      value: storage.option(
                          accentOptionKey, AppColors.defaultAccent),
                      onChanged: (k) async {
                        await storage.setOption(accentOptionKey, k);
                        refresh();
                      },
                    ),
                  ]),
                  _Section(tr('WIEDERGABE'), [
                    if (ref.watch(exoAvailableProvider))
                      _Choice(
                        key: const ValueKey('player-engine'),
                        icon: Icons.play_circle_outline_rounded,
                        title: tr('Player-Engine'),
                        subtitle: tr('ExoPlayer ist schnell und sparsam. '
                            'Läuft ein Sender damit nicht, wechselt der Player '
                            'von selbst zu mpv.'),
                        value: preferredEngine(storage, exoAvailable: true).id,
                        options: {
                          'exo': tr('ExoPlayer (empfohlen)'),
                          'mpv': 'mpv',
                        },
                        onChanged: (v) async {
                          await storage.setOption(EngineKind.optionKey, v);
                          refresh();
                        },
                      ),
                    if (ref.watch(exoAvailableProvider) &&
                        ref.read(engineMemoryProvider.notifier).persistentCount >
                            0)
                      _Item(
                        key: const ValueKey('engine-memory-reset'),
                        icon: Icons.restart_alt_rounded,
                        title: trf('{0} Sender im Kompatibilitätsmodus (mpv)', [
                          ref.read(engineMemoryProvider.notifier).persistentCount
                        ]),
                        subtitle: tr('Zurücksetzen: wieder mit ExoPlayer versuchen'),
                        onTap: () async {
                          await ref
                              .read(engineMemoryProvider.notifier)
                              .clearPersistent();
                          refresh();
                        },
                      ),
                    _Switch(
                      icon: Icons.memory_rounded,
                      title: tr('Hardware-Dekodierung'),
                      subtitle: tr(
                          'Schont Akku und CPU. Bei Bildfehlern ausschalten.'),
                      value: storage.flag('hwdec', fallback: true),
                      onChanged: (v) async {
                        await storage.setFlag('hwdec', v);
                        refresh();
                      },
                    ),
                    if (ref.watch(isTvProvider))
                      _Choice(
                        key: const ValueKey('video-output'),
                        icon: Icons.tv_rounded,
                        title: tr('Video-Ausgabe'),
                        subtitle: tr('Bei Ruckeln „Hardware direkt“, bei '
                            'Bildfehlern „Kompatibel“ probieren'),
                        value: VideoOutput.fromId(storage.option(
                                VideoOutput.optionKey, 'standard'))
                            .id,
                        options: {
                          'standard': tr('Standard'),
                          'direct': tr('Hardware direkt'),
                          'compat': tr('Kompatibel'),
                        },
                        onChanged: (v) async {
                          await storage.setOption(VideoOutput.optionKey, v);
                          refresh();
                        },
                      ),
                    _Choice(
                      icon: Icons.speed_rounded,
                      title: tr('Puffer'),
                      subtitle: tr('Größer = stabiler bei schwachem Netz, '
                          'aber langsameres Umschalten'),
                      value: storage.option('buffer', 'normal'),
                      options: {
                        'klein': tr('Klein'),
                        'normal': tr('Normal'),
                        'gross': tr('Groß'),
                      },
                      onChanged: (v) async {
                        await storage.setOption('buffer', v);
                        refresh();
                      },
                    ),
                    if (!ref.watch(isTvProvider))
                      _Choice(
                        key: const ValueKey('data-saver'),
                        icon: Icons.data_saver_on_rounded,
                        title: tr('Datensparmodus im Mobilfunk'),
                        subtitle: ref.watch(dataSaverActiveProvider)
                            ? tr('Gerade aktiv: niedrigere Videoqualität, '
                                'kleinere Bilder, keine Live-Vorschau und '
                                'keine automatischen Updates')
                            : tr('Niedrigere Videoqualität, kleinere Bilder, '
                                'keine Live-Vorschau und keine automatischen '
                                'Updates. Automatisch: nur bei Mobilfunk.'),
                        value: ref.watch(dataSaverModeProvider).id,
                        options: {
                          'off': tr('Aus'),
                          'auto': tr('Automatisch'),
                          'always': tr('Immer'),
                        },
                        onChanged: (v) async {
                          await ref
                              .read(dataSaverModeProvider.notifier)
                              .set(DataSaverMode.fromId(v));
                          refresh();
                        },
                      ),
                    _Switch(
                      icon: Icons.surround_sound_rounded,
                      title: tr('Dolby/DTS an Receiver durchreichen'),
                      subtitle: tr('Nur mit AV-Receiver/Soundbar über HDMI; '
                          'sonst kein Ton'),
                      value: storage.flag(AudioPassthrough.flagKey),
                      onChanged: (v) async {
                        await storage.setFlag(AudioPassthrough.flagKey, v);
                        refresh();
                      },
                    ),
                    // Live-Puffer (Timeshift) – vom Player bereitgestellt.
                    const LiveBufferTile(),
                    // Serien: „Nächste Folge in 10 s“ (player/next_episode.dart).
                    const NextEpisodeTile(),
                    _Item(
                      icon: Icons.aspect_ratio_rounded,
                      title: tr('Bildformat (Standard)'),
                      subtitle: tr(
                          'Im Player jederzeit umschaltbar und pro Sender merkbar'),
                      trailing:
                          _Pill(storage.defaultAspect().label, accent: true),
                      onTap: () async {
                        final r = await showAspectPicker(
                            context, storage.defaultAspect());
                        if (r == null) return;
                        await storage.setDefaultAspect(r.$1);
                        refresh();
                      },
                    ),
                    if (portal != null &&
                        storage.channelAspectCount(portal.id) > 0)
                      _Item(
                        icon: Icons.restart_alt_rounded,
                        title: trf('{0} Sender mit eigenem Bildformat',
                            [storage.channelAspectCount(portal.id)]),
                        subtitle: tr('Zurücksetzen auf das Standard-Format'),
                        onTap: () async {
                          await storage.clearChannelAspects(portal.id);
                          refresh();
                        },
                      ),
                    if (!ref.watch(isTvProvider))
                      _Choice(
                        key: const ValueKey('leave-player'),
                        icon: Icons.branding_watermark_outlined,
                        title: tr('Zurück im Player'),
                        subtitle: tr('Mini-Player: Stream läuft klein über der '
                            'App weiter. Bild-in-Bild: kleines Systemfenster. '
                            'Stopp: Wiedergabe beenden.'),
                        value: LeaveAction.fromId(storage.option(
                                LeaveAction.optionKey, 'mini'))
                            .id,
                        options: {
                          'mini': tr('Mini-Player'),
                          'pip': tr('Bild-in-Bild'),
                          'stop': tr('Stopp'),
                        },
                        onChanged: (v) async {
                          await storage.setOption(LeaveAction.optionKey, v);
                          refresh();
                        },
                      ),
                    if (!ref.watch(isTvProvider))
                      _Switch(
                        icon: Icons.picture_in_picture_alt_rounded,
                        title: tr('Bild-in-Bild beim Wechsel zum Startbildschirm'),
                        subtitle: tr('Video läuft im kleinen Fenster weiter, '
                            'wenn du zum Startbildschirm wechselst'),
                        value: storage.flag('autopip', fallback: true),
                        onChanged: (v) async {
                          await storage.setFlag('autopip', v);
                          await PlatformInfo.setAutoPip(v);
                          refresh();
                        },
                      ),
                    _Item(
                      icon: Icons.format_size_rounded,
                      title: tr('Oberflächengröße'),
                      subtitle: tr('Antippen zum Wechseln: Sehr klein bis Sehr groß'),
                      trailing: _Pill(
                          switch (storage.option('uiscale', 'auto')) {
                            'sehrklein' => tr('Sehr klein'),
                            'klein' => tr('Klein'),
                            'normal' => tr('Normal'),
                            'gross' => tr('Groß'),
                            'sehrgross' => tr('Sehr groß'),
                            _ => tr('Automatisch'),
                          },
                          accent: true),
                      onTap: () async {
                        const order = [
                          'auto', 'sehrklein', 'klein', 'normal', 'gross', 'sehrgross'
                        ];
                        final cur = storage.option('uiscale', 'auto');
                        final next = order[(order.indexOf(cur) + 1) % order.length];
                        await storage.setOption('uiscale', next);
                        ref.invalidate(storageProvider);
                        refresh();
                      },
                    ),
                    _Item(
                      icon: Icons.home_rounded,
                      title: tr('Beim Öffnen zeigen'),
                      subtitle: tr('Startseite mit Übersicht oder direkt Live TV'),
                      trailing: _Pill(
                          storage.option('starttab', 'home') == 'live'
                              ? tr('Live TV')
                              : tr('Start'),
                          accent: true),
                      onTap: () async {
                        final next = storage.option('starttab', 'home') == 'live'
                            ? 'home'
                            : 'live';
                        await storage.setOption('starttab', next);
                        refresh();
                      },
                    ),
                    _Switch(
                      icon: Icons.play_circle_outline_rounded,
                      title: tr('Mit letztem Sender starten'),
                      value: storage.flag('startlast'),
                      onChanged: (v) async {
                        await storage.setFlag('startlast', v);
                        refresh();
                      },
                    ),
                    _Switch(
                      icon: Icons.smart_display_rounded,
                      title: tr('Live-Vorschau beim Stöbern'),
                      subtitle: tr('Spielt den markierten Sender stumm im '
                          'kleinen Fenster (nur TV/Tablet)'),
                      value: storage.flag('preview', fallback: true),
                      onChanged: (v) async {
                        await storage.setFlag('preview', v);
                        ref.invalidate(livePreviewEnabledProvider);
                        refresh();
                      },
                    ),
                    if (ref.watch(isTvProvider))
                      _Switch(
                        icon: Icons.slow_motion_video_rounded,
                        title: tr('Bildwiederholrate anpassen (AFR)'),
                        subtitle: tr('Fernseher schaltet auf die Bildrate des '
                            'Senders um (z. B. 50 Hz) – flüssigere Bewegungen. '
                            'Beim Umschalten kurz schwarz.'),
                        value: storage.flag('afr'),
                        onChanged: (v) async {
                          await storage.setFlag('afr', v);
                          refresh();
                        },
                      ),
                  ]),
                  _Section(tr('SENDER'), [
                    // Varianten (HD/FHD/4K) zusammenfassen – vom Player.
                    const MergeVariantsTile(),
                    if (portal != null)
                      _Item(
                        icon: Icons.public_rounded,
                        title: tr('Länder anzeigen'),
                        subtitle: tr('Nur Sender, Filme und Serien bestimmter '
                            'Länder zeigen (pro Portal)'),
                        trailing: _Pill(
                            countryFilterSummary(
                                ref.watch(countryFilterProvider)),
                            accent: true),
                        onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                                builder: (_) => const CountryFilterScreen())),
                      ),
                    if (ref.watch(isTvProvider) && PlatformInfo.isAndroid)
                      _Switch(
                        icon: Icons.tv_rounded,
                        title: tr('Favoriten auf dem TV-Startbildschirm'),
                        subtitle: tr('Eigene Zeile mit den Lieblingssendern '
                            'und der laufenden Sendung auf dem Android-TV-'
                            'Startbildschirm'),
                        value: storage.flag(TvHome.flagKey, fallback: true),
                        onChanged: (v) async {
                          await storage.setFlag(TvHome.flagKey, v);
                          refresh();
                          if (v) {
                            await TvHome.sync(ref);
                          } else {
                            await TvHome.clear();
                          }
                        },
                      ),
                    _Switch(
                      icon: Icons.public_off_rounded,
                      title: tr('Am Standort gesperrte Sender ausblenden'),
                      subtitle: tr('Sender, die zuletzt mit „nicht verfügbar“ '
                          'antworteten. Nach 24 Std. wird erneut geprüft.'),
                      value: storage.flag('hideunavail'),
                      onChanged: (v) async {
                        await storage.setFlag('hideunavail', v);
                        ref.invalidate(channelFlagsProvider);
                        refresh();
                      },
                    ),
                    if (portal != null &&
                        storage.unavailable(portal.id).isNotEmpty)
                      _Item(
                        icon: Icons.restart_alt_rounded,
                        title: trf('{0} Sender als „nicht verfügbar“ markiert',
                            [storage.unavailable(portal.id).length]),
                        subtitle:
                            tr('Markierungen zurücksetzen und neu prüfen'),
                        onTap: () async {
                          await storage.clearUnavailable(portal.id);
                          ref.invalidate(channelFlagsProvider);
                          refresh();
                        },
                      ),
                  ]),
                  if (!kIsWeb)
                    _Section(tr('AUFNAHMEN & DOWNLOADS'), [
                      _Item(
                        icon: Icons.video_library_rounded,
                        title: tr('Aufnahmen'),
                        subtitle:
                            tr('Geplante, laufende und fertige Aufnahmen'),
                        onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                                builder: (_) => const RecordingsScreen())),
                      ),
                      _Item(
                        key: const ValueKey('settings-downloads'),
                        icon: Icons.download_for_offline_rounded,
                        title: tr('Downloads'),
                        subtitle: tr('Filme und Folgen zum Offline-Schauen'),
                        onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                                builder: (_) => const DownloadsScreen())),
                      ),
                      if (RecTree.available)
                        _RecLocationItem(storage: storage, onChanged: refresh),
                      if (!ref.watch(isTvProvider))
                        _Switch(
                          icon: Icons.signal_cellular_alt_rounded,
                          title: tr('Downloads auch über Mobilfunk'),
                          subtitle: tr('Aus: nur über WLAN. Der Datensparmodus '
                              'hält Downloads im Mobilfunk immer an.'),
                          value: storage.flag(DownloadSettings.mobileKey),
                          onChanged: (v) async {
                            await storage.setFlag(DownloadSettings.mobileKey, v);
                            refresh();
                            await ref
                                .read(downloadsProvider.notifier)
                                .settingsChanged();
                          },
                        ),
                      _Choice(
                        icon: Icons.download_rounded,
                        title: tr('Gleichzeitige Downloads'),
                        value: storage.option(DownloadSettings.parallelKey, '1'),
                        options: const {'1': '1', '2': '2'},
                        onChanged: (v) async {
                          await storage.setOption(DownloadSettings.parallelKey, v);
                          refresh();
                          await ref
                              .read(downloadsProvider.notifier)
                              .settingsChanged();
                        },
                      ),
                      _Choice(
                        icon: Icons.first_page_rounded,
                        title: tr('Aufnahme: Vorlauf'),
                        subtitle: tr('So viel früher beginnen geplante Aufnahmen'),
                        value: storage.option(RecPadding.preKey, RecPadding.preDefault),
                        options: {
                          for (final m in RecPadding.preOptions)
                            '$m': trf('{0} Min.', [m]),
                        },
                        onChanged: (v) async {
                          await storage.setOption(RecPadding.preKey, v);
                          refresh();
                        },
                      ),
                      _Choice(
                        icon: Icons.last_page_rounded,
                        title: tr('Aufnahme: Nachlauf'),
                        subtitle: tr('So viel länger laufen Aufnahmen nach '
                            'dem geplanten Ende'),
                        value: storage.option(RecPadding.postKey, RecPadding.postDefault),
                        options: {
                          for (final m in RecPadding.postOptions)
                            '$m': trf('{0} Min.', [m]),
                        },
                        onChanged: (v) async {
                          await storage.setOption(RecPadding.postKey, v);
                          refresh();
                        },
                      ),
                      _Switch(
                        icon: Icons.live_tv_rounded,
                        title: tr('Eine Verbindung für Live frei halten'),
                        subtitle: () {
                          final max = ref.watch(maxConnectionsProvider);
                          final base = tr('Aufnahmen und Downloads lassen eine '
                              'Anbieter-Verbindung für Live-TV übrig – nur, '
                              'wenn der Anbieter mehrere erlaubt.');
                          return max == null
                              ? base
                              : '$base ${trf('Dein Anbieter: {0}', [
                                  trf('{0} Verbindungen', [max])
                                ])}';
                        }(),
                        value: storage.flag(DownloadSettings.keepFreeKey),
                        onChanged: (v) async {
                          await storage.setFlag(DownloadSettings.keepFreeKey, v);
                          refresh();
                          await ref
                              .read(downloadsProvider.notifier)
                              .settingsChanged();
                        },
                      ),
                    ]),
                  _Section(tr('PROFILE'), [
                    _Item(
                      key: const ValueKey('settings-profiles'),
                      icon: Icons.people_alt_rounded,
                      title: trf('Profil: {0}', [
                        profileName(ref.watch(activeProfileProvider))
                      ]),
                      subtitle: tr('Profile anlegen, wechseln, Kinderprofil, '
                          'PIN je Profil'),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) => const ProfilesScreen())),
                    ),
                  ]),
                  _Section(tr('KINDERSICHERUNG'), [
                    _Item(
                      icon: Icons.child_care_rounded,
                      title: tr('Kindermodus'),
                      subtitle: tr('Nur freigegebene Gruppen zeigen; '
                          'Beenden nur mit PIN'),
                      onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) => const KidsModeScreen())),
                    ),
                    _Switch(
                      icon: Icons.person_outline_rounded,
                      title: tr('Gastmodus'),
                      subtitle: tr('Nichts in Verlauf und Weiterschauen '
                          'speichern; Favoriten ausblenden'),
                      value: ref.watch(guestModeProvider),
                      onChanged: (_) => toggleGuestMode(context, ref),
                    ),
                    if (kAdultAutoLockFeature)
                      _AdultLockItems(storage: storage, onChanged: refresh),
                    _Item(
                      icon: Icons.lock_rounded,
                      title: !storage.hasPin()
                          ? tr('PIN anlegen')
                          : tr('PIN ändern'),
                      subtitle: tr(
                          'Gesperrte Sender fragen vor dem Abspielen nach der PIN'),
                      onTap: () async {
                        await showParentalSettings(context, ref);
                        refresh();
                      },
                    ),
                    if (portal != null && storage.hidden(portal.id).isNotEmpty)
                      _Item(
                        icon: Icons.visibility_rounded,
                        title: trf('{0} versteckte Sender wieder anzeigen',
                            [storage.hidden(portal.id).length]),
                        onTap: () async {
                          await storage.clearHidden(portal.id);
                          ref.invalidate(channelFlagsProvider);
                          refresh();
                        },
                      ),
                  ]),
                  _Section(tr('SICHERHEIT'), [
                    FutureBuilder<bool>(
                      future: AppLock.available(),
                      builder: (context, snap) {
                        if (snap.data != true) return const SizedBox.shrink();
                        return _Switch(
                          icon: Icons.fingerprint_rounded,
                          title: tr('App-Sperre'),
                          subtitle: tr('Beim Öffnen und nach 1 Min. im Hintergrund '
                              'mit Fingerabdruck, Gesicht oder Geräte-PIN entsperren'),
                          value: storage.flag('applock'),
                          onChanged: (v) async {
                            final ok = await toggleAppLock(ref, v);
                            if (!ok && context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                                  content: Text(tr('Nicht bestätigt – App-Sperre '
                                      'unverändert'))));
                            }
                            refresh();
                          },
                        );
                      },
                    ),
                    _Item(
                      icon: Icons.enhanced_encryption_rounded,
                      title: tr('Zugangsdaten verschlüsselt'),
                      subtitle:
                          tr('Im Android-Schlüsselspeicher, nicht in Backups, '
                              'nie in Fehlermeldungen'),
                      trailing: _Pill(tr('AKTIV'), accent: true),
                    ),
                    if (portal != null && portal.type != PortalType.demo)
                      _Item(
                        icon: UrlPolicy.isUnencrypted(portal.url)
                            ? Icons.lock_open_rounded
                            : Icons.lock_rounded,
                        title: UrlPolicy.isUnencrypted(portal.url)
                            ? tr('Verbindung unverschlüsselt (http)')
                            : tr('Verbindung verschlüsselt (https)'),
                        subtitle: UrlPolicy.isUnencrypted(portal.url)
                            ? tr(
                                'Dein Anbieter nutzt http. Frag nach einer https-Adresse.')
                            : tr(
                                'Zugangsdaten werden verschlüsselt übertragen'),
                      ),
                    if (!kIsWeb)
                      _Item(
                        icon: Icons.move_to_inbox_rounded,
                        title: tr('Sicherung & Übertragung'),
                        subtitle: tr('Alles in eine passwortgeschützte Datei '
                            'sichern oder auf ein neues Gerät übernehmen'),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                                builder: (_) => const BackupScreen())),
                      ),
                    _Item(
                      icon: Icons.delete_forever_rounded,
                      title: tr('Alle Zugangsdaten löschen'),
                      subtitle: tr(
                          'Entfernt alle Portale und die PIN von diesem Gerät'),
                      onTap: () async {
                        final ok = await showDialog<bool>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: Text(tr('Alle Zugangsdaten löschen?')),
                            content: Text(tr(
                                'Alle Portale und die PIN werden von diesem Gerät '
                                'entfernt. Das kann nicht rückgängig gemacht werden.')),
                            actions: [
                              TextButton(
                                  autofocus: true, // D-Pad: sicher starten
                                  onPressed: () => Navigator.pop(ctx, false),
                                  child: Text(tr('Abbrechen'))),
                              FilledButton(
                                  style: FilledButton.styleFrom(
                                      backgroundColor: AppColors.live),
                                  onPressed: () => Navigator.pop(ctx, true),
                                  child: Text(tr('Löschen'))),
                            ],
                          ),
                        );
                        if (ok != true) return;
                        await storage.wipeCredentials();
                        ref.invalidate(portalsProvider);
                        ref.invalidate(activePortalProvider);
                      },
                    ),
                  ]),
                  _Section(tr('ÜBER'), [
                    _VersionItem(storage: storage),
                    if (Updater.enabled)
                      _Item(
                        icon: Icons.system_update_rounded,
                        title: tr('Nach Updates suchen'),
                        subtitle: tr('Neue Versionen direkt in der App installieren'),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: () => manualCheckForUpdate(context, ref),
                      ),
                    _Item(
                      key: const ValueKey('settings-licenses'),
                      icon: Icons.gavel_rounded,
                      title: tr('Open-Source-Lizenzen'),
                      subtitle: tr('Media3/ExoPlayer, FFmpeg, mpv und weitere'),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => showLicensePage(
                          context: context,
                          applicationName: 'Jason Stream Player'),
                    ),
                  ]),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Erwachseneninhalte: automatische Sperre an/aus (Ausschalten mit PIN)
/// und Entsperren für diese Sitzung.
class _AdultLockItems extends ConsumerWidget {
  final Storage storage;
  final VoidCallback onChanged;
  const _AdultLockItems({required this.storage, required this.onChanged});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(adultLockEnabledProvider);
    final unlocked = ref.watch(adultUnlockedProvider);
    final count = ref.watch(adultGroupCountProvider);
    return Column(children: [
      _Switch(
        icon: Icons.no_adult_content_rounded,
        title: tr('Erwachseneninhalte automatisch sperren'),
        subtitle: count > 0
            ? trf('{0} Gruppen erkannt (XXX, Adult, 18+ …) – ausgeblendet bis zur PIN',
                [count])
            : tr('Gruppen wie XXX, Adult oder 18+ ausblenden, bis sie mit der PIN entsperrt werden'),
        value: enabled,
        onChanged: (v) async {
          // Ausschalten nur mit PIN (falls eine gesetzt ist).
          if (!v && !await askPin(context, ref)) return;
          await ref.read(adultLockEnabledProvider.notifier).set(v);
          if (v) ref.read(adultUnlockedProvider.notifier).set(false);
        },
      ),
      if (enabled && count > 0)
        _Item(
          icon: unlocked ? Icons.lock_outline_rounded : Icons.lock_open_rounded,
          title: unlocked
              ? tr('Erwachseneninhalte wieder sperren')
              : tr('Erwachseneninhalte anzeigen'),
          subtitle: unlocked
              ? tr('Bis zum nächsten App-Start entsperrt')
              : storage.hasPin()
                  ? tr('Mit PIN entsperren (bis zum nächsten App-Start)')
                  : tr('Zuerst eine PIN anlegen'),
          onTap: () async {
            if (unlocked) {
              ref.read(adultUnlockedProvider.notifier).set(false);
              return;
            }
            if (await ensurePin(context, ref)) {
              ref.read(adultUnlockedProvider.notifier).set(true);
              onChanged();
            }
          },
        ),
    ]);
  }
}

/// Emby-Server (portalunabhängig): Zustand und Einstieg.
class _EmbySection extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final acc = ref.watch(embyAccountProvider);
    final host = acc == null
        ? ''
        : (acc.serverName ?? Uri.tryParse(acc.server)?.host ?? acc.server);
    return _Section(tr('EMBY'), [
      _Item(
        key: const ValueKey('settings-emby'),
        icon: Icons.home_work_rounded,
        title: tr('Emby-Server'),
        subtitle: acc == null
            ? tr('Eigenen Emby- oder Jellyfin-Server einbinden – unabhängig vom Portal')
            : acc.signedIn
                ? trf('Verbunden mit {0} als {1}', [host, acc.userName])
                : trf('{0} · abgemeldet – zum Anmelden antippen', [host]),
        trailing: acc?.signedIn ?? false
            ? _Pill(tr('AKTIV'), accent: true)
            : null,
        onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const EmbySettingsScreen())),
      ),
    ]);
  }
}

/// Film-Infos (TMDB): Zustand und Einstieg.
class _TmdbSection extends ConsumerWidget {
  const _TmdbSection();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(tmdbSettingsProvider);
    return _Section(tr('FILM-INFOS'), [
      _Item(
        key: const ValueKey('settings-tmdb'),
        icon: Icons.movie_filter_rounded,
        title: tr('Film-Infos (TMDB)'),
        subtitle: !s.hasKey
            ? tr('Eigenen TMDB-Schlüssel eintragen – ohne Schlüssel aus')
            : switch (s.source) {
                TmdbSource.provider => tr('Nur Anbieter'),
                TmdbSource.mix => tr('Anbieter + TMDB'),
                TmdbSource.tmdb => tr('TMDB bevorzugt'),
              },
        trailing: s.active ? _Pill(tr('AKTIV'), accent: true) : null,
        onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const TmdbSettingsScreen())),
      ),
    ]);
  }
}

class _Section extends StatelessWidget {
  final String title;
  final List<Widget> children;
  const _Section(this.title, this.children);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 26),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text(title, style: Theme.of(context).textTheme.labelSmall),
          ),
          Container(
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(16),
            ),
            padding: const EdgeInsets.all(6),
            child: Column(children: children),
          ),
        ]),
      );
}

class _Item extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool autofocus;
  const _Item({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.autofocus = false,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return FocusableTile(
      autofocus: autofocus,
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
          if (onTap != null && trailing == null)
            const Icon(Icons.chevron_right_rounded, color: AppColors.textFaint),
        ]),
      ),
    );
  }
}

/// Versionszeile; 5× OK/Tippen (innerhalb von 3 s) schaltet die versteckte
/// Diagnose-Anzeige im Player um (hwdec, fps, verworfene Bilder, Puffer).
class _VersionItem extends StatefulWidget {
  final Storage storage;
  const _VersionItem({required this.storage});

  @override
  State<_VersionItem> createState() => _VersionItemState();
}

class _VersionItemState extends State<_VersionItem> {
  static const taps = 5;
  final _times = <DateTime>[];
  late final Future<String> _version = Updater.currentVersion();

  Future<void> _tap() async {
    final now = DateTime.now();
    _times
      ..add(now)
      ..removeWhere((t) => now.difference(t) > const Duration(seconds: 3));
    if (_times.length < taps) return;
    _times.clear();
    final st = widget.storage;
    final on = !st.flag(PlayerDebugInfo.flagKey);
    await st.setFlag(PlayerDebugInfo.flagKey, on);
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
        content: Text(on
            ? tr('Diagnose-Anzeige im Player an')
            : tr('Diagnose-Anzeige im Player aus'))));
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<String>(
        future: _version,
        builder: (context, snap) => _Item(
          key: const ValueKey('settings-version'),
          icon: Icons.info_outline_rounded,
          title: 'Jason Stream Player ${snap.data ?? ''}'.trim(),
          subtitle: tr('Für Android 8+ und Android TV. '
              'Reiner Player – liefert keine Inhalte.'),
          onTap: _tap,
          trailing: const SizedBox.shrink(),
        ),
      );
}

class _Switch extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  const _Switch({
    required this.icon,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) => _Item(
        icon: icon,
        title: title,
        subtitle: subtitle,
        onTap: () => onChanged(!value),
        // Nur Anzeige: Eintrag schaltet. Nicht selbst fokussierbar – sonst
        // landet das D-Pad auf dem Schalter, wo OK nichts tut.
        trailing: IgnorePointer(
          child: ExcludeFocus(
            child: Switch(
              value: value,
              onChanged: (_) {},
              activeThumbColor: AppColors.accent,
            ),
          ),
        ),
      );
}

class _Choice extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final String value;
  final Map<String, String> options;
  final ValueChanged<String> onChanged;
  const _Choice({
    super.key,
    required this.icon,
    required this.title,
    required this.value,
    required this.options,
    required this.onChanged,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final keys = options.keys.toList();
    return _Item(
      icon: icon,
      title: title,
      subtitle: subtitle,
      // OK/Tippen schaltet zur nächsten Option weiter (D-Pad-freundlich).
      onTap: () => onChanged(keys[(keys.indexOf(value) + 1) % keys.length]),
      // Lange Bezeichnungen umbrechen statt die Zeile zu sprengen.
      trailing: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 120),
        child: _Pill(options[value] ?? value, accent: true),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final String text;
  final bool accent;
  const _Pill(this.text, {this.accent = false});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: accent ? AppColors.accentSoft : AppColors.surface3,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(text,
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: accent ? AppColors.accent : AppColors.textDim)),
      );
}

/// TV-Guide (EPG): automatische Aktualisierung, Uhrzeit, Stand, „Jetzt“.
class _EpgSection extends ConsumerWidget {
  final Storage storage;
  final VoidCallback onChanged;
  const _EpgSection({required this.storage, required this.onChanged});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(epgStatusProvider);
    final epg = ref.watch(epgProvider).value ?? const {};
    final portal = ref.watch(activePortalProvider).value;
    final schedule = storage.epgSchedule();
    final now = DateTime.now();
    final next = schedule.next(last: status.lastUpdate, now: now);
    // Ab 2.0 hält der Speicher nur ein Fenster – Zahlen aus der Datenbank.
    final dbInfo = portal == null || EpgCache.dbBacked[portal.id] != true
        ? null
        : EpgCache.info[portal.id];
    final programmes =
        dbInfo?.count ?? epg.values.fold<int>(0, (a, l) => a + l.length);
    final epgChannels = dbInfo?.channels ?? epg.length;

    String when(DateTime t) {
      final d = DateTime(t.year, t.month, t.day);
      final today = DateTime(now.year, now.month, now.day);
      final day = d == today
          ? tr('heute')
          : d == today.subtract(const Duration(days: 1))
              ? tr('gestern')
              : d == today.add(const Duration(days: 1))
                  ? tr('morgen')
                  : DateFormat(tr('EEE d.M.'), L10n.lang).format(t);
      return trf('{0}, {1} Uhr', [day, DateFormat.Hm(L10n.lang).format(t)]);
    }

    final String stand;
    if (status.updating) {
      stand = status.progressText ?? tr('Wird gerade aktualisiert …');
    } else if (status.lastError != null) {
      stand = trf('Letzter Versuch fehlgeschlagen: {0}', [status.lastError]);
    } else if (status.lastUpdate != null) {
      stand = trf('Zuletzt {0} · {1} Sender, {2} Sendungen',
          [when(status.lastUpdate!), epgChannels, programmes]);
    } else {
      stand = tr('Noch nicht geladen');
    }

    return _Section(tr('TV-GUIDE (EPG)'), [
      _Item(
        icon: Icons.update_rounded,
        title: tr('Automatisch aktualisieren'),
        subtitle: next == null
            ? tr('Nur wenn du „Jetzt aktualisieren“ wählst')
            : trf('Nächste Aktualisierung: {0}',
                [when(next.isBefore(now) ? now : next)]),
        trailing: _Pill(schedule.interval.label, accent: true),
        onTap: () async {
          final picked = await showDialog<EpgInterval>(
            context: context,
            builder: (ctx) => SimpleDialog(
              title: Text(tr('EPG aktualisieren')),
              children: [
                for (final i in EpgInterval.values)
                  _AutofocusOption(
                    autofocus: i == schedule.interval,
                    padding: _AutofocusOption.optionPadding,
                    onPressed: () => Navigator.pop(ctx, i),
                    child: Row(children: [
                      Icon(
                          i == schedule.interval
                              ? Icons.radio_button_checked
                              : Icons.radio_button_unchecked,
                          color: AppColors.accent,
                          size: 20),
                      const SizedBox(width: 12),
                      Text(i.label),
                    ]),
                  ),
              ],
            ),
          );
          if (picked == null) return;
          await storage.setEpgInterval(picked);
          onChanged();
          ref.read(epgProvider.notifier).checkDue();
        },
      ),
      if (schedule.interval == EpgInterval.daily)
        _Item(
          icon: Icons.schedule_rounded,
          title: tr('Uhrzeit'),
          subtitle: tr('Am besten nachts, wenn niemand fernsieht'),
          trailing: _Pill(
              trf('{0}:00 Uhr', [schedule.hour.toString().padLeft(2, '0')]),
              accent: true),
          onTap: () async {
            final picked = await showDialog<int>(
              context: context,
              builder: (ctx) => SimpleDialog(
                title: Text(tr('Täglich aktualisieren um')),
                children: [
                  SizedBox(
                    width: 300,
                    height: 360,
                    // Alle Einträge aufbauen, damit der Fokus auf der
                    // gewählten Stunde starten kann (D-Pad).
                    child: SingleChildScrollView(
                        child: Column(children: [
                      for (var h = 0; h < 24; h++)
                        _AutofocusOption(
                          autofocus: h == schedule.hour,
                          padding: _AutofocusOption.optionPadding,
                          onPressed: () => Navigator.pop(ctx, h),
                          child: Text(
                            trf('{0}:00 Uhr', [h.toString().padLeft(2, '0')]),
                            style: TextStyle(
                              fontWeight: h == schedule.hour
                                  ? FontWeight.w800
                                  : FontWeight.w500,
                              color: h == schedule.hour
                                  ? AppColors.accent
                                  : AppColors.text,
                            ),
                          ),
                        ),
                    ])),
                  ),
                ],
              ),
            );
            if (picked == null) return;
            await storage.setEpgHour(picked);
            onChanged();
          },
        ),
      if (portal != null && portal.type != PortalType.demo)
        _Item(
          icon: Icons.source_outlined,
          title: tr('EPG-Quellen'),
          subtitle: epgSourcesSummary(portal),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => EpgSourcesScreen(portal: portal))),
        ),
      _Item(
        icon: Icons.download_rounded,
        title: tr('Jetzt aktualisieren'),
        subtitle: stand,
        trailing: status.updating
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2.5))
            : null,
        onTap: status.updating
            ? null
            : () => ref.read(epgProvider.notifier).refresh(),
      ),
    ]);
  }
}

/// Bevorzugte Ton- und Untertitelsprache.
class _LanguageSection extends ConsumerWidget {
  final Storage storage;
  final VoidCallback onChanged;
  const _LanguageSection({required this.storage, required this.onChanged});

  String _label(String code) => switch (code) {
        'auto' => tr('Automatisch'),
        'off' => tr('Aus'),
        _ => TrackLanguage.byCode(code)?.label ?? code,
      };

  Future<void> _pick(BuildContext context, String key, String current,
      {required bool subtitles}) async {
    final codes = [
      if (subtitles) 'off',
      'auto',
      for (final l in TrackLanguage.all) l.code,
    ];
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(subtitles ? tr('Untertitel') : tr('Tonsprache')),
        children: [
          SizedBox(
            width: 320,
            height: 400,
            child: SingleChildScrollView(
                child: Column(children: [
              for (final c in codes)
                _AutofocusOption(
                  autofocus: c == current,
                  padding: _AutofocusOption.optionPadding,
                  onPressed: () => Navigator.pop(ctx, c),
                  child: Row(children: [
                    Icon(
                        c == current
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                        color: AppColors.accent,
                        size: 20),
                    const SizedBox(width: 12),
                    Expanded(child: Text(_label(c))),
                  ]),
                ),
            ])),
          ),
        ],
      ),
    );
    if (picked == null) return;
    await storage.setOption(key, picked);
    onChanged();
  }

  Future<void> _pickAppLang(BuildContext context, WidgetRef ref) async {
    final current = ref.read(appLangProvider.notifier).choice;
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(tr('App-Sprache')),
        children: [
          for (final c in const ['system', ...L10n.supported])
            // D-Pad: Fokus startet auf der aktuellen Auswahl.
            _AutofocusOption(
              autofocus: c == current,
              onPressed: () => Navigator.pop(ctx, c),
              child: Row(children: [
                Icon(
                    c == current
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    color: AppColors.accent,
                    size: 20),
                const SizedBox(width: 12),
                Expanded(
                    child: Text(c == 'system' ? tr('System') : L10n.names[c]!)),
              ]),
            ),
        ],
      ),
    );
    if (picked == null || picked == current) return;
    await ref.read(appLangProvider.notifier).set(picked);
    onChanged();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(appLangProvider);
    final choice = ref.read(appLangProvider.notifier).choice;
    final audio = storage.option('alang', 'auto');
    final subs = storage.option('slang', 'auto');
    return _Section(tr('SPRACHE'), [
      _Item(
        icon: Icons.translate_rounded,
        title: tr('App-Sprache'),
        subtitle: tr('Sprache der Benutzeroberfläche'),
        trailing: _Pill(
            choice == 'system' ? tr('System') : (L10n.names[choice] ?? choice),
            accent: true),
        onTap: () => _pickAppLang(context, ref),
      ),
      _Item(
        icon: Icons.record_voice_over_rounded,
        title: tr('Bevorzugte Tonsprache'),
        subtitle: tr('Wird automatisch gewählt, wenn der Sender sie anbietet'),
        trailing: _Pill(_label(audio), accent: true),
        onTap: () => _pick(context, 'alang', audio, subtitles: false),
      ),
      _Item(
        icon: Icons.subtitles_rounded,
        title: tr('Untertitel'),
        subtitle: tr('Aus, automatisch oder bevorzugte Sprache'),
        trailing: _Pill(_label(subs), accent: true),
        onTap: () => _pick(context, 'slang', subs, subtitles: true),
      ),
      _Item(
        icon: Icons.format_size_rounded,
        title: tr('Untertitel-Aussehen'),
        subtitle: tr('Größe, Farbe, Hintergrund und Rand'),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: () async {
          final r = await showSubtitleStyleDialog(
              context, SubtitleStyle.fromOptions(storage.option));
          if (r == null) return;
          for (final e in r.options.entries) {
            await storage.setOption(e.key, e.value);
          }
          onChanged();
        },
      ),
    ]);
  }
}

/// Speicherort für Hintergrund-Aufnahmen: App-Ordner oder ein per Android-
/// Ordnerauswahl (SAF) gewählter Ordner auf USB-Stick, SD-Karte oder
/// Netzlaufwerk. Netzlaufwerke brauchen eine Anbieter-App (z. B. CX File
/// Explorer, Solid Explorer, eingebaute SMB-Anbieter auf Android TV).
/// In-App-Aufnahmen (MAC-Portal/HLS) landen immer im App-Ordner.
class _RecLocationItem extends StatelessWidget {
  final Storage storage;
  final VoidCallback onChanged;
  const _RecLocationItem({required this.storage, required this.onChanged});

  Future<void> _choose(BuildContext context) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final choice = await showModalBottomSheet<String>(
      useRootNavigator: true,
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.phone_android_rounded),
            title: Text(tr('App-Ordner')),
            subtitle: Text(tr('Android/data/…/Aufnahmen auf diesem Gerät')),
            autofocus: true,
            onTap: () => Navigator.pop(ctx, 'app'),
          ),
          ListTile(
            leading: const Icon(Icons.usb_rounded),
            title: Text(tr('USB-Stick oder Netzlaufwerk wählen …')),
            subtitle: Text(tr('Netzlaufwerke nur mit einer Datei-App, die '
                'sie als Ordner anbietet (z. B. CX File Explorer)')),
            onTap: () => Navigator.pop(ctx, 'pick'),
          ),
          const SizedBox(height: 8),
        ]),
      ),
    );
    if (choice == null) return;
    if (choice == 'app') {
      await storage.setOption(RecTree.optionKey, '');
      onChanged();
      return;
    }
    try {
      final r = await RecTree.pick();
      if (r == null) return;
      await storage.setOption(RecTree.optionKey, r.uri);
      onChanged();
    } catch (_) {
      messenger?.showSnackBar(
          SnackBar(content: Text(tr('Kein Ordnerauswahl-Dialog verfügbar'))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final tree = storage.option(RecTree.optionKey, '');
    if (tree.isEmpty) {
      return _Item(
        icon: Icons.folder_rounded,
        title: tr('Speicherort'),
        subtitle: tr('Für Aufnahmen im Hintergrund und Downloads'),
        trailing: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 120),
            child: _Pill(tr('App-Ordner (intern)'), accent: true)),
        onTap: () => _choose(context),
      );
    }
    return FutureBuilder(
      future: RecTree.info(tree),
      builder: (context, snap) {
        final i = snap.data;
        final String sub;
        if (i == null) {
          sub = '…';
        } else if (!i.granted) {
          sub = tr('Zugriff verloren – bitte neu wählen (sonst App-Ordner)');
        } else {
          final free = RecTree.formatFree(i.free);
          sub = free.isEmpty ? '' : trf('{0} frei', [free]);
        }
        return _Item(
          icon: Icons.usb_rounded,
          title: tr('Speicherort'),
          subtitle: sub,
          trailing: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 120),
            child: _Pill(
                (i?.name.isNotEmpty ?? false) ? i!.name : tr('Externer Ordner'),
                accent: true),
          ),
          onTap: () => _choose(context),
        );
      },
    );
  }
}

/// Fokussierbarer Eintrag für Auswahldialoge (OK/Enter wählt aus).
class _AutofocusOption extends StatelessWidget {
  final bool autofocus;
  final VoidCallback onPressed;
  final Widget child;
  final EdgeInsets padding;
  const _AutofocusOption(
      {required this.autofocus,
      required this.onPressed,
      required this.child,
      this.padding = const EdgeInsets.symmetric(horizontal: 24, vertical: 12)});

  /// Wie [SimpleDialogOption] (gleicher Abstand).
  static const optionPadding = EdgeInsets.symmetric(horizontal: 24, vertical: 8);

  @override
  Widget build(BuildContext context) => InkWell(
        autofocus: autofocus,
        onTap: onPressed,
        // D-Pad: fokussierten Eintrag in langen Listen sichtbar halten.
        onFocusChange: (f) {
          if (f) Scrollable.ensureVisible(context, alignment: 0.5);
        },
        child: Padding(padding: padding, child: child),
      );
}
