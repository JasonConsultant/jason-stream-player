import '../../models/models.dart';

/// Zustand eines Downloads.
enum DownloadState {
  /// Wartet auf einen freien Platz in der Warteschlange.
  queued,
  running,

  /// Vom Nutzer angehalten.
  paused,

  /// Wartet auf eine Bedingung ([DownloadWait]) – läuft danach von selbst.
  waiting,
  done,
  failed;

  static DownloadState byName(String? n) => DownloadState.values
      .firstWhere((s) => s.name == n, orElse: () => DownloadState.queued);

  bool get active =>
      this == queued || this == running || this == waiting;
}

/// Warum ein Download gerade nicht läuft.
enum DownloadWait {
  none,

  /// Keine Verbindung.
  network,

  /// Nur Mobilfunk – Downloads nur über WLAN eingestellt.
  cellular,

  /// Datensparmodus wirksam (gemessene Verbindung).
  dataSaver,

  /// Zu wenig Speicherplatz.
  space,

  /// Alle erlaubten Anbieter-Verbindungen belegt.
  connections,

  /// Nach einem Fehler: neuer Versuch gleich.
  retry;

  static DownloadWait byName(String? n) => DownloadWait.values
      .firstWhere((s) => s.name == n, orElse: () => DownloadWait.none);
}

/// Externe Untertitel-Datei (Emby/Jellyfin), mit dem Film geladen.
class DownloadSub {
  /// Adresse mit Platzhaltern statt Zugangsdaten (siehe [UrlVault]).
  final String maskedUrl;
  final String? language;
  final String? title;

  /// Lokale Datei (Pfad oder content://), sobald geladen.
  final String? path;

  const DownloadSub(
      {required this.maskedUrl, this.language, this.title, this.path});

  DownloadSub withPath(String? p) => DownloadSub(
      maskedUrl: maskedUrl, language: language, title: title, path: p);

  Map<String, Object?> toJson() => {
        'u': maskedUrl,
        if (language != null) 'l': language,
        if (title != null) 't': title,
        if (path != null) 'p': path,
      };

  static DownloadSub? fromJson(Object? j) {
    if (j is! Map || j['u'] is! String) return null;
    return DownloadSub(
      maskedUrl: j['u'] as String,
      language: j['l'] as String?,
      title: j['t'] as String?,
      path: j['p'] as String?,
    );
  }
}

/// Ein heruntergeladener (oder zu ladender) Film bzw. eine Folge.
///
/// Die Adresse wird nur mit Platzhaltern gespeichert ([maskedUrl]); die
/// Zugangsdaten setzt erst der Download zur Laufzeit ein.
class DownloadItem {
  /// Eindeutig je Quelle: `<scope>|<itemId>`.
  final String id;

  /// Portal-ID bzw. `__emby` (portalunabhängig).
  final String scope;
  final VodSource source;

  /// Film- bzw. Folgen-ID (wie in [VodItem.id]/[Episode.id]).
  final String itemId;
  final bool isEpisode;

  /// Serie (bei Folgen).
  final String? seriesId;
  final String? seriesName;
  final int season;
  final int episode;

  /// Anzeigename (Film bzw. Folgentitel).
  final String title;
  final String? posterUrl;

  /// Kategorie des Films bzw. der Serie (Kinderschutz-Freigaben).
  final String categoryId;

  /// Erwachsenen-Kategorie (beim Hinzufügen erkannt).
  final bool adult;

  final String maskedUrl;

  /// Dateiendung ohne Punkt (mkv, mp4, …).
  final String ext;

  /// Zieldatei: Pfad im App-Ordner oder content://-Dokument (SAF).
  final String? path;

  /// SAF-Ordner (USB/Netzlaufwerk), falls dort gespeichert wird.
  final String? tree;

  final int bytes;

  /// Gesamtgröße in Bytes, -1 = unbekannt.
  final int total;
  final DownloadState state;
  final DownloadWait wait;

  /// Fehlercode (siehe [downloadErrorText]) – nie mit Zugangsdaten.
  final String? error;

  /// Kann der Server ab einer Position weiterliefern (HTTP 206)?
  final bool? rangeOk;
  final DateTime added;
  final Duration? duration;
  final List<DownloadSub> subs;

  /// Fehlversuche in Folge (für die Wartezeit bis zum nächsten Versuch).
  final int attempts;

  const DownloadItem({
    required this.id,
    required this.scope,
    required this.source,
    required this.itemId,
    required this.title,
    required this.categoryId,
    required this.maskedUrl,
    required this.ext,
    required this.added,
    this.isEpisode = false,
    this.seriesId,
    this.seriesName,
    this.season = 0,
    this.episode = 0,
    this.posterUrl,
    this.adult = false,
    this.path,
    this.tree,
    this.bytes = 0,
    this.total = -1,
    this.state = DownloadState.queued,
    this.wait = DownloadWait.none,
    this.error,
    this.rangeOk,
    this.duration,
    this.subs = const [],
    this.attempts = 0,
  });

  static String idOf(String scope, String itemId) => '$scope|$itemId';

  /// Schlüssel für „Weiterschauen“ – derselbe wie online.
  String get resumeKey => isEpisode ? 'ep_$itemId' : 'movie_$itemId';

  bool get isEmby => source == VodSource.emby;

  /// 0…1, null = unbekannt.
  double? get progress => total > 0 ? (bytes / total).clamp(0.0, 1.0) : null;

  /// Restliche Bytes (null = unbekannt).
  int? get remaining => total > 0 ? (total - bytes).clamp(0, total) : null;

