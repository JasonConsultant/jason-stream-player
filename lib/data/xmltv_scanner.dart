import '../models/models.dart';

/// Spezialisierter XMLTV-Scanner: sucht direkt nach `<programme …>…</programme>`
/// statt einen allgemeinen XML-Parser zu benutzen. Sender außerhalb des
/// Filters werden übersprungen, ohne ihren Inhalt zu lesen.
///
/// Bekommt den Text stückweise über [write] und behält nur den unvollständigen
/// Rest zwischen zwei Stücken.
class XmltvScanner implements StringSink {
  final Set<String>? channelIds;

  /// Alternativ zum festen Filter: Entscheidung pro XMLTV-Kennung.
  final bool Function(String id)? wants;
  final DateTime _from;
  final DateTime _to;
  final result = <String, List<EpgEntry>>{};

  /// XMLTV-Kennung → erster `<display-name>` (für die manuelle EPG-Zuordnung).
  /// Wird unabhängig vom Filter gesammelt, höchstens [maxChannelNames].
  final channelNames = <String, String>{};
  static const maxChannelNames = 20000;
  String _carry = '';

  /// Letzte `<channel `-Suche im aktuellen Text (−2 = unbekannt, −1 = keins
  /// mehr). Verhindert, dass [_channels] für jede Sendung bis zum Ende des
  /// Stücks sucht (quadratisch bei großen Dateien).
  int _chanHint = -2;
  int _chanHintFrom = 0;

  // ignore: avoid_unused_constructor_parameters
  XmltvScanner(this.channelIds, [Object? legacyTimeParser, this.wants])
      : _from = DateTime.now().subtract(const Duration(days: 7)),
        _to = DateTime.now().add(const Duration(days: 3));

  static final _attr =
      RegExp(r'''([\w:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')''');

  static bool _isBoundary(int c) =>
      c == 0x20 || c == 0x3E || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x2F;

  @override
  void write(Object? obj) {
    final chunk = obj.toString();
    final s = _carry.isEmpty ? chunk : _carry + chunk;
    _chanHint = -2;
    var pos = 0;
    while (true) {
      final i = s.indexOf('<programme', pos);
      if (i < 0) {
        // Rest behalten, falls „<programme“ genau an der Grenze geteilt ist.
        var keep = s.length - 16;
        // Ein angefangenes <channel>-Element (Senderliste am Dateianfang)
        // ebenfalls behalten – begrenzt, damit der Rest klein bleibt.
        final openCh = _channels(s, pos, s.length);
        if (openCh >= 0 && s.length - openCh < 4096) keep = openCh;
        _carry = s.substring(keep > pos ? keep : pos);
        return;
      }
      _channels(s, pos, i);
      if (i + 10 >= s.length) {
        _carry = s.substring(i);
        return;
      }
      if (!_isBoundary(s.codeUnitAt(i + 10))) {
        pos = i + 10; // z. B. „<programmeX“ – anderes Element
        continue;
      }
      final tagEnd = s.indexOf('>', i);
      if (tagEnd < 0) {
        _carry = s.substring(i);
        return;
      }
      if (s.codeUnitAt(tagEnd - 1) == 0x2F) {
        pos = tagEnd + 1; // <programme … /> ohne Inhalt
        continue;
      }
      final close = s.indexOf('</programme>', tagEnd);
      if (close < 0) {
        if (s.length - i > 2 * 1024 * 1024) {
          // Kein Ende in Sicht (defekte Datei) → überspringen, sonst
          // wächst der Rest mit jedem Stück weiter.
          pos = tagEnd + 1;
          continue;
        }
        _carry = s.substring(i);
        return;
      }
      _programme(s, i + 10, tagEnd, close);
      pos = close + 12;
    }
  }

