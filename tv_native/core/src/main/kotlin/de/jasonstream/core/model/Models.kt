package de.jasonstream.core.model

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put

/**
 * Datenmodelle – 1:1 aus lib/models/models.dart portiert.
 *
 * Zeiten sind Epoch-Millisekunden (UTC); die Anzeige rechnet in die
 * Zeitzone des Geräts um.
 */

/** xtream: Xtream-Codes-API · m3u: Playlist · stalker: MAC-Portal · demo. */
enum class PortalType { xtream, m3u, stalker, demo;
    companion object {
        fun byName(n: String?): PortalType? = entries.firstOrNull { it.name == n }
    }
}

data class Portal(
    val id: String,
    val name: String,
    val type: PortalType,
    /** Xtream: Basis-URL (http://host:port). M3U: Playlist-URL. Stalker: Portal-URL. */
    val url: String,
    /** Stalker: MAC-Adresse. */
    val username: String? = null,
    val password: String? = null,
    /** Optionale XMLTV-URL(s), zeilenweise bzw. mit „|“ getrennt. */
    val epgUrl: String? = null,
    val userAgent: String? = null,
    val referer: String? = null,
    /** Ersatz-Adressen (Spiegelserver). */
    val altUrls: List<String> = emptyList(),
    /** 0 = aus, sonst alle N Stunden. */
    val autoRefreshHours: Int = 0,
    /** Zeitversatz je EPG-Quelle in Minuten („portal“ = Anbieter-EPG). */
    val epgOffsets: Map<String, Int> = emptyMap(),
) {
    /** Erweiterte Felder als JSON (für verschlüsselten Speicher und Sicherung). */
    fun extrasToJson(): JsonObject = buildJsonObject {
        userAgent?.let { put("ua", it) }
        referer?.let { put("referer", it) }
        if (altUrls.isNotEmpty()) put("alt", JsonArray(altUrls.map { JsonPrimitive(it) }))
        if (autoRefreshHours > 0) put("autoRefresh", autoRefreshHours)
        if (epgOffsets.isNotEmpty()) put("epgOffsets", JsonObject(epgOffsets.mapValues { JsonPrimitive(it.value) }))
    }

    /** EPG-Quellen in Reihenfolge; „portal“ = EPG des Anbieters. */
    val epgSources: List<String>
        get() {
            val raw = epgUrl?.trim().orEmpty()
            if (raw.isEmpty()) return listOf("portal")
            return raw.split(Regex("[\\n|]+")).map { it.trim() }.filter { it.isNotEmpty() }
        }

    override fun toString(): String = "Portal($id, $name, $type)" // nie Zugangsdaten loggen

    companion object {
        val demo = Portal(id = "__demo", name = "Demo-Portal", type = PortalType.demo, url = "demo://")

        /** Liest die erweiterten Felder (fehlend/ungültig → Standard), wie Portal.withExtras. */
        fun withExtras(base: Portal, j: JsonObject?): Portal {
            if (j == null) return base
            fun s(v: JsonElement?): String? =
                (v as? JsonPrimitive)?.takeIf { it.isString }?.content?.trim()?.takeIf { it.isNotEmpty() }
            val alt = j["alt"]
            val offs = j["epgOffsets"]
            val hours = (j["autoRefresh"] as? JsonPrimitive)?.takeIf { !it.isString }?.let {
                // Dart: nur int > 0 zählt (keine Kommazahl).
                if (it.content.contains('.') || it.content.contains('e', true)) null else it.longOrNull
            }
            return base.copy(
                userAgent = s(j["ua"]),
                referer = s(j["referer"]),
                altUrls = if (alt is JsonArray) alt.mapNotNull { s(it) } else emptyList(),
                autoRefreshHours = if (hours != null && hours > 0) hours.toInt() else 0,
                epgOffsets = if (offs is JsonObject) {
                    buildMap {
                        for ((k, v) in offs) {
                            val p = v as? JsonPrimitive ?: continue
                            if (p.isString) continue
                            val d = p.doubleOrNull ?: continue
                            put(k, d.toInt())
                        }
                    }
                } else emptyMap(),
            )
        }

        fun fromJson(j: JsonObject): Portal? {
            val id = j.str("id") ?: return null
            val name = j.str("name") ?: return null
            val type = PortalType.byName(j.str("type")) ?: return null
            val url = j.str("url") ?: return null
            return withExtras(
                Portal(id, name, type, url, j.str("username"), j.str("password"), j.str("epgUrl")), j,
            )
        }
    }
}

