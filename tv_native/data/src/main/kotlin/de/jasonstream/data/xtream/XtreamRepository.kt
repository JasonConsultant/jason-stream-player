package de.jasonstream.data.xtream

import de.jasonstream.core.model.AccountInfo
import de.jasonstream.core.model.Category
import de.jasonstream.core.model.Channel
import de.jasonstream.core.model.EpgEntry
import de.jasonstream.core.model.Episode
import de.jasonstream.core.model.HostFailover
import de.jasonstream.core.model.Portal
import de.jasonstream.core.model.RepositoryException
import de.jasonstream.core.model.SeriesDetails
import de.jasonstream.core.model.VodItem
import de.jasonstream.core.model.normalizeRating
import de.jasonstream.core.security.SimpleUri
import de.jasonstream.core.security.UrlPolicy
import de.jasonstream.data.IptvRepository
import de.jasonstream.data.LiveList
import de.jasonstream.data.VodList
import de.jasonstream.data.epg.epgKeyOf
import de.jasonstream.data.epg.epgOf
import de.jasonstream.data.net.JsonStream
import de.jasonstream.data.net.JsonStream.int
import de.jasonstream.data.net.JsonStream.long
import de.jasonstream.data.net.JsonStream.s
import de.jasonstream.data.net.JsonStream.str
import de.jasonstream.data.net.Net
import de.jasonstream.data.net.StreamHeaders
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import java.time.Instant
import java.time.ZoneId
import java.util.Base64

/**
 * Xtream-Codes-API (player_api.php) – Port von xtream_repository.dart:
 * Login, Live, EPG mit Archiv, Catch-up, Filme, Serien.
 * Senderliste/Filme/Serien werden **gestreamt** geparst (Moshi JsonReader).
 */
class XtreamRepository(portal: Portal, private val zone: ZoneId = ZoneId.systemDefault()) : IptvRepository(portal) {
    companion object {
        private const val TIMEOUT_MS = 25_000L
        fun clean(b: String) = b.trim().trimEnd('/')

        private fun maps(d: Any?): List<Map<*, *>> = (d as? List<*>)?.filterIsInstance<Map<*, *>>() ?: emptyList()

        fun mapCategories(data: Any?): List<Category> =
            maps(data).filter { it["category_id"] != null }.map {
                Category(s(it["category_id"]), s(it["category_name"] ?: "").trim())
            }

        /** Ein Eintrag aus get_live_streams → Sender (null = fehlerhaft). */
        fun mapLiveItem(m: Map<*, *>, base: String, u: String, p: String): Channel? {
            val rawId = m["stream_id"]
            if (rawId == null || rawId is Map<*, *> || rawId is List<*>) return null
            val id = s(rawId)
            return Channel(
                id = id,
                name = s(m["name"] ?: "").trim(),
                logoUrl = UrlPolicy.image(str(m["stream_icon"])),
                categoryId = s(m["category_id"]),
                epgId = str(m["epg_channel_id"]),
                number = int(m["num"]) ?: 0,
                catchupDays = if (s(m["tv_archive"]) == "1") int(m["tv_archive_duration"]) ?: 0 else 0,
                streamUrl = "$base/live/$u/$p/$id.ts",
            )
        }

        fun mapMovieItem(m: Map<*, *>, base: String, u: String, p: String): VodItem? {
            val rawId = m["stream_id"]
            if (rawId == null || rawId is Map<*, *> || rawId is List<*>) return null
            val id = s(rawId)
            val ext = str(m["container_extension"]) ?: "mp4"
            val added = long(m["added"])
            return VodItem(
                id = id,
                name = s(m["name"] ?: "").trim(),
                posterUrl = UrlPolicy.image(str(m["stream_icon"])),
                categoryId = s(m["category_id"]),
                rating = normalizeRating(m["rating"]),
                year = int(m["year"] ?: ""),
                addedMs = if (added == null || added <= 0) null else added * 1000,
                genre = str(m["genre"]),
                cast = str(m["cast"]) ?: str(m["actors"]),
                director = str(m["director"]),
                trailer = str(m["youtube_trailer"]) ?: str(m["trailer"]),
                streamUrl = "$base/movie/$u/$p/$id.$ext",
            )
        }

        fun mapSeriesItem(m: Map<*, *>): VodItem? {
            val rawId = m["series_id"]
            if (rawId == null || rawId is Map<*, *> || rawId is List<*>) return null
            val backdrops = m["backdrop_path"]
            val modified = long(m["last_modified"])
            val runTime = int(m["episode_run_time"] ?: "")
            return VodItem(
                id = s(rawId),
                isSeries = true,
                streamUrl = "",
                name = s(m["name"] ?: "").trim(),
                posterUrl = UrlPolicy.image(str(m["cover"])),
                backdropUrl = (backdrops as? List<*>)?.firstOrNull()?.let { s(it) },
                categoryId = s(m["category_id"]),
                rating = normalizeRating(m["rating"]),
                year = s(m["releaseDate"] ?: m["year"] ?: "").split('-').first().trim().toIntOrNull(),
                plot = str(m["plot"]),
                genre = str(m["genre"]),
                cast = str(m["cast"]),
                director = str(m["director"]),
                trailer = str(m["youtube_trailer"]),
                addedMs = if (modified == null || modified <= 0) null else modified * 1000,
                durationSec = if (runTime == null || runTime <= 0) null else runTime * 60L,
            )
        }

        fun ts(v: Any?): Long = (long(v) ?: 0) * 1000

        fun b64(v: Any?): String {
            val t = str(v) ?: return ""
            return try {
                String(Base64.getDecoder().decode(t), Charsets.UTF_8)
            } catch (_: Exception) {
                t
            }
        }
    }

