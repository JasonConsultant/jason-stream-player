package de.jasonstream.data.stalker

import de.jasonstream.core.model.AccountInfo
import de.jasonstream.core.model.Category
import de.jasonstream.core.model.Channel
import de.jasonstream.core.model.EpgEntry
import de.jasonstream.core.model.HostFailover
import de.jasonstream.core.model.Portal
import de.jasonstream.core.model.RepositoryException
import de.jasonstream.core.security.Redactor
import de.jasonstream.core.security.SimpleUri
import de.jasonstream.core.security.UrlPolicy
import de.jasonstream.data.IptvRepository
import de.jasonstream.data.LiveList
import de.jasonstream.data.epg.EpgWindow
import de.jasonstream.data.net.JsonStream
import de.jasonstream.data.net.Net
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import java.net.URI
import java.security.MessageDigest
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.OffsetDateTime
import java.time.ZoneId

/**
 * Stalker/Ministra-Middleware („MAC-Portal“) – Port von
 * stalker_repository.dart. Ablauf: Endpunkt suchen (load.php / portal.php)
 * → handshake (Token) → get_profile → Sender/Genres/EPG über load.php.
 * Die MAC-Adresse steht in [Portal.username]. Abspiel-Links sind kurzlebig
 * und entstehen erst über `create_link` ([resolveStreamUrl]).
 * Catch-up und VOD für MAC-Portale: später (wie in der Flutter-App).
 */
class StalkerRepository(portal: Portal, private val zone: ZoneId = ZoneId.systemDefault()) : IptvRepository(portal) {
    private var endpoint: String? = null
    private var token: String? = null
    private var mac: String? = null
    private val lock = Any()

    private class AuthFailed : Exception("Autorisierung fehlgeschlagen.")

