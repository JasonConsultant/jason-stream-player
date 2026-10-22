package de.jasonstream.data

import de.jasonstream.core.model.AccountInfo
import de.jasonstream.core.model.Category
import de.jasonstream.core.model.Channel
import de.jasonstream.core.model.EpgEntry
import de.jasonstream.core.model.Portal
import de.jasonstream.core.model.PortalType
import de.jasonstream.core.model.SeriesDetails
import de.jasonstream.core.model.VodItem
import de.jasonstream.data.epg.EpgWindow
import de.jasonstream.data.epg.XmltvLoader
import de.jasonstream.data.epg.epgOf
import de.jasonstream.data.m3u.M3uRepository
import de.jasonstream.data.net.StreamHeaders
import de.jasonstream.data.stalker.StalkerRepository
import de.jasonstream.data.xtream.XtreamRepository

data class LiveList(val categories: List<Category>, val channels: List<Channel>)
data class VodList(val categories: List<Category>, val items: List<VodItem>)

/**
 * Gemeinsame Schnittstelle aller Quellen (Port von repository.dart).
 *
 * Alle Methoden **blockieren** (Netzwerk) – Aufrufer schalten auf
 * `Dispatchers.IO`. So bleiben die Repositories einfach und ohne
 * Coroutine-Abhängigkeit testbar.
 */
abstract class IptvRepository(val portal: Portal) {
    var account: AccountInfo? = null
        protected set

    fun connect() { account = login() }

    /** Prüft den Zugang; Kontoinfos, wenn die Quelle welche kennt. */
    abstract fun login(): AccountInfo?

    /** Kategorien + Sender (große Listen gestreamt). */
    abstract fun live(): LiveList

    open val supportsVod: Boolean get() = false
    open fun movies(): VodList = VodList(emptyList(), emptyList())
    open fun series(): VodList = VodList(emptyList(), emptyList())
    open fun movieDetails(m: VodItem): VodItem = m
    open fun seriesDetails(s: VodItem): SeriesDetails = SeriesDetails(s, emptyMap())

    /** Kurz-Programm direkt vom Portal (Ersatz, wenn das große EPG nichts hat). */
    open fun shortEpg(c: Channel): List<EpgEntry> = emptyList()

    /** EPG eines Senders inkl. Vergangenheit (Catch-up). */
    open fun channelEpg(c: Channel, fullEpg: Map<String, List<EpgEntry>>): List<EpgEntry> = epgOf(fullEpg, c)

    /** EPG-Adresse(n) des Anbieters (Xtream: xmltv.php, M3U: url-tvg, auch mehrere mit Komma). */
    open fun providerEpgUrl(): String? = null

    /** Endgültige Abspiel-Adresse (Stalker: create_link; sonst Ersatz-Adresse). */
    open fun resolveStreamUrl(c: Channel): String = c.streamUrl

    /** Stream-URL für eine vergangene Sendung oder null. */
    abstract fun catchupUrl(c: Channel, e: EpgEntry, nowMs: Long = System.currentTimeMillis()): String?

    /** Komplettes EPG (epgKey → Sendungen). */
    open fun loadEpg(
        channels: List<Channel>?,
        onProgress: ((Int, Int, Long, Long?) -> Unit)? = null,
    ): Map<String, List<EpgEntry>> = loadXmltvSources(channels, onProgress)

    /** Alle EPG-Quellen des Portals; frühere haben Vorrang. */
    protected fun loadXmltvSources(
        channels: List<Channel>?,
        onProgress: ((Int, Int, Long, Long?) -> Unit)? = null,
        shifts: Map<String, Int>? = null,
    ): Map<String, List<EpgEntry>> {
        val sources = ArrayList<Pair<String, Int>>()
        for (src in portal.epgSources) {
            val offset = EpgWindow.clampOffset(portal.epgOffsets[src] ?: 0)
            if (src != "portal") { sources.add(src to offset); continue }
            val raw = providerEpgUrl()
            if (raw.isNullOrEmpty()) continue
            for (u in XmltvLoader.pickEpgUrls(raw.split(',').map { it.trim() }.filter { it.isNotEmpty() }, channels)) {
                sources.add(u to offset)
            }
        }
        val n = sources.size
        return XmltvLoader.loadSources(
            sources, channels, StreamHeaders.portalHeaders(portal), shifts = shifts,
            onProgress = { i, b, t -> onProgress?.invoke(i + 1, n, b, t) },
        )
    }

    companion object {
        fun forPortal(p: Portal): IptvRepository = when (p.type) {
            PortalType.xtream -> XtreamRepository(p)
            PortalType.m3u -> M3uRepository(p)
            PortalType.stalker -> StalkerRepository(p)
            PortalType.demo -> throw de.jasonstream.core.model.RepositoryException("Demo-Portal folgt in Phase 2.")
        }
    }
}
