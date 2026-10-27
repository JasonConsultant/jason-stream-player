/// Handy als Fernbedienung (ab 2.4): gemeinsame Begriffe des Protokolls
/// zwischen Handy und Fernseher (gleiches WLAN).
///
/// Ablauf einer Verbindung (WebSocket, Pfad [remotePath]):
/// 1. TV → Handy (Klartext): `hello` mit TV-Kennung, Name und Zufallswert.
/// 2. Handy → TV:
///    - gekoppelt: `auth` (Geräte-Kennung, Zufallswert, HMAC mit dem
///      gemeinsamen Schlüssel) → danach nur noch verschlüsselte Rahmen.
///    - neu: `pair` (öffentlicher X25519-Schlüssel) → TV zeigt einen
///      4-stelligen Code → ziffernweise Commit/Reveal (siehe pairing.dart)
///      → `pairOk` → Verbindung schließt, Handy verbindet sich mit `auth`.
/// 3. Verschlüsselt (AES-256-GCM, je Richtung eigener Schlüssel, Zähler
///    gegen Wiederholung): JSON-Nachrichten mit Feld `t` (siehe unten).
///
/// Es gehen nie Zugangsdaten oder Stream-Adressen über das Netz – Inhalte
/// werden nur über ihre Kennung ([ContentRef]) übergeben.
library;

/// mDNS/NSD-Diensttyp.
const remoteServiceType = '_jsp-remote._tcp';

/// WebSocket-Pfad.
const remotePath = '/jsp-remote';

/// Protokollversion (im `hello` und in den TXT-Daten der Ankündigung).
const remoteProtocolVersion = 1;

/// Größte erlaubte Nachricht (Klartext oder Rahmen) in Bytes.
const remoteMaxMessage = 64 * 1024;

/// Seitengröße der Senderliste (Handy fragt seitenweise).
const remotePageSize = 50;

/// Tasten der Handy-Fernbedienung (Name auf der Leitung = [wire]).
enum RemoteKey {
  up('up'),
  down('down'),
  left('left'),
  right('right'),
  ok('ok'),
  back('back'),
  home('home'),
  menu('menu'),
  channelUp('chUp'),
  channelDown('chDown'),
  digit0('0'),
  digit1('1'),
  digit2('2'),
  digit3('3'),
  digit4('4'),
  digit5('5'),
  digit6('6'),
  digit7('7'),
  digit8('8'),
  digit9('9'),
  playPause('playPause'),
  rewind('rew'),
  fastForward('ffw'),
  red('red'),
  green('green'),
  yellow('yellow'),
  blue('blue'),
  info('info'),
  volumeUp('volUp'),
  volumeDown('volDown'),
  mute('mute');

  const RemoteKey(this.wire);
  final String wire;

  static final _byWire = {for (final k in values) k.wire: k};
  static RemoteKey? fromWire(Object? w) => w is String ? _byWire[w] : null;

  static const digits = [
    digit0, digit1, digit2, digit3, digit4,
    digit5, digit6, digit7, digit8, digit9,
  ];

  /// Lautstärke wird nicht als Taste eingespeist, sondern über das System
  /// (nur wenn der Fernseher sie über die App regeln kann).
  bool get isVolume => this == volumeUp || this == volumeDown || this == mute;

  /// Darf gedrückt gehalten werden (Wiederholung am Fernseher)?
  bool get repeats => switch (this) {
        home || back || mute => false,
        _ => true,
      };
}

/// Tasten-Aktion: kurz drücken, gedrückt halten (Beginn) oder loslassen.
enum KeyAction {
  tap('tap'),
  down('down'),
  up('up');

  const KeyAction(this.wire);
  final String wire;
  static KeyAction? fromWire(Object? w) => switch (w) {
        'tap' => tap,
        'down' => down,
        'up' => up,
        _ => null,
      };
}

/// Fehlercodes in Antworten (`res` mit `err`).
abstract final class RemoteError {
  /// Inhalt gibt es auf dem Fernseher nicht (anderes Portal, nicht in der
  /// Liste, im Kinder-/Gastprofil ausgeblendet).
  static const notAvailable = 'notAvailable';

  /// Das passende Portal ist am Fernseher eingerichtet, aber nicht aktiv.
  static const portalInactive = 'portalInactive';

  /// Abgelehnt (PIN am Fernseher abgebrochen o. Ä.).
  static const refused = 'refused';

  /// Unbekannte oder fehlerhafte Anfrage.
  static const bad = 'bad';

  /// Fernseher noch nicht bereit (Listen laden, kein Portal).
  static const busy = 'busy';
}