    companion object {
        private const val USER_AGENT = "Mozilla/5.0 (QtEmbedded; U; Linux; C) AppleWebKit/533.3 " +
            "(KHTML, like Gecko) MAG200 stbapp ver: 2 rev: 250 Safari/533.3"
        private const val X_USER_AGENT = "Model: MAG250; Link: WiFi"
        private const val TIMEOUT_MS = 25_000L
        private val macRe = Regex("^[0-9A-F]{2}(:[0-9A-F]{2}){5}$")

        fun normalizeMac(mac: String?): String {
            val m = (mac ?: "").trim().uppercase().replace('-', ':')
            if (!macRe.matches(m)) {
                throw RepositoryException("Ungültige MAC-Adresse – Format XX:XX:XX:XX:XX:XX (z. B. 00:1A:79:12:34:56).")
            }
            return m
        }

        private fun parseUserUrl(url: String): SimpleUri {
            var s = url.trim()
            if (!s.contains("://")) s = "http://$s"
            val u = SimpleUri.parse(s)
            if (u == null || u.host.isEmpty()) throw RepositoryException("Ungültige Portal-Adresse.")
            return u
        }

        /** Wurzel des Portals (Schema://Host[:Port]/). */
        fun portalRoot(url: String): String = parseUserUrl(url).origin + "/"

        /** Mögliche API-Endpunkte in Probier-Reihenfolge. */
        fun endpointCandidates(url: String): List<String> {
            val u = parseUserUrl(url)
            val origin = u.origin
            val out = ArrayList<String>()
            fun add(c: String) { if (c !in out) out.add(c) }
            var path = u.path
            if (path.lowercase().endsWith(".php")) {
                add(origin + path)
                path = path.substring(0, path.lastIndexOf('/') + 1)
                if (path.endsWith("/server/")) path = path.substring(0, path.length - "server/".length)
            }
            path = path.replaceFirst(Regex("/[^/]+\\.html?$", RegexOption.IGNORE_CASE), "/")
            if (!path.endsWith("/")) path = "$path/"
            if (path.endsWith("/c/")) path = path.substring(0, path.length - 2)
            add("$origin${path}server/load.php")
            add("$origin/portal.php")
            add("$origin/stalker_portal/server/load.php")
            return out
        }

        private val cmdRe = Regex("^(ffmpeg|ffrt\\d*|auto)\\s+", RegexOption.IGNORE_CASE)

        /** Entfernt Player-Präfixe wie `ffmpeg `, `ffrt `, `auto `. */
        fun stripCmd(cmd: String?): String {
            var s = (cmd ?: "").trim()
            while (cmdRe.containsMatchIn(s)) s = cmdRe.replaceFirst(s, "").trim()
            return s
        }

        /** `{js: …}`-Hülle entfernen (bis zu drei Ebenen). */
        fun unwrapJs(d: Any?): Any? {
            var cur = d
            repeat(3) {
                if (cur is Map<*, *> && (cur as Map<*, *>).containsKey("js")) cur = (cur as Map<*, *>)["js"] else return cur
            }
            return cur
        }

        private fun str(v: Any?): String? {
            if (v == null) return null
            val s = JsonStream.s(v).trim()
            return if (s.isEmpty() || s == "null") null else s
        }

        private fun int(v: Any?): Int? {
            val s = str(v) ?: return null
            return s.toIntOrNull() ?: s.toDoubleOrNull()?.toInt()
        }

        private fun dataList(js: Any?): List<Any?> {
            val d = unwrapJs(js)
            if (d is List<*>) return d
            if (d is Map<*, *>) {
                val data = d["data"]
                if (data is List<*>) return data
                if (data is Map<*, *>) return data.values.toList()
            }
            return emptyList()
        }

        fun parseGenres(js: Any?): List<Category> = dataList(js).mapNotNull { g ->
            if (g !is Map<*, *>) return@mapNotNull null
            val id = str(g["id"]) ?: return@mapNotNull null
            if (id == "*") return@mapNotNull null
            Category(id, str(g["title"]) ?: str(g["name"]) ?: id)
        }

        fun parseChannels(js: Any?, root: String): List<Channel> = dataList(js).mapNotNull { s ->
            if (s !is Map<*, *>) return@mapNotNull null
            val id = str(s["id"]) ?: return@mapNotNull null
            val cmd = str(s["cmd"]) ?: return@mapNotNull null
            Channel(
                id = id,
                name = str(s["name"]) ?: "Sender $id",
                categoryId = str(s["tv_genre_id"]) ?: "",
                streamUrl = cmd,
                epgId = id, // Stalker-ID, damit get_epg_info passt
                number = int(s["number"]) ?: 0,
                logoUrl = logo(str(s["logo"]), root),
                catchupDays = 0, // Catch-up für MAC-Portale folgt
            )
        }

        private fun logo(logo: String?, root: String): String? {
            if (logo == null) return null
            if (UrlPolicy.isWeb(logo)) return UrlPolicy.image(logo)
            if (logo.contains("://")) return null
            return try {
                UrlPolicy.image(URI(root).resolve(logo.replace(" ", "%20")).toString())
            } catch (_: Exception) {
                null
            }
        }

        /** Unix-Sekunden oder „YYYY-MM-DD HH:MM:SS“ (Ortszeit). */
        private fun time(v: Any?, zone: ZoneId): Long? {
            val s = str(v) ?: return null
            s.toLongOrNull()?.let { return if (it > 0) it * 1000 else null }
            return parseIso(s, zone)
        }

        private val isoRe = Regex(
            "^([+-]?\\d{4,6})-(\\d{2})-(\\d{2})(?:[ T](\\d{2})(?::?(\\d{2}))?(?::?(\\d{2}))?(?:[.,]\\d+)?)?\\s*(Z|[+-]\\d{2}(?::?\\d{2})?)?$",
        )

        /** Wie Darts DateTime.tryParse für die üblichen Formate. */
        internal fun parseIso(s: String, zone: ZoneId): Long? {
            val m = isoRe.matchEntire(s.trim()) ?: return null
            val g = m.groupValues
            return try {
                val ldt = LocalDateTime.of(
                    g[1].toInt(), g[2].toInt(), g[3].toInt(),
                    g[4].ifEmpty { "0" }.toInt(), g[5].ifEmpty { "0" }.toInt(), g[6].ifEmpty { "0" }.toInt(),
                )
                val tz = g[7]
                if (tz.isEmpty()) ldt.atZone(zone).toInstant().toEpochMilli()
                else {
                    val off = if (tz == "Z") "+00:00" else tz.let { t ->
                        val d = t.replace(":", "")
                        if (d.length == 3) "${d}:00" else "${d.substring(0, 3)}:${d.substring(3)}"
                    }
                    OffsetDateTime.of(ldt, java.time.ZoneOffset.of(off)).toInstant().toEpochMilli()
                }
            } catch (_: Exception) {
                null
            }
        }

        fun parseEpg(js: Any?, channelIds: Set<String>? = null, zone: ZoneId = ZoneId.systemDefault()): Map<String, List<EpgEntry>> {
            val out = LinkedHashMap<String, MutableList<EpgEntry>>()
            var data = unwrapJs(js)
            if (data is Map<*, *> && data["data"] != null) data = data["data"]
            fun addEntry(key: String?, e: Any?) {
                if (e !is Map<*, *>) return
                val ch = key ?: str(e["ch_id"]) ?: return
                if (channelIds != null && ch !in channelIds) return
                val start = time(e["start_timestamp"], zone) ?: time(e["time"], zone) ?: return
                var end = time(e["stop_timestamp"], zone) ?: time(e["time_to"], zone)
                if (end == null) {
                    val dur = int(e["duration"])
                    if (dur == null || dur <= 0) return
                    end = start + dur * 1000L
                }
                if (end <= start) return
                out.getOrPut(ch) { ArrayList() }.add(
                    EpgEntry(ch, str(e["name"]) ?: "", start, end, str(e["descr"]), str(e["category"])),
                )
            }
            when (data) {
                is Map<*, *> -> data.forEach { (k, v) -> if (v is List<*>) v.forEach { addEntry(JsonStream.s(k), it) } }
                is List<*> -> data.forEach { addEntry(null, it) }
            }
            out.values.forEach { l -> l.sortBy { it.startMs } }
            return out
        }

        fun profileError(js: Any?): String? {
            val p = unwrapJs(js)
            if (p !is Map<*, *>) return "Portal lehnt die MAC-Adresse ab."
            val status = str(p["status"])
            val id = str(p["id"])
            if (status != null && status != "0") return "Portal lehnt die MAC-Adresse ab."
            if (status == null && (id == null || id == "0")) return "Portal lehnt die MAC-Adresse ab."
            return null
        }

        private val months = mapOf(
            "jan" to 1, "feb" to 2, "mar" to 3, "apr" to 4, "may" to 5, "jun" to 6,
            "jul" to 7, "aug" to 8, "sep" to 9, "oct" to 10, "nov" to 11, "dec" to 12,
        )
        private val deRe = Regex("^(\\d{1,2})\\.(\\d{1,2})\\.(\\d{4})")
        private val enRe = Regex("([A-Za-z]{3})[a-z]*\\.?\\s+(\\d{1,2}),?\\s+(\\d{4})")

        /** Ablaufdatum: Unix-Sekunden, ISO, „December 31, 2025, 11:59 pm“, „31.12.2025“. */
        fun parseExpiry(v: Any?, zone: ZoneId = ZoneId.systemDefault()): Long? {
            val s = str(v) ?: return null
            s.toLongOrNull()?.let { return if (it > 0) it * 1000 else null }
            parseIso(s, zone)?.let { return it }
            fun at(y: Int, m: Int, d: Int) = runCatching {
                LocalDate.of(y, m, d).atTime(23, 59).atZone(zone).toInstant().toEpochMilli()
            }.getOrNull()
            deRe.find(s)?.let { return at(it.groupValues[3].toInt(), it.groupValues[2].toInt(), it.groupValues[1].toInt()) }
            enRe.find(s)?.let { m ->
                val mo = months[m.groupValues[1].lowercase()] ?: return null
                return at(m.groupValues[3].toInt(), mo, m.groupValues[2].toInt())
            }
            return null
        }

        fun parseAccount(js: Any?, zone: ZoneId = ZoneId.systemDefault()): AccountInfo? {
            val d = unwrapJs(js) as? Map<*, *> ?: return null
            val expires = parseExpiry(d["end_date"], zone) ?: parseExpiry(d["phone"], zone)
                ?: parseExpiry(d["expire_billing_date"], zone)
            val status = str(d["status"]) ?: "Active"
            return AccountInfo(status = if (status == "0" || status == "1") "Active" else status, expiresMs = expires)
        }

        private fun hex(b: ByteArray) = b.joinToString("") { "%02x".format(it) }
        private fun md5(s: String) = hex(MessageDigest.getInstance("MD5").digest(s.toByteArray()))
        private fun sha256(s: String) = hex(MessageDigest.getInstance("SHA-256").digest(s.toByteArray()))
    }

