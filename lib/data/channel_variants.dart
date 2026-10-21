/// Sender-Varianten: Viele Anbieter führen denselben Sender mehrfach
/// („ZDF HD“, „ZDF FHD“, „DE: ZDF ᴴᴰ“, „ZDF (Backup)“ …). Hier werden sie
/// – rein funktional, ohne Flutter – zu Gruppen zusammengefasst und nach
/// Qualität sortiert.
///
/// Regeln (bewusst vorsichtig, lieber eine Variante zu viel als ein falsch
/// zusammengelegter Sender):
/// * gleicher normalisierter Name (Länderpräfix, Qualitätsangaben,
///   Klammern, Satzzeichen und Groß-/Kleinschreibung entfernt),
/// * UND gleiche Gruppe ODER gleiches Länderpräfix,
/// * nie bei verschiedenen Länderpräfixen („DE: Eurosport 1“ ≠ „UK: …“),
/// * nie, wenn der normalisierte Name kürzer als 2 Zeichen ist.
library;

import 'package:flutter/foundation.dart' show compute;

import '../models/models.dart';
import 'content_filters.dart' show CountryDetector;

/// Qualitätsstufe einer Variante (aus dem Namen erkannt).
enum VariantQuality { fhd, hd, unknown, uhd, raw, sd }

/// Analyse eines Sendernamens.
class VariantName {
  /// Normalisierter Name ohne Präfix/Qualität (z. B. „zdf“, „trt 1“).
  final String key;

  /// Länderpräfix in Großbuchstaben („DE“, „TR“) oder null.
  final String? country;
  final VariantQuality quality;

  /// Ersatz-/Backup-Quelle („Backup“, „Alt“, „#2“).
  final bool backup;

  const VariantName(this.key, this.country, this.quality, this.backup);

  /// Rang für die Sortierung (kleiner = besser).
  /// FHD, HD, ohne Angabe, 4K/UHD, RAW, SD – Backups immer zuletzt.
  int get rank => quality.index + (backup ? 10 : 0);

  /// Kurzes Etikett für die Variantenauswahl („FHD“, „4K“, „Backup“ …).
  String get label {
    final q = switch (quality) {
      VariantQuality.fhd => 'FHD',
      VariantQuality.hd => 'HD',
      VariantQuality.uhd => '4K',
      VariantQuality.raw => 'RAW',
      VariantQuality.sd => 'SD',
      VariantQuality.unknown => '',
    };
    if (backup) return q.isEmpty ? 'Backup' : '$q · Backup';
    return q;
  }

  @override
  String toString() => 'VariantName($key, $country, $quality, backup=$backup)';
}

// Hochgestellte Buchstaben/Ziffern („ᴴᴰ“, „ᵁᴴᴰ“, „⁴ᴷ“) → normale Zeichen.
const _superscript = {
  'ᴬ': 'A', 'ᴮ': 'B', 'ᴰ': 'D', 'ᴱ': 'E', 'ᴳ': 'G', 'ᴴ': 'H', 'ᴵ': 'I',
  'ᴶ': 'J', 'ᴷ': 'K', 'ᴸ': 'L', 'ᴹ': 'M', 'ᴺ': 'N', 'ᴼ': 'O', 'ᴾ': 'P',
  'ᴿ': 'R', 'ᵀ': 'T', 'ᵁ': 'U', 'ⱽ': 'V', 'ᵂ': 'W', 'ᵃ': 'a', 'ᵇ': 'b',
  'ᶜ': 'c', 'ᵈ': 'd', 'ᵉ': 'e', 'ᶠ': 'f', 'ᵍ': 'g', 'ʰ': 'h', 'ⁱ': 'i',
  'ʲ': 'j', 'ᵏ': 'k', 'ˡ': 'l', 'ᵐ': 'm', 'ⁿ': 'n', 'ᵒ': 'o', 'ᵖ': 'p',
  'ʳ': 'r', 'ˢ': 's', 'ᵗ': 't', 'ᵘ': 'u', 'ᵛ': 'v', 'ʷ': 'w', 'ˣ': 'x',
  'ʸ': 'y', 'ᶻ': 'z', '⁰': '0', '¹': '1', '²': '2', '³': '3', '⁴': '4',
  '⁵': '5', '⁶': '6', '⁷': '7', '⁸': '8', '⁹': '9', 'ᶦ': 'i',
};