internal fun JsonObject.str(key: String): String? =
    (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.content

data class AccountInfo(
    val status: String,
    val expiresMs: Long? = null,
    val maxConnections: Int = 1,
    val activeConnections: Int = 0,
)

data class Category(val id: String, val name: String)

data class Channel(
    val id: String,
    val name: String,
    val categoryId: String,
    val streamUrl: String,
    val logoUrl: String? = null,
    /** EPG-Kennung (tvg-id bzw. epg_channel_id). */
    val epgId: String? = null,
    /** Catch-up-Tage, 0 = nicht verfügbar. */
    val catchupDays: Int = 0,
    val number: Int = 0,
    val catchupMode: String? = null,
    val catchupSource: String? = null,
    /** M3U: eigene HTTP-Header (nur User-Agent, Referer, Origin, Cookie). */
    val headers: Map<String, String>? = null,
    /** M3U tvg-shift in Minuten. */
    val epgShift: Int = 0,
) {
    val hasCatchup: Boolean get() = catchupDays > 0

    /** [ChannelOverride] anwenden (Name, Logo, EPG-Kennung). */
    fun withOverride(o: ChannelOverride?): Channel {
        if (o == null || o.isEmpty) return this
        return copy(
            name = o.name?.trim()?.takeIf { it.isNotEmpty() } ?: name,
            logoUrl = o.logoUrl?.trim()?.takeIf { it.isNotEmpty() } ?: logoUrl,
            // epgId: null = automatisch, '' = „Kein EPG“, sonst manuell.
            epgId = o.epgId ?: epgId,
        )
    }
}

/** Manuelle Anpassungen eines Senders (Name, Logo, EPG-Zuordnung). */
data class ChannelOverride(val name: String? = null, val logoUrl: String? = null, val epgId: String? = null) {
    val isEmpty: Boolean get() = name.isNullOrEmpty() && logoUrl.isNullOrEmpty() && epgId == null

    fun toJson(): JsonObject = buildJsonObject {
        if (!name.isNullOrEmpty()) put("name", name)
        if (!logoUrl.isNullOrEmpty()) put("logo", logoUrl)
        if (epgId != null) put("epg", epgId)
    }

    companion object {
        fun fromJson(j: JsonObject) = ChannelOverride(j.str("name"), j.str("logo"), j.str("epg"))
    }
}

data class EpgEntry(
    val channelEpgId: String,
    val title: String,
    val startMs: Long,
    val endMs: Long,
    val description: String? = null,
    val genre: String? = null,
    /** Vom Server als „im Archiv“ markiert (Xtream has_archive). */
    val hasArchive: Boolean = false,
) {
    val durationMs: Long get() = endMs - startMs
    fun isNowAt(t: Long) = t >= startMs && t < endMs
    fun isPastAt(t: Long) = endMs <= t
    fun progressAt(t: Long): Float {
        val total = durationMs / 1000
        if (total <= 0) return 0f
        return (((t - startMs) / 1000).toFloat() / total).coerceIn(0f, 1f)
    }
    fun shifted(offsetMs: Long) = if (offsetMs == 0L) this else copy(startMs = startMs + offsetMs, endMs = endMs + offsetMs)
}

/** Bewertung auf die 0–10-Skala (manche Anbieter liefern 0–100). */
fun normalizeRating(raw: Any?): Double? {
    val r = when (raw) {
        is Number -> raw.toDouble()
        is JsonPrimitive -> if (raw is JsonNull) null else raw.content.trim().toDoubleOrNull()
        null -> null
        else -> raw.toString().trim().toDoubleOrNull()
    } ?: return null
    if (r.isNaN() || r <= 0 || r > 100) return null
    return if (r > 10) r / 10 else r
}

data class VodItem(
    val id: String,
    val name: String,
    val categoryId: String,
    val streamUrl: String,
    val posterUrl: String? = null,
    val backdropUrl: String? = null,
    val rating: Double? = null,
    val year: Int? = null,
    val plot: String? = null,
    val genre: String? = null,
    val cast: String? = null,
    val director: String? = null,
    val durationSec: Long? = null,
    val addedMs: Long? = null,
    val trailer: String? = null,
    val isSeries: Boolean = false,
)

data class Episode(
    val id: String,
    val season: Int,
    val number: Int,
    val title: String,
    val streamUrl: String,
    val plot: String? = null,
    val stillUrl: String? = null,
    val durationSec: Long? = null,
)

data class SeriesDetails(
    val series: VodItem,
    val seasons: Map<Int, List<Episode>>,
    val cast: String? = null,
)

/** Eigene Gruppe (lib/state/my_groups.dart), JSON {id, n, c}. */
data class MyGroup(val id: String, val name: String, val channels: List<String>) {
    companion object {
        const val PREFIX = "my_"
        fun isMy(categoryId: String) = categoryId.startsWith(PREFIX)
    }
}