    // ===================================================================== Netzwerk

    private fun headers(): Map<String, String> {
        val m = mac!!
        return buildMap {
            put("User-Agent", portal.userAgent ?: USER_AGENT)
            put("X-User-Agent", X_USER_AGENT)
            put("Cookie", "mac=${SimpleUri.encodeQueryComponent(m)}; stb_lang=en; timezone=${SimpleUri.encodeQueryComponent("Europe/Berlin")}")
            put("Referer", portal.referer ?: HostFailover.activeBase(portal))
            put("Accept", "*/*")
            token?.let { put("Authorization", "Bearer $it") }
        }
    }

    private fun decode(text: String): Any? {
        val body = text.trim()
        if (body.isEmpty()) return null
        return try {
            JsonStream.parse(body).also { if (it is String && !body.startsWith("\"")) throw IllegalStateException() }
        } catch (_: Exception) {
            if (body.length > 200) body.substring(0, 200) else body
        }
    }

    private fun isAuthFailure(e: Throwable) =
        e is AuthFailed || (e is RepositoryException && (e.statusCode == 401 || e.statusCode == 403))

    /** Eine Anfrage an [ep]; liefert den Inhalt von `js`. */
    private fun call(ep: String, params: Map<String, String>): Any? {
        val url = ep.toHttpUrlOrNull()?.newBuilder()?.apply {
            query(null)
            params.forEach { (k, v) -> addQueryParameter(k, v) }
            addQueryParameter("JsHttpRequest", "1-xml")
        }?.build()?.toString() ?: throw RepositoryException("Ungültige Portal-Adresse.")
        val bytes = Net.get(url, headers(), TIMEOUT_MS)
        val decoded = decode(String(bytes, Charsets.UTF_8))
        if (decoded is String) {
            if (decoded.lowercase().contains("authorization failed")) throw AuthFailed()
            throw RepositoryException("Das Portal hat eine ungültige Antwort geschickt.")
        }
        if (decoded is Map<*, *> && !decoded.containsKey("js") && decoded.isNotEmpty()) return decoded
        return unwrapJs(decoded)
    }

