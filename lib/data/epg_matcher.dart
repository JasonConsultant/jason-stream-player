import '../models/models.dart';

/// Schlüssel, unter dem das Programm eines Senders in der EPG-Map liegt.
/// Sender mit eigener EPG-Kennung: diese; sonst „@“ + Sender-ID.
String epgKeyOf(Channel c) =>
    (c.epgId != null && c.epgId!.isNotEmpty) ? c.epgId! : '@${c.id}';

/// Programm eines Senders (oder leer).
List<EpgEntry> epgOf(Map<String, List<EpgEntry>> epg, Channel c) =>
    epg[epgKeyOf(c)] ?? const [];

/// Ordnet XMLTV-Kanäle den Sendern des Portals zu – wie TiviMate:
/// 1. EPG-Kennung exakt, 2. ohne Groß/Klein, 3. über den Sendernamen
///    („DE: ZDF HD“ ↔ „ZDF.de“, „Das Erste FHD“ ↔ „DasErste.de“).
class EpgMatcher {
  final List<Channel> channels;
  final _byId = <String, List<Channel>>{};
  final _byName = <String, List<Channel>>{};
  final _cache = <String, bool>{};

  EpgMatcher(this.channels) {
    for (final c in channels) {
      final id = c.epgId?.trim();
      if (id != null && id.isNotEmpty) {
        (_byId[id.toLowerCase()] ??= []).add(c);
      }
      final n = nameKey(c.name);
      if (n.length >= 2) (_byName[n] ??= []).add(c);
    }
  }

  // Länderkürzel am Anfang: „DE: “, „DE • “, „|DE| “, „[TR] “
  static final _prefix = RegExp(
      r'^\s*(?:[|\[(]\s*[a-z]{2,3}\s*[|\])]\s*[:•\-–]?|[a-z]{2,3}\s*[:|•\-–])\s*',
      caseSensitive: false);
  static final _brackets = RegExp(r'[(\[{].*?[)\]}]');
  static final _quality = RegExp(
      r'\b(?:u?hd|fhd|sd|4k|8k|hevc|h\.?26[45]|raw|backup|1080[pi]?|720p|50fps|60fps|vip|plus)\b',
      caseSensitive: false);
  static final _country = RegExp(r'\.[a-z]{2,3}$', caseSensitive: false);
  static final _nonAlnum = RegExp(r'[^0-9a-zäöüßçğışéèáàâ]', unicode: true);

  /// Vergleichsschlüssel aus einem Sendernamen.
  static String nameKey(String name) {
    var s = name.toLowerCase().replaceFirst(_prefix, '');
    s = s.replaceAll(_brackets, ' ');
    s = s.replaceAll(_quality, ' ');
    s = s.replaceAll('+', ' plus ').replaceAll(_quality, ' ');
    return s.replaceAll(_nonAlnum, '');
  }

  /// Vergleichsschlüssel aus einer XMLTV-Kennung („ZDF.de“ → „zdf“).
  static String idKey(String id) => nameKey(id.replaceFirst(_country, ''));

  /// Wird das Programm dieser XMLTV-Kennung gebraucht? (gecacht – wird für
  /// jede Sendung gefragt)
  bool wants(String xmltvId) => _cache[xmltvId] ??=
      _byId.containsKey(xmltvId.toLowerCase()) ||
          _byName.containsKey(idKey(xmltvId));

  /// Ergebnis des Parsers (nach XMLTV-Kennung) → Map nach [epgKeyOf].
  /// Exakte Kennung hat Vorrang, Namen füllen nur Lücken.
  Map<String, List<EpgEntry>> assign(Map<String, List<EpgEntry>> parsed) {
    final out = <String, List<EpgEntry>>{};
    // 1. exakt / ohne Groß-Klein
    for (final e in parsed.entries) {
      for (final c in _byId[e.key.toLowerCase()] ?? const <Channel>[]) {
        out.putIfAbsent(epgKeyOf(c), () => e.value);
      }
    }
    // 2. über den Namen – nur für Sender ohne Treffer
    final byIdKey = <String, List<EpgEntry>>{};
    for (final e in parsed.entries) {
      final k = idKey(e.key);
      final prev = byIdKey[k];
      if (prev == null || e.value.length > prev.length) byIdKey[k] = e.value;
    }
    for (final c in channels) {
      final key = epgKeyOf(c);
      if (out.containsKey(key)) continue;
      final hit = byIdKey[nameKey(c.name)];
      if (hit != null) out[key] = hit;
    }
    return out;
  }
}
