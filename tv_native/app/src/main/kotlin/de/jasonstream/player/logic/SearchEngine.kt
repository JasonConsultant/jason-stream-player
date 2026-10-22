package de.jasonstream.player.logic

import de.jasonstream.core.model.Channel
import de.jasonstream.core.model.EpgEntry
import de.jasonstream.data.epg.epgKeyOf

data class ShowHit(val channel: Channel, val entry: EpgEntry)

data class SearchResults(val channels: List<Channel>, val shows: List<ShowHit>) {
    val isEmpty get() = channels.isEmpty() && shows.isEmpty()

    companion object {
        val EMPTY = SearchResults(emptyList(), emptyList())
    }
}

/**
 * Suche über Sender und EPG-Sendungen (Port von search_engine.dart):
 * - Kleinbuchstaben einmal je Liste, gleiche Sendungstitel nur einmal.
 * - Wird der Begriff nur verlängert, wird in den alten Treffern gesucht.
 * - Sender: genauer Name → Anfang → Wortanfang → irgendwo (stabil).
 * - Sendungen: läuft → demnächst → vergangen (nur mit Archiv, neueste zuerst).
 */
class SearchEngine(private val channels: List<Channel>, epg: Map<String, List<EpgEntry>>) {
    companion object {
        const val MAX_CHANNELS = 40
        const val MAX_SHOWS = 60
        const val MIN_QUERY = 2

        fun normalize(q: String) = q.replace("​", "").trim().lowercase()

        /** 0 = genau, 1 = Anfang, 2 = Wortanfang, 3 = enthalten. */
        fun rankName(lower: String, q: String): Int = when {
            lower == q -> 0
            lower.startsWith(q) -> 1
            wordStart(lower, q) -> 2
            else -> 3
        }

        private fun wordStart(s: String, q: String): Boolean {
            var i = s.indexOf(q)
            while (i > 0) {
                if (!s[i - 1].isLetterOrDigit()) return true
                i = s.indexOf(q, i + 1)
            }
            return i == 0
        }
    }

    private val chLane = Lane(channels.map { it.name.lowercase() })
    private val titles = ArrayList<String>()
    private val hits = ArrayList<MutableList<ShowHit>>()
    private val tiLane: Lane

    init {
        val byKey = HashMap<String, Channel>(channels.size * 2)
        for (c in channels) byKey.putIfAbsent(epgKeyOf(c), c)
        val index = HashMap<String, Int>()
        for ((k, list) in epg) {
            val c = byKey[k] ?: continue
            for (p in list) {
                val i = index.getOrPut(p.title) {
                    titles.add(p.title.lowercase()); hits.add(ArrayList()); titles.size - 1
                }
                hits[i].add(ShowHit(c, p))
            }
        }
        tiLane = Lane(titles)
    }

    fun search(query: String, now: Long): SearchResults {
        val q = normalize(query)
        if (q.length < MIN_QUERY) return SearchResults.EMPTY
        val chIdx = chLane.find(q)
        // Rang berechnen, stabil sortieren, kürzen.
        val ranked = chIdx.sortedWith(compareBy({ rankName(chLane.lower[it], q) }, { it }))
        val chans = ranked.take(MAX_CHANNELS).map { channels[it] }

        val from = now - 7 * 86_400_000L
        val to = now + 2 * 86_400_000L
        fun rank(e: EpgEntry) = if (e.isNowAt(now)) 0 else if (e.startMs > now) 1 else 2
        val cmp = Comparator<ShowHit> { a, b ->
            val ra = rank(a.entry)
            val rb = rank(b.entry)
            if (ra != rb) ra.compareTo(rb)
            else if (ra == 2) b.entry.startMs.compareTo(a.entry.startMs)
            else a.entry.startMs.compareTo(b.entry.startMs)
        }
        val shows = ArrayList<ShowHit>()
        for (t in tiLane.find(q)) {
            for (s in hits[t]) {
                val p = s.entry
                if (p.endMs < from || p.startMs > to) continue
                if (p.isPastAt(now) && !s.channel.hasCatchup) continue
                if (shows.size == MAX_SHOWS && cmp.compare(s, shows.last()) >= 0) continue
                var lo = 0
                var hi = shows.size
                while (lo < hi) {
                    val mid = (lo + hi) ushr 1
                    if (cmp.compare(shows[mid], s) <= 0) lo = mid + 1 else hi = mid
                }
                shows.add(lo, s)
                if (shows.size > MAX_SHOWS) shows.removeAt(shows.size - 1)
            }
        }
        return SearchResults(chans, shows)
    }

    /** Durchsuchbare Liste mit Gedächtnis für die letzte Suche. */
    private class Lane(val lower: List<String>) {
        private var lastQ: String? = null
        private var last: List<Int>? = null

        fun find(q: String): List<Int> {
            val pq = lastQ
            val prev = last
            val out = if (pq != null && prev != null && q.startsWith(pq)) prev.filter { lower[it].contains(q) }
            else lower.indices.filter { lower[it].contains(q) }
            lastQ = q
            last = out
            return out
        }
    }
}

/** „Letzte Suchen“ (höchstens 8, neueste zuerst, Groß/Klein-Dubletten ersetzt). */
object RecentSearches {
    const val MAX = 8

    fun add(list: List<String>, query: String): List<String> {
        val q = query.trim()
        if (q.length < 2) return list
        val low = q.lowercase()
        return (listOf(q) + list.filter { it.lowercase() != low }).take(MAX)
    }

    fun remove(list: List<String>, query: String) = list.filter { it != query }
}