  /// `<channel id="…"><display-name>…</display-name></channel>` in
  /// [from, to) einsammeln. Liefert den Anfang eines unvollständigen
  /// Elements (oder −1). Nur ein indexOf pro Abschnitt – günstig, denn
  /// zwischen zwei Sendungen steht fast nie etwas.
  int _channels(String s, int from, int to) {
    var k = from;
    while (true) {
      // Letztes Suchergebnis wiederverwenden: In [_chanHintFrom, _chanHint)
      // gibt es kein `<channel ` (−1 = bis zum Ende keins).
      if (_chanHint != -2 &&
          k >= _chanHintFrom &&
          (_chanHint < 0 || k <= _chanHint)) {
        k = _chanHint;
      } else {
        _chanHintFrom = k;
        k = _chanHint = s.indexOf('<channel ', k);
      }
      if (k < 0 || k >= to) return -1;
      final end = s.indexOf('</channel>', k);
      if (end < 0 || end > to) return k; // unvollständig
      if (channelNames.length < maxChannelNames) {
        final tagEnd = s.indexOf('>', k);
        if (tagEnd > 0 && tagEnd < end) {
          final id = _attrValue(s, 'id', k + 8, tagEnd);
          if (id != null && id.isNotEmpty) {
            final name = _child(s, 'display-name', tagEnd, end) ?? '';
            final cid = _intern(unescape(id));
            channelNames.putIfAbsent(cid, () => name.isEmpty ? cid : name);
          }
        }
      }
      k = end + 10;
    }
  }

  void _programme(String s, int attrStart, int tagEnd, int close) {
    var channel = _attrValue(s, 'channel', attrStart, tagEnd);
    final start = _attrValue(s, 'start', attrStart, tagEnd);
    final stop = _attrValue(s, 'stop', attrStart, tagEnd);
    if (channel == null || start == null || stop == null) {
      // Ungewöhnliche Schreibweise (Leerzeichen um „=“ o. Ä.) → langsamer Weg
      final m = {
        for (final x in _attr.allMatches(s.substring(attrStart, tagEnd)))
          x[1]!: x[2] ?? x[3] ?? ''
      };
      channel = m['channel'];
      if (channel == null || m['start'] == null || m['stop'] == null) return;
      return _add(s, unescape(channel), m['start']!, m['stop']!, tagEnd, close);
    }
    _add(s, channel.contains('&') ? unescape(channel) : channel, start, stop,
        tagEnd, close);
  }

  void _add(String s, String channel, String start, String stop, int tagEnd,
      int close) {
    final ids = channelIds;
    if (ids != null && !ids.contains(channel)) return; // schnell überspringen
    final w = wants;
    if (w != null && !w(channel)) return;
    final st = _cachedTime(start);
    final en = _cachedTime(stop);
    if (st == null || en == null || en.isBefore(_from) || st.isAfter(_to)) {
      return;
    }
    final title = _child(s, 'title', tagEnd, close) ?? '';
    final desc = _child(s, 'desc', tagEnd, close);
    final genre = _child(s, 'category', tagEnd, close);
    final ch = _intern(channel);
    (result[ch] ??= []).add(EpgEntry(
      channelEpgId: ch,
      title: _intern(title),
      description: (desc == null || desc.isEmpty) ? null : desc,
      genre: (genre == null || genre.isEmpty) ? null : _intern(genre),
      start: st,
      end: en,
    ));
  }

  /// Wert von name="…" ohne RegExp (häufigster Fall, sehr schnell).
  static String? _attrValue(String s, String name, int from, int to) {
    var k = from;
    while (true) {
      k = s.indexOf(name, k);
      if (k < 0 || k >= to) return null;
      final before = s.codeUnitAt(k - 1);
      final eq = k + name.length;
      if ((before == 0x20 || before == 0x09 || before == 0x0A || before == 0x0D) &&
          eq + 1 < to &&
          s.codeUnitAt(eq) == 0x3D) {
        final q = s.codeUnitAt(eq + 1);
        if (q == 0x22 || q == 0x27) {
          final end = s.indexOf(String.fromCharCode(q), eq + 2);
          if (end < 0 || end > to) return null;
          return s.substring(eq + 2, end);
        }
      }
      k = eq;
    }
  }

  // Start einer Sendung = Ende der vorigen → Zeiten sind oft schon bekannt.
  final _times = <String, DateTime?>{};
  DateTime? _cachedTime(String v) {
    final hit = _times[v];
    if (hit != null || _times.containsKey(v)) return hit;
    if (_times.length > 20000) _times.clear();
    return _times[v] = fastTime(v);
  }