// Länderpräfix am Anfang: „DE:“, „DE |“, „|DE|“, „[DE]“, „DE -“, „DE▎“.
final _prefix = RegExp(
    r'^\s*(?:[|\[(]\s*([A-Za-z]{2,4})\s*[|\])]|([A-Z]{2,4}|[a-z]{2})\s*(?:[:|▎┃•»]|\s-\s|-\s))\s*');

/// Länderkürzel, die der Länderfilter nicht kennt, die als Präfix aber
/// trotzdem ein Land bezeichnen.
const _extraCountries = {
  'EN', 'IE', 'AU', 'NZ', 'BR', 'MT', 'LT', 'LV', 'EE', 'IS', 'IL', 'JP',
  'KR', 'CN', 'AZ', 'GE', 'AM', 'KZ', 'CY', 'LU', 'SA', 'AE', 'EG', 'MA',
  'DZ', 'TN', 'IQ', 'SY', 'LB', 'JO', 'QA', 'KW', 'ZA', 'NG', 'PH', 'TH',
  'VN', 'ID', 'MY', 'BD', 'LK', 'NP', 'CL', 'CO', 'PE', 'VE', 'EC', 'UY',
  'PY', 'BO', 'CR', 'PA', 'DO', 'CU', 'PR', 'HK', 'TW', 'SG', 'AFR', 'ASIA',
};

final _nonWord =RegExp(r'[^\p{L}\p{N}+]+', unicode: true);

const _uhd = {'4k', '8k', 'uhd', '2160p', '2160', 'uhd4k'};
const _fhd = {'fhd', '1080p', '1080i', '1080', 'fullhd'};
const _hd = {'hd', '720p', '720', 'hq', 'hdr'};
const _sd = {'sd', '576p', '576i', '576', '480p', '480', 'lq', 'low'};
const _raw = {'raw'};
const _codec = {
  'hevc', 'h265', 'h264', 'x265', 'x264', 'avc',
  '50fps', '60fps', '25fps', '30fps', 'fps',
};
const _backup = {'backup', 'bkp', 'bk', 'alt', 'yedek', 'reserve', 'ersatz'};

final _backupGlued = RegExp(r'^(?:backup|alt|bkp|yedek)\d+$');
final _hash = RegExp(r'^#\d+$');

/// Wörter (Buchstaben, Ziffern, „+“). Reine ASCII-Namen (der Normalfall)
/// ohne regulären Ausdruck – das ist bei 50 000 Sendern spürbar schneller.
List<String> _words(String s) {
  final out = <String>[];
  var start = -1;
  for (var i = 0; i < s.length; i++) {
    final u = s.codeUnitAt(i);
    if (u >= 0x80) {
      return s.split(_nonWord)..removeWhere((t) => t.isEmpty);
    }
    final word = (u >= 0x61 && u <= 0x7A) || // a-z (bereits klein)
        (u >= 0x30 && u <= 0x39) ||
        (u >= 0x41 && u <= 0x5A) ||
        u == 0x2B; // +
    if (word) {
      if (start < 0) start = i;
    } else if (start >= 0) {
      out.add(s.substring(start, i));
      start = -1;
    }
  }
  if (start >= 0) out.add(s.substring(start));
  return out;
}

/// Code-Einheiten der hochgestellten Zeichen (alle im BMP).
final _supUnits = {for (final k in _superscript.keys) k.codeUnitAt(0)};

bool _hasSuperscript(String s) {
  for (var i = 0; i < s.length; i++) {
    final u = s.codeUnitAt(i);
    if (u >= 0xB2 && _supUnits.contains(u)) return true;
  }
  return false;
}
final _hashNum = RegExp(r'#(\d+)');
bool _isDigit(int u) => u >= 0x30 && u <= 0x39;

bool _allDigits(String t) {
  for (var i = 0; i < t.length; i++) {
    if (!_isDigit(t.codeUnitAt(i))) return false;
  }
  return t.isNotEmpty;
}