    private fun handshake() {
        if (mac == null) mac = normalizeMac(portal.username)
        Redactor.register(mac, null)
        token = null
        val bases = HostFailover.bases(portal)
        val candidates = ArrayList<Pair<String, Int>>()
        val ep0 = endpoint
        if (ep0 != null) candidates.add(ep0 to HostFailover.activeIndex(portal))
        else for (i in HostFailover.order(portal)) {
            if (i < bases.size) runCatching { endpointCandidates(bases[i]) }.getOrDefault(emptyList()).forEach { candidates.add(it to i) }
        }
        if (candidates.isEmpty()) endpointCandidates(portal.url) // wirft
        var lastError: Throwable? = null
        for ((ep, baseIndex) in candidates) {
            try {
                val js = call(ep, mapOf("type" to "stb", "action" to "handshake", "token" to "", "prehash" to ""))
                val t = (js as? Map<*, *>)?.let { str(it["token"]) }
                if (t == null) { lastError = RepositoryException("Kein Token vom Portal erhalten."); continue }
                endpoint = ep
                token = t
                HostFailover.markWorking(portal, baseIndex)
                Redactor.register(t, null)
                return
            } catch (e: Exception) {
                lastError = e
            }
        }
        val le = lastError
        if (le is RepositoryException && le.message?.contains("Unsichere Adresse") == true) throw le
        throw RepositoryException("Kein MAC-Portal unter dieser Adresse gefunden. Adresse prüfen (z. B. http://server:port/c/).")
    }

    private fun ensureSession() = synchronized(lock) {
        if (token == null || endpoint == null) handshake()
    }

    /** Anfrage mit gültigem Token; bei abgelaufenem Token einmal neu anmelden. */
    private fun get(params: Map<String, String>): Any? {
        ensureSession()
        try {
            return call(endpoint!!, params)
        } catch (e: Exception) {
            if (HostFailover.isHostFailure(e) && HostFailover.bases(portal).size > 1) {
                synchronized(lock) { endpoint = null; token = null }
                ensureSession(); profile()
                return call(endpoint!!, params)
            }
            if (!isAuthFailure(e)) throw e
            synchronized(lock) { token = null }
            ensureSession(); profile()
            try {
                return call(endpoint!!, params)
            } catch (_: AuthFailed) {
                throw RepositoryException("Portal verweigert den Zugriff – MAC-Adresse freischalten lassen.")
            }
        }
    }

