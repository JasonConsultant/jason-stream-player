/// Datenmodelle für Jason Stream Player.
library;

/// xtream: Xtream-Codes-API · m3u: Playlist · stalker: MAC-Portal
/// (Ministra/Stalker, wie MAG-Boxen) · demo: eingebaute Demo.
/// Bei stalker steht die MAC-Adresse in [Portal.username].
enum PortalType { xtream, m3u, stalker, demo }

class Portal {
  final String id;
  final String name;
  final PortalType type;

  /// Xtream: Basis-URL (http://host:port). M3U: Playlist-URL.
  final String url;
  final String? username;
  final String? password;

  /// Optionale XMLTV-URL (bei M3U-Portalen oder als Override).
  final String? epgUrl;

  /// Erweitert: eigener User-Agent (null = App-Standard) und Referer –
  /// für API-, Playlist-, EPG- und Stream-Anfragen (siehe stream_headers.dart).
  final String? userAgent;
  final String? referer;

  /// Ersatz-Adressen (Spiegelserver), automatisch genutzt, wenn [url]
  /// nicht antwortet. Können Zugangsdaten enthalten → verschlüsselt.
  final List<String> altUrls;

  /// Listen automatisch neu laden: 0 = aus, sonst alle N Stunden.
  final int autoRefreshHours;

  /// Zeitversatz je EPG-Quelle in Minuten (Schlüssel wie in [epgSources],
  /// „portal“ = Anbieter-EPG), z. B. {'portal': -60}.
  final Map<String, int> epgOffsets;

  const Portal({
    required this.id,
    required this.name,
    required this.type,
    required this.url,
    this.username,
    this.password,
    this.epgUrl,
    this.userAgent,
    this.referer,
    this.altUrls = const [],
    this.autoRefreshHours = 0,
    this.epgOffsets = const {},
  });

  /// Kopie mit geänderten Feldern. Für nullbare Texte: '' = entfernen.
  Portal copyWith({
    String? name,
    String? url,
    String? username,
    String? password,
    String? epgUrl,
    bool clearEpgUrl = false,
    String? userAgent,
    String? referer,
    List<String>? altUrls,
    int? autoRefreshHours,
    Map<String, int>? epgOffsets,
  }) {
    String? nz(String? v, String? old) =>
        v == null ? old : (v.isEmpty ? null : v);
    return Portal(
      id: id,
      name: name ?? this.name,
      type: type,
      url: url ?? this.url,
      username: username ?? this.username,
      password: password ?? this.password,
      epgUrl: clearEpgUrl ? null : (epgUrl ?? this.epgUrl),
      userAgent: nz(userAgent, this.userAgent),
      referer: nz(referer, this.referer),
      altUrls: altUrls ?? this.altUrls,
      autoRefreshHours: autoRefreshHours ?? this.autoRefreshHours,
      epgOffsets: epgOffsets ?? this.epgOffsets,
    );
  }

  /// Erweiterte Felder als JSON (für verschlüsselten Speicher und Sicherung).
  Map<String, dynamic> extrasToJson() => {
        if (userAgent != null) 'ua': userAgent,
        if (referer != null) 'referer': referer,
        if (altUrls.isNotEmpty) 'alt': altUrls,
        if (autoRefreshHours > 0) 'autoRefresh': autoRefreshHours,
        if (epgOffsets.isNotEmpty) 'epgOffsets': epgOffsets,
      };

  /// Liest die erweiterten Felder (fehlend/ungültig → Standard) und setzt
  /// sie auf [base]. Alte Daten ohne diese Felder bleiben gültig.
  static Portal withExtras(Portal base, Map<dynamic, dynamic>? j) {
    if (j == null) return base;
    String? s(Object? v) => v is String && v.trim().isNotEmpty ? v.trim() : null;
    final alt = j['alt'];
    final offs = j['epgOffsets'];
    final hours = j['autoRefresh'];
    return Portal(
      id: base.id,
      name: base.name,
      type: base.type,
      url: base.url,
      username: base.username,
      password: base.password,
      epgUrl: base.epgUrl,
      userAgent: s(j['ua']),
      referer: s(j['referer']),
      altUrls: alt is List
          ? [for (final a in alt) if (s(a) != null) s(a)!]
          : const [],
      autoRefreshHours: hours is int && hours > 0 ? hours : 0,
      epgOffsets: offs is Map
          ? {
              for (final e in offs.entries)
                if (e.key is String && e.value is num)
                  e.key as String: (e.value as num).toInt(),
            }
          : const {},
    );
  }