// ---------------------------------------------------------------------------
// Nachrichten (verschlüsselt, JSON). Handy → TV:
//   {t:'key', k:<RemoteKey.wire>, a:'tap'|'down'|'up'}
//   {t:'text', v:'…'}                     – kompletter Inhalt des TV-Felds
//   {t:'textDone'}                         – „Fertig“/Suchen auf dem Handy
//   {t:'req', id:n, m:'groups'}            → {t:'res', id, groups:[{id,name,n}]}
//   {t:'req', id:n, m:'channels', g, o, n} → {t:'res', id, items, total}
//   {t:'req', id:n, m:'tune', ch}          → {t:'res', id, ok} / {err}
//   {t:'req', id:n, m:'play', ref:{…}}     → {t:'res', id, ok} / {err}
// TV → Handy:
//   {t:'ready', name, caps:{volume:bool}}
//   {t:'status', …}                        – siehe RemoteStatus
//   {t:'text', focus:bool, v, hint, obscure, multiline}
// ---------------------------------------------------------------------------

/// Lesehilfen für eingehende (nicht vertrauenswürdige) Nachrichten.
abstract final class Wire {
  static String? str(Map<String, Object?> m, String key, {int max = 512}) {
    final v = m[key];
    if (v is! String || v.length > max) return null;
    return v;
  }

  static int? integer(Map<String, Object?> m, String key,
      {int min = 0, int max = 1 << 31}) {
    final v = m[key];
    if (v is! int || v < min || v > max) return null;
    return v;
  }

  static bool flag(Map<String, Object?> m, String key) => m[key] == true;

  static Map<String, Object?>? map(Map<String, Object?> m, String key) {
    final v = m[key];
    return v is Map ? v.cast<String, Object?>() : null;
  }
}

/// Was gerade am Fernseher läuft (oben in der Fernbedienung).
class RemoteStatus {
  /// Kein Stream, Live, Film/Folge (`none`/`live`/`vod`).
  final String kind;
  final String title;
  final String? subtitle;

  /// Live: Kennung und Nummer des Senders (Markierung in der Liste).
  final String? channelId;
  final int? channelNumber;

  /// Live: laufende Sendung (aus dem EPG des Fernsehers).
  final String? programme;
  final bool playing;
  final bool buffering;

  /// Sekunden (Filme/Folgen).
  final int position;
  final int duration;

  const RemoteStatus({
    this.kind = 'none',
    this.title = '',
    this.subtitle,
    this.channelId,
    this.channelNumber,
    this.programme,
    this.playing = false,
    this.buffering = false,
    this.position = 0,
    this.duration = 0,
  });

  static const none = RemoteStatus();

  bool get active => kind != 'none';
  bool get live => kind == 'live';

  Map<String, Object?> toJson() => {
        't': 'status',
        'kind': kind,
        'title': title,
        if (subtitle != null) 'sub': subtitle,
        if (channelId != null) 'ch': channelId,
        if (channelNumber != null) 'num': channelNumber,
        if (programme != null) 'prog': programme,
        'playing': playing,
        'buf': buffering,
        'pos': position,
        'dur': duration,
      };

  factory RemoteStatus.fromJson(Map<String, Object?> m) {
    final kind = Wire.str(m, 'kind', max: 8);
    return RemoteStatus(
      kind: kind == 'live' || kind == 'vod' ? kind! : 'none',
      title: Wire.str(m, 'title') ?? '',
      subtitle: Wire.str(m, 'sub'),
      channelId: Wire.str(m, 'ch'),
      channelNumber: Wire.integer(m, 'num'),
      programme: Wire.str(m, 'prog'),
      playing: Wire.flag(m, 'playing'),
      buffering: Wire.flag(m, 'buf'),
      position: Wire.integer(m, 'pos') ?? 0,
      duration: Wire.integer(m, 'dur') ?? 0,
    );
  }

  /// Ohne Position verglichen: die Position allein löst keine Neuanzeige
  /// der Sender-Markierung aus.
  bool sameShow(RemoteStatus o) =>
      o.kind == kind &&
      o.title == title &&
      o.subtitle == subtitle &&
      o.channelId == channelId &&
      o.programme == programme;

  @override
  bool operator ==(Object other) =>
      other is RemoteStatus &&
      sameShow(other) &&
      other.channelNumber == channelNumber &&
      other.playing == playing &&
      other.buffering == buffering &&
      other.position == position &&
      other.duration == duration;

  @override
  int get hashCode => Object.hash(kind, title, subtitle, channelId,
      channelNumber, programme, playing, buffering, position, duration);
}

/// Textfeld am Fernseher (Handy zeigt dann automatisch ein Eingabefeld).
class RemoteTextState {
  final bool focus;

  /// Inhalt – bei verdeckten Feldern (Passwort/PIN) immer leer.
  final String text;
  final String? hint;
  final bool obscure;
  final bool multiline;

  /// Nur Ziffern (PIN, Nummern).
  final bool numeric;

  const RemoteTextState({
    this.focus = false,
    this.text = '',
    this.hint,
    this.obscure = false,
    this.multiline = false,
    this.numeric = false,
  });

  static const none = RemoteTextState();

  Map<String, Object?> toJson() => {
        't': 'text',
        'focus': focus,
        'v': obscure ? '' : text,
        if (hint != null) 'hint': hint,
        'obscure': obscure,
        'multi': multiline,
        'num': numeric,
      };