  DownloadItem copyWith({
    String? path,
    String? tree,
    int? bytes,
    int? total,
    DownloadState? state,
    DownloadWait? wait,
    String? error,
    bool clearError = false,
    bool? rangeOk,
    List<DownloadSub>? subs,
    int? attempts,
    String? maskedUrl,
    String? ext,
  }) =>
      DownloadItem(
        id: id,
        scope: scope,
        source: source,
        itemId: itemId,
        isEpisode: isEpisode,
        seriesId: seriesId,
        seriesName: seriesName,
        season: season,
        episode: episode,
        title: title,
        posterUrl: posterUrl,
        categoryId: categoryId,
        adult: adult,
        maskedUrl: maskedUrl ?? this.maskedUrl,
        ext: ext ?? this.ext,
        path: path ?? this.path,
        tree: tree ?? this.tree,
        bytes: bytes ?? this.bytes,
        total: total ?? this.total,
        state: state ?? this.state,
        wait: wait ?? (state != null && state != DownloadState.waiting
            ? DownloadWait.none
            : this.wait),
        error: clearError ? null : (error ?? this.error),
        rangeOk: rangeOk ?? this.rangeOk,
        added: added,
        duration: duration,
        subs: subs ?? this.subs,
        attempts: attempts ?? this.attempts,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'sc': scope,
        'src': source.name,
        'item': itemId,
        if (isEpisode) 'ep': true,
        if (seriesId != null) 'sid': seriesId,
        if (seriesName != null) 'sn': seriesName,
        if (season != 0) 's': season,
        if (episode != 0) 'e': episode,
        't': title,
        if (posterUrl != null) 'img': posterUrl,
        'cat': categoryId,
        if (adult) 'adult': true,
        'u': maskedUrl,
        'x': ext,
        if (path != null) 'p': path,
        if (tree != null) 'tree': tree,
        'b': bytes,
        'tot': total,
        // Läuft gerade → beim nächsten Start wieder in die Warteschlange.
        'st': state == DownloadState.running ? DownloadState.queued.name : state.name,
        if (wait != DownloadWait.none) 'w': wait.name,
        if (error != null) 'err': error,
        if (rangeOk != null) 'range': rangeOk,
        'add': added.millisecondsSinceEpoch,
        if (duration != null) 'dur': duration!.inSeconds,
        if (subs.isNotEmpty) 'subs': [for (final s in subs) s.toJson()],
        if (attempts > 0) 'try': attempts,
      };

  static DownloadItem? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final j = raw.cast<String, Object?>();
    String? s(String k) => j[k] is String ? j[k] as String : null;
    int i(String k, [int f = 0]) => j[k] is num ? (j[k] as num).toInt() : f;
    final id = s('id'), scope = s('sc'), item = s('item'), url = s('u');
    if (id == null || scope == null || item == null || url == null) return null;
    return DownloadItem(
      id: id,
      scope: scope,
      source: s('src') == VodSource.emby.name ? VodSource.emby : VodSource.portal,
      itemId: item,
      isEpisode: j['ep'] == true,
      seriesId: s('sid'),
      seriesName: s('sn'),
      season: i('s'),
      episode: i('e'),
      title: s('t') ?? '',
      posterUrl: s('img'),
      categoryId: s('cat') ?? '',
      adult: j['adult'] == true,
      maskedUrl: url,
      ext: s('x') ?? 'mkv',
      path: s('p'),
      tree: s('tree'),
      bytes: i('b'),
      total: i('tot', -1),
      state: DownloadState.byName(s('st')),
      wait: DownloadWait.byName(s('w')),
      error: s('err'),
      rangeOk: j['range'] is bool ? j['range'] as bool : null,
      added: DateTime.fromMillisecondsSinceEpoch(i('add')),
      duration: j['dur'] is num ? Duration(seconds: i('dur')) : null,
      subs: [
        if (j['subs'] is List)
          for (final x in j['subs'] as List)
            if (DownloadSub.fromJson(x) != null) DownloadSub.fromJson(x)!,
      ],
      attempts: i('try'),
    );
  }
}

/// Dateiname für einen Download (ohne problematische Zeichen).
String downloadFileName(DownloadItem d) {
  String clean(String s) => s
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  String two(int n) => n.toString().padLeft(2, '0');
  final base = d.isEpisode
      ? '${clean(d.seriesName ?? '')} S${two(d.season)}E${two(d.episode)} '
          '${clean(d.title)}'
      : clean(d.title);
  // Kennung anhängen: zwei Titel mit gleichem Namen überschreiben sich nicht.
  final tag = d.itemId.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
  final shortTag = tag.length > 12 ? tag.substring(tag.length - 12) : tag;
  var name = '${base.trim()} [$shortTag]';
  if (name.length > 140) name = name.substring(0, 140);
  return '$name.${d.ext}';
}

/// Dateiendung aus einer Stream-Adresse (Xtream: `…/123.mkv`), sonst null.
String? extOfUrl(String url) {
  final path = Uri.tryParse(url)?.path ?? url;
  final m = RegExp(r'\.([A-Za-z0-9]{2,5})$').firstMatch(path);
  return m?.group(1)?.toLowerCase();
}

/// Endungen, die als einzelne Datei heruntergeladen werden können
/// (keine Wiedergabelisten wie HLS/DASH).
const downloadableExts = {
  'mkv', 'mp4', 'm4v', 'avi', 'mov', 'ts', 'mpg', 'mpeg', 'webm', 'wmv',
  'flv', '3gp', 'm2ts', 'divx', 'xvid', 'ogv', 'vob',
};

/// Ob eine Portal-Adresse direkt als Datei geladen werden kann.
bool isDownloadableUrl(String url) {
  final u = Uri.tryParse(url);
  if (u == null || (u.scheme != 'http' && u.scheme != 'https')) return false;
  final ext = extOfUrl(url);
  return ext != null && downloadableExts.contains(ext);
}
