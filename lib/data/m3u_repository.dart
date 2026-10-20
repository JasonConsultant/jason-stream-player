import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;

import '../models/models.dart';
import 'm3u_parser.dart';
import 'net.dart';
import 'repository.dart';

/// M3U/M3U8-Playlist mit optionalem XMLTV-EPG und Catch-up
/// (catchup="default|append|shift|flussonic" + catchup-source).
class M3uRepository extends IptvRepository {
  @override
  final Portal portal;
  M3uParseResult? _cache;

  M3uRepository(this.portal);

  Future<M3uParseResult> _load() async {
    if (_cache != null) return _cache!;
    final bytes = await Net.get(Uri.parse(portal.url.trim()),
        maxBytes: 80 * 1024 * 1024, timeout: const Duration(seconds: 60));
    // Dekodieren + Parsen im Hintergrund (Playlisten haben oft 10 MB+).
    final result = await compute(_parse, bytes);
    if (result == null) {
      throw RepositoryException('Das ist keine gültige M3U-Playlist.');
    }
    return _cache = result;
  }

  static M3uParseResult? _parse(Uint8List bytes) {
    final text = utf8.decode(bytes, allowMalformed: true);
    if (!text.contains('#EXTINF')) return null;
    return M3uParser.parse(text);
  }

  @override
  Future<AccountInfo?> login() async {
    await _load();
    return null;
  }

  @override
  Future<List<Category>> liveCategories() async => (await _load()).categories;

  @override
  Future<List<Channel>> liveChannels() async => (await _load()).channels;

  @override
  Future<Map<String, List<EpgEntry>>> loadEpg(
      {Set<String>? channelIds, List<Channel>? channels, EpgProgress? progress}) async {
    return loadXmltvSources(
        channelIds: channelIds, channels: channels, progress: progress);
  }

  @override
  Future<String?> providerEpgUrl() async => (await _load()).epgUrl;

  @override
  bool get supportsVod => false;

  @override
  String? catchupUrl(Channel c, EpgEntry e) {
    if (!c.hasCatchup) return null;
    final mode = (c.catchupMode ?? 'default').toLowerCase();
    final now = DateTime.now();

    switch (mode) {
      case 'shift':
        final sep = c.streamUrl.contains('?') ? '&' : '?';
        return '${c.streamUrl}${sep}utc=${_unix(e.start)}&lutc=${_unix(now)}';
      case 'flussonic':
      case 'fs':
        final dur = e.duration.inSeconds;
        return c.streamUrl.replaceFirstMapped(
          RegExp(r'/(index|video|mono)(\.m3u8|\.ts|-live\.m3u8)?(\?|$)'),
          (m) => '/${m[1]}-${_unix(e.start)}-$dur${m[2] ?? '.m3u8'}${m[3]}',
        );
      case 'append':
        final src = c.catchupSource;
        if (src == null) return null;
        return c.streamUrl + _fill(src, e, now);
      default:
        final src = c.catchupSource;
        if (src == null) return null;
        return _fill(src, e, now);
    }
  }

  static int _unix(DateTime t) => t.millisecondsSinceEpoch ~/ 1000;

  /// Ersetzt die gängigen Platzhalter in catchup-source.
  static String _fill(String tpl, EpgEntry e, DateTime now) {
    String two(int n) => n.toString().padLeft(2, '0');
    final s = e.start;
    final values = <String, String>{
      'utc': '${_unix(e.start)}',
      'start': '${_unix(e.start)}',
      'timestamp': '${_unix(e.start)}',
      'utcend': '${_unix(e.end)}',
      'end': '${_unix(e.end)}',
      'lutc': '${_unix(now)}',
      'now': '${_unix(now)}',
      'offset': '${now.difference(e.start).inSeconds}',
      'Y': '${s.year}',
      'm': two(s.month),
      'd': two(s.day),
      'H': two(s.hour),
      'M': two(s.minute),
      'S': two(s.second),
    };
    var out = tpl.replaceAllMapped(
      RegExp(r'\$?\{duration(?::(\d+))?\}'),
      (m) {
        final div = int.tryParse(m[1] ?? '') ?? 1;
        return '${e.duration.inSeconds ~/ div}';
      },
    );
    out = out.replaceAllMapped(RegExp(r'\$?\{([A-Za-z]+)\}'),
        (m) => values[m[1]] ?? m[0]!);
    return out;
  }
}
