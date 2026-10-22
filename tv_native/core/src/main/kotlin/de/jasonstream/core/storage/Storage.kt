package de.jasonstream.core.storage

import de.jasonstream.core.model.ChannelOverride
import de.jasonstream.core.model.HostFailover
import de.jasonstream.core.model.MyGroup
import de.jasonstream.core.model.Portal
import de.jasonstream.core.model.PortalType
import de.jasonstream.core.prefs.KeyValueStore
import de.jasonstream.core.security.PinHasher
import de.jasonstream.core.security.Redactor
import de.jasonstream.core.security.SecretCipher
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import java.util.concurrent.ConcurrentHashMap

/**
 * Lokale Ablage – Port von lib/data/storage.dart mit **denselben
 * Schlüsselnamen** (ohne „flutter.“). Dadurch übernimmt die Migration die
 * Flutter-Daten 1:1, und spätere Sicherungen bleiben zwischen beiden Apps
 * austauschbar.
 *
 * Zugangsdaten und PIN liegen nur verschlüsselt unter `sec_*`
 * ([SecretCipher], gleicher Keystore-Schlüssel wie die Flutter-App).
 * Im Klartext stehen nur Name/Typ der Portale, Favoriten, Positionen usw.
 *
 * [open] entschlüsselt alle Geheimnisse (Keystore) – nicht auf dem
 * Haupt-Thread aufrufen.
 */