    private fun profile(): Any? {
        val m = mac!!
        val sn = md5(m).uppercase().substring(0, 13)
        val deviceId = sha256(m).uppercase()
        return call(
            endpoint!!,
            mapOf(
                "type" to "stb", "action" to "get_profile", "hd" to "1",
                "ver" to "ImageDescription: 0.2.18-r23-250; ImageDate: Thu Sep 13 11:31:16 EEST 2018; PORTAL version: 5.6.1; " +
                    "API Version: JS API version: 343; STB API version: 146; Player Engine version: 0x58c",
                "num_banks" to "2", "sn" to sn, "stb_type" to "MAG250", "image_version" to "218", "video_out" to "hdmi",
                "device_id" to deviceId, "device_id2" to deviceId, "signature" to "", "auth_second_step" to "1",
                "hw_version" to "1.7-BD-00", "not_valid_token" to "0", "metrics" to "",
            ),
        )
    }

    override fun login(): AccountInfo {
        mac = normalizeMac(portal.username)
        Redactor.register(mac, null)
        synchronized(lock) { token = null }
        ensureSession()
        val prof = try {
            profile()
        } catch (e: Exception) {
            if (isAuthFailure(e)) throw RepositoryException("Portal lehnt die MAC-Adresse ab.")
            throw e
        }
        profileError(prof)?.let { throw RepositoryException(it) }
        try {
            parseAccount(get(mapOf("type" to "account_info", "action" to "get_main_info")), zone)?.let { return it }
        } catch (_: Exception) {
        }
        return AccountInfo(status = "Active")
    }

    override fun live(): LiveList {
        val cats = parseGenres(get(mapOf("type" to "itv", "action" to "get_genres")))
        return LiveList(cats, channels())
    }

    private fun channels(): List<Channel> {
        val root = portalRoot(portal.url)
        val all = try {
            parseChannels(get(mapOf("type" to "itv", "action" to "get_all_channels")), root)
        } catch (e: RepositoryException) {
            throw e
        } catch (_: Exception) {
            emptyList()
        }
        if (all.isNotEmpty()) return all
        // Ausweichweg: seitenweise (manche Portale sperren get_all_channels).
        val out = ArrayList<Channel>()
        val seen = HashSet<String>()
        var total: Int? = null
        for (p in 1..100) {
            val js = get(
                mapOf(
                    "type" to "itv", "action" to "get_ordered_list", "genre" to "*", "force_ch_link_check" to "",
                    "fav" to "0", "sortby" to "number", "hd" to "0", "p" to "$p",
                ),
            )
            if (js is Map<*, *> && total == null) total = int(js["total_items"])
            val fresh = parseChannels(js, root).filter { seen.add(it.id) }
            if (fresh.isEmpty()) break
            out.addAll(fresh)
            if (total != null && out.size >= total) break
        }
        return out
    }

    override fun resolveStreamUrl(c: Channel): String {
        val original = stripCmd(c.streamUrl)
        val link = try {
            val js = get(
                mapOf(
                    "type" to "itv", "action" to "create_link", "cmd" to c.streamUrl, "series" to "",
                    "forced_storage" to "0", "disable_ad" to "0", "download" to "0",
                ),
            )
            (js as? Map<*, *>)?.let { stripCmd(str(it["cmd"])) }
        } catch (_: Exception) {
            null
        }
        if (!link.isNullOrEmpty() && UrlPolicy.isStream(link)) return link
        val d = SimpleUri.parse(original)
        if (d != null && (d.scheme == "http" || d.scheme == "https") && !d.host.contains("localhost") && UrlPolicy.isStream(original)) {
            return original
        }
        throw RepositoryException("Das Portal hat keinen abspielbaren Link für diesen Sender geliefert.")
    }

    override fun loadEpg(channels: List<Channel>?, onProgress: ((Int, Int, Long, Long?) -> Unit)?): Map<String, List<EpgEntry>> {
        var ext: Map<String, List<EpgEntry>> = emptyMap()
        if (portal.epgSources.any { it != "portal" }) {
            ext = runCatching { loadXmltvSources(channels, onProgress) }.getOrDefault(emptyMap())
        }
        if ("portal" !in portal.epgSources) return ext
        val offset = EpgWindow.clampOffset(portal.epgOffsets["portal"] ?: 0)
        val own = EpgWindow.shift(
            runCatching { parseEpg(get(mapOf("type" to "itv", "action" to "get_epg_info", "period" to "48")), null, zone) }
                .getOrDefault(emptyMap()),
            offset * 60_000L,
        )
        return LinkedHashMap(own).apply { putAll(ext) }
    }

    override fun catchupUrl(c: Channel, e: EpgEntry, nowMs: Long): String? = null
    override val supportsVod get() = false
}