    private val base: String get() = clean(HostFailover.activeBase(portal))
    private val u: String get() = SimpleUri.encodeComponent(portal.username ?: "")
    private val p: String get() = SimpleUri.encodeComponent(portal.password ?: "")
    private val headers get() = StreamHeaders.portalHeaders(portal)

    /** player_api.php-Adresse für [b] mit Parametern. */
    fun apiUrl(b: String, params: Map<String, String>): String {
        val url = "${clean(b)}/player_api.php".toHttpUrlOrNull()
            ?: throw RepositoryException("Ungültige Portal-Adresse.")
        return url.newBuilder().apply {
            addQueryParameter("username", portal.username ?: "")
            addQueryParameter("password", portal.password ?: "")
            params.forEach { (k, v) -> addQueryParameter(k, v) }
        }.build().toString()
    }

    /** Kleine Antwort komplett. */
    private fun get(params: Map<String, String>): Any? = HostFailover.run(portal) { b ->
        Net.open(apiUrl(b, params), headers, TIMEOUT_MS).use { JsonStream.parse(it.source) }
    }

    /** Große Liste gestreamt; ein Neuversuch auf einer Ersatz-Adresse beginnt von vorn. */
    private fun <T> streamList(params: Map<String, String>, map: (Map<*, *>, base: String) -> T?): List<T> =
        HostFailover.run(portal) { b ->
            val out = ArrayList<T>()
            val cb = clean(b) // Stream-Adressen auf dem Server, der gerade antwortet
            Net.open(apiUrl(b, params), headers, TIMEOUT_MS).use { body ->
                JsonStream.forEachObject(body.source) { m -> map(m, cb)?.let(out::add) }
            }
            out.trimToSize()
            out
        }

    override fun login(): AccountInfo {
        val data = get(emptyMap())
        val user = (data as? Map<*, *>)?.get("user_info") as? Map<*, *>
        if (user == null || s(user["auth"]) != "1") {
            throw RepositoryException("Login fehlgeschlagen – Benutzername oder Passwort prüfen.")
        }
        val exp = long(user["exp_date"])
        return AccountInfo(
            status = s(user["status"] ?: "Active"),
            expiresMs = exp?.let { it * 1000 },
            maxConnections = int(user["max_connections"]) ?: 1,
            activeConnections = int(user["active_cons"]) ?: 0,
        )
    }

    override fun live(): LiveList {
        val cats = mapCategories(get(mapOf("action" to "get_live_categories")))
        val (uu, pp) = u to p
        return LiveList(cats, streamList(mapOf("action" to "get_live_streams")) { m, b -> mapLiveItem(m, b, uu, pp) })
    }

    override val supportsVod get() = true

    override fun movies(): VodList {
        val cats = mapCategories(get(mapOf("action" to "get_vod_categories")))
        val (uu, pp) = u to p
        return VodList(cats, streamList(mapOf("action" to "get_vod_streams")) { m, b -> mapMovieItem(m, b, uu, pp) })
    }

    override fun series(): VodList {
        val cats = mapCategories(get(mapOf("action" to "get_series_categories")))
        return VodList(cats, streamList(mapOf("action" to "get_series")) { m, _ -> mapSeriesItem(m) })
    }

    override fun providerEpgUrl() = "$base/xmltv.php?username=$u&password=$p"

    override fun shortEpg(c: Channel): List<EpgEntry> {
        val data = get(mapOf("action" to "get_short_epg", "stream_id" to c.id, "limit" to "12"))
        val list = (data as? Map<*, *>)?.get("epg_listings") as? List<*> ?: emptyList<Any?>()
        return list.filterIsInstance<Map<*, *>>().map {
            EpgEntry(epgKeyOf(c), b64(it["title"]), ts(it["start_timestamp"]), ts(it["stop_timestamp"]), b64(it["description"]))
        }.filter { it.endMs > it.startMs }.sortedBy { it.startMs }
    }

