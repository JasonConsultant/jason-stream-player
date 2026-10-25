import '../../models/models.dart';
import 'catalog_io.dart' show withCatalog;
import 'db_io.dart' as dbi;
import 'db_types.dart';

/// Synchrone Datenbank-Aufrufe für Hintergrund-Isolates (Listen-/EPG-
/// Abgleich). Jede Funktion öffnet eine eigene Verbindung über [path].

bool syncHasList(String path, String portal, String kind) =>
    withCatalog(path, (db) => dbi.hasList(db, portal, kind));

DbList<Channel>? syncReadLive(String path, String portal, String fp,
        String Function(String) restore) =>
    withCatalog(
        path, (db) => dbi.readLive(db, portal, fp: fp, restore: restore));

DbList<VodItem>? syncReadVod(String path, String portal, String kind, String fp,
        String Function(String) restore) =>
    withCatalog(
        path, (db) => dbi.readVod(db, portal, kind, fp: fp, restore: restore));

void syncWriteLive(String path, String portal,
        {required String fp,
        required String? hash,
        required DateTime saved,
        required List<Category> cats,
        required List<Channel> items,
        required String Function(String) mask,
        bool onlyIfMissing = false}) =>
    withCatalog(
        path,
        (db) => dbi.writeLive(db, portal,
            fp: fp,
            hash: hash,
            saved: saved,
            cats: cats,
            items: items,
            mask: mask,
            onlyIfMissing: onlyIfMissing));

void syncWriteVod(String path, String portal, String kind,
        {required String fp,
        required String? hash,
        required DateTime saved,
        required List<Category> cats,
        required List<VodItem> items,
        required String Function(String) mask,
        bool onlyIfMissing = false}) =>
    withCatalog(
        path,
        (db) => dbi.writeVod(db, portal, kind,
            fp: fp,
            hash: hash,
            saved: saved,
            cats: cats,
            items: items,
            mask: mask,
            onlyIfMissing: onlyIfMissing));

EpgDbInfo? syncEpgInfo(String path, String portal) =>
    withCatalog(path, (db) => dbi.epgInfo(db, portal));

EpgDbInfo? syncWriteEpg(
        String path, String portal, Map<String, List<EpgEntry>> epg,
        {required DateTime saved,
        String? hash,
        bool activate = true,
        bool Function()? cancelled}) =>
    withCatalog(
        path,
        (db) => dbi.writeEpg(db, portal, epg,
            saved: saved,
            hash: hash,
            activate: activate,
            cancelled: cancelled));

bool syncActivateEpg(String path, String portal, int gen, DateTime saved) =>
    withCatalog(path, (db) => dbi.activateEpg(db, portal, gen, saved: saved));

void syncTouchEpg(String path, String portal, DateTime saved) =>
    withCatalog(path, (db) => dbi.touchEpg(db, portal, saved));

Map<String, List<EpgEntry>> syncReadEpgWindow(
        String path, String portal, int from, int to) =>
    withCatalog(path, (db) => dbi.readEpgWindow(db, portal, from, to));

void syncDeletePortal(String path, String portal) =>
    withCatalog(path, (db) => dbi.deletePortalData(db, portal));
