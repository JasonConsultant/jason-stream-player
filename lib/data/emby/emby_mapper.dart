import '../../models/models.dart';
import '../../core/languages.dart';
import 'emby_client.dart';

/// Emby-Titel als [VodItem]/[Episode] – damit Filme-/Serien-Seiten,
/// Details, Suche, Stöbern, Empfehlungen usw. sie wie Portal-Titel zeigen.
///
/// IDs bekommen das Präfix `emby_` (Weiterschauen, „gesehen“, Meine Liste
/// und Verlauf geraten so nie mit Portal-IDs durcheinander), Kategorien
/// sind die Mediatheken des Servers (`emby_<Mediathek-ID>`).
const embyPrefix = 'emby_';

String embyId(String raw) => '$embyPrefix$raw';
bool isEmbyId(String id) => id.startsWith(embyPrefix);

/// Server-ID zu einer App-ID (ohne Präfix bleibt sie unverändert).
String embyRaw(String id) =>
    isEmbyId(id) ? id.substring(embyPrefix.length) : id;

String embyCategoryId(String viewId) => '$embyPrefix$viewId';

Duration? ticksToDuration(Object? ticks) =>
    ticks is num && ticks > 0 ? Duration(microseconds: ticks ~/ 10) : null;

class EmbyMapper {
  final EmbyClient client;
  const EmbyMapper(this.client);

  static const posterWidth = 400;
  static const backdropWidth = 1280;
  static const stillWidth = 480;

  String? _tag(Map<String, dynamic> j, String type) {
    final tags = j['ImageTags'];
    final t = tags is Map ? tags[type] : null;
    return t is String && t.isNotEmpty ? t : null;
  }

  String? poster(Map<String, dynamic> j) {
    final id = j['Id'] as String?;
    if (id == null) return null;
    final tag = _tag(j, 'Primary');
    return tag == null
        ? null
        : client.imageUrl(id, 'Primary', tag: tag, maxWidth: posterWidth);
  }

  String? backdrop(Map<String, dynamic> j) {
    final id = j['Id'] as String?;
    final tags = j['BackdropImageTags'];
    if (id != null && tags is List && tags.isNotEmpty && tags.first is String) {
      return client.imageUrl(id, 'Backdrop',
          tag: tags.first as String, maxWidth: backdropWidth, index: 0);
    }
    // Folgen/Serien aus „Weiterschauen“: Hintergrund der Serie.
    final pid = j['ParentBackdropItemId'];
    final ptags = j['ParentBackdropImageTags'];
    if (pid is String && ptags is List && ptags.isNotEmpty && ptags.first is String) {
      return client.imageUrl(pid, 'Backdrop',
          tag: ptags.first as String, maxWidth: backdropWidth, index: 0);
    }
    return null;
  }

  static String? _people(Object? people, String type, {int max = 10}) {
    if (people is! List) return null;
    final names = <String>[
      for (final p in people)
        if (p is Map && p['Type'] == type && p['Name'] is String &&
            (p['Name'] as String).trim().isNotEmpty)
          (p['Name'] as String).trim(),
    ];
    if (names.isEmpty) return null;
    return (names.length > max ? names.sublist(0, max) : names).join(', ');
  }

  static ({Duration? position, bool played}) userData(Map<String, dynamic> j) {
    final u = j['UserData'];
    if (u is! Map) return (position: null, played: false);
    return (
      position: ticksToDuration(u['PlaybackPositionTicks']),
      played: u['Played'] == true,
    );
  }

  static String? _trailer(Object? trailers) {
    if (trailers is! List) return null;
    for (final t in trailers) {
      if (t is Map && t['Url'] is String && (t['Url'] as String).isNotEmpty) {
        return t['Url'] as String;
      }
    }
    return null;
  }