/// Zerlegt [name] in normalisierten Namen, Land, Qualität und Backup-Flag.
VariantName analyzeVariantName(String name) {
  var s = name;
  // Hochgestellte Läufe vorher abtrennen: „ZDFᴴᴰ“ → „ZDF HD“.
  // (Schneller Vorabtest: die meisten Namen haben keine.)
  if (_hasSuperscript(s)) {
    final b = StringBuffer();
    var inSup = false;
    for (final r in s.runes) {
      final ch = String.fromCharCode(r);
      final m = _superscript[ch];
      if (m != null) {
        if (!inSup) b.write(' ');
        b.write(m);
        inSup = true;
      } else {
        if (inSup) b.write(' ');
        b.write(ch);
        inSup = false;
      }
    }
    s = b.toString();
  }

  String? country;
  final pm = _prefix.firstMatch(s);
  if (pm != null && pm.end < s.length) {
    // Nur echte Länderkürzel abtrennen: „ATV - Avrupa“ oder „HBO: Family“
    // sind Sendernamen (sonst würde „HBO: Family“ mit „Family“ verschmelzen).
    final tok = (pm.group(1) ?? pm.group(2))!.toUpperCase();
    final code = CountryDetector.normalizeCode(tok) ??
        (_extraCountries.contains(tok) ? tok : null);
    if (code != null) {
      country = code;
      s = s.substring(pm.end);
    }
  }

  // Satzzeichen und Klammern → Leerzeichen; Inhalt in Klammern bleibt
  // Teil des Namens (z. B. „ZDF (Österreich)“), außer es ist eine
  // Qualitäts-/Backup-Angabe.
  if (s.contains('İ') || s.contains('ı')) {
    s = s.replaceAll('İ', 'i').replaceAll('ı', 'i');
  }
  s = s.toLowerCase();
  // „#2“ als eigenes Wort erhalten (sonst wird es zur „2“).
  if (s.contains('#')) {
    s = s.replaceAllMapped(_hashNum, (m) => ' bkpnr${m[1]} ');
  }
  final raw = _words(s);

  var quality = VariantQuality.unknown;
  var backup = false;
  void q(VariantQuality v) {
    // Bei mehreren Angaben („UHD 4K“, „FHD 1080p“) die erste behalten,
    // außer bisher unbekannt.
    if (quality == VariantQuality.unknown) quality = v;
  }

  final kept = <String>[];
  for (var i = 0; i < raw.length; i++) {
    final t = raw[i];
    final prev = i > 0 ? raw[i - 1] : null;
    final nextT = i + 1 < raw.length ? raw[i + 1] : null;
    if (t == 'full' && nextT == 'hd') {
      q(VariantQuality.fhd);
      i++; // „hd“ überspringen
      continue;
    }
    if (_uhd.contains(t)) {
      q(VariantQuality.uhd);
    } else if (_fhd.contains(t)) {
      q(VariantQuality.fhd);
    } else if (_hd.contains(t)) {
      q(VariantQuality.hd);
    } else if (_sd.contains(t)) {
      q(VariantQuality.sd);
    } else if (_raw.contains(t)) {
      q(VariantQuality.raw);
    } else if (t == '50' || t == '60') {
      // Nur als Bildrate („HD 50“, „50 fps“) – „Sky Sport 50“ bleibt.
      if (!_isFpsContext(raw, i)) kept.add(t);
    } else if (_codec.contains(t)) {
      // Codec/Bildrate: kein Teil des Namens.
    } else if (_backup.contains(t) ||
        (_isDigit(t.codeUnitAt(t.length - 1)) &&
            (_backupGlued.hasMatch(t) || t.startsWith('bkpnr'))) ||
        (t.startsWith('#') && _hash.hasMatch(t))) {
      backup = true;
    } else if (_allDigits(t) &&
        prev != null &&
        (_backup.contains(prev))) {
      // „Backup 2“, „Alt 1“: Nummer gehört zur Backup-Angabe.
      backup = true;
    } else {
      kept.add(t);
    }
  }
  return VariantName(kept.join(' '), country, quality, backup);
}

/// „50“/„60“ sind nur dann eine Bildrate, wenn „fps“ folgt oder eine
/// Qualitätsangabe direkt davor steht („HD 50“). „Sky Sport 50“ bleibt.
bool _isFpsContext(List<String> raw, int i) {
  final next = i + 1 < raw.length ? raw[i + 1] : null;
  final prev = i > 0 ? raw[i - 1] : null;
  if (next == 'fps') return true;
  bool qual(String? t) =>
      t != null &&
      (_uhd.contains(t) || _fhd.contains(t) || _hd.contains(t) || _sd.contains(t));
  return qual(prev);
}