    override fun channelEpg(c: Channel, fullEpg: Map<String, List<EpgEntry>>): List<EpgEntry> = try {
        val data = get(mapOf("action" to "get_simple_data_table", "stream_id" to c.id))
        val list = (data as? Map<*, *>)?.get("epg_listings") as? List<*> ?: emptyList<Any?>()
        if (list.isEmpty()) epgOf(fullEpg, c)
        else list.filterIsInstance<Map<*, *>>().map {
            EpgEntry(
                c.epgId ?: c.id, b64(it["title"]), ts(it["start_timestamp"]), ts(it["stop_timestamp"]),
                b64(it["description"]), hasArchive = s(it["has_archive"]) == "1",
            )
        }.sortedBy { it.startMs }
    } catch (_: Exception) {
        epgOf(fullEpg, c)
    }

    override fun resolveStreamUrl(c: Channel) = HostFailover.rewrite(portal, c.streamUrl)

    /** …/timeshift/U/P/<Minuten>/<YYYY-MM-DD:HH-MM>/<id>.ts (Ortszeit des Geräts). */
    override fun catchupUrl(c: Channel, e: EpgEntry, nowMs: Long): String? {
        if (!c.hasCatchup) return null
        val t = Instant.ofEpochMilli(e.startMs).atZone(zone)
        fun two(n: Int) = n.toString().padStart(2, '0')
        val start = "${t.year}-${two(t.monthValue)}-${two(t.dayOfMonth)}:${two(t.hour)}-${two(t.minute)}"
        val minutes = (e.durationMs / 60_000).coerceIn(1, 24 * 60)
        return "$base/timeshift/$u/$p/$minutes/$start/${c.id}.ts"
    }

    override fun movieDetails(m: VodItem): VodItem {
        val data = get(mapOf("action" to "get_vod_info", "vod_id" to m.id))
        val info = (data as? Map<*, *>)?.get("info") as? Map<*, *> ?: emptyMap<Any, Any>()
        val backdrops = info["backdrop_path"] as? List<*>
        return m.copy(
            plot = str(info["plot"]) ?: str(info["description"]) ?: m.plot,
            genre = str(info["genre"]) ?: m.genre,
            cast = str(info["cast"]) ?: str(info["actors"]) ?: m.cast,
            director = str(info["director"]) ?: m.director,
            rating = normalizeRating(info["rating"]) ?: m.rating,
            year = s(info["releasedate"] ?: "").split('-').first().trim().toIntOrNull() ?: m.year,
            durationSec = long(info["duration_secs"]) ?: 0,
            backdropUrl = backdrops?.firstOrNull()?.let { s(it) } ?: m.backdropUrl,
            trailer = str(info["youtube_trailer"]) ?: str(info["trailer"]) ?: m.trailer,
        )
    }

    override fun seriesDetails(s0: VodItem): SeriesDetails {
        val data = get(mapOf("action" to "get_series_info", "series_id" to s0.id))
        val info = (data as? Map<*, *>)?.get("info") as? Map<*, *> ?: emptyMap<Any, Any>()
        val eps = (data as? Map<*, *>)?.get("episodes")
        val seasons = sortedMapOf<Int, List<Episode>>()
        if (eps is Map<*, *>) {
            for ((season, list) in eps) {
                val n = s(season).trim().toIntOrNull() ?: 0
                if (list !is List<*>) continue
                seasons[n] = list.filterIsInstance<Map<*, *>>().map { e ->
                    val epInfo = e["info"] as? Map<*, *> ?: emptyMap<Any, Any>()
                    val ext = str(e["container_extension"]) ?: "mp4"
                    Episode(
                        id = s(e["id"]),
                        season = n,
                        number = int(e["episode_num"]) ?: 0,
                        title = s(e["title"]),
                        plot = str(epInfo["plot"]),
                        stillUrl = UrlPolicy.image(str(epInfo["movie_image"])),
                        durationSec = long(epInfo["duration_secs"]) ?: 0,
                        streamUrl = "$base/series/$u/$p/${s(e["id"])}.$ext",
                    )
                }.sortedBy { it.number }
            }
        }
        val backdrops = info["backdrop_path"] as? List<*>
        return SeriesDetails(
            series = s0.copy(
                plot = str(info["plot"]) ?: s0.plot,
                genre = str(info["genre"]) ?: s0.genre,
                cast = str(info["cast"]) ?: s0.cast,
                director = str(info["director"]) ?: s0.director,
                trailer = str(info["youtube_trailer"]) ?: s0.trailer,
                backdropUrl = backdrops?.firstOrNull()?.let { s(it) } ?: s0.backdropUrl,
            ),
            cast = str(info["cast"]),
            seasons = seasons,
        )
    }
}
