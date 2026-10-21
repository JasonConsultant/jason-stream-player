import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;

import '../models/models.dart';
import 'm3u_parser.dart';
import 'local_playlist_stub.dart'
    if (dart.library.io) 'local_playlist_io.dart';
import 'epg_matcher.dart' show epgKeyOf;
import 'epg_window.dart';
import 'host_failover.dart';
import 'net.dart';
import 'repository.dart';
import 'stream_headers.dart';

/// M3U/M3U8-Playlist mit optionalem XMLTV-EPG und Catch-up
/// (catchup="default|append|shift|flussonic" + catchup-source).
class M3uRepository extends IptvRepository {
  @override
  final Portal portal;
  M3uParseResult? _cache;

  M3uRepository(this.portal);

  Future<M3uParseResult> _load() async {
    if (_cache != null) return _cache!;
    final url = portal.url.trim();
    final bytes = url.startsWith('file://')
        ? await readLocalPlaylist(url)
        : await HostFailover.run(
            portal,
            (u) => Net.get(Uri.parse(u),
                maxBytes: 80 * 1024 * 1024,
                timeout: const Duration(seconds: 60),
                headers: portalHeaders(portal)));
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
    final epg = await loadXmltvSources(
        channelIds: channelIds, channels: channels, progress: progress);
    return applyTvgShift(epg, channels ?? await liveChannels());
  }

  /// tvg-shift der Playlist (pro Sender bzw. global) auf das EPG anwenden.
  /// Teilen sich Sender mit verschiedenem Versatz eine Kennung, gilt der
  /// erste.
  static Map<String, List<EpgEntry>> applyTvgShift(
      Map<String, List<EpgEntry>> epg, List<Channel> channels) {
    final done = <String>{};
    for (final c in channels) {
      final key = epgKeyOf(c);
      if (!done.add(key) || c.epgShift == 0) continue;
      final l = epg[key];
      if (l == null || l.isEmpty) continue;
      final d = Duration(minutes: c.epgShift);
      epg[key] = [for (final p in l) EpgWindow.shiftEntry(p, d)];
    }
    return epg;
  }

  @override
  Future<String?> providerEpgUrl() async => (await _load()).epgUrl;

  @override
  bool get supportsVod => false;

  /// Streams auf dem Server der Playlist: auf die zuletzt funktionierende
  /// Adresse umschreiben (Ersatz-Adressen).
  @override
  Future<String> resolveStreamUrl(Channel c) async =>
      HostFailover.rewrite(portal, c.streamUrl);

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
