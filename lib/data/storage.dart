import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../core/aspect.dart';
import '../core/epg_schedule.dart';
import '../core/secret_store.dart';
import '../core/security.dart';
import '../models/models.dart';

/// Lokale Ablage.
///
/// **Zugangsdaten** (Server-/Playlist-Adresse, Benutzername, Passwort,
/// EPG-Adresse) und die **PIN** werden mit einem Schlüssel aus dem
/// Android-Keystore verschlüsselt (AES-256-GCM, [SecretStore]) und nur als
/// Chiffretext gespeichert. Im Klartext stehen nur Name und Typ eines Portals
/// sowie Favoriten, Positionen usw.
class Storage {
  static const _kPortals = 'portals';
  static const _kActive = 'active_portal';
  static const _kLegacyPin = 'parental_pin';
  static const _kPinHash = 'pin_hash';
  static const _kPinSalt = 'pin_salt';

  static const _secPrefix = 'sec_';

  final SharedPreferences _prefs;
  final SecretStore _store;

  /// Entschlüsselte Geheimnisse im Arbeitsspeicher (nur zur Laufzeit).
  final Map<String, String> _secrets;

  /// Geheimnisse, die nicht mehr entschlüsselt werden konnten.
  final int unreadableSecrets;

  Storage._(this._prefs, this._store, this._secrets, this.unreadableSecrets);

  static Future<Storage> open({SecretStore? store}) async {
    final prefs = await SharedPreferences.getInstance()
        .timeout(const Duration(seconds: 8));
    final st = store ?? SecretStore.platform();
    final secrets = <String, String>{};
    var unreadable = 0;
    for (final k in prefs.getKeys().where((k) => k.startsWith(_secPrefix))) {
      final cipher = prefs.getString(k);
      if (cipher == null) continue;
      try {
        secrets[k.substring(_secPrefix.length)] = await st.decrypt(cipher);
      } on SecretStoreException {
        // Schlüssel weg (z. B. App-Daten wiederhergestellt) → neu anmelden.
        unreadable++;
        await prefs.remove(k);
      }
    }
    final s = Storage._(prefs, st, secrets, unreadable);
    await s._migrate();
    for (final p in s.portals()) {
      Redactor.register(p.username, p.password);
      Redactor.registerUrl(p.url);
    }
    return s;
  }

  /// Ältere Versionen speicherten alles im Klartext → einmalig umziehen.
  Future<void> _migrate() async {
    final raw = _prefs.getString(_kPortals);
    if (raw != null) {
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      if (list.any((j) => j.containsKey('password') || j.containsKey('url'))) {
        final portals = list.map(Portal.fromJson).toList();
        for (final p in portals) {
          await _writeSecret(p);
        }
        await _writePublic(portals);
      }
    }
    final legacyPin = _prefs.getString(_kLegacyPin);
    if (legacyPin != null) {
      await setPin(legacyPin);
      await _prefs.remove(_kLegacyPin);
    }
  }

  // ---------- Portale ----------
  List<Portal> portals() {
    final raw = _prefs.getString(_kPortals);
    if (raw == null) return [];
    final out = <Portal>[];
    for (final j in (jsonDecode(raw) as List).cast<Map<String, dynamic>>()) {
      final id = j['id'] as String;
      final secretRaw = _secrets['portal_$id'];
      if (secretRaw == null) continue; // Zugang nicht mehr lesbar
      final sec = jsonDecode(secretRaw) as Map<String, dynamic>;
      out.add(Portal(
        id: id,
        name: j['name'] as String,
        type: PortalType.values.byName(j['type'] as String),
        url: sec['url'] as String,
        username: sec['username'] as String?,
        password: sec['password'] as String?,
        epgUrl: sec['epgUrl'] as String?,
      ));
    }
    return out;
  }

  Future<void> _writeSecret(Portal p) async {
    final value = jsonEncode({
      'url': p.url,
      'username': p.username,
      'password': p.password,
      'epgUrl': p.epgUrl,
    });
    await _putSecret('portal_${p.id}', value);
  }

  Future<void> _putSecret(String key, String value) async {
    final cipher = await _store.encrypt(value);
    await _prefs.setString('$_secPrefix$key', cipher);
    _secrets[key] = value;
  }

  Future<void> _deleteSecret(String key) async {
    await _prefs.remove('$_secPrefix$key');
    _secrets.remove(key);
  }

  /// Nur unkritische Felder in die normalen Einstellungen.
  Future<void> _writePublic(List<Portal> list) => _prefs.setString(
      _kPortals,
      jsonEncode([
        for (final p in list) {'id': p.id, 'name': p.name, 'type': p.type.name},
      ]));

