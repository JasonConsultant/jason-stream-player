package de.jasonstream.core.migration

import de.jasonstream.core.prefs.KeyValueStore
import de.jasonstream.core.security.SecretCipher
import de.jasonstream.core.storage.Storage
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray

/**
 * Einmalige Übernahme der Flutter-Daten beim ersten Start der nativen App
 * (gleiches Paket → gleiches Datenverzeichnis und gleicher Keystore).
 *
 * - Alle „flutter.*“-Einstellungen werden typgerecht und mit **gleichem
 *   Schlüssel** in den nativen Speicher kopiert (Portale, aktives Portal,
 *   Favoriten, ausgeblendete/gesperrte Sender und Gruppen, Reihenfolgen,
 *   Überschreibungen `chov_*`, eigene Gruppen `set_mygroups_*`, Verlauf,
 *   Weiterschauen, Einstellungen `set_*` …).
 * - `sec_*` (Zugangsdaten, PIN) bleiben Chiffretext: dieselbe
 *   [SecretCipher]-Implementierung (Keystore-Alias `jason_stream_master_v1`)
 *   entschlüsselt sie. Die Migration prüft nur, wie viele lesbar sind.
 * - Die Flutter-Datei bleibt unverändert (Rückweg/Fehlersuche möglich).
 * - Ergebnis und Zeitpunkt stehen unter [K_DONE]/[K_REPORT]; danach läuft
 *   die Migration nie wieder (auch nicht, wenn keine Flutter-Daten da waren).
 */
class FlutterMigration(
    private val target: KeyValueStore,
    private val cipher: SecretCipher,
    private val clock: () -> Long = System::currentTimeMillis,
) {
    companion object {
        const val K_DONE = "native.migrated_at"
        const val K_REPORT = "native.migration_report"
        const val K_ATTEMPTS = "native.migration_attempts"
        const val MAX_ATTEMPTS = 3
        private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

        fun report(store: KeyValueStore): Report? =
            store.getString(K_REPORT)?.let { runCatching { json.decodeFromString<Report>(it) }.getOrNull() }
    }

    @Serializable
    data class Report(
        val sourceFound: Boolean,
        val keysCopied: Int = 0,
        val portals: Int = 0,
        val secrets: Int = 0,
        val unreadableSecrets: Int = 0,
        val activePortal: String? = null,
        val favorites: Int = 0,
        val myGroups: Int = 0,
        val overrides: Int = 0,
        val error: String? = null,
        val atMs: Long = 0,
    )

    fun isDone() = target.contains(K_DONE)

    /**
     * Führt die Migration aus, falls noch nicht geschehen. [source] liefert
     * die dekodierten Flutter-Werte (siehe [FlutterPrefs]) oder null, wenn es
     * keine Flutter-Daten gibt. Liefert null, wenn schon migriert.
     */
    fun runIfNeeded(source: () -> Map<String, Any>?): Report? {
        if (isDone()) return null
        val values = try {
            source()
        } catch (e: Exception) {
            return fail("read: ${e.javaClass.simpleName}")
        }
        if (values == null) return finish(Report(sourceFound = false, atMs = clock()))
        return try {
            finish(copy(values))
        } catch (e: Exception) {
            fail("copy: ${e.javaClass.simpleName}")
        }
    }

    private fun copy(values: Map<String, Any>): Report {
        // Nur Schlüssel übernehmen, die die native App nicht selbst verwaltet.
        val entries = values.filterKeys { !it.startsWith("native.") }
        target.edit { entries.forEach { (k, v) -> put(k, v) } }

        val secKeys = entries.keys.filter { it.startsWith(Storage.SEC_PREFIX) }
        val ciphers = secKeys.mapNotNull { entries[it] as? String }
        val plain = runCatching { cipher.decryptAll(ciphers) }.getOrElse { ciphers.map { null } }
        val portals = (entries[Storage.K_PORTALS] as? String)?.let {
            runCatching { Json.parseToJsonElement(it).jsonArray.size }.getOrNull()
        } ?: 0
        return Report(
            sourceFound = true,
            keysCopied = entries.size,
            portals = portals,
            secrets = ciphers.size,
            unreadableSecrets = plain.count { it == null },
            activePortal = entries[Storage.K_ACTIVE] as? String,
            favorites = entries.filterKeys { it.startsWith("fav_") }.values.sumOf { (it as? List<*>)?.size ?: 0 },
            myGroups = entries.filterKeys { it.startsWith("set_mygroups_") }.values.sumOf { v ->
                (v as? String)?.let { s -> runCatching { Json.parseToJsonElement(s).jsonArray.size }.getOrNull() } ?: 0
            },
            overrides = entries.keys.count { it.startsWith("chov_") },
            atMs = clock(),
        )
    }

    private fun finish(r: Report): Report {
        target.edit {
            putLong(K_DONE, r.atMs)
            putString(K_REPORT, json.encodeToString(Report.serializer(), r))
            remove(K_ATTEMPTS)
        }
        return r
    }

    /** Fehler: beim nächsten Start erneut versuchen, höchstens [MAX_ATTEMPTS]-mal. */
    private fun fail(msg: String): Report {
        val n = (target.getLong(K_ATTEMPTS) ?: 0) + 1
        val r = Report(sourceFound = true, error = msg, atMs = clock())
        if (n >= MAX_ATTEMPTS) return finish(r)
        target.edit { putLong(K_ATTEMPTS, n); putString(K_REPORT, json.encodeToString(Report.serializer(), r)) }
        return r
    }
}