class Storage private constructor(
    private val prefs: KeyValueStore,
    private val cipher: SecretCipher,
    private val secrets: MutableMap<String, String>,
    /** Geheimnisse, die nicht mehr entschlüsselt werden konnten. */
    val unreadableSecrets: Int,
    private val clock: () -> Long,
) {
    companion object {
        const val K_PORTALS = "portals"
        const val K_ACTIVE = "active_portal"
        const val K_LEGACY_PIN = "parental_pin"
        const val K_PIN_HASH = "pin_hash"
        const val K_PIN_SALT = "pin_salt"
        const val SEC_PREFIX = "sec_"
        const val KIDS_FLAG = "kids"
        const val GUEST_FLAG = "guest"
        const val ADULT_LOCK_FLAG = "adultlock"
        private const val UNAVAILABLE_TTL_MS = 24L * 3600 * 1000

        private val json = Json { ignoreUnknownKeys = true }

        fun open(prefs: KeyValueStore, cipher: SecretCipher, clock: () -> Long = System::currentTimeMillis): Storage {
            val keys = prefs.keys().filter { it.startsWith(SEC_PREFIX) }.sorted()
            val ciphers = keys.map { prefs.getString(it) }
            val present = keys.indices.filter { ciphers[it] != null }
            val plain = try {
                cipher.decryptAll(present.map { ciphers[it]!! })
            } catch (_: Exception) {
                present.map { null }
            }
            val secrets = ConcurrentHashMap<String, String>()
            var unreadable = 0
            val drop = ArrayList<String>()
            present.forEachIndexed { n, i ->
                val p = plain[n]
                if (p != null) secrets[keys[i].removePrefix(SEC_PREFIX)] = p
                else { unreadable++; drop.add(keys[i]) }
            }
            // Schlüssel weg (z. B. App-Daten wiederhergestellt) → neu anmelden.
            if (drop.isNotEmpty()) prefs.edit { drop.forEach { remove(it) } }
            val s = Storage(prefs, cipher, secrets, unreadable, clock)
            s.migrateLegacy()
            for (p in s.portals()) {
                registerSecrets(p)
                prefs.getLong("althost_${p.id}")?.let { HostFailover.restore(p.id, it.toInt()) }
            }
            HostFailover.persist = { id, i ->
                prefs.edit { if (i == 0) remove("althost_$id") else putLong("althost_$id", i.toLong()) }
            }
            return s
        }

        private fun registerSecrets(p: Portal) {
            Redactor.register(p.username, p.password)
            Redactor.registerUrl(p.url)
            p.altUrls.forEach { Redactor.registerUrl(it) }
        }
    }

    /** Ältere Versionen speicherten alles im Klartext → einmalig umziehen. */
    private fun migrateLegacy() {
        val raw = prefs.getString(K_PORTALS)
        if (raw != null) {
            val list = runCatching { json.parseToJsonElement(raw).jsonArray.map { it.jsonObject } }.getOrNull()
            if (list != null && list.any { it.containsKey("password") || it.containsKey("url") }) {
                val portals = list.mapNotNull { Portal.fromJson(it) }
                portals.forEach { writeSecret(it) }
                writePublic(portals)
            }
        }
        prefs.getString(K_LEGACY_PIN)?.let {
            setPin(it)
            prefs.edit { remove(K_LEGACY_PIN) }
        }
    }

    // ---------- Portale ----------
    fun portals(): List<Portal> {
        val raw = prefs.getString(K_PORTALS) ?: return emptyList()
        val arr = runCatching { json.parseToJsonElement(raw).jsonArray }.getOrNull() ?: return emptyList()
        val out = ArrayList<Portal>()
        for (e in arr) {
            val j = e as? JsonObject ?: continue
            val id = (j["id"] as? JsonPrimitive)?.content ?: continue
            val secretRaw = secrets["portal_$id"] ?: continue // Zugang nicht mehr lesbar
            val sec = runCatching { json.parseToJsonElement(secretRaw).jsonObject }.getOrNull() ?: continue
            val type = PortalType.byName((j["type"] as? JsonPrimitive)?.content) ?: continue
            val base = Portal(
                id = id,
                name = (j["name"] as? JsonPrimitive)?.content ?: id,
                type = type,
                url = sec.s("url") ?: continue,
                username = sec.s("username"),
                password = sec.s("password"),
                epgUrl = sec.s("epgUrl"),
            )
            out.add(Portal.withExtras(base, sec["x"] as? JsonObject))
        }
        return out
    }

    private fun JsonObject.s(k: String): String? =
        (this[k] as? JsonPrimitive)?.takeIf { it !is JsonNull && it.isString }?.content

    private fun writeSecret(p: Portal) {
        val extras = p.extrasToJson()
        val value = buildJsonObject {
            put("url", p.url)
            put("username", p.username)
            put("password", p.password)
            put("epgUrl", p.epgUrl)
            if (extras.isNotEmpty()) put("x", extras)
        }
        putSecret("portal_${p.id}", value.toString())
    }

    private fun putSecret(key: String, value: String) {
        val c = cipher.encrypt(value)
        prefs.edit { putString("$SEC_PREFIX$key", c) }
        secrets[key] = value
    }

    private fun deleteSecret(key: String) {
        prefs.edit { remove("$SEC_PREFIX$key") }
        secrets.remove(key)
    }

    private fun writePublic(list: List<Portal>) {
        val arr = buildJsonArray {
            for (p in list) add(buildJsonObject { put("id", p.id); put("name", p.name); put("type", p.type.name) })
        }
        prefs.edit { putString(K_PORTALS, arr.toString()) }
    }

    fun addPortal(p: Portal) {
        writeSecret(p)
        registerSecrets(p)
        writePublic(portals().filter { it.id != p.id } + p)
    }

    fun updatePortal(p: Portal) {
        val old = portals().firstOrNull { it.id == p.id }
        if (old != null && HostFailover.bases(old) != HostFailover.bases(p)) {
            HostFailover.forget(p.id)
            prefs.edit { remove("althost_${p.id}") }
        }
        writeSecret(p)
        registerSecrets(p)
        writePublic(portals().map { if (it.id == p.id) p else it })
    }

    fun reorderPortals(ids: List<String>) {
        fun pos(p: Portal) = ids.indexOf(p.id).let { if (it < 0) ids.size else it }
        writePublic(portals().sortedBy { pos(it) })
    }

    fun removePortal(id: String) {
        writePublic(portals().filter { it.id != id })
        deleteSecret("portal_$id")
        prefs.edit {
            remove("althost_$id"); remove("listrefresh_$id"); remove("set_recentsearch_$id")
        }
        if (activePortalId() == id) prefs.edit { remove(K_ACTIVE) }
    }

    fun activePortalId(): String? = prefs.getString(K_ACTIVE)
    fun setActivePortal(id: String?) = prefs.edit { if (id == null) remove(K_ACTIVE) else putString(K_ACTIVE, id) }

    /** Aktives Portal oder (wie die Flutter-App) das erste. */
    fun activePortal(): Portal? {
        val all = portals()
        val id = activePortalId()
        return all.firstOrNull { it.id == id } ?: all.firstOrNull()
    }

    // ---------- Sender-Listen pro Portal ----------
    private fun set(key: String): Set<String> = prefs.getStringList(key)?.toCollection(LinkedHashSet()) ?: emptySet()
    private fun saveSet(key: String, s: Set<String>) = prefs.edit { putStringList(key, s.toList()) }

    fun favorites(portalId: String) = set("fav_$portalId")
    fun hidden(portalId: String) = set("hidden_$portalId")
    fun locked(portalId: String) = set("locked_$portalId")

    fun toggleFavorite(portalId: String, channelId: String) {
        if (guestMode) return
        toggle("fav_$portalId", channelId)
    }
    fun toggleHidden(portalId: String, channelId: String) = toggle("hidden_$portalId", channelId)
    fun toggleLocked(portalId: String, channelId: String) = toggle("locked_$portalId", channelId)
    fun clearHidden(portalId: String) = prefs.edit { remove("hidden_$portalId") }

    private fun toggle(key: String, id: String) {
        val s = LinkedHashSet(set(key))
        if (!s.remove(id)) s.add(id)
        saveSet(key, s)
    }

    // ---------- Sender-Überschreibungen ----------
    fun overrides(portalId: String): Map<String, ChannelOverride> {
        val raw = prefs.getString("chov_$portalId")
        if (raw.isNullOrEmpty()) return emptyMap()
        return try {
            json.parseToJsonElement(raw).jsonObject.entries
                .filter { it.value is JsonObject }
                .associate { it.key to ChannelOverride.fromJson(it.value.jsonObject) }
        } catch (_: Exception) {
            emptyMap()
        }
    }

    fun setOverride(portalId: String, channelId: String, o: ChannelOverride?) {
        val all = LinkedHashMap(overrides(portalId))
        if (o == null || o.isEmpty) all.remove(channelId) else all[channelId] = o
        prefs.edit {
            if (all.isEmpty()) remove("chov_$portalId")
            else putString("chov_$portalId", JsonObject(all.mapValues { it.value.toJson() }).toString())
        }
    }

    // ---------- Verlauf ----------
    fun recent(portalId: String): List<String> = prefs.getStringList("recent_$portalId") ?: emptyList()
    fun pushRecent(portalId: String, channelId: String) {
        if (guestMode) return
        val l = listOf(channelId) + recent(portalId).filter { it != channelId }
        prefs.edit { putStringList("recent_$portalId", l.take(20)) }
    }
    fun clearRecent(portalId: String) = prefs.edit { remove("recent_$portalId") }

    fun lastChannel(portalId: String): String? = prefs.getString("last_$portalId")
    fun setLastChannel(portalId: String, channelId: String) {
        if (guestMode) return
        prefs.edit { putString("last_$portalId", channelId) }
    }

    // ---------- Kindersicherung ----------
    fun hasPin() = secrets[K_PIN_HASH] != null

    fun setPin(pin: String?) {
        if (pin == null) {
            deleteSecret(K_PIN_HASH); deleteSecret(K_PIN_SALT); return
        }
        val salt = PinHasher.newSalt()
        val hash = PinHasher.hash(pin, salt)
        putSecret(K_PIN_SALT, salt)
        putSecret(K_PIN_HASH, hash)
        prefs.edit { remove("pin_fails"); remove("pin_locked_until") }
    }

    sealed interface PinResult {
        data object Ok : PinResult
        data class Wrong(val attemptsLeft: Int) : PinResult
        data class Locked(val forMs: Long) : PinResult
    }

    /** Nach 5 Fehlversuchen gesperrt (30 s, dann länger, höchstens 1 h). */
    fun verifyPin(pin: String): PinResult {
        val hash = secrets[K_PIN_HASH]
        val salt = secrets[K_PIN_SALT]
        if (hash == null || salt == null) return PinResult.Ok
        val now = clock()
        val lockedUntil = prefs.getLong("pin_locked_until") ?: 0
        if (lockedUntil > now) return PinResult.Locked(lockedUntil - now)
        if (PinHasher.equals(PinHasher.hash(pin, salt), hash)) {
            prefs.edit { remove("pin_fails") }
            return PinResult.Ok
        }
        val fails = (prefs.getLong("pin_fails") ?: 0) + 1
        prefs.edit { putLong("pin_fails", fails) }
        if (fails >= 5) {
            val secs = (30L * (1L shl (fails - 5).toInt().coerceAtMost(20))).coerceIn(30, 3600)
            prefs.edit { putLong("pin_locked_until", now + secs * 1000) }
            return PinResult.Locked(secs * 1000)
        }
        return PinResult.Wrong((5 - fails).toInt())
    }

    // ---------- Weiterschauen ----------
    fun resume(key: String): Pair<Int, Int>? {
        val parts = prefs.getString("resume_$key")?.split('/') ?: return null
        if (parts.size != 2) return null
        return (parts[0].toIntOrNull() ?: 0) to (parts[1].toIntOrNull() ?: 0)
    }

    fun setResume(key: String, pos: Int, total: Int) {
        if (guestMode) return
        if (total > 0 && pos > total * 0.95) {
            prefs.edit { remove("resume_$key"); putBoolean("watched_$key", true) }
            return
        }
        prefs.edit { putString("resume_$key", "$pos/$total") }
    }

    fun isWatched(key: String) = prefs.getBoolean("watched_$key") ?: false

    // ---------- Einstellungen ----------
    fun flag(key: String, fallback: Boolean = false) = prefs.getBoolean("set_$key") ?: fallback
    fun setFlag(key: String, v: Boolean) = prefs.edit { putBoolean("set_$key", v) }
    fun option(key: String, fallback: String) = prefs.getString("set_$key") ?: fallback
    fun setOption(key: String, v: String) = prefs.edit { putString("set_$key", v) }

    // ---------- Bildformat (aspect.dart-IDs: original, cover, stretch, 16x9, 4x3, cinema, zoom) ----------
    /** Standard-Bildformat (Einstellung „set_fit“). */
    fun defaultAspectId(): String? = prefs.getString("set_fit")
    fun setDefaultAspectId(id: String) = prefs.edit { putString("set_fit", id) }

    /** Für einen Sender gemerktes Format (oder null → Standard). */
    fun channelAspectId(portalId: String, channelId: String): String? = prefs.getString("aspect_${portalId}_$channelId")
    fun setChannelAspectId(portalId: String, channelId: String, id: String?) = prefs.edit {
        if (id == null) remove("aspect_${portalId}_$channelId") else putString("aspect_${portalId}_$channelId", id)
    }

    /** Folge/Film als gesehen markieren (nächste Folge gestartet). */
    fun setWatched(key: String) {
        if (guestMode) return
        prefs.edit { remove("resume_$key"); putBoolean("watched_$key", true) }
    }

    val kidsMode get() = flag(KIDS_FLAG)
    val guestMode get() = flag(GUEST_FLAG)
    val adultLock get() = flag(ADULT_LOCK_FLAG, fallback = true)

    // ---------- Reihenfolge / Gruppen ----------
    fun groupOrder(portalId: String) = prefs.getStringList("order_groups_$portalId") ?: emptyList()
    fun channelOrder(portalId: String, groupId: String) =
        prefs.getStringList("order_ch_${portalId}_$groupId") ?: emptyList()
    fun hiddenGroups(portalId: String) = set("hidden_groups_$portalId")
    fun setHiddenGroups(portalId: String, ids: Set<String>) = saveSet("hidden_groups_$portalId", ids)

    /** Eigene Gruppen (Option „mygroups_<portal>“, JSON [{id, n, c}]). */
    fun myGroups(portalId: String): List<MyGroup> = try {
        json.parseToJsonElement(option("mygroups_$portalId", "[]")).jsonArray.mapNotNull { e ->
            val o = e as? JsonObject ?: return@mapNotNull null
            MyGroup(
                (o["id"] as? JsonPrimitive)?.content ?: return@mapNotNull null,
                (o["n"] as? JsonPrimitive)?.content ?: "",
                (o["c"] as? JsonArray)?.map { (it as JsonPrimitive).content } ?: emptyList(),
            )
        }
    } catch (_: Exception) {
        emptyList()
    }

    fun setMyGroups(portalId: String, groups: List<MyGroup>) = setOption(
        "mygroups_$portalId",
        buildJsonArray {
            for (g in groups) add(buildJsonObject {
                put("id", g.id); put("n", g.name)
                put("c", JsonArray(g.channels.map { JsonPrimitive(it) }))
            })
        }.toString(),
    )

    /** „Meine Liste“ Filme/Serien (Option „vodfav_<portal>“, JSON-Liste). */
    fun vodFavorites(portalId: String): Set<String> = try {
        json.parseToJsonElement(option("vodfav_$portalId", "[]")).jsonArray
            .mapTo(LinkedHashSet()) { (it as JsonPrimitive).content }
    } catch (_: Exception) {
        emptySet()
    }

    // ---------- Länder, Kindermodus ----------
    fun countries(portalId: String) = set("set_countries_$portalId")
    fun setCountries(portalId: String, codes: Set<String>) = prefs.edit {
        if (codes.isEmpty()) remove("set_countries_$portalId")
        else putStringList("set_countries_$portalId", codes.sorted())
    }
    fun kidsGroups(portalId: String) = set("set_kidsgroups_$portalId")
    fun kidsVod(portalId: String) = set("set_kidsvod_$portalId")

    // ---------- Verfügbarkeit (24 h) ----------
    fun unavailable(portalId: String): Set<String> {
        val now = clock()
        val out = LinkedHashSet<String>()
        for (e in prefs.getStringList("unavail_$portalId") ?: emptyList()) {
            val i = e.lastIndexOf('|')
            if (i < 0) continue
            val ts = e.substring(i + 1).toLongOrNull() ?: 0
            if (now - ts < UNAVAILABLE_TTL_MS) out.add(e.substring(0, i))
        }
        return out
    }

    // ---------- Zeitstempel ----------
    fun epgUpdatedMs(portalId: String) = prefs.getLong("epg_updated_$portalId")
    fun setEpgUpdated(portalId: String, ms: Long?) =
        prefs.edit { if (ms == null) remove("epg_updated_$portalId") else putLong("epg_updated_$portalId", ms) }
    fun listRefreshedMs(portalId: String) = prefs.getLong("listrefresh_$portalId")
    fun setListRefreshed(portalId: String, ms: Long) = prefs.edit { putLong("listrefresh_$portalId", ms) }

    /** Alle Zugangsdaten und die PIN unwiderruflich löschen. */
    fun wipeCredentials() {
        prefs.edit {
            prefs.keys().filter { it.startsWith(SEC_PREFIX) }.forEach { remove(it) }
            remove(K_PORTALS); remove(K_ACTIVE)
        }
        secrets.clear()
        Redactor.clear()
    }

    /** Roh-Zugriff (z. B. für Diagnose/Sicherung). */
    internal val store: KeyValueStore get() = prefs
}