  /// Film oder Serie.
  VodItem item(Map<String, dynamic> j, {required String categoryId}) {
    final id = j['Id'] as String;
    final genres = j['Genres'];
    final ud = userData(j);
    final year = j['ProductionYear'];
    return VodItem(
      id: embyId(id),
      name: (j['Name'] as String?)?.trim().isNotEmpty == true
          ? (j['Name'] as String).trim()
          : '?',
      posterUrl: poster(j),
      backdropUrl: backdrop(j),
      categoryId: categoryId,
      // Abspieladresse entsteht erst beim Abspielen (PlaybackInfo) – so
      // steht kein Token im Zwischenspeicher.
      streamUrl: '',
      rating: normalizeRating(j['CommunityRating']),
      year: year is int && year > 0 ? year : null,
      plot: (j['Overview'] as String?)?.trim().isNotEmpty == true
          ? (j['Overview'] as String).trim()
          : null,
      genre: genres is List && genres.isNotEmpty
          ? genres.whereType<String>().join(', ')
          : null,
      cast: _people(j['People'], 'Actor'),
      director: _people(j['People'], 'Director', max: 3),
      duration: ticksToDuration(j['RunTimeTicks']),
      added: DateTime.tryParse('${j['DateCreated'] ?? ''}')?.toLocal(),
      trailer: _trailer(j['RemoteTrailers']),
      isSeries: j['Type'] == 'Series',
      source: VodSource.emby,
      serverPosition: ud.position,
      serverPlayed: ud.played,
    );
  }

  /// Serie zu einer Folge (für „Weiterschauen“ auf der Startseite).
  VodItem seriesOfEpisode(Map<String, dynamic> j, {String categoryId = ''}) {
    final sid = j['SeriesId'] as String;
    final tag = j['SeriesPrimaryImageTag'];
    return VodItem(
      id: embyId(sid),
      name: (j['SeriesName'] as String?) ?? (j['Name'] as String? ?? '?'),
      posterUrl: tag is String && tag.isNotEmpty
          ? client.imageUrl(sid, 'Primary', tag: tag, maxWidth: posterWidth)
          : null,
      backdropUrl: backdrop(j),
      categoryId: categoryId,
      streamUrl: '',
      isSeries: true,
      source: VodSource.emby,
    );
  }

  Episode episode(Map<String, dynamic> j, {int? seasonFallback}) {
    final ud = userData(j);
    final season = j['ParentIndexNumber'];
    final number = j['IndexNumber'];
    final id = j['Id'] as String;
    final tag = _tag(j, 'Primary');
    return Episode(
      id: embyId(id),
      season: season is int ? season : (seasonFallback ?? 1),
      number: number is int ? number : 0,
      title: (j['Name'] as String?)?.trim() ?? '',
      streamUrl: '',
      plot: (j['Overview'] as String?)?.trim().isNotEmpty == true
          ? (j['Overview'] as String).trim()
          : null,
      stillUrl: tag == null
          ? null
          : client.imageUrl(id, 'Primary', tag: tag, maxWidth: stillWidth),
      duration: ticksToDuration(j['RunTimeTicks']),
      serverPosition: ud.position,
      serverPlayed: ud.played,
    );
  }
}

// ---------------------------------------------------------------------------
// Abspielweg wählen
// ---------------------------------------------------------------------------

/// Gewählter Abspielweg für einen Titel.
class EmbyStreamChoice {
  final String url;
  final bool transcoding;
  final String mediaSourceId;
  final String? playSessionId;
  final List<RemoteSubtitle> subtitles;
  final int? audioStreamIndex;
  const EmbyStreamChoice({
    required this.url,
    required this.transcoding,
    required this.mediaSourceId,
    this.playSessionId,
    this.subtitles = const [],
    this.audioStreamIndex,
  });

  String get playMethod => transcoding ? 'Transcode' : 'DirectStream';
}

