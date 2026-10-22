package de.jasonstream.data.epg

import de.jasonstream.core.model.Channel
import de.jasonstream.core.model.EpgEntry
import de.jasonstream.data.net.Net
import java.io.BufferedInputStream
import java.io.InputStream
import java.io.InputStreamReader
import java.nio.charset.CodingErrorAction
import java.util.zip.GZIPInputStream

/**
 * Lädt und parst XMLTV (gz oder unkomprimiert) **als Datenstrom**: Netz →
 * (gunzip) → UTF-8 → [XmltvScanner], je 512 K Zeichen. Im Speicher liegt
 * nie mehr als ein Stück plus das Ergebnis (Port von xmltv_parser.dart, ohne
 * Isolate – Aufrufer laufen auf Dispatchers.IO).
 */
object XmltvLoader {
    const val MAX_DOWNLOAD_BYTES = 300L * 1024 * 1024
    private const val CHUNK = 512 * 1024

    /** Datenstrom parsen (erkennt gzip an 1f 8b). */
    fun parse(
        input: InputStream,
        channelIds: Set<String>? = null,
        wants: ((String) -> Boolean)? = null,
        namesOut: MutableMap<String, String>? = null,
        offsetMinutes: Int = 0,
        now: Long = System.currentTimeMillis(),
    ): Map<String, List<EpgEntry>> {
        val scanner = XmltvScanner(channelIds, wants, now).apply { shiftMs = offsetMinutes * 60_000L }
        val buffered = BufferedInputStream(input, 64 * 1024)
        buffered.mark(2)
        val b0 = buffered.read()
        val b1 = buffered.read()
        buffered.reset()
        val raw: InputStream = if (b0 == 0x1f && b1 == 0x8b) GZIPInputStream(buffered, 64 * 1024) else buffered
        val decoder = Charsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPLACE)
            .onUnmappableCharacter(CodingErrorAction.REPLACE)
        InputStreamReader(raw, decoder).use { r ->
            val buf = CharArray(CHUNK)
            while (true) {
                val n = r.read(buf)
                if (n < 0) break
                if (n > 0) scanner.write(String(buf, 0, n))
            }
        }
        val out = scanner.finish()
        namesOut?.putAll(scanner.channelNames)
        return out
    }

    fun parse(xml: String, channelIds: Set<String>? = null, offsetMinutes: Int = 0, now: Long = System.currentTimeMillis()) =
        XmltvScanner(channelIds, null, now).apply {
            shiftMs = offsetMinutes * 60_000L
            write(xml)
        }.finish()

    /**
     * Alle Quellen (Adresse, Versatz in Minuten) nacheinander laden und
     * zusammenführen – frühere Quellen haben Vorrang. Wirft den ersten Fehler
     * nur, wenn gar nichts geladen werden konnte. [shifts]: EPG-Schlüssel →
     * Minuten (tvg-shift), nach der Obergrenze angewendet.
     */
    fun loadSources(
        sources: List<Pair<String, Int>>,
        channels: List<Channel>?,
        headers: Map<String, String>,
        channelIds: Set<String>? = null,
        shifts: Map<String, Int>? = null,
        namesOut: MutableMap<String, String>? = null,
        onProgress: ((index: Int, received: Long, total: Long?) -> Unit)? = null,
    ): Map<String, List<EpgEntry>> {
        if (sources.isEmpty()) return emptyMap()
        val matcher = channels?.let { EpgMatcher(it) }
        val out = LinkedHashMap<String, List<EpgEntry>>()
        var firstError: Exception? = null
        sources.forEachIndexed { i, (url, offset) ->
            try {
                Net.open(url, headers, timeoutMs = 90_000, maxBytes = MAX_DOWNLOAD_BYTES).use { body ->
                    val counting = object : java.io.FilterInputStream(body.source.inputStream()) {
                        var n = 0L
                        var last = 0L
                        override fun read(b: ByteArray, off: Int, len: Int): Int {
                            val r = super.read(b, off, len)
                            if (r > 0) {
                                n += r
                                if (n - last > 512 * 1024) { last = n; onProgress?.invoke(i, n, body.declaredLength) }
                            }
                            return r
                        }
                    }
                    val parsed = parse(
                        counting,
                        channelIds = if (matcher == null) channelIds else null,
                        wants = matcher?.let { m -> { id: String -> m.wants(id) } },
                        namesOut = namesOut,
                        offsetMinutes = offset,
                    )
                    val m = EpgWindow.cap(matcher?.assign(parsed) ?: parsed)
                    for ((k, v) in m) {
                        val prev = out[k]
                        if (prev == null || prev.isEmpty()) out[k] = v
                    }
                }
            } catch (e: Exception) {
                if (firstError == null) firstError = e
            }
        }
        if (out.isEmpty() && firstError != null) throw firstError!!
        var epg = EpgWindow.cap(out)
        if (!shifts.isNullOrEmpty()) {
            val m = LinkedHashMap(epg)
            for ((k, minutes) in shifts) {
                val l = m[k]
                if (l.isNullOrEmpty() || minutes == 0) continue
                m[k] = l.map { it.shifted(minutes * 60_000L) }
            }
            epg = m
        }
        return epg
    }

    /**
     * Viele Playlisten nennen Dutzende Länder-EPGs – nur die Länder der
     * Sender nehmen (Endung der EPG-Kennung), höchstens [max].
     */
    fun pickEpgUrls(urls: List<String>, channels: List<Channel>?, max: Int = 4): List<String> {
        val skip = Regex("ALL_SOURCES|DUMMY", RegexOption.IGNORE_CASE)
        val useful = urls.filter { !skip.containsMatchIn(it) }
        if (useful.size <= max || channels == null) return useful
        val count = LinkedHashMap<String, Int>()
        val cc = Regex("\\.([a-z]{2})$", RegexOption.IGNORE_CASE)
        for (c in channels) {
            val m = cc.find(c.epgId ?: "") ?: continue
            var code = m.groupValues[1].uppercase()
            if (code == "GB") code = "UK"
            count[code] = (count[code] ?: 0) + 1
        }
        val top = count.entries.sortedByDescending { it.value }.take(max).map { it.key }.toSet()
        val codeOf = Regex("ripper_([A-Z]{2})\\d*\\.xml", RegexOption.IGNORE_CASE)
        val picked = useful.filter { u -> codeOf.find(u)?.let { it.groupValues[1].uppercase() in top } ?: false }
        return picked.ifEmpty { useful.take(max) }
    }
}
