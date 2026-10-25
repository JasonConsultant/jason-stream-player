/// Nutzerprofile (ab 2.3).
///
/// Je Profil getrennt: Favoriten, eigene Gruppen, Verlauf (Sender, Filme/
/// Serien), Weiterschauen-Positionen und „gesehen“, zuletzt gesehener
/// Sender, Suchverlauf. Gemeinsam: Portale/Zugangsdaten, Geräte-Einstellungen,
/// Aufnahmen, Downloads, Erinnerungen, Kindermodus-Freigaben.
///
/// Das Standardprofil [UserProfile.mainId] benutzt die bisherigen Schlüssel
/// unverändert – beim Update auf 2.3 muss deshalb nichts umkopiert werden
/// (keine Migration, die etwas verlieren könnte). Weitere Profile legen
/// ihre Schlüssel unter `p.<id>.<schlüssel>` ab ([ProfileKeys]).
class UserProfile {
  static const mainId = 'main';

  /// Anzahl der wählbaren Farben (siehe UI `profileColors`).
  static const colorCount = 8;

  final String id;

  /// Leer beim Standardprofil, solange es nicht umbenannt wurde – die
  /// Oberfläche zeigt dann „Ich“ in der App-Sprache.
  final String name;

  /// Index in die Profilfarben.
  final int color;

  /// Kinderprofil: verhält sich wie der Kindermodus (nur freigegebene
  /// Gruppen, Einstellungen gesperrt, Verlassen nur mit der Eltern-PIN).
  final bool kid;

  const UserProfile({
    required this.id,
    this.name = '',
    this.color = 0,
    this.kid = false,
  });

  static const main = UserProfile(id: mainId);

  bool get isMain => id == mainId;

  UserProfile copyWith({String? name, int? color, bool? kid}) => UserProfile(
        id: id,
        name: name ?? this.name,
        color: color ?? this.color,
        kid: kid ?? this.kid,
      );

  Map<String, Object> toJson() => {
        'id': id,
        'name': name,
        'color': color,
        if (kid) 'kid': true,
      };

  static UserProfile? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['id'];
    if (id is! String || id.isEmpty || !ProfileKeys.validId(id)) return null;
    final name = j['name'];
    final color = j['color'];
    return UserProfile(
      id: id,
      name: name is String ? name.trim() : '',
      color: color is int ? color.clamp(0, colorCount - 1) : 0,
      kid: j['kid'] == true,
    );
  }

  /// Initiale für den Avatar ('' → Fallback der Oberfläche).
  static String initialOf(String name) {
    final t = name.trim();
    if (t.isEmpty) return '';
    return String.fromCharCode(t.runes.first).toUpperCase();
  }

  @override
  bool operator ==(Object other) =>
      other is UserProfile &&
      other.id == id &&
      other.name == name &&
      other.color == color &&
      other.kid == kid;

  @override
  int get hashCode => Object.hash(id, name, color, kid);
}

/// Welche gespeicherten Schlüssel je Profil getrennt sind und wie sie für
/// ein anderes als das Standardprofil heißen.
class ProfileKeys {
  ProfileKeys._();

  static const prefix = 'p.';

  /// Direkte Schlüssel (Storage-Methoden).
  static const direct = ['fav_', 'recent_', 'resume_', 'watched_', 'last_'];

  /// Optionen (`set_` + …), die je Profil gelten.
  static const options = ['mygroups_', 'vodfav_', 'vodhist_', 'recentsearch_'];

  static bool validId(String id) => RegExp(r'^[A-Za-z0-9_-]{1,40}$').hasMatch(id);

  /// Ist [key] (ohne Profil-Präfix) ein profilbezogener Schlüssel?
  static bool isProfileKey(String key) =>
      direct.any(key.startsWith) ||
      (key.startsWith('set_') && options.any(key.substring(4).startsWith));

  /// Schlüssel [key] für Profil [profileId].
  static String map(String profileId, String key) =>
      profileId == UserProfile.mainId ? key : '$prefix$profileId.$key';

  /// `p.<id>.<key>` → (id, key); sonst null.
  static ({String profile, String key})? split(String stored) {
    if (!stored.startsWith(prefix)) return null;
    final dot = stored.indexOf('.', prefix.length);
    if (dot < 0) return null;
    final id = stored.substring(prefix.length, dot);
    if (!validId(id)) return null;
    return (profile: id, key: stored.substring(dot + 1));
  }
}
