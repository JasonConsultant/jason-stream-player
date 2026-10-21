import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../l10n/strings.dart';
import '../../models/models.dart';

/// Vorlesetexte für TalkBack (Bedienungshilfen). Kurz, das Wichtigste
/// zuerst: Name, dann laufende Sendung.

/// Sender in Listen und Zapping-Leiste: „12 Das Erste, jetzt: Tagesschau“.
String channelSemantics(Channel c, EpgEntry? now) {
  final head = c.number > 0 ? '${c.number} ${c.name}' : c.name;
  final title = now?.title.trim() ?? '';
  return title.isEmpty ? head : trf('{0}, jetzt: {1}', [head, title]);
}

/// Film/Serie (Poster): „Titel, 2021“, dazu „Gesehen“ bzw. „40 % gesehen“.
String posterSemantics(String title,
    {int? year, bool seen = false, double? progress}) {
  final state = _watchState(seen, progress);
  return [
    title,
    if (year != null && year > 0) '$year',
    if (state != null) state,
  ].join(', ');
}

String? _watchState(bool seen, double? progress) {
  if (seen) return tr('Gesehen');
  if (progress != null && progress > 0) {
    final pct = (progress * 100).round().clamp(1, 100);
    return trf('{0} % gesehen', [pct]);
  }
  return null;
}

/// Uhrzeit-Spanne zum Vorlesen: „20:15 bis 21:00“.
String timeRangeSemantics(DateTime from, DateTime to) {
  final f = DateFormat.Hm(L10n.lang);
  return trf('{0} bis {1}', [f.format(from), f.format(to)]);
}

/// Sendung im TV-Guide: „Tagesschau, 20:00 bis 20:15, Das Erste“ – dazu
/// „läuft gerade“ bzw. „Replay verfügbar“. [entry] null = keine
/// Programminfo.
String programmeSemantics(EpgEntry? entry, Channel channel,
    {bool running = false, bool replay = false}) {
  if (entry == null) return '${tr('Keine Programminfo')}, ${channel.name}';
  final title = entry.title.trim();
  return [
    if (title.isNotEmpty) title,
    timeRangeSemantics(entry.start, entry.end),
    channel.name,
    if (running) tr('läuft gerade') else if (replay) tr('Replay verfügbar'),
  ].join(', ');
}

/// Serienfolge: „Staffel 1, Folge 3: Titel, 45 Min., Gesehen“.
String episodeSemantics(Episode e,
    {bool watched = false, double? progress}) {
  final mins = e.duration?.inMinutes ?? 0;
  final state = _watchState(watched, progress);
  return [
    trf('Staffel {0}, Folge {1}: {2}', [e.season, e.number, e.title.trim()]),
    if (mins > 0) trf('{0} Min.', [mins]),
    if (state != null) state,
  ].join(', ');
}

/// Staffel-Reiter: „Staffel 2, 3 von 10 gesehen“.
String seasonSemantics(String label, int watched, int total) =>
    '$label, ${trf('{0} von {1} gesehen', [watched, total])}';

/// Bewertung: „Bewertung 7,5“ statt „Stern 7.5“.
String ratingSemantics(double rating) =>
    trf('Bewertung {0}', [NumberFormat('0.0', L10n.lang).format(rating)]);

/// Runde Symbol-Knöpfe im Player: Vorlesetext je Symbol (null = unbekannt,
/// dann bleibt es beim Symbol).
String? playerButtonSemantics(IconData icon) {
  bool is_(IconData i) => i == icon;
  if (is_(Icons.arrow_back_rounded)) return tr('Zurück');
  if (is_(Icons.screen_rotation_rounded)) return tr('Bild drehen');
  if (is_(Icons.more_vert_rounded)) return tr('Optionen');
  if (is_(Icons.aspect_ratio_rounded)) return tr('Bildformat');
  if (is_(Icons.subtitles_outlined)) return tr('Tonspur & Untertitel');
  if (is_(Icons.picture_in_picture_alt_rounded)) return tr('Bild-in-Bild');
  if (is_(Icons.bedtime_outlined)) return tr('Schlaf-Timer');
  if (is_(Icons.replay_rounded)) return tr('Von vorne');
  if (is_(Icons.swap_horiz_rounded)) return tr('Vorheriger Sender');
  if (is_(Icons.fiber_manual_record_rounded)) return tr('Aufnehmen');
  if (is_(Icons.grid_view_rounded)) return tr('Mehrfachansicht');
  if (is_(Icons.keyboard_arrow_up_rounded)) return tr('Nächster Sender');
  if (is_(Icons.keyboard_arrow_down_rounded)) return tr('Vorheriger Sender');
  if (is_(Icons.layers_rounded)) return tr('Qualität/Quelle wählen');
  if (is_(Icons.star_rounded)) return tr('Favorit');
  if (is_(Icons.star_border_rounded)) return tr('Favorit');
  if (is_(Icons.format_list_bulleted_rounded)) return tr('Senderliste');
  if (is_(Icons.play_arrow_rounded)) return tr('Abspielen');
  if (is_(Icons.pause_rounded)) return tr('Pause');
  if (is_(Icons.replay_10_rounded)) return tr('10 Sekunden zurück');
  if (is_(Icons.forward_10_rounded)) return tr('10 Sekunden vor');
  return null;
}
