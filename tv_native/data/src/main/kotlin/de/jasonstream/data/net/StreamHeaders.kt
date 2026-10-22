package de.jasonstream.data.net

import de.jasonstream.core.model.Channel
import de.jasonstream.core.model.Portal
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.net.URLDecoder

/**
 * HTTP-Header für Portal-Anfragen und Streams – Port von stream_headers.dart.
 * Erlaubt sind nur **User-Agent, Referer, Origin und Cookie**; alles andere
 * aus Playlisten (z. B. DRM-/Lizenzangaben) wird bewusst ignoriert.
 */
object StreamHeaders {
    const val UA_VLC = "VLC/3.0.20 LibVLC/3.0.20"
    const val UA_BROWSER = "Mozilla/5.0 (Linux; Android 11; Android TV) AppleWebKit/537.36 " +
        "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    /** Vorlage zu einem gespeicherten Wert: app, vlc, browser oder custom. */
    fun presetIdOf(ua: String?): String = when {
        ua.isNullOrBlank() -> "app"
        ua == UA_VLC -> "vlc"
        ua == UA_BROWSER -> "browser"
        else -> "custom"
    }

    /** Kanonische Schreibweise erlaubter Header, null = nicht erlaubt. */
    fun canonical(name: String): String? = when (name.trim().lowercase()) {
        "user-agent", "useragent", "http-user-agent" -> "User-Agent"
        "referer", "referrer", "http-referrer", "http-referer" -> "Referer"
        "origin", "http-origin" -> "Origin"
        "cookie", "http-cookie" -> "Cookie"
        else -> null
    }

    private val control = Regex("[\\x00-\\x1F\\x7F]")

    private fun clean(v: String?): String? {
        if (v == null) return null
        val s = control.replace(v, "").trim()
        return if (s.isEmpty() || s.length > 2048) null else s
    }

    private fun put(out: MutableMap<String, String>, name: String, value: String?) {
        val k = canonical(name) ?: return
        val v = clean(value) ?: return
        out[k] = v
    }

    private fun decode(v: String): String = try {
        URLDecoder.decode(v.replace("+", "%20"), "UTF-8")
    } catch (_: Exception) {
        v
    }

    /** `a=b&c=d` (Werte ggf. URL-kodiert) → erlaubte Header. */
    fun parseHeaderQuery(s: String): Map<String, String> {
        val out = LinkedHashMap<String, String>()
        for (part in s.split('&')) {
            val eq = part.indexOf('=')
            if (eq <= 0) continue
            put(out, decode(part.substring(0, eq)), decode(part.substring(eq + 1)))
        }
        return out
    }

    private val kodiHeaderProps = setOf(
        "inputstream.adaptive.stream_headers",
        "inputstream.adaptive.manifest_headers",
        "inputstream.adaptive.common_headers",
    )

    /** Header aus #EXTVLCOPT, #KODIPROP, #EXTHTTP. DRM-Angaben → leer. */
    fun parseM3uOptionLine(line: String): Map<String, String> {
        val out = LinkedHashMap<String, String>()
        val l = line.trim()
        val up = l.uppercase()
        when {
            up.startsWith("#EXTVLCOPT:") -> {
                val body = l.substring(11).trim()
                val eq = body.indexOf('=')
                if (eq > 0) put(out, body.substring(0, eq), body.substring(eq + 1))
            }
            up.startsWith("#KODIPROP:") -> {
                val body = l.substring(10).trim()
                val eq = body.indexOf('=')
                if (eq <= 0) return out
                val key = body.substring(0, eq).trim().lowercase()
                if (key !in kodiHeaderProps) return out
                return parseHeaderQuery(body.substring(eq + 1).trim())
            }
            up.startsWith("#EXTHTTP:") -> try {
                val j = Json.parseToJsonElement(l.substring(9).trim())
                if (j is JsonObject) {
                    for ((k, v) in j) {
                        if (v is JsonPrimitive && v.isString) put(out, k, v.content)
                    }
                }
            } catch (_: Exception) {
            }
        }
        return out
    }

    /** „…|User-Agent=…&Referer=…“ → Adresse ohne Anhang + erlaubte Header. */
    fun splitPipeHeaders(url: String): Pair<String, Map<String, String>> {
        val i = url.indexOf('|')
        if (i < 0) return url to emptyMap()
        return url.substring(0, i).trim() to parseHeaderQuery(url.substring(i + 1))
    }

    /** Header für Anfragen an das Portal selbst (eigener User-Agent/Referer). */
    fun portalHeaders(p: Portal): Map<String, String> {
        val out = LinkedHashMap<String, String>()
        put(out, "User-Agent", p.userAgent)
        put(out, "Referer", p.referer)
        return out
    }

    /** Header zum Abspielen: Portal-Einstellungen, überschrieben vom Sender. */
    fun streamHeadersFor(p: Portal, c: Channel?): Map<String, String> {
        val out = LinkedHashMap(portalHeaders(p))
        c?.headers?.forEach { (k, v) -> put(out, k, v) }
        return out
    }
}