/// Eine Gruppe von Varianten desselben Senders.
class VariantGroup {
  /// Stabiler Schlüssel (normalisierter Name + Land bzw. Gruppe), unter dem
  /// die Auswahl des Nutzers gespeichert wird.
  final String key;

  /// Varianten, nach Qualität sortiert (beste zuerst).
  final List<Channel> members;
  final Map<String, VariantName> names;

  const VariantGroup(this.key, this.members, this.names);

  Channel get best => members.first;
  int get length => members.length;

  String labelOf(Channel c) {
    final n = names[c.id];
    final l = n?.label ?? '';
    return l.isEmpty ? c.name : l;
  }

  /// Reihenfolge zum Abspielen: gewählte Variante zuerst, dann nach Rang.
  List<Channel> playOrder(String? chosenId) {
    if (chosenId == null) return members;
    final i = members.indexWhere((c) => c.id == chosenId);
    if (i <= 0) return members;
    return [members[i], for (final c in members) if (c.id != chosenId) c];
  }
}

class _Cluster {
  final String name;
  String? country;
  final Set<String> groups = {};
  final List<int> idx = [];
  _Cluster(this.name);
}

/// Fasst Varianten in [channels] zusammen. Liefert nur Gruppen mit
/// mindestens zwei Mitgliedern (Sender ohne Varianten fehlen).
List<VariantGroup> groupVariants(List<Channel> channels) => _buildGroups(
    channels,
    clusterVariantNames((
      [for (final c in channels) c.name],
      [for (final c in channels) c.categoryId],
    )));

/// Ab so vielen Sendern rechnet [groupVariantsInBackground] in einem
/// eigenen Isolate (schwache TV-Boxen: sonst ruckelt die Oberfläche).
const variantBackgroundThreshold = 4000;

/// Wie [groupVariants], die Namensanalyse läuft aber im Hintergrund
/// (übertragen werden nur Namen und Gruppen-IDs, nicht die Sender).
Future<List<VariantGroup>> groupVariantsInBackground(
    List<Channel> channels) async {
  final clusters = await compute(clusterVariantNames, (
    [for (final c in channels) c.name],
    [for (final c in channels) c.categoryId],
  ));
  return _buildGroups(channels, clusters);
}

/// Ergebnis der Gruppierung ohne Sender-Objekte: Schlüssel, Indizes (nach
/// Rang sortiert) und die Namensanalyse je Mitglied.
typedef VariantCluster = ({String key, List<int> idx, List<VariantName> names});

/// Reine Gruppierung über (Namen, Gruppen-IDs) – isolate-tauglich.
List<VariantCluster> clusterVariantNames((List<String>, List<String>) job) {
  final (labels, cats) = job;
  final names = <VariantName>[for (final n in labels) analyzeVariantName(n)];
  final byName = <String, List<_Cluster>>{};
  for (var i = 0; i < names.length; i++) {
    final n = names[i];
    if (n.key.replaceAll(' ', '').length < 2) continue;
    final cat = cats[i];
    final list = byName.putIfAbsent(n.key, () => []);
    _Cluster? hit;
    for (final cl in list) {
      // Verschiedene Länder nie zusammenlegen.
      if (cl.country != null && n.country != null && cl.country != n.country) {
        continue;
      }
      final sameGroup = cl.groups.contains(cat);
      final sameCountry = n.country != null && cl.country == n.country;
      if (sameGroup || sameCountry) {
        hit = cl;
        break;
      }
    }
    if (hit == null) {
      hit = _Cluster(n.key);
      list.add(hit);
    }
    hit.country ??= n.country;
    hit.groups.add(cat);
    hit.idx.add(i);
  }
  final out = <VariantCluster>[];
  for (final list in byName.values) {
    for (final cl in list) {
      if (cl.idx.length < 2) continue;
      final sorted = [...cl.idx]..sort((a, b) {
          final r = names[a].rank.compareTo(names[b].rank);
          return r != 0 ? r : a.compareTo(b);
        });
      out.add((
        key: '${cl.name}|${cl.country ?? 'g:${cats[cl.idx.first]}'}',
        idx: sorted,
        names: [for (final i in sorted) names[i]],
      ));
    }
  }
  return out;
}

