import '../models/models.dart';
import 'epg_matcher.dart';
import 'list_cache.dart';
import 'epg_window.dart';
import 'stream_headers.dart';
import 'xmltv_parser.dart';
import 'demo_repository.dart';
import 'm3u_repository.dart';
import 'stalker_repository.dart';
import 'xtream_repository.dart';

/// Gemeinsame Schnittstelle für alle Quellen (Xtream, M3U, Demo).
/// Fortschritt beim EPG-Laden: Quelle i von n, geladene Bytes, Gesamtgröße
/// (falls bekannt), true = wird verarbeitet.
typedef EpgProgress = void Function(
    (int source, int sources, int bytes, int? total, bool parsing) p);

abstract class IptvRepository {
  Portal get portal;

  /// Nach [connect] gesetzt (nur Xtream liefert Kontoinfos).
  AccountInfo? account;

  Future<void> connect() async {
    account = await login();
  }

  /// Prüft den Zugang. Liefert Kontoinfos, wenn die Quelle welche kennt.
  Future<AccountInfo?> login();

  // ---------- Live ----------
  Future<List<Category>> liveCategories();
  Future<List<Channel>> liveChannels();

  /// Komplettes EPG als Map epgId → Sendungen (sortiert).
  /// [channelIds]: nur Sendungen dieser EPG-Kennungen behalten (spart viel
  /// Zeit und Speicher bei großen EPGs). null = alle.
  Future<Map<String, List<EpgEntry>>> loadEpg(
      {Set<String>? channelIds,
      List<Channel>? channels,
      EpgProgress? progress});

  /// EPG eines Senders inklusive vergangener Sendungen (für Catch-up).
  /// Standard: aus dem kompletten EPG.
  Future<List<EpgEntry>> channelEpg(
      Channel c, Map<String, List<EpgEntry>> fullEpg) async {
    return epgOf(fullEpg, c);
  }

  /// EPG-Adresse(n) des Anbieters (Xtream: xmltv.php, M3U: url-tvg –
  /// dort auch mehrere, durch Komma getrennt).
  Future<String?> providerEpgUrl() async => null;