  // Wiederkehrende Texte (Sendernamen, „Nachrichten“, Genres) nur einmal
  // im Speicher halten.
  final _pool = <String, String>{};
  String _intern(String v) {
    if (v.length > 80) return v;
    if (_pool.length > 200000) _pool.clear();
    return _pool[v] ??= v;
  }

  /// XMLTV-Zeit „20261019120000 +0200“ ohne substring/RegExp.
  static DateTime? fastTime(String s) {
    if (s.length < 14) return null;
    int d(int i) {
      final c = s.codeUnitAt(i) - 0x30;
      if (c < 0 || c > 9) throw const FormatException();
      return c;
    }

    try {
      final y = d(0) * 1000 + d(1) * 100 + d(2) * 10 + d(3);
      final mo = d(4) * 10 + d(5);
      final da = d(6) * 10 + d(7);
      final h = d(8) * 10 + d(9);
      final mi = d(10) * 10 + d(11);
      final se = d(12) * 10 + d(13);
      var offsetMin = 0;
      var i = 14;
      while (i < s.length && s.codeUnitAt(i) == 0x20) {
        i++;
      }
      if (s.length >= i + 5) {
        final sign = s.codeUnitAt(i);
        if (sign == 0x2B || sign == 0x2D) {
          offsetMin = (d(i + 1) * 10 + d(i + 2)) * 60 + d(i + 3) * 10 + d(i + 4);
          if (sign == 0x2D) offsetMin = -offsetMin;
        }
      }
      final utcMs = DateTime.utc(y, mo, da, h, mi, se).millisecondsSinceEpoch -
          offsetMin * 60000;
      return DateTime.fromMillisecondsSinceEpoch(utcMs);
    } on FormatException {
      return null;
    }
  }

  /// Inhalt des ersten Kind-Elements [name] (erste Sprache gewinnt).
  static String? _child(String s, String name, int from, int to) {
    var k = from;
    while (true) {
      k = s.indexOf('<$name', k);
      if (k < 0 || k >= to) return null;
      if (_isBoundary(s.codeUnitAt(k + name.length + 1))) break;
      k += name.length + 1;
    }
    final open = s.indexOf('>', k);
    if (open < 0 || open >= to) return null;
    if (s.codeUnitAt(open - 1) == 0x2F) return ''; // <title/>
    final end = s.indexOf('</$name>', open);
    if (end < 0 || end > to) return null;
    final v = s.substring(open + 1, end);
    if (!v.contains('<![CDATA[')) return unescape(v).trim();
    // CDATA unverändert übernehmen, Text außerhalb entschlüsseln.
    final b = StringBuffer();
    var p = 0;
    while (true) {
      final c = v.indexOf('<![CDATA[', p);
      if (c < 0) {
        b.write(unescape(v.substring(p)));
        break;
      }
      b.write(unescape(v.substring(p, c)));
      final ce = v.indexOf(']]>', c + 9);
      if (ce < 0) {
        b.write(v.substring(c + 9));
        break;
      }
      b.write(v.substring(c + 9, ce));
      p = ce + 3;
    }
    return b.toString().trim();
  }

  static final _entity =
      RegExp(r'&(#x[0-9a-fA-F]+|#\d+|amp|lt|gt|quot|apos);');

  static String unescape(String v) {
    if (!v.contains('&')) return v;
    return v.replaceAllMapped(_entity, (m) {
      final e = m[1]!;
      switch (e) {
        case 'amp':
          return '&';
        case 'lt':
          return '<';
        case 'gt':
          return '>';
        case 'quot':
          return '"';
        case 'apos':
          return "'";
      }
      final code = e.startsWith('#x')
          ? int.tryParse(e.substring(2), radix: 16)
          : int.tryParse(e.substring(1));
      return code == null ? m[0]! : String.fromCharCode(code);
    });
  }

  Map<String, List<EpgEntry>> finish() {
    _carry = '';
    for (final list in result.values) {
      list.sort((a, b) => a.start.compareTo(b.start));
    }
    return result;
  }

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) {
    for (final o in objects) {
      write(o);
    }
  }

  @override
  void writeCharCode(int charCode) => write(String.fromCharCode(charCode));

  @override
  void writeln([Object? obj = '']) => write(obj);
}
