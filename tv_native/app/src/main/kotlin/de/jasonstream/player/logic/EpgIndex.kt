package de.jasonstream.player.logic

import de.jasonstream.core.model.Channel
import de.jasonstream.core.model.EpgEntry
import de.jasonstream.data.epg.EpgWindow
import de.jasonstream.data.epg.epgKeyOf
import java.util.Calendar
import java.util.TimeZone

/** Laufende und nächste Sendung. */
data class NowNext(val now: EpgEntry?, val next: EpgEntry?) {
    val isEmpty get() = now == null && next == null

    companion object {
        val EMPTY = NowNext(null, null)
    }
}

/**
 * Schneller Zugriff auf das EPG (epgKey → Sendungen, nach Start sortiert):
 * Jetzt/Danach und Zeitfenster per Binärsuche – auch bei 1 Mio. Sendungen
 * und 50 000 Sendern ohne Kopien.
 */
class EpgIndex(
    map: Map<String, List<EpgEntry>>,
    /** Nachgeladenes Kurz-EPG (Portal), wenn das große EPG den Sender nicht kennt. */
    private val extra: Map<String, List<EpgEntry>> = emptyMap(),
) {
    private val epg: Map<String, List<EpgEntry>> = run {
        // Normalerweise schon sortiert – nur bei Bedarf sortieren.
        var sorted = true
        for (l in map.values) {
            for (i in 1 until l.size) if (l[i].startMs < l[i - 1].startMs) { sorted = false; break }
            if (!sorted) break
        }
        if (sorted) map else map.mapValues { (_, l) -> l.sortedBy { it.startMs } }
    }

    val size: Int get() = epg.size
    val isEmpty: Boolean get() = epg.isEmpty()
    val raw: Map<String, List<EpgEntry>> get() = epg

    fun of(c: Channel): List<EpgEntry> = epgKeyOf(c).let { k -> epg[k] ?: extra[k] } ?: emptyList()

    fun has(c: Channel): Boolean = epgKeyOf(c).let { epg.containsKey(it) || extra.containsKey(it) }

    /** Index der ersten Sendung mit Ende nach [t] (oder size). */
    private fun firstEndingAfter(l: List<EpgEntry>, t: Long): Int {
        var lo = 0
        var hi = l.size
        while (lo < hi) {
            val mid = (lo + hi) ushr 1
            if (l[mid].endMs <= t) lo = mid + 1 else hi = mid
        }
        return lo
    }

    fun nowNext(c: Channel, t: Long): NowNext {
        val l = of(c)
        if (l.isEmpty()) return NowNext.EMPTY
        val i = firstEndingAfter(l, t)
        if (i >= l.size) return NowNext.EMPTY
        val e = l[i]
        return if (e.startMs <= t) NowNext(e, l.getOrNull(i + 1)) else NowNext(null, e)
    }

    /** Sendung, die um [t] läuft. */
    fun at(c: Channel, t: Long): EpgEntry? = at(of(c), t)

    fun at(l: List<EpgEntry>, t: Long): EpgEntry? {
        val i = firstEndingAfter(l, t)
        val e = l.getOrNull(i) ?: return null
        return if (e.startMs <= t) e else null
    }

    /** Sendungen, die [from, to) berühren (Ansicht, keine Kopie). */
    fun range(c: Channel, from: Long, to: Long): List<EpgEntry> = range(of(c), from, to)

    fun range(l: List<EpgEntry>, from: Long, to: Long): List<EpgEntry> {
        if (l.isEmpty()) return l
        val a = firstEndingAfter(l, from)
        var b = a
        while (b < l.size && l[b].startMs < to) b++
        return if (a >= b) emptyList() else l.subList(a, b)
    }

    /** Vorherige Sendung vor [e] (oder null). */
    fun before(l: List<EpgEntry>, e: EpgEntry): EpgEntry? {
        val i = firstEndingAfter(l, e.startMs) // erste mit Ende > start (= e selbst oder Überlappung)
        return if (i > 0) l[i - 1] else null
    }

    /** Erste Sendung, die nach [t] beginnt. */
    fun after(l: List<EpgEntry>, t: Long): EpgEntry? {
        var i = firstEndingAfter(l, t)
        while (i < l.size && l[i].startMs <= t) i++
        return l.getOrNull(i)
    }

    /** Früheste und späteste Zeit im EPG (für die Tagesauswahl). */
    fun span(): Pair<Long, Long>? {
        var lo = Long.MAX_VALUE
        var hi = Long.MIN_VALUE
        for (l in epg.values) {
            if (l.isEmpty()) continue
            if (l.first().startMs < lo) lo = l.first().startMs
            if (l.last().endMs > hi) hi = l.last().endMs
        }
        return if (lo == Long.MAX_VALUE) null else lo to hi
    }

    companion object {
        val EMPTY = EpgIndex(emptyMap())
    }
}

/** Tage im TV-Guide (Port von guide_days.dart). */
object GuideDays {
    fun startOfDay(t: Long, tz: TimeZone = TimeZone.getDefault()): Long {
        val c = Calendar.getInstance(tz)
        c.timeInMillis = t
        c.set(Calendar.HOUR_OF_DAY, 0); c.set(Calendar.MINUTE, 0); c.set(Calendar.SECOND, 0); c.set(Calendar.MILLISECOND, 0)
        return c.timeInMillis
    }

    fun addDays(dayStart: Long, days: Int, tz: TimeZone = TimeZone.getDefault()): Long {
        val c = Calendar.getInstance(tz)
        c.timeInMillis = dayStart
        c.add(Calendar.DAY_OF_MONTH, days)
        return c.timeInMillis
    }

    /** Tag relativ zu heute (0 = heute). */
    fun dayOf(t: Long, now: Long, tz: TimeZone = TimeZone.getDefault()): Int {
        val d = startOfDay(t, tz) - startOfDay(now, tz)
        return Math.round(d / 86_400_000.0).toInt()
    }

    /** −7 … +7 Tage, nur soweit das EPG reicht; heute immer dabei. */
    fun offsets(span: Pair<Long, Long>?, now: Long, tz: TimeZone = TimeZone.getDefault()): List<Int> {
        val back = (EpgWindow.BACK / EpgWindow.DAY).toInt()
        val fwd = (EpgWindow.FORWARD / EpgWindow.DAY).toInt()
        val first = span?.let { dayOf(it.first, now, tz).coerceIn(-back, 0) } ?: 0
        val last = span?.let { dayOf(it.second - 1000, now, tz).coerceIn(0, fwd) } ?: 0
        return (first..last).toList()
    }

    /** Gleiche Uhrzeit wie jetzt (auf halbe Stunde abgerundet) am Tag [offset]. */
    fun jumpTarget(offset: Int, now: Long, tz: TimeZone = TimeZone.getDefault()): Long {
        val c = Calendar.getInstance(tz)
        c.timeInMillis = now
        c.add(Calendar.DAY_OF_MONTH, offset)
        c.set(Calendar.MINUTE, if (c.get(Calendar.MINUTE) < 30) 0 else 30)
        c.set(Calendar.SECOND, 0); c.set(Calendar.MILLISECOND, 0)
        return c.timeInMillis
    }
}