List<VariantGroup> _buildGroups(
        List<Channel> channels, List<VariantCluster> clusters) =>
    [
      for (final cl in clusters)
        VariantGroup(
          cl.key,
          [for (final i in cl.idx) channels[i]],
          {
            for (var k = 0; k < cl.idx.length; k++)
              channels[cl.idx[k]].id: cl.names[k]
          },
        ),
    ];

/// Nachschlagetabelle über alle Gruppen.
class VariantIndex {
  /// Sender-ID (jede Variante) → Gruppe.
  final Map<String, VariantGroup> _byMember;

  /// Gruppen-Schlüssel → sichtbarer Vertreter (ID).
  final Map<String, String> _rep;

  VariantIndex._(this._byMember, this._rep);

  static final empty = VariantIndex._(const {}, const {});

  bool get isEmpty => _byMember.isEmpty;

  /// Wer vertritt die Gruppe in den Listen?
  /// 1. nur nicht ausgeblendete Varianten ([hidden]) – sonst verschwände
  ///    der ganze Sender, wenn die beste Variante ausgeblendet wurde,
  /// 2. ist eine davon gesperrt ([locked], Kindersicherung), vertritt eine
  ///    gesperrte die Gruppe – sonst wäre die Sperre über eine andere
  ///    Variante umgehbar,
  /// 3. ein Favorit (so bleiben Favoriten über die ID erhalten),
  /// 4. sonst die beste Variante.
  factory VariantIndex.of(List<VariantGroup> groups,
      {Set<String> favorites = const {},
      Set<String> hidden = const {},
      Set<String> locked = const {}}) {
    final by = <String, VariantGroup>{};
    final rep = <String, String>{};
    for (final g in groups) {
      for (final c in g.members) {
        by[c.id] = g;
      }
      var cands = [
        for (final c in g.members)
          if (!hidden.contains(c.id)) c
      ];
      if (cands.isEmpty) cands = g.members;
      if (locked.isNotEmpty) {
        final lk = [
          for (final c in cands)
            if (locked.contains(c.id)) c
        ];
        if (lk.isNotEmpty) cands = lk;
      }
      final fav = cands.where((c) => favorites.contains(c.id));
      rep[g.key] = (fav.isEmpty ? cands.first : fav.first).id;
    }
    return VariantIndex._(by, rep);
  }

  /// IDs (Verlauf, eigene Gruppen, Erinnerungen …) → sichtbare Sender aus
  /// [byId]. Die ID einer verdeckten Variante zählt als ihr Vertreter;
  /// doppelte Treffer erscheinen nur einmal (Reihenfolge bleibt).
  List<Channel> resolve(Iterable<String> ids, Map<String, Channel> byId) {
    final seen = <String>{};
    final out = <Channel>[];
    for (final id in ids) {
      final c = byId[id] ?? byId[representativeOf(id)];
      if (c != null && seen.add(c.id)) out.add(c);
    }
    return out;
  }

  VariantGroup? groupOf(String channelId) => _byMember[channelId];

  /// Anzahl Varianten des Senders (1 = keine).
  int countOf(String channelId) => _byMember[channelId]?.length ?? 1;

  /// ID des sichtbaren Vertreters (für Favoriten, Direktwahl usw.).
  String representativeOf(String channelId) {
    final g = _byMember[channelId];
    return g == null ? channelId : (_rep[g.key] ?? channelId);
  }

  bool isRepresentative(String channelId) =>
      representativeOf(channelId) == channelId;

  /// Liste ohne die verdeckten Varianten (Reihenfolge bleibt). Fehlen dem
  /// Vertreter Logo oder EPG-Kennung, kommen sie von einer anderen Variante.
  List<Channel> collapse(List<Channel> channels) {
    if (_byMember.isEmpty) return channels;
    final out = <Channel>[];
    for (final c in channels) {
      final g = _byMember[c.id];
      if (g == null) {
        out.add(c);
        continue;
      }
      if (_rep[g.key] != c.id) continue;
      String? pick(String? Function(Channel) f) {
        if ((f(c) ?? '').isNotEmpty) return null;
        for (final m in g.members) {
          final v = f(m);
          if (v != null && v.isNotEmpty) return v;
        }
        return null;
      }

      final logo = pick((m) => m.logoUrl);
      final epg = pick((m) => m.epgId);
      out.add(logo == null && epg == null
          ? c
          : c.copyWith(logoUrl: logo, epgId: epg));
    }
    return out;
  }
}
