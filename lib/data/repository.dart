import '../models/models.dart';
import 'epg_matcher.dart';
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
      {Set<String>? channelIds, List<Channel>? channels, EpgProgress? progress});

  /// EPG eines Senders inklusive vergangener Sendungen (für Catch-up).
  /// Standard: aus dem kompletten EPG.
  Future<List<EpgEntry>> channelEpg(
      Channel c, Map<String, List<EpgEntry>> fullEpg) async {
    return epgOf(fullEpg, c);
  }

  /// EPG-Adresse des Anbieters (Xtream: xmltv.php, M3U: url-tvg).
  Future<String?> providerEpgUrl() async => null;

  /// Lädt alle EPG-Quellen des Portals ([Portal.epgSources]) nacheinander
  /// und führt sie zusammen – frühere Quellen haben Vorrang.
  Future<Map<String, List<EpgEntry>>> loadXmltvSources(
      {Set<String>? channelIds,
      List<Channel>? channels,
      EpgProgress? progress}) async {
    final sources = portal.epgSources;
    final out = <String, List<EpgEntry>>{};
    Object? firstError;
    for (var i = 0; i < sources.length; i++) {
      final url =
          sources[i] == 'portal' ? await providerEpgUrl() : sources[i];
      if (url == null || url.isEmpty) continue;
      try {
        final m = await XmltvParser.load(Uri.parse(url),
            channelIds: channelIds,
            channels: channels,
            onProgress: (b, t) =>
                progress?.call((i + 1, sources.length, b, t, false)),
            onParsing: () =>
                progress?.call((i + 1, sources.length, 0, null, true)));
        for (final e in m.entries) {
          final prev = out[e.key];
          if (prev == null || prev.isEmpty) out[e.key] = e.value;
        }
      } catch (e) {
        firstError ??= e;
      }
    }
    if (out.isEmpty && firstError != null) throw firstError;
    return out;
  }

  /// Kurz-Programm (jetzt + nächste Sendungen) direkt vom Portal – Ersatz,
  /// wenn das große EPG für diesen Sender nichts liefert. Standard: nichts.
  Future<List<EpgEntry>> shortEpg(Channel c) async => const [];

  /// Endgültige Abspiel-Adresse. Standard: [Channel.streamUrl].
  /// Stalker-Portale erzeugen hier kurzlebige Links (create_link).
  Future<String> resolveStreamUrl(Channel c) async => c.streamUrl;

  /// Stream-URL für eine vergangene Sendung oder null, wenn nicht möglich.
  String? catchupUrl(Channel c, EpgEntry e);

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
  RepositoryException(this.message);
  @override
  String toString() => message;
}