  /// EPG-Quellen in Reihenfolge. „portal“ = EPG des Anbieters
  /// (Xtream: xmltv.php, M3U: url-tvg). Gespeichert zeilenweise in [epgUrl].
  List<String> get epgSources {
    final raw = epgUrl?.trim() ?? '';
    if (raw.isEmpty) return const ['portal'];
    return raw
        .split(RegExp(r'[\n|]+'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }

  /// Eingebautes Demo-Portal mit erfundenen Inhalten zum Ausprobieren.
  static const demo = Portal(
    id: '__demo',
    name: 'Demo-Portal',
    type: PortalType.demo,
    url: 'demo://',
  );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'type': type.name,
        'url': url,
        'username': username,
        'password': password,
        'epgUrl': epgUrl,
        ...extrasToJson(),
      };

  factory Portal.fromJson(Map<String, dynamic> j) => Portal.withExtras(
      Portal(
        id: j['id'] as String,
        name: j['name'] as String,
        type: PortalType.values.byName(j['type'] as String),
        url: j['url'] as String,
        username: j['username'] as String?,
        password: j['password'] as String?,
        epgUrl: j['epgUrl'] as String?,
      ),
      j);
}

/// Kontoinfos (Xtream user_info).
class AccountInfo {
  final String status;
  final DateTime? expires;
  final int maxConnections;
  final int activeConnections;

  const AccountInfo({
    required this.status,
    this.expires,
    this.maxConnections = 1,
    this.activeConnections = 0,
  });
}

class Category {
  final String id;
  final String name;
  const Category({required this.id, required this.name});
}

class Channel {
  final String id;
  final String name;
  final String? logoUrl;
  final String categoryId;
  final String streamUrl;

  /// EPG-Kennung (tvg-id bzw. epg_channel_id).
  final String? epgId;

  /// Catch-up/Timeshift-Tage, 0 = nicht verfügbar.
  final int catchupDays;
  final int number;

  /// M3U: catchup-Modus und -Vorlage (z. B. "shift", "default").
  final String? catchupMode;
  final String? catchupSource;

  /// M3U: eigene HTTP-Header des Senders (#EXTVLCOPT, #KODIPROP,
  /// „|User-Agent=…“) – nur User-Agent, Referer, Origin, Cookie.
  final Map<String, String>? headers;

  /// M3U tvg-shift: EPG-Versatz dieses Senders in Minuten.
  final int epgShift;

  const Channel({
    required this.id,
    required this.name,
    required this.categoryId,
    required this.streamUrl,
    this.logoUrl,
    this.epgId,
    this.catchupDays = 0,
    this.number = 0,
    this.catchupMode,
    this.catchupSource,
    this.headers,
    this.epgShift = 0,
  });

  bool get hasCatchup => catchupDays > 0;

  /// Kopie mit geänderten Feldern (für Sender-Überschreibungen).
  Channel copyWith({String? name, String? logoUrl, String? epgId}) => Channel(
        id: id,
        name: name ?? this.name,
        categoryId: categoryId,
        streamUrl: streamUrl,
        logoUrl: logoUrl ?? this.logoUrl,
        epgId: epgId ?? this.epgId,
        catchupDays: catchupDays,
        number: number,
        catchupMode: catchupMode,
        catchupSource: catchupSource,
        headers: headers,
        epgShift: epgShift,
      );

  /// [ChannelOverride] anwenden (Name, Logo, EPG-Kennung).
  Channel withOverride(ChannelOverride? o) {
    if (o == null || o.isEmpty) return this;
    return copyWith(
      name: (o.name == null || o.name!.trim().isEmpty) ? null : o.name!.trim(),
      logoUrl: (o.logoUrl == null || o.logoUrl!.trim().isEmpty)
          ? null
          : o.logoUrl!.trim(),
      // epgId: null = automatisch, '' = „Kein EPG“ (wird '@id'), sonst manuell.
      epgId: o.epgId,
    );
  }
}

/// Manuelle Anpassungen eines Senders (wie bei TiviMate): Name, Logo und
/// EPG-Zuordnung. null = Original beibehalten. Bei [epgId] bedeutet ''
/// „kein EPG“ (die automatische Zuordnung wird abgeschaltet).
class ChannelOverride {
  String? name;
  String? logoUrl;
  String? epgId;

  ChannelOverride({this.name, this.logoUrl, this.epgId});

  bool get isEmpty =>
      (name == null || name!.isEmpty) &&
      (logoUrl == null || logoUrl!.isEmpty) &&
      epgId == null;

