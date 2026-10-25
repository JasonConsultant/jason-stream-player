import '../../models/models.dart';
import 'db_types.dart';

/// Web: keine Datenbank – Aufrufer fallen auf das bisherige Verhalten zurück.

Never _no() => throw UnsupportedError('Keine Datenbank');

bool syncHasList(String path, String portal, String kind) => _no();
DbList<Channel>? syncReadLive(String path, String portal, String fp,
        String Function(String) restore) =>
    _no();
DbList<VodItem>? syncReadVod(String path, String portal, String kind, String fp,
        String Function(String) restore) =>
    _no();
void syncWriteLive(String path, String portal,
        {required String fp,
        required String? hash,
        required DateTime saved,
        required List<Category> cats,
        required List<Channel> items,
        required String Function(String) mask,
        bool onlyIfMissing = false}) =>
    _no();
void syncWriteVod(String path, String portal, String kind,
        {required String fp,
        required String? hash,
        required DateTime saved,
        required List<Category> cats,
        required List<VodItem> items,
        required String Function(String) mask,
        bool onlyIfMissing = false}) =>
    _no();
EpgDbInfo? syncEpgInfo(String path, String portal) => _no();
EpgDbInfo? syncWriteEpg(
        String path, String portal, Map<String, List<EpgEntry>> epg,
        {required DateTime saved,
        String? hash,
        bool activate = true,
        bool Function()? cancelled}) =>
    _no();
bool syncActivateEpg(String path, String portal, int gen, DateTime saved) =>
    _no();
void syncTouchEpg(String path, String portal, DateTime saved) => _no();
Map<String, List<EpgEntry>> syncReadEpgWindow(
        String path, String portal, int from, int to) =>
    _no();
void syncDeletePortal(String path, String portal) => _no();
