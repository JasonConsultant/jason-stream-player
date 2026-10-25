import 'download_models.dart';

/// Netzregel für Downloads.
///
/// - Ohne Verbindung: warten.
/// - Mobilfunk: nur mit Einstellung „Downloads auch über Mobilfunk“.
/// - Datensparmodus (1.8c) wirksam: keine Downloads über gemessene
///   Verbindungen (Mobilfunk, Hotspot) – auch nicht mit Mobilfunk-Erlaubnis.
///   Über ungemessenes WLAN laden Downloads weiter (ausdrücklicher Wunsch).
DownloadWait networkRule({
  required bool connected,
  required bool cellular,
  required bool metered,
  required bool mobileAllowed,
  required bool dataSaverActive,
}) {
  if (!connected) return DownloadWait.network;
  if (dataSaverActive && (cellular || metered)) return DownloadWait.dataSaver;
  if (cellular && !mobileAllowed) return DownloadWait.cellular;
  return DownloadWait.none;
}

/// Reserve, die auf dem Gerät frei bleiben muss.
const downloadSpaceReserve = 300 * 1024 * 1024;

/// Ohne bekannte Größe: mindestens so viel frei.
const downloadUnknownSizeNeed = 1024 * 1024 * 1024;

/// Reicht der freie Platz? [free] < 0 = unbekannt → versuchen.
/// [remaining] null = Größe unbekannt.
bool enoughSpace(int free, int? remaining) {
  if (free < 0) return true;
  final need = (remaining ?? downloadUnknownSizeNeed) + downloadSpaceReserve;
  return free >= need;
}

/// Wie viele Portal-Downloads gleichzeitig laufen dürfen.
///
/// [setting]: Einstellung 1 oder 2. [maxConnections]: vom Anbieter
/// gemeldet (null = unbekannt). [otherConnections]: bereits belegte
/// Verbindungen desselben Anbieters (laufende Aufnahmen).
/// [keepLiveFree]: eine Verbindung für Live-TV frei halten – nur wenn der
/// Anbieter mehrere erlaubt.
int portalDownloadSlots({
  required int setting,
  required int? maxConnections,
  int otherConnections = 0,
  bool keepLiveFree = false,
}) {
  final want = setting.clamp(1, 2);
  if (maxConnections == null || maxConnections <= 0) return want;
  if (maxConnections == 1) {
    // Nur eine Verbindung: Download nur, wenn keine Aufnahme läuft.
    return otherConnections > 0 ? 0 : 1;
  }
  final free = maxConnections - otherConnections - (keepLiveFree ? 1 : 0);
  return free.clamp(0, want);
}

/// Medienserver (Emby/Jellyfin) haben kein IPTV-Verbindungslimit.
int embyDownloadSlots(int setting) => setting.clamp(1, 2);

/// Wartezeit vor dem nächsten Versuch nach einem Fehler.
Duration retryDelay(int attempts) => switch (attempts) {
      <= 1 => const Duration(seconds: 5),
      2 => const Duration(seconds: 15),
      3 => const Duration(seconds: 30),
      4 => const Duration(seconds: 60),
      _ => const Duration(minutes: 2),
    };

/// Nach so vielen Fehlversuchen in Folge gilt ein Download als gescheitert.
const downloadMaxAttempts = 6;

/// Fehler, bei denen ein neuer Versuch nichts bringt.
/// `nas:*` (Netzlaufwerk nicht erreichbar, voll, Rechte …): nicht
/// automatisch wiederholen und nie still in den App-Ordner ausweichen –
/// der Download bleibt mit Hinweis stehen, „Erneut“ setzt fort.
bool isPermanentDownloadError(String code) =>
    code.startsWith('nas:') ||
    const {
      'auth',
      'notfound',
      'notfile',
      'credentials',
      'forbidden',
      'nospace',
      'storage',
    }.contains(code);

/// Kinderschutz/Erwachsenen-Sperre für die Downloads-Liste.
///
/// - [adultLocked]: Erwachsenen-Sperre aktiv → Titel aus
///   Erwachsenen-Kategorien ausblenden.
/// - [kids]: Kindermodus an → nur freigegebene Kategorien:
///   [kidsVod] (Portal [portalId], Schlüssel `m:`/`s:` + Kategorie) bzw.
///   [kidsEmby] für Medienserver-Titel. Titel anderer Portale sind im
///   Kindermodus nicht prüfbar → ausgeblendet.
bool downloadVisible(
  DownloadItem d, {
  required bool adultLocked,
  required bool kids,
  String? portalId,
  Set<String> kidsVod = const {},
  Set<String> kidsEmby = const {},
}) {
  if (d.adult && (adultLocked || kids)) return false;
  if (!kids) return true;
  final key = '${d.isEpisode ? 's' : 'm'}:${d.categoryId}';
  if (d.isEmby) return kidsEmby.contains(key);
  return d.scope == portalId && kidsVod.contains(key);
}
