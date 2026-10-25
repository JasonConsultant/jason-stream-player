import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/storage.dart';
import '../../l10n/strings.dart';
import '../../state/profile_mode.dart';
import '../../state/profiles.dart';
import '../../state/providers.dart';
import '../live/parental.dart';
import '../widgets/dpad_text_field.dart';
import '../widgets/focusable_tile.dart';

/// Profilfarben (Index = [UserProfile.color]).
const profileColors = <Color>[
  Color(0xFFFF7A45),
  Color(0xFF5AA2FF),
  Color(0xFF3DD68C),
  Color(0xFFB48CFF),
  Color(0xFFFF6470),
  Color(0xFF22C7D6),
  Color(0xFFF2B33D),
  Color(0xFFFF7FC8),
];

Color profileColor(UserProfile p) =>
    profileColors[p.color.clamp(0, profileColors.length - 1)];

/// Anzeigename (Standardprofil ohne Namen: „Ich“).
String profileName(UserProfile p) =>
    p.name.isEmpty ? (p.isMain ? tr('Ich') : '?') : p.name;

/// Runder Avatar mit Initiale in der Profilfarbe.
class ProfileAvatar extends StatelessWidget {
  final UserProfile profile;
  final double size;
  final bool guest;
  const ProfileAvatar(this.profile, {super.key, this.size = 40})
      : guest = false;
  const ProfileAvatar.guest({super.key, this.size = 40})
      : profile = UserProfile.main,
        guest = true;

  @override
  Widget build(BuildContext context) {
    final color = guest ? AppColors.gold : profileColor(profile);
    final initial = UserProfile.initialOf(profileName(profile));
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.22),
        shape: BoxShape.circle,
        border: Border.all(color: color, width: size > 48 ? 3 : 2),
      ),
      child: guest
          ? Icon(Icons.person_outline_rounded, size: size * 0.5, color: color)
          : profile.kid
              ? Icon(Icons.child_care_rounded, size: size * 0.52, color: color)
              : Text(initial,
                  style: TextStyle(
                      color: color,
                      fontSize: size * 0.44,
                      fontWeight: FontWeight.w800,
                      height: 1)),
    );
  }
}

/// Profil wechseln (mit PIN-Abfragen). true = gewechselt.
///
/// - Aus dem Kindermodus/Kinderprofil heraus nur mit der Eltern-PIN.
/// - Hat das Ziel eine eigene PIN, wird sie verlangt.
/// - Ein laufender Gastmodus endet mit der Wahl eines Profils.
Future<bool> selectProfile(
    BuildContext context, WidgetRef ref, UserProfile target) async {
  final st = await ref.read(storageProvider.future);
  final mode = ref.read(profileModeProvider);
  final cur = ref.read(activeProfileProvider);
  if (target.id == cur.id && !mode.guest) {
    ref.read(profilePickPendingProvider.notifier).done();
    return true;
  }
  if (!context.mounted) return false;
  // Kinder dürfen nur zwischen Kinderprofilen ohne PIN wechseln.
  final fromKids = st.kidsMode;
  if (fromKids && !(target.kid && !st.flag(Storage.kidsFlag))) {
    if (!await askPin(context, ref)) return false;
  }
  if (st.profileHasPin(target.id)) {
    if (!context.mounted) return false;
    if (!await _askProfilePin(context, st, target)) return false;
  }
  // Eltern-PIN gegeben → alter Kindermodus-Schalter aus (das Ziel bestimmt
  // jetzt, ob gefiltert wird).
  if (fromKids && !target.kid && st.flag(Storage.kidsFlag)) {
    await ref.read(profileModeProvider.notifier).setKids(false);
  }
  if (mode.guest) await ref.read(profileModeProvider.notifier).setGuest(false);
  await ref.read(profilesProvider.notifier).switchTo(target.id);
  return true;
}

/// Als Gast weiterschauen (speichert nichts). Aus dem Kindermodus heraus
/// nur mit der Eltern-PIN – dann im Standardprofil, damit der Gast nicht
/// die Kinder-Freigaben aushebelt oder Kinderdaten sieht.
Future<bool> startGuest(BuildContext context, WidgetRef ref) async {
  final st = await ref.read(storageProvider.future);
  if (st.kidsMode) {
    if (!context.mounted || !await askPin(context, ref)) return false;
    if (st.flag(Storage.kidsFlag)) {
      await ref.read(profileModeProvider.notifier).setKids(false);
    }
    if (st.activeProfile.kid) {
      await ref.read(profilesProvider.notifier).switchTo(UserProfile.mainId);
    }
  }
  await ref.read(profileModeProvider.notifier).setGuest(true);
  ref.read(profilePickPendingProvider.notifier).done();
  return true;
}

