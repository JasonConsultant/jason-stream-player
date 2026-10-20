import '../core/security.dart';
import '../models/models.dart';

typedef M3uParseResult = ({
  List<Channel> channels,
  List<Category> categories,
  String? epgUrl,
});

/// Parser für M3U/M3U8-Playlisten mit #EXTINF-Attributen
/// (tvg-id, tvg-logo, tvg-chno, group-title, catchup, catchup-days,
/// catchup-source).
class M3uParser {
  static final _attr = RegExp(r'([a-zA-Z0-9\-_]+)="([^"]*)"');

  static M3uParseResult parse(String content) {
    final lines = content.split(RegExp(r'\r?\n'));
    final channels = <Channel>[];
    final groups = <String, Category>{};
    String? epgUrl;
    Map<String, String> header = {};

    String? pendingName;
    Map<String, String> attrs = {};
    String? extGrp;
    var number = 0;

    for (final raw in lines) {
      final line = raw.trim();
      if (line.isEmpty) continue;

      if (line.startsWith('#EXTM3U')) {
        header = {for (final m in _attr.allMatches(line)) m[1]!: m[2]!};
        // Auch mehrere Adressen (durch Komma getrennt) – nur gültige behalten.
        final urls = (header['x-tvg-url'] ?? header['url-tvg'] ?? '')
            .split(',')
            .map((e) => e.trim())
            .where(UrlPolicy.isWeb)
            .toList();
        epgUrl = urls.isEmpty ? null : urls.join(',');
        continue;
      }
      if (line.startsWith('#EXTINF')) {
        attrs = {for (final m in _attr.allMatches(line)) m[1]!: m[2]!};
        final comma = _nameComma(line);
        pendingName = comma >= 0 ? line.substring(comma + 1).trim() : 'Sender';
        continue;
      }
      if (line.startsWith('#EXTGRP:')) {
        extGrp = line.substring(8).trim();
        continue;
      }
      if (line.startsWith('#')) continue;

      // Stream-URL – unsichere Schemata (file:, content: …) überspringen
      if (pendingName != null && !UrlPolicy.isStream(line)) {
        pendingName = null;
        attrs = {};
        extGrp = null;
        continue;
      }
      if (pendingName != null) {
        final groupName = attrs['group-title'] ?? extGrp ?? 'Allgemein';
        final cat = groups.putIfAbsent(
            groupName, () => Category(id: groupName, name: groupName));
        number++;
        final days = int.tryParse(attrs['catchup-days'] ??
                attrs['timeshift'] ??
                header['catchup-days'] ??
                '') ??
            0;
        channels.add(Channel(
          id: 'm3u_$number',
          name: pendingName,
          logoUrl: UrlPolicy.image(_nz(attrs['tvg-logo'])),
          categoryId: cat.id,
          streamUrl: line,
          epgId: _nz(attrs['tvg-id']) ?? _nz(attrs['tvg-name']),
          number: int.tryParse(attrs['tvg-chno'] ?? '') ?? number,
          catchupDays: days,
          catchupMode: attrs['catchup'] ?? header['catchup'],
          catchupSource: attrs['catchup-source'] ?? header['catchup-source'],
        ));
        pendingName = null;
        attrs = {};
        extGrp = null;
      }
    }
    return (
      channels: channels,
      categories: groups.values.toList(),
      epgUrl: epgUrl,
    );
  }

  /// Das Komma vor dem Sendernamen – nicht eines innerhalb von "…".
  static int _nameComma(String line) {
    var inQuotes = false;
    for (var i = 0; i < line.length; i++) {
      final ch = line[i];
      if (ch == '"') inQuotes = !inQuotes;
      if (ch == ',' && !inQuotes) return i;
    }
    return -1;
  }

  static String? _nz(String? s) => (s == null || s.isEmpty) ? null : s;
}