  /// Viele Playlisten nennen Dutzende Länder-EPGs (z. B. Free-TV). Alle zu
  /// laden würde ewig dauern – nur die Länder der Sender nehmen
  /// (Endung der EPG-Kennung: „ZDF.de“ → DE), höchstens [max].
  static List<String> pickEpgUrls(List<String> urls, List<Channel>? channels,
      {int max = 4}) {
    final useful = urls
        .where((u) =>
            !RegExp(r'ALL_SOURCES|DUMMY', caseSensitive: false).hasMatch(u))
        .toList();
    if (useful.length <= max || channels == null) return useful;
    final count = <String, int>{};
    for (final c in channels) {
      final m = RegExp(r'\.([a-z]{2})$', caseSensitive: false)
          .firstMatch(c.epgId ?? '');
      if (m == null) continue;
      var cc = m.group(1)!.toUpperCase();
      if (cc == 'GB') cc = 'UK';
      count[cc] = (count[cc] ?? 0) + 1;
    }
    final top = (count.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value)))
        .take(max)
        .map((e) => e.key)
        .toSet();
    final codeOf = RegExp(r'ripper_([A-Z]{2})\d*\.xml', caseSensitive: false);
    final picked = useful.where((u) {
      final m = codeOf.firstMatch(u);
      return m != null && top.contains(m.group(1)!.toUpperCase());
    }).toList();
    return picked.isEmpty ? useful.take(max).toList() : picked;
  }

  /// Lädt alle EPG-Quellen des Portals ([Portal.epgSources]) nacheinander
  /// und führt sie zusammen – frühere Quellen haben Vorrang.
  Future<Map<String, List<EpgEntry>>> loadXmltvSources(
      {Set<String>? channelIds,
      List<Channel>? channels,
      EpgProgress? progress,
      Map<String, int>? shifts}) async {
    // (Adresse, Zeitversatz in Minuten) – der Versatz gehört zur Quelle,
    // wie sie in den EPG-Quellen steht („portal“ für alle Anbieter-EPGs).
    final sources = <(String, int)>[];
    for (final src in portal.epgSources) {
      final offset = EpgWindow.clampOffset(portal.epgOffsets[src] ?? 0);
      if (src != 'portal') {
        sources.add((src, offset));
        continue;
      }
      final raw = await providerEpgUrl();
      if (raw == null || raw.isEmpty) continue;
      for (final u in pickEpgUrls(
          raw
              .split(',')
              .map((e) => e.trim())
              .where((e) => e.isNotEmpty)
              .toList(),
          channels)) {
        sources.add((u, offset));
      }
    }
    // Alles (Laden, Parsen, Zusammenführen, Obergrenze, Kodieren für den
    // Zwischenspeicher) in einem Hintergrund-Isolate.
    final n = sources.length;
    return XmltvParser.loadSources(sources,
        channelIds: channelIds,
        channels: channels,
        headers: portalHeaders(portal),
        shifts: shifts,
        onProgress: (i, b, t) => progress?.call((i + 1, n, b, t, false)),
        onParsing: (i) => progress?.call((i + 1, n, 0, null, true)));
  }

  /// Kurz-Programm (jetzt + nächste Sendungen) direkt vom Portal – Ersatz,
  /// wenn das große EPG für diesen Sender nichts liefert. Standard: nichts.
  Future<List<EpgEntry>> shortEpg(Channel c) async => const [];

  /// Endgültige Abspiel-Adresse. Standard: [Channel.streamUrl].
  /// Stalker-Portale erzeugen hier kurzlebige Links (create_link).
  Future<String> resolveStreamUrl(Channel c) async => c.streamUrl;

  /// Stream-URL für eine vergangene Sendung oder null, wenn nicht möglich.
  String? catchupUrl(Channel c, EpgEntry e);

  /// Kategorien + Sender laden und (mit [cache]) im Hintergrund prüfen und
  /// speichern. Unverändert gegenüber [CacheSpec.prevHash] →
  /// [ListOutcome.unchanged]. Standard: Objekte laden, Kodieren/Speichern
  /// im Isolate; Xtream erledigt auch Dekodieren und Umwandeln dort.
  Future<ListOutcome<Channel>> liveBundle(CacheSpec? cache) async {
    final (cats, chans) = await (liveCategories(), liveChannels()).wait;
    if (cache == null) return ListOutcome(cats, chans, '');
    return ListCache.storeLive(cache, cats, chans);
  }

  /// Wie [liveBundle] für Filme ([series] = false) bzw. Serien.
  Future<ListOutcome<VodItem>> vodBundle(bool series, CacheSpec? cache) async {
    final (cats, items) = series
        ? await (seriesCategories(), this.series()).wait
        : await (movieCategories(), movies()).wait;
    if (cache == null) return ListOutcome(cats, items, '');
    return ListCache.storeVod(cache, cats, items);
  }

  // ---------- Filme ----------
  bool get supportsVod;
  Future<List<Category>> movieCategories() async => const [];
  Future<List<VodItem>> movies() async => const [];
  Future<VodItem> movieDetails(VodItem m) async => m;

  // ---------- Serien ----------
  Future<List<Category>> seriesCategories() async => const [];
  Future<List<VodItem>> series() async => const [];
  Future<SeriesDetails> seriesDetails(VodItem s) async =>
      SeriesDetails(series: s, seasons: const {});

  static IptvRepository forPortal(Portal p) => switch (p.type) {
        PortalType.xtream => XtreamRepository(p),
        PortalType.m3u => M3uRepository(p),
        PortalType.stalker => StalkerRepository(p),
        PortalType.demo => DemoRepository(p),
      };
}

class RepositoryException implements Exception {
  final String message;

  /// HTTP-Status, falls der Fehler eine Server-Antwort war.
  final int? statusCode;
  RepositoryException(this.message, {this.statusCode});
  @override
  String toString() => message;
}