Future<bool> _askProfilePin(
    BuildContext context, Storage st, UserProfile p) async {
  String? hint;
  while (true) {
    if (!context.mounted) return false;
    final pin = await pinDialog(
        context, trf('PIN für {0}', [profileName(p)]),
        hint: hint);
    if (pin == null) return false;
    final r = await st.verifyProfilePin(p.id, pin);
    if (r.ok) return true;
    if (r.lockedFor != null) {
      if (context.mounted) {
        final s = r.lockedFor!.inSeconds;
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
            content: Text(trf(
                'Zu viele Fehlversuche. Bitte in {0} erneut versuchen.', [
          s >= 60 ? trf('{0} Min.', [(s / 60).ceil()]) : trf('{0} Sek.', [s])
        ]))));
      }
      return false;
    }
    hint = r.attemptsLeft == 1
        ? tr('Falsche PIN – noch 1 Versuch')
        : trf('Falsche PIN – noch {0} Versuche', [r.attemptsLeft]);
  }
}

/// Profilwahl öffnen (Startseite, Einstellungen).
Future<void> openProfilePicker(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => const ProfilePickerScreen(startup: false)));

/// „Wer schaut?“ – beim Start (wenn mehrere Profile und „Beim Start
/// fragen“) oder zum Wechseln. D-Pad: ◀▶ zwischen den Profilen, OK wählt.
class ProfilePickerScreen extends ConsumerWidget {
  final bool startup;
  const ProfilePickerScreen({super.key, this.startup = true});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ps = ref.watch(profilesProvider);
    final mode = ref.watch(profileModeProvider);
    final t = Theme.of(context).textTheme;
    final tv = ref.watch(isTvProvider);
    final size = tv ? 64.0 : 72.0;

    Future<void> pick(UserProfile p) async {
      final ok = await selectProfile(context, ref, p);
      if (ok && context.mounted && !startup) {
        Navigator.of(context).popUntil((r) => r.isFirst);
      }
    }

    Widget tile(
            {required Key key,
            required Widget avatar,
            required String label,
            String? sub,
            bool current = false,
            bool autofocus = false,
            required VoidCallback onTap}) =>
        SizedBox(
          width: size + 36,
          child: FocusableTile(
            key: key,
            autofocus: autofocus,
            scaleOnFocus: true,
            radius: BorderRadius.circular(16),
            onTap: onTap,
            semanticLabel: sub == null ? label : '$label, $sub',
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 6),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                avatar,
                const SizedBox(height: 10),
                Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: t.titleSmall?.copyWith(
                        fontWeight: current ? FontWeight.w800 : null,
                        color: current ? AppColors.text : AppColors.textDim)),
                if (sub != null)
                  Text(sub,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.bodySmall),
              ]),
            ),
          ),
        );

    final current = mode.guest ? null : ps.active.id;
    final body = SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(tr('Wer schaut?'),
                style: (tv ? t.headlineSmall : t.headlineMedium)
                    ?.copyWith(fontFamily: 'InterDisplay')),
            const SizedBox(height: 24),
            FocusTraversalGroup(
              child: Wrap(
                alignment: WrapAlignment.center,
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (final p in ps.list)
                    tile(
                      key: ValueKey('profile-pick-${p.id}'),
                      avatar: ProfileAvatar(p, size: size),
                      label: profileName(p),
                      sub: p.kid ? tr('Kind') : null,
                      current: p.id == current,
                      autofocus: p.id == ps.active.id,
                      onTap: () => pick(p),
                    ),
                  tile(
                    key: const ValueKey('profile-pick-guest'),
                    avatar: ProfileAvatar.guest(size: size),
                    label: tr('Gast'),
                    sub: tr('speichert nichts'),
                    current: mode.guest,
                    onTap: () async {
                      if (await startGuest(context, ref) &&
                          context.mounted &&
                          !startup) {
                        Navigator.of(context).popUntil((r) => r.isFirst);
                      }
                    },
                  ),
                ],
              ),
            ),
            if (!mode.kids) ...[
              const SizedBox(height: 24),
              TextButton.icon(
                key: const ValueKey('profile-manage'),
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const ProfilesScreen())),
                icon: const Icon(Icons.manage_accounts_rounded),
                label: Text(tr('Profile verwalten')),
              ),
            ],
          ]),
        ),
      ),
    );
    return Scaffold(
      appBar: startup ? null : AppBar(title: Text(tr('Profil wechseln'))),
      body: body,
    );
  }
}

