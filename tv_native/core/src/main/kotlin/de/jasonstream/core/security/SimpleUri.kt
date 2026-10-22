package de.jasonstream.core.security

import java.net.URLDecoder
import java.nio.charset.StandardCharsets

/**
 * Nachsichtiger URL-Zerleger (ähnlich Darts `Uri.tryParse`): IPTV-Adressen
 * enthalten oft Zeichen, an denen `java.net.URI` scheitert (Leerzeichen,
 * „|“, Umlaute). Liefert nur die Teile, die wir für Prüfungen brauchen.
 */
class SimpleUri private constructor(
    val scheme: String,
    val userInfo: String,
    val host: String,
    /** -1 = nicht angegeben. */
    val port: Int,
    val path: String,
    val query: String?,
) {
    /** Wie Dart: Standard-Ports (http 80, https 443) gelten als „nicht angegeben“. */
    val hasPort: Boolean
        get() = port >= 0 && !(scheme == "http" && port == 80) && !(scheme == "https" && port == 443)

    /** Dekodierte Query-Parameter (erster Wert gewinnt, „+“ = Leerzeichen). */
    val queryParameters: Map<String, String> by lazy {
        val q = query ?: return@lazy emptyMap()
        val out = LinkedHashMap<String, String>()
        for (part in q.split('&')) {
            if (part.isEmpty()) continue
            val eq = part.indexOf('=')
            val k = decode(if (eq < 0) part else part.substring(0, eq))
            val v = if (eq < 0) "" else decode(part.substring(eq + 1))
            out.putIfAbsent(k, v)
        }
        out
    }

    /** scheme://host[:port] */
    val origin: String get() = "$scheme://$host" + (if (hasPort) ":$port" else "")

    companion object {
        private val schemeRe = Regex("^([a-zA-Z][a-zA-Z0-9+.\\-]*):")

        fun parse(raw: String?): SimpleUri? {
            val s = raw?.trim() ?: return null
            if (s.isEmpty()) return null
            val m = schemeRe.find(s) ?: return SimpleUri("", "", "", -1, s, null)
            val scheme = m.groupValues[1].lowercase()
            var rest = s.substring(m.range.last + 1)
            val hashAt = rest.indexOf('#')
            if (hashAt >= 0) rest = rest.substring(0, hashAt)
            var userInfo = ""
            var host = ""
            var port = -1
            if (rest.startsWith("//")) {
                rest = rest.substring(2)
                val end = rest.indexOfAny(charArrayOf('/', '?')).let { if (it < 0) rest.length else it }
                var authority = rest.substring(0, end)
                rest = rest.substring(end)
                val at = authority.lastIndexOf('@')
                if (at >= 0) {
                    userInfo = authority.substring(0, at)
                    authority = authority.substring(at + 1)
                }
                if (authority.startsWith("[")) {
                    val close = authority.indexOf(']')
                    if (close < 0) return null
                    host = authority.substring(1, close)
                    val after = authority.substring(close + 1)
                    if (after.startsWith(":") && after.length > 1) port = after.substring(1).toIntOrNull() ?: return null
                } else {
                    val colon = authority.lastIndexOf(':')
                    if (colon >= 0) {
                        val p = authority.substring(colon + 1)
                        host = authority.substring(0, colon)
                        if (p.isNotEmpty()) port = p.toIntOrNull()?.takeIf { it in 0..65535 } ?: return null
                    } else {
                        host = authority
                    }
                }
                if (host.any { it == ' ' || it == '<' || it == '>' || it == '"' || it == '\\' }) return null
                host = host.lowercase()
            }
            val qAt = rest.indexOf('?')
            val path = if (qAt < 0) rest else rest.substring(0, qAt)
            val query = if (qAt < 0) null else rest.substring(qAt + 1)
            return SimpleUri(scheme, userInfo, host, port, path, query)
        }

        fun decode(s: String): String = try {
            URLDecoder.decode(s, StandardCharsets.UTF_8.name())
        } catch (_: Exception) {
            s
        }

        private const val HEX = "0123456789ABCDEF"

        private fun encode(s: String, keep: (Char) -> Boolean, spaceToPlus: Boolean): String {
            val sb = StringBuilder()
            for (b in s.toByteArray(Charsets.UTF_8)) {
                val c = (b.toInt() and 0xFF)
                val ch = c.toChar()
                when {
                    c < 0x80 && keep(ch) -> sb.append(ch)
                    spaceToPlus && ch == ' ' -> sb.append('+')
                    else -> sb.append('%').append(HEX[c shr 4]).append(HEX[c and 15])
                }
            }
            return sb.toString()
        }

        private fun alnum(c: Char) = c in 'a'..'z' || c in 'A'..'Z' || c in '0'..'9'

        /** Wie Darts `Uri.encodeComponent` (RFC 2396 unreserved). */
        fun encodeComponent(s: String) = encode(s, { alnum(it) || it in "-_.!~*'()" }, false)

        /** Wie Darts `Uri.encodeQueryComponent` (Leerzeichen → „+“). */
        fun encodeQueryComponent(s: String) = encode(s, { alnum(it) || it in "-._~*" }, true)
    }
}