  Future<void> addPortal(Portal p) async {
    await _writeSecret(p);
    Redactor.register(p.username, p.password);
    Redactor.registerUrl(p.url);
    final list = portals()..removeWhere((x) => x.id == p.id);
    await _writePublic(list..add(p));
  }

  /// Ändert ein Portal an seiner bisherigen Position (z. B. Umbenennen).
  Future<void> updatePortal(Portal p) async {
    await _writeSecret(p);
    await _writePublic([for (final x in portals()) x.id == p.id ? p : x]);
  }

  /// Neue Reihenfolge der Portale (Liste der IDs).
  Future<void> reorderPortals(List<String> ids) async {
    final list = portals();
    int pos(Portal p) {
      final i = ids.indexOf(p.id);
      return i < 0 ? ids.length : i;
    }
    await _writePublic(list..sort((a, b) => pos(a).compareTo(pos(b))));
  }

  Future<void> removePortal(String id) async {
    await _writePublic(portals()..removeWhere((x) => x.id == id));
    await _deleteSecret('portal_$id');
    if (activePortalId() == id) await _prefs.remove(_kActive);
  }

  String? activePortalId() => _prefs.getString(_kActive);
  Future<void> setActivePortal(String? id) =>
      id == null ? _prefs.remove(_kActive) : _prefs.setString(_kActive, id);

  // ---------- Sender-Listen pro Portal ----------
  Set<String> _set(String key) =>
      (_prefs.getStringList(key) ?? const []).toSet();
  Future<void> _saveSet(String key, Set<String> s) =>
      _prefs.setStringList(key, s.toList());

  Set<String> favorites(String portalId) => _set('fav_$portalId');