/// Einstellungen → Profile: anlegen, bearbeiten, löschen, „Beim Start
/// fragen“.
class ProfilesScreen extends ConsumerWidget {
  const ProfilesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ps = ref.watch(profilesProvider);
    final st = ref.watch(storageProvider).value;
    final t = Theme.of(context).textTheme;
    final ask = st?.flag(Storage.askProfileFlag, fallback: true) ?? true;
    return Scaffold(
      appBar: AppBar(title: Text(tr('Profile'))),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
            children: [
              Text(
                  tr('Jedes Profil hat eigene Favoriten, eigene Gruppen, '
                      'Verlauf, Weiterschauen und Suchverlauf. Portale und '
                      'Geräte-Einstellungen gelten für alle.'),
                  style: t.bodyMedium),
              const SizedBox(height: 14),
              for (final p in ps.list)
                FocusableTile(
                  key: ValueKey('profile-row-${p.id}'),
                  autofocus: p.id == ps.list.first.id,
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => ProfileEditScreen(profileId: p.id))),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    child: Row(children: [
                      ProfileAvatar(p, size: 40),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(profileName(p),
                                  style: t.titleSmall?.copyWith(fontSize: 15)),
                              Text(
                                  [
                                    p.kid ? tr('Kinderprofil') : tr('Normal'),
                                    if (st?.profileHasPin(p.id) ?? false)
                                      tr('mit PIN'),
                                    if (p.isMain) tr('Standard'),
                                  ].join(' · '),
                                  style: t.bodySmall),
                            ]),
                      ),
                      if (p.id == ps.active.id)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                              color: AppColors.accentSoft,
                              borderRadius: BorderRadius.circular(8)),
                          child: Text(tr('AKTIV'),
                              style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w800,
                                  color: AppColors.accent)),
                        ),
                      const Icon(Icons.chevron_right_rounded,
                          color: AppColors.textFaint),
                    ]),
                  ),
                ),
              const SizedBox(height: 8),
              FocusableTile(
                key: const ValueKey('profile-add'),
                onTap: () async {
                  final p = await ref.read(profilesProvider.notifier).add(
                      name: trf('Profil {0}', [ps.list.length + 1]),
                      color: ps.list.length % profileColors.length);
                  if (context.mounted) {
                    await Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) =>
                            ProfileEditScreen(profileId: p.id, isNew: true)));
                  }
                },
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  child: Row(children: [
                    Icon(Icons.person_add_alt_1_rounded,
                        color: AppColors.accent),
                    const SizedBox(width: 14),
                    Text(tr('Profil hinzufügen'),
                        style: t.titleSmall?.copyWith(fontSize: 15)),
                  ]),
                ),
              ),
              const Divider(height: 28),
              FocusableTile(
                key: const ValueKey('profile-ask'),
                onTap: () async {
                  await st?.setFlag(Storage.askProfileFlag, !ask);
                  ref.invalidate(storageProvider);
                },
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  child: Row(children: [
                    const Icon(Icons.how_to_reg_rounded,
                        color: AppColors.textDim),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(tr('Beim Start fragen'),
                                style: t.titleSmall?.copyWith(fontSize: 15)),
                            Text(
                                tr('Profilwahl beim App-Start, wenn es mehr '
                                    'als ein Profil gibt'),
                                style: t.bodySmall),
                          ]),
                    ),
                    IgnorePointer(
                      child: ExcludeFocus(
                        child: Switch(
                            value: ask,
                            onChanged: (_) {},
                            activeThumbColor: AppColors.accent),
                      ),
                    ),
                  ]),
                ),
              ),
              if (ps.multiple)
                FocusableTile(
                  key: const ValueKey('profile-switch'),
                  onTap: () => openProfilePicker(context),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 12),
                    child: Row(children: [
                      const Icon(Icons.switch_account_rounded,
                          color: AppColors.textDim),
                      const SizedBox(width: 14),
                      Text(tr('Profil wechseln'),
                          style: t.titleSmall?.copyWith(fontSize: 15)),
                    ]),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Ein Profil bearbeiten: Name, Farbe, Typ, PIN, löschen.