  factory RemoteTextState.fromJson(Map<String, Object?> m) => RemoteTextState(
        focus: Wire.flag(m, 'focus'),
        text: Wire.str(m, 'v', max: 4000) ?? '',
        hint: Wire.str(m, 'hint', max: 200),
        obscure: Wire.flag(m, 'obscure'),
        multiline: Wire.flag(m, 'multi'),
        numeric: Wire.flag(m, 'num'),
      );

  @override
  bool operator ==(Object other) =>
      other is RemoteTextState &&
      other.focus == focus &&
      other.text == text &&
      other.hint == hint &&
      other.obscure == obscure &&
      other.multiline == multiline &&
      other.numeric == numeric;

  @override
  int get hashCode =>
      Object.hash(focus, text, hint, obscure, multiline, numeric);
}

/// Gruppe der Senderliste des Fernsehers.
class RemoteGroup {
  final String id;
  final String name;
  final int count;
  const RemoteGroup(this.id, this.name, this.count);

  Map<String, Object?> toJson() => {'id': id, 'name': name, 'n': count};
  static RemoteGroup? fromJson(Object? j) {
    if (j is! Map) return null;
    final m = j.cast<String, Object?>();
    final id = Wire.str(m, 'id');
    final name = Wire.str(m, 'name');
    if (id == null || name == null) return null;
    return RemoteGroup(id, name, Wire.integer(m, 'n') ?? 0);
  }
}

/// Sendung (jetzt/danach) für Liste und kompakten Guide.
class RemoteProgramme {
  final String title;
  final DateTime start;
  final DateTime end;
  const RemoteProgramme(this.title, this.start, this.end);

  Map<String, Object?> toJson() => {
        'title': title,
        's': start.millisecondsSinceEpoch ~/ 1000,
        'e': end.millisecondsSinceEpoch ~/ 1000,
      };

  static RemoteProgramme? fromJson(Object? j) {
    if (j is! Map) return null;
    final m = j.cast<String, Object?>();
    final t = Wire.str(m, 'title');
    final s = Wire.integer(m, 's');
    final e = Wire.integer(m, 'e');
    if (t == null || s == null || e == null) return null;
    return RemoteProgramme(t, DateTime.fromMillisecondsSinceEpoch(s * 1000),
        DateTime.fromMillisecondsSinceEpoch(e * 1000));
  }

  /// Anteil 0…1 zum Zeitpunkt [now].
  double progress(DateTime now) {
    final total = end.difference(start).inSeconds;
    if (total <= 0) return 0;
    return (now.difference(start).inSeconds / total).clamp(0.0, 1.0);
  }
}

/// Sender aus der Liste des Fernsehers.
class RemoteChannel {
  final String id;
  final String name;
  final int number;

  /// Logo nur, wenn die Adresse keine Zugangsdaten enthalten kann.
  final String? logo;
  final RemoteProgramme? now;
  final RemoteProgramme? next;

  /// Gesperrt (PIN am Fernseher nötig).
  final bool locked;

  const RemoteChannel({
    required this.id,
    required this.name,
    this.number = 0,
    this.logo,
    this.now,
    this.next,
    this.locked = false,
  });

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        if (number > 0) 'num': number,
        if (logo != null) 'logo': logo,
        if (now != null) 'now': now!.toJson(),
        if (next != null) 'next': next!.toJson(),
        if (locked) 'lock': true,
      };

  static RemoteChannel? fromJson(Object? j) {
    if (j is! Map) return null;
    final m = j.cast<String, Object?>();
    final id = Wire.str(m, 'id');
    final name = Wire.str(m, 'name');
    if (id == null || name == null) return null;
    final logo = Wire.str(m, 'logo', max: 2000);
    return RemoteChannel(
      id: id,
      name: name,
      number: Wire.integer(m, 'num') ?? 0,
      logo: logo != null && isSafeLogoUrl(logo) ? logo : null,
      now: RemoteProgramme.fromJson(m['now']),
      next: RemoteProgramme.fromJson(m['next']),
      locked: Wire.flag(m, 'lock'),
    );
  }
}

/// Logo-Adresse darf übertragen werden: http(s), ohne Benutzerdaten und
/// ohne Abfrageteil (dort stehen bei Portalen oft Zugangsdaten/Token).
/// [secrets]: Zeichenketten, die nicht vorkommen dürfen (Benutzername,
/// Passwort, MAC des Portals).
bool isSafeLogoUrl(String url, {Iterable<String?> secrets = const []}) {
  final u = Uri.tryParse(url);
  if (u == null || !(u.scheme == 'http' || u.scheme == 'https')) return false;
  if (u.host.isEmpty || u.userInfo.isNotEmpty || u.hasQuery || u.hasFragment) {
    return false;
  }
  final lower = url.toLowerCase();
  for (final s in secrets) {
    if (s != null && s.length >= 3 && lower.contains(s.toLowerCase())) {
      return false;
    }
  }
  return true;
}