  Map<String, dynamic> toJson() => {
        if (name != null && name!.isNotEmpty) 'name': name,
        if (logoUrl != null && logoUrl!.isNotEmpty) 'logo': logoUrl,
        if (epgId != null) 'epg': epgId,
      };

  factory ChannelOverride.fromJson(Map<String, dynamic> j) => ChannelOverride(
        name: j['name'] as String?,
        logoUrl: j['logo'] as String?,
        epgId: j['epg'] as String?,
      );
}

class EpgEntry {
  final String channelEpgId;
  final String title;
  final String? description;
  final String? genre;
  final DateTime start;
  final DateTime end;

  /// Vom Server als „im Archiv“ markiert (Xtream has_archive).
  final bool hasArchive;

  const EpgEntry({
    required this.channelEpgId,
    required this.title,
    required this.start,
    required this.end,
    this.description,
    this.genre,
    this.hasArchive = false,
  });

  Duration get duration => end.difference(start);
  bool isNowAt(DateTime t) => !t.isBefore(start) && t.isBefore(end);
  bool isPastAt(DateTime t) => !end.isAfter(t);
  double progressAt(DateTime t) {
    final total = duration.inSeconds;
    if (total <= 0) return 0;
    return (t.difference(start).inSeconds / total).clamp(0, 1).toDouble();
  }
}

/// Bewertung auf die 0–10-Skala bringen: manche Anbieter liefern 0–100
/// (z. B. „84“ → 8.4). ≤ 0, > 100 oder keine Zahl → null.
double? normalizeRating(Object? raw) {
  final r = raw is num ? raw.toDouble() : double.tryParse('${raw ?? ''}'.trim());
  if (r == null || r.isNaN || r <= 0 || r > 100) return null;
  return r > 10 ? r / 10 : r;
}

/// Herkunft eines Films/einer Serie: Portal (Xtream/Stalker/Demo) oder
/// der eigene Emby-/Jellyfin-Server (unabhängig vom aktiven Portal).
enum VodSource { portal, emby }

class VodItem {
  final String id;
  final String name;
  final String? posterUrl;
  final String? backdropUrl;
  final String categoryId;
  final String streamUrl;
  final double? rating;
  final int? year;
  final String? plot;
  final String? genre;
  final String? cast;
  final String? director;
  final Duration? duration;
  final DateTime? added;

  /// YouTube-Trailer (ID oder Adresse, wie vom Anbieter geliefert).
  final String? trailer;

  /// true = Serie (Folgen über seriesDetails), false = Film.
  final bool isSeries;

  /// Herkunft (Portal oder Emby). Emby-IDs beginnen mit `emby_`.
  final VodSource source;

  /// Emby: Stand des Servers (UserData) – gespeicherte Position und
  /// „gesehen“. Lokale Werte (Storage.resume/isWatched) haben Vorrang.
  final Duration? serverPosition;
  final bool serverPlayed;

  bool get isEmby => source == VodSource.emby;

  const VodItem({
    required this.id,
    required this.name,
    required this.categoryId,
    required this.streamUrl,
    this.posterUrl,
    this.backdropUrl,
    this.rating,
    this.year,
    this.plot,
    this.genre,
    this.cast,
    this.director,
    this.duration,
    this.added,
    this.trailer,
    this.isSeries = false,
    this.source = VodSource.portal,
    this.serverPosition,
    this.serverPlayed = false,
  });

  VodItem copyWith({
    String? plot,
    String? genre,
    String? cast,
    String? director,
    Duration? duration,
    String? backdropUrl,
    double? rating,
    int? year,
    String? trailer,
  }) =>
      VodItem(
        id: id,
        name: name,
        categoryId: categoryId,
        streamUrl: streamUrl,
        posterUrl: posterUrl,
        backdropUrl: backdropUrl ?? this.backdropUrl,
        rating: rating ?? this.rating,
        year: year ?? this.year,
        plot: plot ?? this.plot,
        genre: genre ?? this.genre,
        cast: cast ?? this.cast,
        director: director ?? this.director,
        duration: duration ?? this.duration,
        added: added,
        trailer: trailer ?? this.trailer,
        isSeries: isSeries,
        source: source,
        serverPosition: serverPosition,
        serverPlayed: serverPlayed,
      );