  // ---------- Sender-Überschreibungen (Name, Logo, EPG-Zuordnung) ----------
  // Ein JSON-Objekt pro Portal unter chov_<portalId> (Backup exportiert
  // alle Schlüssel mit diesem Präfix).
  Map<String, ChannelOverride> overrides(String portalId) {
    final raw = _prefs.getString('chov_$portalId');
    if (raw == null || raw.isEmpty) return const {};
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      return {
        for (final e in j.entries)
          if (e.value is Map)
            e.key: ChannelOverride.fromJson(
                (e.value as Map).cast<String, dynamic>()),
      };
    } catch (_) {
      return const {};
    }
  }

  /// Überschreibung setzen; null oder leer entfernt sie.
  Future<void> setOverride(
      String portalId, String channelId, ChannelOverride? o) async {
    final all = Map<String, ChannelOverride>.of(overrides(portalId));
    if (o == null || o.isEmpty) {
      all.remove(channelId);
    } else {
      all[channelId] = o;
    }
    if (all.isEmpty) {
      await _prefs.remove('chov_$portalId');
      return;
    }
    await _prefs.setString('chov_$portalId',
        jsonEncode({for (final e in all.entries) e.key: e.value.toJson()}));
  }

  /// Zuletzt gesehene Sender (neueste zuerst, max. 20).
  List<String> recent(String portalId) =>
      _prefs.getStringList('recent_$portalId') ?? const [];
  Future<void> pushRecent(String portalId, String channelId) {
    final l = [channelId, ...recent(portalId).where((x) => x != channelId)];
    return _prefs.setStringList(
        'recent_$portalId', l.length > 20 ? l.sublist(0, 20) : l);
  }
  Future<void> clearRecent(String portalId) =>
      _prefs.remove('recent_$portalId');
  Set<String> hidden(String portalId) => _set('hidden_$portalId');
  Set<String> locked(String portalId) => _set('locked_$portalId');

  Future<void> toggleFavorite(String portalId, String channelId) =>
      _toggle('fav_$portalId', channelId);
  Future<void> toggleHidden(String portalId, String channelId) =>
      _toggle('hidden_$portalId', channelId);
  Future<void> toggleLocked(String portalId, String channelId) =>
      _toggle('locked_$portalId', channelId);

  Future<void> _toggle(String key, String id) async {
    final s = _set(key);
    s.contains(id) ? s.remove(id) : s.add(id);
    await _saveSet(key, s);
  }

  /// Alle Zugangsdaten und die PIN unwiderruflich löschen.
  Future<void> wipeCredentials() async {
    for (final k in _prefs.getKeys().where((k) => k.startsWith(_secPrefix)).toList()) {
      await _prefs.remove(k);
    }
    _secrets.clear();
    await _prefs.remove(_kPortals);
    await _prefs.remove(_kActive);
    Redactor.clear();
  }

  // ---------- Kindersicherung ----------
  bool hasPin() => _secrets[_kPinHash] != null;

  /// PIN setzen (nur Hash + Salz werden gespeichert) oder mit null löschen.
  Future<void> setPin(String? pin) async {
    if (pin == null) {
      await _deleteSecret(_kPinHash);
      await _deleteSecret(_kPinSalt);
      return;
    }
    final salt = PinHasher.newSalt();
    final hash = PinHasher.hash(pin, salt);
    await _putSecret(_kPinSalt, salt);
    await _putSecret(_kPinHash, hash);
    await _prefs.remove('pin_fails');
    await _prefs.remove('pin_locked_until');
  }

  /// Prüft die PIN. Nach 5 Fehlversuchen wird gesperrt (30 s, dann länger).
  Future<PinResult> verifyPin(String pin) async {
    final hash = _secrets[_kPinHash];
    final salt = _secrets[_kPinSalt];
    if (hash == null || salt == null) return const PinResult.ok();

    final lockedUntil = _prefs.getInt('pin_locked_until') ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (lockedUntil > now) {
      return PinResult.locked(Duration(milliseconds: lockedUntil - now));
    }
    if (PinHasher.equals(PinHasher.hash(pin, salt), hash)) {
      await _prefs.remove('pin_fails');
      return const PinResult.ok();
    }
    final fails = (_prefs.getInt('pin_fails') ?? 0) + 1;
    await _prefs.setInt('pin_fails', fails);
    if (fails >= 5) {
      final secs = (30 * (1 << (fails - 5))).clamp(30, 3600);
      await _prefs.setInt('pin_locked_until', now + secs * 1000);
      return PinResult.locked(Duration(seconds: secs));
    }
    return PinResult.wrong(5 - fails);
  }

  // ---------- Weiterschauen (Filme/Folgen/Catch-up) ----------
  /// Gespeicherte Position in Sekunden und Gesamtlänge.
  ({int pos, int total})? resume(String key) {
    final raw = _prefs.getString('resume_$key');
    if (raw == null) return null;
    final parts = raw.split('/');
    if (parts.length != 2) return null;
    return (pos: int.tryParse(parts[0]) ?? 0, total: int.tryParse(parts[1]) ?? 0);
  }

  Future<void> setResume(String key, int pos, int total) async {
    // Fast fertig → als gesehen werten und Position löschen.
    if (total > 0 && pos > total * 0.95) {
      await _prefs.remove('resume_$key');
      await _prefs.setBool('watched_$key', true);
      return;
    }
    await _prefs.setString('resume_$key', '$pos/$total');
  }

  /// Zu Ende gesehen (Film/Folge).
  bool isWatched(String key) => _prefs.getBool('watched_$key') ?? false;

  // ---------- Einstellungen ----------
  bool flag(String key, {bool fallback = false}) =>
      _prefs.getBool('set_$key') ?? fallback;
  Future<void> setFlag(String key, bool v) => _prefs.setBool('set_$key', v);
  String option(String key, String fallback) =>
      _prefs.getString('set_$key') ?? fallback;
  Future<void> setOption(String key, String v) =>
      _prefs.setString('set_$key', v);

  Future<void> clearHidden(String portalId) => _prefs.remove('hidden_$portalId');

  // ---------- Eigene Reihenfolge ----------
  /// Gruppen-Reihenfolge (Kategorie-IDs) bzw. Sender-Reihenfolge je Gruppe.
  List<String> groupOrder(String portalId) =>
      _prefs.getStringList('order_groups_$portalId') ?? const [];
  Future<void> setGroupOrder(String portalId, List<String> ids) =>
      _prefs.setStringList('order_groups_$portalId', ids);
  List<String> channelOrder(String portalId, String groupId) =>
      _prefs.getStringList('order_ch_${portalId}_$groupId') ?? const [];
  Future<void> setChannelOrder(String portalId, String groupId, List<String> ids) =>
      _prefs.setStringList('order_ch_${portalId}_$groupId', ids);
  Set<String> hiddenGroups(String portalId) =>
      (_prefs.getStringList('hidden_groups_$portalId') ?? const []).toSet();
  Future<void> setHiddenGroups(String portalId, Set<String> ids) =>
      _prefs.setStringList('hidden_groups_$portalId', ids.toList());
  Future<void> resetOrder(String portalId) async {
    for (final k in _prefs.getKeys().where((k) =>
        k == 'order_groups_$portalId' ||
        k.startsWith('order_ch_${portalId}_') ||
        k == 'hidden_groups_$portalId').toList()) {
      await _prefs.remove(k);
    }
  }

  // ---------- EPG-Aktualisierung ----------
  EpgSchedule epgSchedule() => EpgSchedule(
        interval: EpgInterval.fromId(_prefs.getString('set_epginterval')),
        hour: _prefs.getInt('set_epghour') ?? 5,
      );
  Future<void> setEpgInterval(EpgInterval i) =>
      _prefs.setString('set_epginterval', i.id);
  Future<void> setEpgHour(int h) => _prefs.setInt('set_epghour', h);

  DateTime? epgUpdated(String portalId) {
    final ms = _prefs.getInt('epg_updated_$portalId');
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  Future<void> setEpgUpdated(String portalId, DateTime? t) => t == null
      ? _prefs.remove('epg_updated_$portalId')
      : _prefs.setInt('epg_updated_$portalId', t.millisecondsSinceEpoch);

  // ---------- Bildformat ----------
  /// Standardformat für alle Sender/Filme.
  AspectMode defaultAspect() => AspectMode.fromId(_prefs.getString('set_fit'));
  Future<void> setDefaultAspect(AspectMode m) =>
      _prefs.setString('set_fit', m.id);

  /// Für einen Sender gemerktes Format (oder null → Standard).
  AspectMode? channelAspect(String portalId, String channelId) {
    final id = _prefs.getString('aspect_${portalId}_$channelId');
    return id == null ? null : AspectMode.fromId(id);
  }

  Future<void> setChannelAspect(
          String portalId, String channelId, AspectMode? m) =>
      m == null
          ? _prefs.remove('aspect_${portalId}_$channelId')
          : _prefs.setString('aspect_${portalId}_$channelId', m.id);

  int channelAspectCount(String portalId) => _prefs
      .getKeys()
      .where((k) => k.startsWith('aspect_${portalId}_'))
      .length;

  Future<void> clearChannelAspects(String portalId) async {
    for (final k in _prefs
        .getKeys()
        .where((k) => k.startsWith('aspect_${portalId}_'))
        .toList()) {
      await _prefs.remove(k);
    }
  }

  // ---------- Am Standort nicht verfügbare Sender ----------
  // Vermerk mit Zeitstempel; nach 24 h wird automatisch erneut probiert.
  static const _unavailableTtl = Duration(hours: 24);

  Set<String> unavailable(String portalId) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final out = <String>{};
    for (final e in _prefs.getStringList('unavail_$portalId') ?? const []) {
      final i = e.lastIndexOf('|');
      if (i < 0) continue;
      final ts = int.tryParse(e.substring(i + 1)) ?? 0;
      if (now - ts < _unavailableTtl.inMilliseconds) out.add(e.substring(0, i));
    }
    return out;
  }

  Future<void> markUnavailable(String portalId, String channelId,
      {bool on = true}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final keep = (_prefs.getStringList('unavail_$portalId') ?? const [])
        .where((e) => !e.startsWith('$channelId|'))
        .where((e) {
      final ts = int.tryParse(e.substring(e.lastIndexOf('|') + 1)) ?? 0;
      return now - ts < _unavailableTtl.inMilliseconds;
    }).toList();
    if (on) keep.add('$channelId|$now');
    await _prefs.setStringList('unavail_$portalId', keep);
  }

  Future<void> clearUnavailable(String portalId) =>
      _prefs.remove('unavail_$portalId');

  // ---------- Zuletzt gesehen ----------
  String? lastChannel(String portalId) => _prefs.getString('last_$portalId');
  Future<void> setLastChannel(String portalId, String channelId) =>
      _prefs.setString('last_$portalId', channelId);

  // ---------- Sicherung & Übertragung ----------
  /// Präfixe von Einstellungen, die in eine Sicherung gehören (pro Portal).
  static const _backupPrefixes = [
    'fav_', 'hidden_', 'locked_', 'recent_', 'order_groups_', 'order_ch_',
    'hidden_groups_', 'aspect_', 'resume_', 'watched_', 'last_', 'chov_',
    'set_mygroups_', 'set_vodfav_', 'set_vodhist_', 'set_chov_',
  ];

  /// Globale Optionen/Schalter (set_*), die gesichert werden. Nicht dabei:
  /// Aufnahmen, Erinnerungen, Update-Prüfung, App-Sperre, Risiko-Hinweis,
  /// EPG-Versuche – die gehören zum Gerät, nicht zum Nutzerprofil.
  static const _backupOptions = [
    'set_applang', 'set_alang', 'set_slang', 'set_starttab', 'set_buffer',
    'set_hwdec', 'set_autopip', 'set_startlast', 'set_preview', 'set_afr',
    'set_hideunavail', 'set_playerlandscape',
    'set_epginterval', 'set_epghour', 'set_fit',
  ];

  static bool _isBackupKey(String k) =>
      _backupOptions.contains(k) || _backupPrefixes.any(k.startsWith);

  /// Alles für den Umzug auf ein anderes Gerät – Portale mit entschlüsselten
  /// Zugangsdaten, aktives Portal und die Einstellungen aus [_isBackupKey].
  /// Nie dabei: PIN-Hash/Salz, sec_*-Chiffretext, Gerätevermerke.
  /// Die Ausgabe gehört nur verschlüsselt auf die Platte (BackupCodec).
  Map<String, Object?> exportAll() {
    final prefs = <String, Object?>{};
    for (final k in _prefs.getKeys().where(_isBackupKey)) {
      final v = _prefs.get(k);
      if (v is String || v is bool || v is int || v is double || v is List) {
        prefs[k] = v is List ? v.cast<String>().toList() : v;
      }
    }
    return {
      'format': 1,
      'app': 'jason_stream_player',
      'created': DateTime.now().toIso8601String(),
      'portals': [
        for (final p in portals())
          {
            'id': p.id,
            'name': p.name,
            'type': p.type.name,
            'url': p.url,
            'username': p.username,
            'password': p.password,
            'epgUrl': p.epgUrl,
          },
      ],
      'active': activePortalId(),
      'prefs': prefs,
    };
  }

  /// Sicherung einspielen. [merge] = true: vorhandene Portale bleiben,
  /// gleiche IDs werden aktualisiert, Einstellungen überschrieben.
  /// [merge] = false: alle Portale und gesicherten Einstellungen werden
  /// vorher entfernt (PIN und Gerätevermerke bleiben).
  Future<void> importAll(Map<String, Object?> data, {bool merge = true}) async {
    if (data['app'] != 'jason_stream_player' || data['portals'] is! List) {
      throw const FormatException('Keine Sicherung von Jason Stream Player');
    }
    if (!merge) {
      for (final p in portals()) {
        await removePortal(p.id);
      }
      for (final k in _prefs.getKeys().where(_isBackupKey).toList()) {
        await _prefs.remove(k);
      }
    }
    final existing = {for (final p in portals()) p.id};
    for (final j in (data['portals'] as List).whereType<Map>()) {
      final id = j['id'];
      final name = j['name'];
      final url = j['url'];
      final types = PortalType.values.where((t) => t.name == j['type']);
      final type = types.isEmpty ? null : types.first;
      if (id is! String || name is! String || url is! String || type == null) {
        continue;
      }
      final p = Portal(
        id: id,
        name: name,
        type: type,
        url: url,
        username: j['username'] as String?,
        password: j['password'] as String?,
        epgUrl: j['epgUrl'] as String?,
      );
      existing.contains(id) ? await updatePortal(p) : await addPortal(p);
    }
    final prefs = data['prefs'];
    if (prefs is Map) {
      for (final e in prefs.entries) {
        final k = e.key;
        final v = e.value;
        if (k is! String || !_isBackupKey(k)) continue;
        if (v is bool) {
          await _prefs.setBool(k, v);
        } else if (v is int) {
          await _prefs.setInt(k, v);
        } else if (v is double) {
          await _prefs.setDouble(k, v);
        } else if (v is String) {
          await _prefs.setString(k, v);
        } else if (v is List) {
          await _prefs.setStringList(k, v.map((x) => '$x').toList());
        }
      }
    }
    final active = data['active'];
    final ids = {for (final p in portals()) p.id};
    if (active is String &&
        ids.contains(active) &&
        (!merge || !ids.contains(activePortalId()))) {
      await setActivePortal(active);
    }
  }
}

/// Ergebnis einer PIN-Prüfung.
class PinResult {
  final bool ok;
  final int attemptsLeft;
  final Duration? lockedFor;
  const PinResult.ok()
      : ok = true,
        attemptsLeft = 0,
        lockedFor = null;
  const PinResult.wrong(this.attemptsLeft)
      : ok = false,
        lockedFor = null;
  const PinResult.locked(Duration d)
      : ok = false,
        attemptsLeft = 0,
        lockedFor = d;
}
