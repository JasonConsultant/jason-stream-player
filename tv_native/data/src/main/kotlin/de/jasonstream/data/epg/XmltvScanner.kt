package de.jasonstream.data.epg

import de.jasonstream.core.model.EpgEntry

/**
 * Spezialisierter XMLTV-Scanner (Port von xmltv_scanner.dart): sucht direkt
 * nach `<programme …>…</programme>` statt einen allgemeinen XML-Parser zu
 * benutzen. Sender außerhalb des Filters werden übersprungen, ohne ihren
 * Inhalt zu lesen. Bekommt den Text stückweise über [write] und behält nur
 * den unvollständigen Rest zwischen zwei Stücken.
 */
class XmltvScanner(
    private val channelIds: Set<String>? = null,
    private val wants: ((String) -> Boolean)? = null,
    now: Long = System.currentTimeMillis(),
) {
    private val from = EpgWindow.from(now)
    private val to = EpgWindow.to(now)
    val result = LinkedHashMap<String, MutableList<EpgEntry>>()

    /** XMLTV-Kennung → erster `<display-name>` (für die manuelle Zuordnung). */
    val channelNames = LinkedHashMap<String, String>()
    private var carry = ""
    private var chanHint = -2
    private var chanHintFrom = 0

    /** Zeitversatz der Quelle in ms (vor der Prüfung des Zeitfensters). */
    var shiftMs = 0L

    companion object {
        const val MAX_CHANNEL_NAMES = 20000
        private val attrRe = Regex("""([\w:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')""")

        private fun isBoundary(c: Char) =
            c == ' ' || c == '>' || c == '\t' || c == '\n' || c == '\r' || c == '/'

        /** XMLTV-Zeit „20261019120000 +0200“ → Epoch-ms (UTC), ohne substring/RegExp. */
        fun fastTime(s: String): Long? {
            if (s.length < 14) return null
            fun d(i: Int): Int {
                val c = s[i] - '0'
                if (c < 0 || c > 9) throw NumberFormatException()
                return c
            }
            return try {
                val y = d(0) * 1000 + d(1) * 100 + d(2) * 10 + d(3)
                val mo = d(4) * 10 + d(5)
                val da = d(6) * 10 + d(7)
                val h = d(8) * 10 + d(9)
                val mi = d(10) * 10 + d(11)
                val se = d(12) * 10 + d(13)
                var offsetMin = 0
                var i = 14
                while (i < s.length && s[i] == ' ') i++
                if (s.length >= i + 5) {
                    val sign = s[i]
                    if (sign == '+' || sign == '-') {
                        offsetMin = (d(i + 1) * 10 + d(i + 2)) * 60 + d(i + 3) * 10 + d(i + 4)
                        if (sign == '-') offsetMin = -offsetMin
                    }
                }
                utcMillis(y, mo, da, h, mi, se) - offsetMin * 60_000L
            } catch (_: NumberFormatException) {
                null
            }
        }

        /** Wie DateTime.utc (Monate/Tage außerhalb des Bereichs werden übertragen). */
        fun utcMillis(y0: Int, mo0: Int, d: Int, h: Int, mi: Int, s: Int): Long {
            var y = y0.toLong()
            var m = mo0.toLong() - 1
            y += Math.floorDiv(m, 12L)
            m = Math.floorMod(m, 12L)
            val days = daysFromCivil(y, m + 1, 1) + (d - 1)
            return ((days * 24 + h) * 60 + mi) * 60_000L + s * 1000L
        }

        private fun daysFromCivil(y0: Long, m: Long, d: Long): Long {
            val y = if (m <= 2) y0 - 1 else y0
            val era = Math.floorDiv(y, 400L)
            val yoe = y - era * 400
            val doy = (153 * (if (m > 2) m - 3 else m + 9) + 2) / 5 + d - 1
            val doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
            return era * 146097 + doe - 719468
        }

        private val entity = Regex("&(#x[0-9a-fA-F]+|#\\d+|amp|lt|gt|quot|apos);")

        fun unescape(v: String): String {
            if (!v.contains('&')) return v
            return entity.replace(v) { m ->
                when (val e = m.groupValues[1]) {
                    "amp" -> "&"
                    "lt" -> "<"
                    "gt" -> ">"
                    "quot" -> "\""
                    "apos" -> "'"
                    else -> {
                        val code = if (e.startsWith("#x")) e.substring(2).toIntOrNull(16) else e.substring(1).toIntOrNull()
                        if (code == null || code < 0 || code > 0x10FFFF) m.value else String(Character.toChars(code))
                    }
                }
            }
        }

        private fun attrValue(s: String, name: String, from: Int, to: Int): String? {
            var k = from
            while (true) {
                k = s.indexOf(name, k)
                if (k < 0 || k >= to) return null
                val before = s[k - 1]
                val eq = k + name.length
                if ((before == ' ' || before == '\t' || before == '\n' || before == '\r') && eq + 1 < to && s[eq] == '=') {
                    val q = s[eq + 1]
                    if (q == '"' || q == '\'') {
                        val end = s.indexOf(q, eq + 2)
                        if (end < 0 || end > to) return null
                        return s.substring(eq + 2, end)
                    }
                }
                k = eq
            }
        }

        /** Inhalt des ersten Kind-Elements [name] (erste Sprache gewinnt). */
        private fun child(s: String, name: String, from: Int, to: Int): String? {
            var k = from
            while (true) {
                k = s.indexOf("<$name", k)
                if (k < 0 || k >= to) return null
                if (k + name.length + 1 < s.length && isBoundary(s[k + name.length + 1])) break
                k += name.length + 1
            }
            val open = s.indexOf('>', k)
            if (open < 0 || open >= to) return null
            if (s[open - 1] == '/') return ""
            val end = s.indexOf("</$name>", open)
            if (end < 0 || end > to) return null
            val v = s.substring(open + 1, end)
            if (!v.contains("<![CDATA[")) return unescape(v).trim()
            val b = StringBuilder()
            var p = 0
            while (true) {
                val c = v.indexOf("<![CDATA[", p)
                if (c < 0) { b.append(unescape(v.substring(p))); break }
                b.append(unescape(v.substring(p, c)))
                val ce = v.indexOf("]]>", c + 9)
                if (ce < 0) { b.append(v.substring(c + 9)); break }
                b.append(v, c + 9, ce)
                p = ce + 3
            }
            return b.toString().trim()
        }
    }

    fun write(chunk: String) {
        val s = if (carry.isEmpty()) chunk else carry + chunk
        chanHint = -2
        var pos = 0
        while (true) {
            val i = s.indexOf("<programme", pos)
            if (i < 0) {
                var keep = s.length - 16
                val openCh = channels(s, pos, s.length)
                if (openCh >= 0 && s.length - openCh < 4096) keep = openCh
                carry = s.substring(if (keep > pos) keep else pos)
                return
            }
            channels(s, pos, i)
            if (i + 10 >= s.length) { carry = s.substring(i); return }
            if (!isBoundary(s[i + 10])) { pos = i + 10; continue }
            val tagEnd = s.indexOf('>', i)
            if (tagEnd < 0) { carry = s.substring(i); return }
            if (s[tagEnd - 1] == '/') { pos = tagEnd + 1; continue }
            val close = s.indexOf("</programme>", tagEnd)
            if (close < 0) {
                if (s.length - i > 2 * 1024 * 1024) { pos = tagEnd + 1; continue }
                carry = s.substring(i)
                return
            }
            programme(s, i + 10, tagEnd, close)
            pos = close + 12
        }
    }

    private fun channels(s: String, from: Int, to: Int): Int {
        var k = from
        while (true) {
            if (chanHint != -2 && k >= chanHintFrom && (chanHint < 0 || k <= chanHint)) {
                k = chanHint
            } else {
                chanHintFrom = k
                chanHint = s.indexOf("<channel ", k)
                k = chanHint
            }
            if (k < 0 || k >= to) return -1
            val end = s.indexOf("</channel>", k)
            if (end < 0 || end > to) return k
            if (channelNames.size < MAX_CHANNEL_NAMES) {
                val tagEnd = s.indexOf('>', k)
                if (tagEnd in 1 until end) {
                    val id = attrValue(s, "id", k + 8, tagEnd)
                    if (!id.isNullOrEmpty()) {
                        val name = child(s, "display-name", tagEnd, end) ?: ""
                        val cid = intern(unescape(id))
                        channelNames.putIfAbsent(cid, name.ifEmpty { cid })
                    }
                }
            }
            k = end + 10
        }
    }

    private fun programme(s: String, attrStart: Int, tagEnd: Int, close: Int) {
        val channel = attrValue(s, "channel", attrStart, tagEnd)
        val start = attrValue(s, "start", attrStart, tagEnd)
        val stop = attrValue(s, "stop", attrStart, tagEnd)
        if (channel == null || start == null || stop == null) {
            val m = HashMap<String, String>()
            for (x in attrRe.findAll(s.substring(attrStart, tagEnd))) {
                m[x.groupValues[1]] = x.groups[2]?.value ?: x.groups[3]?.value ?: ""
            }
            val ch = m["channel"] ?: return
            add(s, unescape(ch), m["start"] ?: return, m["stop"] ?: return, tagEnd, close)
            return
        }
        add(s, if (channel.contains('&')) unescape(channel) else channel, start, stop, tagEnd, close)
    }

    private fun add(s: String, channel: String, start: String, stop: String, tagEnd: Int, close: Int) {
        channelIds?.let { if (channel !in it) return }
        wants?.let { if (!it(channel)) return }
        var st = cachedTime(start) ?: return
        var en = cachedTime(stop) ?: return
        st += shiftMs
        en += shiftMs
        if (en < from || st > to) return
        val title = child(s, "title", tagEnd, close) ?: ""
        val desc = child(s, "desc", tagEnd, close)
        val genre = child(s, "category", tagEnd, close)
        val ch = intern(channel)
        result.getOrPut(ch) { ArrayList() }.add(
            EpgEntry(
                channelEpgId = ch,
                title = intern(title),
                startMs = st,
                endMs = en,
                description = desc?.ifEmpty { null },
                genre = genre?.ifEmpty { null }?.let { intern(it) },
            ),
        )
    }

    private val times = HashMap<String, Long?>()
    private fun cachedTime(v: String): Long? {
        if (times.containsKey(v)) return times[v]
        if (times.size > 20000) times.clear()
        return fastTime(v).also { times[v] = it }
    }

    private val pool = HashMap<String, String>()
    private fun intern(v: String): String {
        if (v.length > 80) return v
        if (pool.size > 200000) pool.clear()
        return pool.getOrPut(v) { v }
    }

    fun finish(): Map<String, List<EpgEntry>> {
        carry = ""
        for (l in result.values) l.sortBy { it.startMs }
        return result
    }
}