class ProfileEditScreen extends ConsumerStatefulWidget {
  final String profileId;
  final bool isNew;
  const ProfileEditScreen(
      {super.key, required this.profileId, this.isNew = false});

  @override
  ConsumerState<ProfileEditScreen> createState() => _ProfileEditScreenState();
}

class _ProfileEditScreenState extends ConsumerState<ProfileEditScreen> {
  late final TextEditingController _name;

  UserProfile? get _p => ref
      .read(profilesProvider)
      .list
      .where((p) => p.id == widget.profileId)
      .firstOrNull;

  @override
  void initState() {
    super.initState();
    final p = _p;
    _name = TextEditingController(
        text: p == null ? '' : (p.name.isEmpty ? profileName(p) : p.name));
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save(UserProfile p) =>
      ref.read(profilesProvider.notifier).update(p);

  Future<void> _saveName() async {
    final p = _p;
    final n = _name.text.trim();
    if (p == null || n.isEmpty || n == p.name) return;
    await _save(p.copyWith(name: n.length > 30 ? n.substring(0, 30) : n));
  }

  @override
  Widget build(BuildContext context) {
    final ps = ref.watch(profilesProvider);
    final p = ps.list.where((x) => x.id == widget.profileId).firstOrNull;
    final st = ref.watch(storageProvider).value;
    final t = Theme.of(context).textTheme;
    if (p == null) return const Scaffold();
    final hasPin = st?.profileHasPin(p.id) ?? false;

    Widget heading(String s) => Padding(
          padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
          child: Text(s, style: t.labelSmall),
        );

    return PopScope(
      onPopInvokedWithResult: (_, __) => _saveName(),
      child: Scaffold(
        appBar: AppBar(
            title: Text(widget.isNew ? tr('Neues Profil') : profileName(p))),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
              children: [
                Center(child: ProfileAvatar(p, size: 72)),
                heading(tr('NAME')),
                DpadTextField(
                  controller: _name,
                  builder: (_, dp) => TextField(
                    key: const ValueKey('profile-name'),
                    controller: _name,
                    autofocus: widget.isNew,
                    maxLength: 30,
                    textInputAction: TextInputAction.done,
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) {
                      _saveName();
                      dp.submitted();
                    },
                    readOnly: dp.readOnly,
                    showCursor: dp.showCursor,
                    onTap: dp.onTap,
                  ),
                ),
                heading(tr('FARBE')),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (var i = 0; i < profileColors.length; i++)
                    FocusableTile(
                      key: ValueKey('profile-color-$i'),
                      radius: BorderRadius.circular(24),
                      selected: p.color == i,
                      semanticLabel: trf('Farbe {0}', [i + 1]),
                      onTap: () => _save(p.copyWith(color: i)),
                      child: Padding(
                        padding: const EdgeInsets.all(6),
                        child: Container(
                          width: 30,
                          height: 30,
                          decoration: BoxDecoration(
                            color: profileColors[i],
                            shape: BoxShape.circle,
                          ),
                          child: p.color == i
                              ? const Icon(Icons.check_rounded,
                                  size: 18, color: Colors.black)
                              : null,
                        ),
                      ),
                    ),
                ]),
                heading(tr('TYP')),
                if (!p.isMain)
                  _Choice(
                    key: const ValueKey('profile-type-normal'),
                    label: tr('Normal'),
                    icon: Icons.person_rounded,
                    selected: !p.kid,
                    onTap: () async {
                      if (!p.kid) return;
                      // Kinderprofil → normal nur mit Eltern-PIN.
                      if (!await askPin(context, ref)) return;
                      await _save(p.copyWith(kid: false));
                    },
                  ),
                if (!p.isMain)
                  _Choice(
                    key: const ValueKey('profile-type-kid'),
                    label: tr('Kind'),
                    sub: tr('Nur im Kindermodus freigegebene Gruppen; '
                        'Wechsel nur mit der Eltern-PIN'),
                    icon: Icons.child_care_rounded,
                    selected: p.kid,
                    onTap: () async {
                      if (p.kid) return;
                      // Ohne Eltern-PIN ließe sich das Profil nie absichern.
                      if (!await ensurePin(context, ref)) return;
                      final s = await ref.read(storageProvider.future);
                      if (!s.hasPin()) return;
                      await _save(p.copyWith(kid: true));
                    },
                  ),
                if (p.isMain)
                  Text(tr('Das Standardprofil ist immer ein normales Profil.'),
                      style: t.bodySmall),
                heading(tr('PIN')),
                _Choice(
                  key: const ValueKey('profile-pin'),
                  label: hasPin ? tr('PIN ändern') : tr('PIN festlegen'),
                  sub: tr('Optional: fragt beim Wechsel zu diesem Profil'),
                  icon: Icons.pin_rounded,
                  onTap: () async {
                    final s = await ref.read(storageProvider.future);
                    if (hasPin) {
                      if (!context.mounted ||
                          !await _askProfilePin(context, s, p)) {
                        return;
                      }
                    }
                    if (!context.mounted) return;
                    final pin = await pinDialog(context, tr('Neue PIN'));
                    if (pin == null || pin.length < 4) return;
                    await ref.read(profilesProvider.notifier).setPin(p.id, pin);
                    ref.invalidate(storageProvider);
                  },
                ),
                if (hasPin)
                  _Choice(
                    key: const ValueKey('profile-pin-remove'),
                    label: tr('PIN entfernen'),
                    icon: Icons.lock_open_rounded,
                    onTap: () async {
                      final s = await ref.read(storageProvider.future);
                      if (!context.mounted ||
                          !await _askProfilePin(context, s, p)) {
                        return;
                      }
                      await ref
                          .read(profilesProvider.notifier)
                          .setPin(p.id, null);
                      ref.invalidate(storageProvider);
                    },
                  ),
                if (!p.isMain) ...[
                  const Divider(height: 32),
                  _Choice(
                    key: const ValueKey('profile-delete'),
                    label: tr('Profil löschen'),
                    sub: tr('Favoriten, Verlauf und Gruppen dieses Profils '
                        'werden entfernt'),
                    icon: Icons.delete_outline_rounded,
                    danger: true,
                    onTap: () async {
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: Text(
                              trf('„{0}“ löschen?', [profileName(p)])),
                          content: Text(tr(
                              'Favoriten, eigene Gruppen, Verlauf und '
                              'Weiterschauen dieses Profils werden gelöscht.')),
                          actions: [
                            TextButton(
                                autofocus: true,
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
                      await ref.read(profilesProvider.notifier).remove(p.id);
                      if (context.mounted) Navigator.of(context).pop();
                    },
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Choice extends StatelessWidget {
  final String label;
  final String? sub;
  final IconData icon;
  final bool? selected;
  final bool danger;
  final VoidCallback onTap;
  const _Choice({
    super.key,
    required this.label,
    required this.icon,
    required this.onTap,
    this.sub,
    this.selected,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final color = danger ? AppColors.live : AppColors.textDim;
    return Semantics(
      selected: selected,
      child: FocusableTile(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          child: Row(children: [
            Icon(icon, size: 22, color: color),
            const SizedBox(width: 14),
            Expanded(
              child:
                  Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(label,
                    style: t.titleSmall?.copyWith(
                        fontSize: 15, color: danger ? AppColors.live : null)),
                if (sub != null) Text(sub!, style: t.bodySmall),
              ]),
            ),
            if (selected != null)
              Icon(
                  selected!
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_off_rounded,
                  color: selected! ? AppColors.accent : AppColors.textFaint),
          ]),
        ),
      ),
    );
  }
}

/// Kleiner Profil-Knopf (Startseite): Avatar des aktiven Profils, öffnet
/// die Profilwahl. Nur sichtbar, wenn es mehrere Profile gibt.
class ProfileSwitchButton extends ConsumerWidget {
  final double size;
  const ProfileSwitchButton({super.key, this.size = 36});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ps = ref.watch(profilesProvider);
    final guest = ref.watch(guestModeProvider);
    if (!ps.multiple) return const SizedBox.shrink();
    final name = guest ? tr('Gast') : profileName(ps.active);
    return FocusableTile(
      key: const ValueKey('home-profile'),
      radius: BorderRadius.circular(size),
      semanticLabel: trf('Profil: {0} – wechseln', [name]),
      onTap: () => openProfilePicker(context),
      child: Padding(
        padding: const EdgeInsets.all(3),
        child: guest
            ? ProfileAvatar.guest(size: size)
            : ProfileAvatar(ps.active, size: size),
      ),
    );
  }
}
