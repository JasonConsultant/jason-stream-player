package de.jasonstream.playback.api

import de.jasonstream.core.model.Channel
import de.jasonstream.core.model.EpgEntry
import de.jasonstream.core.model.Portal
import de.jasonstream.core.storage.Storage
import de.jasonstream.data.channels.VariantIndex
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject

/**
 * Alles, was der Player von der App braucht. Die meisten Methoden haben
 * eine Vorgabe auf Basis von [Storage] (gleiche Schlüssel wie die
 * Flutter-App); die App überschreibt nur, was sie selbst verwaltet
 * (EPG, Varianten, PIN, Aufnahme).
 *
 * Aufrufe kommen vom Haupt-Thread, außer den `suspend`-Funktionen (dürfen
 * blockieren/Netz – der Player ruft sie auf Dispatchers.IO).
 */
interface PlayerDeps {
    /** Geöffneter Speicher (Einstellungen „set_*“, resume_, fav_, last_ …). */
    val storage: Storage

    /** App-Sprache: „de“, „en“, „tr“ oder „system“ (Einstellung set_applang). */
    fun appLanguage(): String = storage.option("applang", "system")

    /** Portal zu [PlayRequest.portalId] (Kopfzeilen, Ersatz-Adressen). */
    fun portal(portalId: String): Portal?

    // ---------- Adressen ----------
    /** Live-Adresse (Stalker: create_link; Xtream/M3U: Ersatz-Adresse). Darf blockieren. */
    suspend fun resolveLiveUrl(portalId: String, channel: Channel): String = channel.streamUrl

    /** Catch-up-Adresse einer Sendung oder null (kein Archiv). Darf blockieren. */
    suspend fun catchupUrl(portalId: String, channel: Channel, entry: EpgEntry): String? = null

    // ---------- EPG ----------
    /** Sendungen des Senders, nach Start sortiert (schnell, aus dem Speicher). */
    fun epgOf(channel: Channel): List<EpgEntry> = emptyList()

    /** Zählt hoch, wenn sich das EPG ändert (Neuzeichnen von Zap-Leiste/Overlay). */
    val epgRevision: StateFlow<Long> get() = NoRevision

    /** Zap-Leiste zeigt [channel]: EPG bei Bedarf nachladen (Kurz-EPG). */
    fun wantEpg(channel: Channel) {}

    /** Vollständiges Sender-EPG inkl. Vergangenheit (Replay ◀▶). Darf blockieren. */
    suspend fun channelEpg(channel: Channel): List<EpgEntry> = epgOf(channel)

    // ---------- Varianten ----------
    /** Varianten-Gruppen der sichtbaren Senderliste. */
    fun variantIndex(): VariantIndex = VariantIndex.empty

    /** Gewählte Variante je Gruppe (Option „varpick_<portal>“, JSON Gruppe → Sender-ID). */
    fun variantChoices(portalId: String): Map<String, String> = try {
        (Json.parseToJsonElement(storage.option("varpick_$portalId", "{}")) as? JsonObject)
            ?.mapNotNull { (k, v) -> (v as? JsonPrimitive)?.takeIf { it.isString }?.let { k to it.content } }
            ?.toMap() ?: emptyMap()
    } catch (_: Exception) {
        emptyMap()
    }

    /** Variante merken (beste Variante = Standard, nichts merken). */
    fun chooseVariant(portalId: String, channel: Channel) {
        val g = variantIndex().groupOf(channel.id) ?: return
        val next = variantChoices(portalId).toMutableMap()
        if (g.best.id == channel.id) next.remove(g.key) else next[g.key] = channel.id
        storage.setOption("varpick_$portalId", buildJsonObject { next.forEach { (k, v) -> put(k, JsonPrimitive(v)) } }.toString())
    }

    // ---------- Sender-Zustand ----------
    /** Alle sichtbaren Sender (Direktwahl-Rückfall, wenn die Nummer nicht in der Liste ist). */
    fun allChannels(portalId: String): List<Channel> = emptyList()

    /** Alle Sender inkl. zusammengefasster Varianten (Nummer einer Variante). */
    fun rawChannels(portalId: String): List<Channel> = emptyList()

    fun isFavorite(portalId: String, channel: Channel): Boolean = channel.id in storage.favorites(portalId)

    /** Favorit umschalten. false = nicht möglich (Gastmodus). */
    fun toggleFavorite(portalId: String, channel: Channel): Boolean {
        if (storage.guestMode) return false
        storage.toggleFavorite(portalId, channel.id)
        return true
    }

    fun isLocked(portalId: String, channel: Channel): Boolean = channel.id in storage.locked(portalId)

    /** PIN-Abfrage der App für gesperrte Sender; true = freigegeben. */
    suspend fun confirmPin(channel: Channel): Boolean = true

    /** Sender läuft (nicht bei stillen Wiederverbindungen): Verlauf + letzter Sender. */
    fun onChannelStarted(portalId: String, channel: Channel) {
        storage.pushRecent(portalId, channel.id)
        storage.setLastChannel(portalId, channel.id)
    }

    /** Sender ist am Standort gesperrt (403/451) bzw. läuft wieder. */
    fun setUnavailable(portalId: String, channel: Channel, unavailable: Boolean) {}

    /**
     * Rote Taste / Aufnahme-Knopf. Rückgabe: anzuzeigende Meldung oder null
     * (Player zeigt dann „Aufnahme folgt“ – Stub bis Phase „Aufnahmen“).
     */
    fun onRecord(portalId: String, channel: Channel, now: EpgEntry?): String? = null

    /** Ein Sender/Film wurde gestartet oder die Wiedergabe beendet (Verlauf „Weiterschauen“ neu laden). */
    fun onResumeSaved(key: String) {}

    companion object {
        private val NoRevision: StateFlow<Long> = MutableStateFlow(0L)
    }
}

/** Einfachste Variante: nur Speicher, kein EPG/Varianten (Tests, Platzhalter). */
open class StoragePlayerDeps(
    override val storage: Storage,
    private val portals: () -> List<Portal> = { storage.portals() },
) : PlayerDeps {
    override fun portal(portalId: String): Portal? = portals().firstOrNull { it.id == portalId }
}
