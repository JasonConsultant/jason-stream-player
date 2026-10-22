package de.jasonstream.data.m3u

import de.jasonstream.core.model.AccountInfo
import de.jasonstream.core.model.Channel
import de.jasonstream.core.model.EpgEntry
import de.jasonstream.core.model.HostFailover
import de.jasonstream.core.model.Portal
import de.jasonstream.core.model.RepositoryException
import de.jasonstream.data.IptvRepository
import de.jasonstream.data.LiveList
import de.jasonstream.data.epg.epgKeyOf
import de.jasonstream.data.net.Net
import de.jasonstream.data.net.StreamHeaders
import okio.buffer
import okio.source
import java.io.File
import java.time.Instant
import java.time.ZoneId

/**
 * M3U/M3U8-Playlist mit optionalem XMLTV-EPG und Catch-up
 * (catchup="default|append|shift|flussonic" + catchup-source) –
 * Port von m3u_repository.dart. Die Playlist wird zeilenweise aus dem
 * Netz-Datenstrom geparst.
 */
class M3uRepository(portal: Portal, private val zone: ZoneId = ZoneId.systemDefault()) : IptvRepository(portal) {
    @Volatile
    private var cache: M3uParser.Result? = null

    private fun load(): M3uParser.Result {
        cache?.let { return it }
        val url = portal.url.trim()
        val result = if (url.startsWith("file://")) {
            File(url.removePrefix("file://")).source().buffer().use { M3uParser.parse(it) }
        } else {
            HostFailover.run(portal) { u ->
                Net.open(u, StreamHeaders.portalHeaders(portal), timeoutMs = 60_000, maxBytes = 80L * 1024 * 1024)
                    .use { M3uParser.parse(it.source) }
            }
        } ?: throw RepositoryException("Das ist keine gültige M3U-Playlist.")
        cache = result
        return result
    }

    override fun login(): AccountInfo? { load(); return null }

    override fun live(): LiveList = load().let { LiveList(it.categories, it.channels) }

    override fun providerEpgUrl() = load().epgUrl

    override fun loadEpg(channels: List<Channel>?, onProgress: ((Int, Int, Long, Long?) -> Unit)?) =
        loadXmltvSources(channels, onProgress, shifts = tvgShifts(channels ?: load().channels))

    override fun resolveStreamUrl(c: Channel) = HostFailover.rewrite(portal, c.streamUrl)

    override fun catchupUrl(c: Channel, e: EpgEntry, nowMs: Long): String? {
        if (!c.hasCatchup) return null
        return when ((c.catchupMode ?: "default").lowercase()) {
            "shift" -> {
                val sep = if (c.streamUrl.contains('?')) "&" else "?"
                "${c.streamUrl}${sep}utc=${e.startMs / 1000}&lutc=${nowMs / 1000}"
            }
            "flussonic", "fs" -> {
                val dur = e.durationMs / 1000
                val m = flussonicRe.find(c.streamUrl) ?: return c.streamUrl
                val rep = "/${m.groupValues[1]}-${e.startMs / 1000}-$dur${m.groups[2]?.value ?: ".m3u8"}${m.groupValues[3]}"
                c.streamUrl.substring(0, m.range.first) + rep + c.streamUrl.substring(m.range.last + 1)
            }
            "append" -> c.catchupSource?.let { c.streamUrl + fill(it, e, nowMs, zone) }
            else -> c.catchupSource?.let { fill(it, e, nowMs, zone) }
        }
    }

    companion object {
        private val flussonicRe = Regex("/(index|video|mono)(\\.m3u8|\\.ts|-live\\.m3u8)?(\\?|$)")
        private val durationRe = Regex("\\$?\\{duration(?::(\\d+))?\\}")
        private val placeholderRe = Regex("\\$?\\{([A-Za-z]+)\\}")

        /** EPG-Schlüssel → tvg-shift in Minuten (erster Sender je Schlüssel). */
        fun tvgShifts(channels: List<Channel>): Map<String, Int> {
            val out = LinkedHashMap<String, Int>()
            val done = HashSet<String>()
            for (c in channels) {
                val key = epgKeyOf(c)
                if (!done.add(key) || c.epgShift == 0) continue
                out[key] = c.epgShift
            }
            return out
        }

        /** tvg-shift auf ein EPG anwenden (einmal je Kennung). */
        fun applyTvgShift(epg: MutableMap<String, List<EpgEntry>>, channels: List<Channel>): MutableMap<String, List<EpgEntry>> {
            for ((k, minutes) in tvgShifts(channels)) {
                val l = epg[k] ?: continue
                if (l.isEmpty()) continue
                epg[k] = l.map { it.shifted(minutes * 60_000L) }
            }
            return epg
        }

        /** Ersetzt die gängigen Platzhalter in catchup-source. */
        fun fill(tpl: String, e: EpgEntry, nowMs: Long, zone: ZoneId): String {
            fun two(n: Int) = n.toString().padStart(2, '0')
            val s = Instant.ofEpochMilli(e.startMs).atZone(zone)
            val start = (e.startMs / 1000).toString()
            val values = mapOf(
                "utc" to start, "start" to start, "timestamp" to start,
                "utcend" to (e.endMs / 1000).toString(), "end" to (e.endMs / 1000).toString(),
                "lutc" to (nowMs / 1000).toString(), "now" to (nowMs / 1000).toString(),
                "offset" to ((nowMs - e.startMs) / 1000).toString(),
                "Y" to s.year.toString(), "m" to two(s.monthValue), "d" to two(s.dayOfMonth),
                "H" to two(s.hour), "M" to two(s.minute), "S" to two(s.second),
            )
            var out = durationRe.replace(tpl) { m ->
                val div = m.groups[1]?.value?.toIntOrNull()?.takeIf { it != 0 } ?: 1
                ((e.durationMs / 1000) / div).toString()
            }
            out = placeholderRe.replace(out) { m -> values[m.groupValues[1]] ?: m.value }
            return out
        }
    }
}
