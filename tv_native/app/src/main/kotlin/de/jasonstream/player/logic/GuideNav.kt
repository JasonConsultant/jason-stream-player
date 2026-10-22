package de.jasonstream.player.logic

import de.jasonstream.core.model.EpgEntry

/**
 * Bewegung im TV-Guide-Raster – reine Logik, ohne Oberfläche.
 *
 * Der Fokus ist ein Zeitpunkt ([GuideCursor.anchor]) in einer Zeile. Die
 * fokussierte Zelle ist die Sendung, die zu diesem Zeitpunkt läuft – oder,
 * wo das EPG eine Lücke hat, ein 30-Minuten-Feld. ◀▶ springen von Zelle zu
 * Zelle, ▲▼ wechseln die Zeile und behalten die Uhrzeit. Das sichtbare
 * Zeitfenster ([GuideCursor.viewStart]) folgt dem Fokus in halben Stunden.
 */
data class GuideCursor(val row: Int, val anchor: Long, val viewStart: Long)

/** Fokussierbare Zelle: Sendung oder Lücke. */
data class GuideCell(val start: Long, val end: Long, val entry: EpgEntry?)

object GuideNav {
    const val SLOT = 30L * 60 * 1000

    fun floorSlot(t: Long, tzOffset: Long = 0): Long = Math.floorDiv(t + tzOffset, SLOT) * SLOT - tzOffset

    /** Zelle zum Zeitpunkt [t]: laufende Sendung oder Lücken-Feld (an Nachbarn gekappt). */
    fun cellAt(idx: EpgIndex, list: List<EpgEntry>, t: Long): GuideCell {
        idx.at(list, t)?.let { return GuideCell(it.startMs, it.endMs, it) }
        var s = floorSlot(t)
        var e = s + SLOT
        // Vorherige Sendung endet in diesem Feld → Lücke beginnt dort.
        idx.at(list, s)?.let { if (it.endMs > s) s = it.endMs }
        idx.after(list, t)?.let { if (it.startMs < e) e = it.startMs }
        if (s > t) s = t
        if (e <= t) e = t + 1
        return GuideCell(s, e, null)
    }

    fun right(idx: EpgIndex, list: List<EpgEntry>, c: GuideCursor, span: Long, min: Long, max: Long): GuideCursor {
        val cell = cellAt(idx, list, c.anchor)
        val t = cell.end.coerceAtMost(max)
        if (t <= c.anchor) return c
        return follow(c.copy(anchor = t), span, min, max)
    }

    fun left(idx: EpgIndex, list: List<EpgEntry>, c: GuideCursor, span: Long, min: Long, max: Long): GuideCursor {
        val cell = cellAt(idx, list, c.anchor)
        val t = cell.start - 1
        if (t < min) return c
        val prev = cellAt(idx, list, t)
        // Sehr lange Vorgänger-Sendung: nur so weit zurück, dass ihr Ende
        // sichtbar bleibt (Fenster springt nicht Stunden zurück).
        val a = maxOf(min, prev.start, prev.end - span / 2)
        return follow(c.copy(anchor = minOf(a, t)), span, min, max)
    }

    /** Zeile wechseln, Uhrzeit behalten. [rows] = Anzahl Zeilen. */
    fun vertical(c: GuideCursor, delta: Int, rows: Int): GuideCursor {
        if (rows <= 0) return c
        val r = (c.row + delta).coerceIn(0, rows - 1)
        // Uhrzeit nie vor dem sichtbaren Fenster (lange Sendungen).
        return c.copy(row = r, anchor = maxOf(c.anchor, c.viewStart))
    }

    /** Fenster so verschieben, dass der Fokus sichtbar ist. */
    fun follow(c: GuideCursor, span: Long, min: Long, max: Long): GuideCursor {
        var v = c.viewStart
        if (c.anchor < v) v = floorSlot(c.anchor)
        else if (c.anchor >= v + span - SLOT) v = floorSlot(c.anchor) - SLOT
        v = v.coerceIn(floorSlot(min), maxOf(floorSlot(min), max - span))
        return if (v == c.viewStart) c else c.copy(viewStart = v)
    }

    /** Sprung zu einem Zeitpunkt (Tag wählen, „Jetzt“). Fenster beginnt eine halbe Stunde davor. */
    fun jump(c: GuideCursor, t: Long, span: Long, min: Long, max: Long): GuideCursor {
        val a = t.coerceIn(min, max)
        val v = (floorSlot(a) - SLOT).coerceIn(floorSlot(min), maxOf(floorSlot(min), max - span))
        return c.copy(anchor = a, viewStart = v)
    }

    /** Was OK auf einer Zelle bewirkt. */
    enum class Action { PlayLive, PlayCatchup, Remind, None }

    fun actionFor(cell: GuideCell, now: Long, catchupDays: Int): Action {
        val e = cell.entry
        if (e == null) return if (cell.start <= now && cell.end > now) Action.PlayLive else Action.None
        return when {
            e.isNowAt(now) -> Action.PlayLive
            e.isPastAt(now) ->
                if (catchupDays > 0 && e.startMs >= now - catchupDays * 86_400_000L) Action.PlayCatchup else Action.None
            else -> Action.Remind
        }
    }
}
