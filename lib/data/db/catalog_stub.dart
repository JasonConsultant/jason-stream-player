import '../../models/models.dart';
import 'db_types.dart';

export 'db_types.dart';

/// Ohne Dateisystem (Web-Vorschau): keine Datenbank – alles wie vor 2.0
/// im Speicher.
class Catalog {
  Catalog._();
  static const supported = false;
  static const fileName = 'databases/catalog.db';
  static Future<String?> path() async => null;
  static void closeWorker() {}
  static Future<bool> hasList(String portal, String kind) async => false;
  static Future<List<String>> searchChannelIds(String portal, String q) async =>
      const [];
  static Future<List<String>> searchVodIds(
          String portal, String kind, String q) async =>
      const [];
  static Future<List<String>> searchVodPeopleIds(
          String portal, String kind, String q) async =>
      const [];
  static Future<bool> setSearchChannels(Map<String, bool> keys) async => false;
  static Future<List<EpgHit>?> searchEpg(String portal, String q,
          {required int now,
          required int from,
          required int to,
          int limit = 60}) async =>
      null;
  static Future<EpgDbInfo?> epgInfo(String portal) async => null;
  static Future<Map<String, List<EpgEntry>>?> epgChannels(
          String portal, List<String> keys,
          {int? from, int? to}) async =>
      null;
  static Future<Map<String, List<EpgEntry>>?> epgWindow(
          String portal, int from, int to) async =>
      null;
  static Future<int> countChannels(String portal, {String? category}) async =>
      0;
  static Future<List<Channel>> channelWindow(String portal,
          {String? category,
          required int offset,
          required int limit,
          String Function(String)? restore}) async =>
      const [];
  static Future<int> countVod(String portal, String kind,
          {String? category}) async =>
      0;
  static Future<List<VodItem>> vodWindow(String portal, String kind,
          {String? category,
          required int offset,
          required int limit,
          String Function(String)? restore}) async =>
      const [];
  static Future<bool> deleteEpg(String portal) async => false;

  static Future<bool> deletePortal(String portal) async => false;
  static Future<List<String>> portalsWithData() async => const [];
}
