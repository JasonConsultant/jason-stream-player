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

  const Portal({
    required this.id,
    required this.name,
    required this.type,
    required this.url,
    this.username,
    this.password,
    this.epgUrl,
  });

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
      };

  factory Portal.fromJson(Map<String, dynamic> j) => Portal(
        id: j['id'] as String,
        name: j['name'] as String,
        type: PortalType.values.byName(j['type'] as String),
        url: j['url'] as String,
        username: j['username'] as String?,
        password: j['password'] as String?,
        epgUrl: j['epgUrl'] as String?,
      );
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

  /// true = Serie (Folgen über seriesDetails), false = Film.
  final bool isSeries;

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
    this.isSeries = false,
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
        isSeries: isSeries,
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

  const Episode({
    required this.id,
    required this.season,
    required this.number,
    required this.title,
    required this.streamUrl,
    this.plot,
    this.stillUrl,
    this.duration,
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
  });
}
