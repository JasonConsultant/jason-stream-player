package de.jasonstream.data.epg

import de.jasonstream.core.model.Channel
import de.jasonstream.core.model.EpgEntry
import kotlin.math.roundToInt

/** Schlüssel, unter dem das Programm eines Senders liegt: EPG-Kennung, sonst „@“ + ID. */
fun epgKeyOf(c: Channel): String = if (!c.epgId.isNullOrEmpty()) c.epgId!! else "@${c.id}"

fun epgOf(epg: Map<String, List<EpgEntry>>, c: Channel): List<EpgEntry> = epg[epgKeyOf(c)] ?: emptyList()

/**
 * Zeitfenster und Speichergrenzen des EPG (Port von epg_window.dart):
 * 7 Tage zurück, 7 Tage voraus; Obergrenzen pro Sender und insgesamt.
 */
object EpgWindow {
    const val DAY = 24L * 3600 * 1000
    const val BACK = 7 * DAY
    const val FORWARD = 7 * DAY
    const val MAX_PER_CHANNEL = 900
    const val DEFAULT_MAX_TOTAL = 1_200_000

    @Volatile
    var maxTotal = DEFAULT_MAX_TOTAL

    /** ≤ 2,5 GB RAM → 500 000 Sendungen, „Low-RAM“ → 250 000. */
    fun tuneForDevice(totalBytes: Long, lowRam: Boolean) {
        maxTotal = when {
            lowRam -> 250_000
            totalBytes <= 2560L shl 20 -> 500_000
            else -> DEFAULT_MAX_TOTAL
        }
    }

    fun from(now: Long) = now - BACK
    fun to(now: Long) = now + FORWARD

    fun cap(
        epg: Map<String, List<EpgEntry>>,
        now: Long = System.currentTimeMillis(),
        total: Int? = null,
        perChannel: Int = MAX_PER_CHANNEL,
        window: Boolean = false,
    ): Map<String, List<EpgEntry>> {
        val limit = total ?: maxTotal
        var fwd = FORWARD
        var bwd = BACK
        fun apply(): Map<String, List<EpgEntry>> {
            val lo = now - bwd
            val hi = now + fwd
            val out = LinkedHashMap<String, List<EpgEntry>>()
            for ((k, v) in epg) {
                var list = v.filter { it.endMs > lo && it.startMs < hi }
                if (list.size > perChannel) list = nearest(list, now, perChannel)
                if (list.isNotEmpty()) out[k] = list
            }
            return out
        }
        fun count(m: Map<String, List<EpgEntry>>) = m.values.sumOf { it.size }
        if (!window && count(epg) <= limit && epg.values.all { it.size <= perChannel }) return epg
        var out = apply()
        while (count(out) > limit) {
            if (fwd > 2 * DAY) fwd -= DAY
            else if (bwd > DAY) bwd -= DAY
            else break
            out = apply()
        }
        return out
    }

    private fun nearest(list: List<EpgEntry>, now: Long, keep: Int): List<EpgEntry> {
        var i = list.indexOfFirst { it.endMs > now }
        if (i < 0) i = list.size
        var start = (i - keep / 2).coerceAtLeast(0)
        var end = start + keep
        if (end > list.size) {
            end = list.size
            start = (end - keep).coerceIn(0, end)
        }
        return list.subList(start, end).toList()
    }

    fun shift(epg: Map<String, List<EpgEntry>>, offsetMs: Long): Map<String, List<EpgEntry>> =
        if (offsetMs == 0L) epg else epg.mapValues { (_, l) -> l.map { it.shifted(offsetMs) } }

    /** −3 h … +3 h in 30-Minuten-Schritten. */
    fun clampOffset(minutes: Int): Int = ((minutes / 30.0).roundToIntDart() * 30).coerceIn(-180, 180)

    private fun Double.roundToIntDart(): Int = if (this < 0) -(-this).roundToInt() else roundToInt()
}

/**
 * Ordnet XMLTV-Kanäle den Sendern zu – wie TiviMate (Port von epg_matcher.dart):
 * 1. EPG-Kennung exakt, 2. ohne Groß/Klein, 3. über den Sendernamen.
 */
class EpgMatcher(val channels: List<Channel>) {
    private val byId = HashMap<String, MutableList<Channel>>()
    private val byName = HashMap<String, MutableList<Channel>>()
    private val cache = HashMap<String, Boolean>()

    init {
        for (c in channels) {
            val id = c.epgId?.trim()
            if (!id.isNullOrEmpty()) byId.getOrPut(id.lowercase()) { ArrayList() }.add(c)
            if (id != null && id.isEmpty()) continue // „Kein EPG“
            val n = nameKey(c.name)
            if (n.length >= 2) byName.getOrPut(n) { ArrayList() }.add(c)
        }
    }

    companion object {
        // Dart: RegExp(..., caseSensitive: false) – \b dort ASCII-Wortgrenze.
        private const val W = "[A-Za-z0-9_]"
        private val prefix = Regex(
            "^\\s*(?:[|\\[(]\\s*[a-z]{2,3}\\s*[|\\])]\\s*[:•\\-–]?|[a-z]{2,3}\\s*[:|•\\-–])\\s*",
            RegexOption.IGNORE_CASE,
        )
        private val brackets = Regex("[(\\[{].*?[)\\]}]")
        private val quality = Regex(
            "(?<!$W)(?:u?hd|fhd|sd|4k|8k|hevc|h\\.?26[45]|raw|backup|1080[pi]?|720p|50fps|60fps|vip|plus)(?!$W)",
            RegexOption.IGNORE_CASE,
        )
        private val country = Regex("\\.[a-z]{2,3}$", RegexOption.IGNORE_CASE)
        private val nonAlnum = Regex("[^0-9a-zäöüßçğışéèáàâ]")

        /** Vergleichsschlüssel aus einem Sendernamen. */
        fun nameKey(name: String): String {
            var s = prefix.replaceFirst(name.lowercase(), "")
            s = brackets.replace(s, " ")
            s = quality.replace(s, " ")
            s = quality.replace(s.replace("+", " plus "), " ")
            return nonAlnum.replace(s, "")
        }

        /** Vergleichsschlüssel aus einer XMLTV-Kennung („ZDF.de“ → „zdf“). */
        fun idKey(id: String) = nameKey(country.replaceFirst(id, ""))
    }

    /** Wird das Programm dieser XMLTV-Kennung gebraucht? */
    fun wants(xmltvId: String): Boolean = cache.getOrPut(xmltvId) {
        byId.containsKey(xmltvId.lowercase()) || byName.containsKey(idKey(xmltvId))
    }

    /** Ergebnis des Parsers (nach XMLTV-Kennung) → Map nach [epgKeyOf]. */
    fun assign(parsed: Map<String, List<EpgEntry>>): Map<String, List<EpgEntry>> {
        val out = LinkedHashMap<String, List<EpgEntry>>()
        for ((k, v) in parsed) {
            for (c in byId[k.lowercase()] ?: emptyList()) out.putIfAbsent(epgKeyOf(c), v)
        }
        val byIdKey = HashMap<String, List<EpgEntry>>()
        for ((k, v) in parsed) {
            val key = idKey(k)
            val prev = byIdKey[key]
            if (prev == null || v.size > prev.size) byIdKey[key] = v
        }
        for (c in channels) {
            if (c.epgId == "") continue
            val key = epgKeyOf(c)
            if (out.containsKey(key)) continue
            byIdKey[nameKey(c.name)]?.let { out[key] = it }
        }
        return out
    }
}