/// Index der Tonspur in der bevorzugten Sprache ([pref] wie Einstellung
/// „Tonspur“: 'auto' = Standard des Servers).
int? preferredAudioIndex(List<Map<String, dynamic>> streams, String pref) {
  if (pref == 'auto' || pref == 'off') return null;
  final lang = TrackLanguage.byCode(pref);
  if (lang == null) return null;
  for (final s in streams) {
    if (s['Type'] != 'Audio' || s['Index'] is! int) continue;
    if (lang.matches(s['Language'] as String?, s['DisplayTitle'] as String?)) {
      return s['Index'] as int;
    }
  }
  return null;
}

const _textSubs = {'srt', 'subrip', 'ass', 'ssa', 'vtt', 'webvtt', 'sub', 'smi', 'mov_text', 'ttml'};

/// Wählt aus der PlaybackInfo-Antwort: Direktwiedergabe der Originaldatei,
/// wenn der Server sie erlaubt, der Container passt und die Bitrate unter
/// [maxBitrate] liegt – sonst HLS-Umwandlung (H.264/AAC).
/// [forceTranscode]: Direktwiedergabe ist im Player gescheitert.
EmbyStreamChoice chooseEmbyStream(
  EmbyClient c,
  String itemId,
  Map<String, dynamic> info, {
  int? maxBitrate,
  bool forceTranscode = false,
  String audioPref = 'auto',
}) {
  final sources = info['MediaSources'];
  if (sources is! List || sources.isEmpty || sources.first is! Map) {
    throw const EmbyException(EmbyErrorKind.server, status: 0);
  }
  final src = (sources.first as Map).cast<String, dynamic>();
  final msid = (src['Id'] as String?) ?? itemId;
  final session = info['PlaySessionId'] as String?;
  final container = (src['Container'] as String?)?.toLowerCase();
  final streams = [
    for (final s in (src['MediaStreams'] as List? ?? const []))
      if (s is Map) s.cast<String, dynamic>(),
  ];
  final audio = preferredAudioIndex(streams, audioPref);
  final bitrate = src['Bitrate'];
  final containerOk = container != null &&
      container.split(',').any(EmbyClient.directContainers.contains);
  final serverAllows =
      src['SupportsDirectPlay'] == true || src['SupportsDirectStream'] == true;
  final bitrateOk =
      maxBitrate == null || bitrate is! num || bitrate <= maxBitrate;
  final direct = !forceTranscode && serverAllows && containerOk && bitrateOk;

  final String url;
  if (direct) {
    url = c.directUrl(itemId,
        mediaSourceId: msid,
        container: container.split(',').first,
        playSessionId: session);
  } else {
    final t = src['TranscodingUrl'];
    url = t is String && t.isNotEmpty && !forceTranscode && audio == null
        ? c.absolute(t)
        : c.transcodeUrl(itemId,
            mediaSourceId: msid,
            playSessionId: session,
            maxBitrate: maxBitrate,
            audioStreamIndex: audio);
  }
  // Direkt: eingebettete Untertitel liefert die Datei selbst, externe
  // Dateien kommen dazu. Umgewandelt: alle Text-Untertitel als SRT.
  final subs = <RemoteSubtitle>[
    for (final s in streams)
      if (s['Type'] == 'Subtitle' &&
          s['Index'] is int &&
          (s['IsExternal'] == true ||
              (!direct &&
                  (s['IsTextSubtitleStream'] == true ||
                      _textSubs.contains('${s['Codec']}'.toLowerCase())))))
        RemoteSubtitle(c.subtitleUrl(itemId, msid, s['Index'] as int),
            language: s['Language'] as String?,
            title: (s['DisplayTitle'] ?? s['Title']) as String?),
  ];
  return EmbyStreamChoice(
    url: url,
    transcoding: !direct,
    mediaSourceId: msid,
    playSessionId: session,
    subtitles: subs,
    audioStreamIndex: audio,
  );
}

/// Einstellung „Max. Streaming-Bitrate“ → Bit/s (null = automatisch).
int? embyBitrateOf(String option) => switch (option) {
      '20' => 20000000,
      '10' => 10000000,
      '4' => 4000000,
      _ => null,
    };
