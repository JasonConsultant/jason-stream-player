import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/profiles.dart';
import '../data/storage.dart';
import 'providers.dart';

export '../data/profiles.dart' show UserProfile;

/// Profile und aktives Profil (ab 2.3).
class ProfilesState {
  final List<UserProfile> list;
  final UserProfile active;
  const ProfilesState(this.list, this.active);
  static const initial = ProfilesState([UserProfile.main], UserProfile.main);

  bool get multiple => list.length > 1;

  @override
  bool operator ==(Object other) =>
      other is ProfilesState &&
      other.active == active &&
      other.list.length == list.length &&
      [for (var i = 0; i < list.length; i++) other.list[i] == list[i]]
          .every((x) => x);

  @override
  int get hashCode => Object.hash(active, list.length);
}

class ProfilesNotifier extends Notifier<ProfilesState> {
  @override
  ProfilesState build() {
    final st = ref.watch(storageProvider).value;
    if (st == null) return ProfilesState.initial;
    return ProfilesState(st.profiles(), st.activeProfile);
  }

  Future<Storage> get _st => ref.read(storageProvider.future);

  void _reload(Storage st) =>
      state = ProfilesState(st.profiles(), st.activeProfile);

  /// Profil wechseln. PIN-Abfragen macht die Oberfläche vorher.
  Future<void> switchTo(String id) async {
    final st = await _st;
    await st.setActiveProfile(id);
    _reload(st);
    ref.read(profilePickPendingProvider.notifier).done();
  }

  Future<UserProfile> add(
      {required String name, int color = 0, bool kid = false}) async {
    final st = await _st;
    final p = await st.addProfile(name: name, color: color, kid: kid);
    _reload(st);
    return p;
  }

  Future<void> update(UserProfile p) async {
    final st = await _st;
    await st.updateProfile(p);
    _reload(st);
  }

  Future<void> remove(String id) async {
    final st = await _st;
    await st.removeProfile(id);
    _reload(st);
  }

  Future<void> setPin(String id, String? pin) async {
    final st = await _st;
    await st.setProfilePin(id, pin);
    _reload(st);
  }
}

final profilesProvider =
    NotifierProvider<ProfilesNotifier, ProfilesState>(ProfilesNotifier.new);

/// Aktives Profil.
final activeProfileProvider =
    Provider<UserProfile>((ref) => ref.watch(profilesProvider).active);

/// Nur die ID – profilbezogene Daten (Favoriten, Verlauf, eigene Gruppen,
/// Weiterschauen, Suchverlauf) laden neu, wenn sie sich ändert.
final activeProfileIdProvider =
    Provider<String>((ref) => ref.watch(activeProfileProvider).id);

/// Profilwahl beim Start noch offen? (Einstellung „Beim Start fragen“, nur
/// mit mehr als einem Profil.) Einmal je App-Start.
class _PickDone extends Notifier<bool> {
  @override
  bool build() => false;
  void set() => state = true;
}

final _pickDoneProvider = NotifierProvider<_PickDone, bool>(_PickDone.new);

class ProfilePickPending extends Notifier<bool> {
  @override
  bool build() {
    if (ref.watch(_pickDoneProvider)) return false;
    final st = ref.watch(storageProvider).value;
    return st != null && st.askProfileOnStart;
  }

  void done() => ref.read(_pickDoneProvider.notifier).set();
}

final profilePickPendingProvider =
    NotifierProvider<ProfilePickPending, bool>(ProfilePickPending.new);