  /// Kopie mit neuem Server-Stand (Emby: Position, gesehen).
  VodItem withServerState({Duration? position, bool? played}) => VodItem(
        id: id,
        name: name,
        categoryId: categoryId,
        streamUrl: streamUrl,
        posterUrl: posterUrl,
        backdropUrl: backdropUrl,
        rating: rating,
        year: year,
        plot: plot,
        genre: genre,
        cast: cast,
        director: director,
        duration: duration,
        added: added,
        trailer: trailer,
        isSeries: isSeries,
        source: source,
        serverPosition: position ?? serverPosition,
        serverPlayed: played ?? serverPlayed,
      );
}

class Episode {
  final String id;
  final int season;
  final int number;
  final String title;
  final String streamUrl;
  final String? plot;
  final String? stillUrl;
  final Duration? duration;

  /// Emby: Stand des Servers (siehe [VodItem.serverPosition]).
  final Duration? serverPosition;
  final bool serverPlayed;

  const Episode({
    required this.id,
    required this.season,
    required this.number,
    required this.title,
    required this.streamUrl,
    this.plot,
    this.stillUrl,
    this.duration,
    this.serverPosition,
    this.serverPlayed = false,
  });
}

class SeriesDetails {
  final VodItem series;
  final String? cast;
  final Map<int, List<Episode>> seasons;

  const SeriesDetails({
    required this.series,
    required this.seasons,
    this.cast,
  });
}

/// Was der Player abspielen soll.
class PlayRequest {
  final String title;
  final String? subtitle;
  final String url;

  /// Live-TV: Zapping, kein Spulen.
  final bool isLive;
  final List<Channel>? channels;
  final Channel? channel;

  /// Schlüssel zum Merken der Position (Filme, Folgen, Catch-up).
  final String? resumeKey;

  /// Für die Hintergrundgrafik beim Laden.
  final String? artworkSeed;
  final String? artworkUrl;

  /// Replay einer Sendung (Catch-up) – mit [channel] und [channels], damit
  /// der Player zur vorherigen/nächsten Sendung oder zurück zu Live kann.
  final EpgEntry? replayEntry;

  /// Serienfolge: liefert die nächste Folge (für „Nächste Folge in 10 s“)
  /// oder null am Serienende.
  final Future<NextUp?> Function()? nextUp;

  /// Medienserver (Emby): Adresse erst beim Öffnen holen, Fortschritt melden.
  final RemotePlayback? remote;

  bool get isReplay => replayEntry != null;

  const PlayRequest({
    required this.title,
    required this.url,
    this.subtitle,
    this.isLive = false,
    this.channels,
    this.channel,
    this.resumeKey,
    this.artworkSeed,
    this.artworkUrl,
    this.replayEntry,
    this.nextUp,
    this.remote,
  });
}

/// Wiedergabe über einen Medienserver (Emby/Jellyfin): Der Player holt die
/// Abspieladresse erst beim Öffnen ([resolve]) und meldet Start,
/// Fortschritt (alle 10 s) und Ende an den Server.
abstract class RemotePlayback {
  /// [transcode]: Direktwiedergabe ist gescheitert → umgewandelter Stream.
  Future<RemoteMedia> resolve({bool transcode = false});
  Future<void> started(Duration position);
  Future<void> progress(Duration position, {required bool paused});
  Future<void> stopped(Duration position);
}

/// Ergebnis von [RemotePlayback.resolve].
class RemoteMedia {
  final String url;

  /// true = vom Server umgewandelt (HLS), false = Originaldatei.
  final bool transcoding;

  /// Gespeicherte Position auf dem Server (falls lokal keine bekannt).
  final Duration? startAt;
  final List<RemoteSubtitle> subtitles;

  /// Heruntergeladene Datei auf dem Gerät (Offline-Wiedergabe): file://
  /// bzw. content:// – von der App selbst erzeugt, daher erlaubt.
  final bool local;
  const RemoteMedia({
    required this.url,
    this.transcoding = false,
    this.startAt,
    this.subtitles = const [],
    this.local = false,
  });
}

/// Externe Untertitel-Datei (wird zusätzlich in den Player geladen).
class RemoteSubtitle {
  final String url;
  final String? language;
  final String? title;
  const RemoteSubtitle(this.url, {this.language, this.title});
}

/// Nächste Folge für den Player: Anzeige und Abspiel-Anfrage.
class NextUp {
  /// z. B. „S2 · F4 – Der Bruch“.
  final String label;
  final PlayRequest request;

  /// Beim Start der Folge (Verlauf aktualisieren).
  final void Function()? onStart;
  const NextUp({required this.label, required this.request, this.onStart});
}
