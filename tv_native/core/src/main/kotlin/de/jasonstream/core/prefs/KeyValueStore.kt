package de.jasonstream.core.prefs

import android.content.SharedPreferences
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import java.util.concurrent.ConcurrentHashMap

/**
 * Typisierte Einstellungen mit denselben Schlüsselnamen wie die Flutter-App
 * (ohne deren Präfix „flutter.“). Unterstützt die vier Dart-Typen String,
 * int (Long), bool und `List<String>` (Reihenfolge bleibt!) sowie double.
 *
 * Listen und Kommazahlen haben in SharedPreferences keinen passenden Typ;
 * sie liegen unter eigenen Namensräumen („L:“/„D:“ + Schlüssel). Kein
 * Flutter-Schlüssel beginnt damit.
 */
interface KeyValueStore {
    fun keys(): Set<String>
    fun contains(key: String): Boolean = key in keys()
    fun getString(key: String): String?
    fun getLong(key: String): Long?
    fun getBoolean(key: String): Boolean?
    fun getDouble(key: String): Double?
    fun getStringList(key: String): List<String>?

    /** Roh-Wert in seinem Typ (String, Long, Boolean, Double, List<String>). */
    fun get(key: String): Any? =
        getString(key) ?: getLong(key) ?: getBoolean(key) ?: getDouble(key) ?: getStringList(key)

    fun edit(block: Editor.() -> Unit)

    interface Editor {
        fun putString(key: String, v: String)
        fun putLong(key: String, v: Long)
        fun putBoolean(key: String, v: Boolean)
        fun putDouble(key: String, v: Double)
        fun putStringList(key: String, v: List<String>)
        /** Entfernt den Schlüssel in jedem Typ. */
        fun remove(key: String)
        /** Wert passenden Typs schreiben (für Migration/Sicherung). */
        fun put(key: String, v: Any) {
            when (v) {
                is String -> putString(key, v)
                is Boolean -> putBoolean(key, v)
                is Int -> putLong(key, v.toLong())
                is Long -> putLong(key, v)
                is Double -> putDouble(key, v)
                is Float -> putDouble(key, v.toDouble())
                is List<*> -> putStringList(key, v.map { it.toString() })
                else -> putString(key, v.toString())
            }
        }
    }

    companion object {
        const val LIST_NS = "L:"
        const val DOUBLE_NS = "D:"
        internal fun encodeList(l: List<String>) = JsonArray(l.map { JsonPrimitive(it) }).toString()
        internal fun decodeList(s: String): List<String>? = try {
            Json.parseToJsonElement(s).jsonArray.map { (it as JsonPrimitive).content }
        } catch (_: Exception) {
            null
        }
    }
}

/** Arbeitsspeicher-Variante (Tests). */
class MemoryKeyValueStore(initial: Map<String, Any> = emptyMap()) : KeyValueStore {
    private val map = ConcurrentHashMap<String, Any>()

    init {
        edit { initial.forEach { (k, v) -> put(k, v) } }
    }

    override fun keys(): Set<String> = map.keys.toSet()
    override fun getString(key: String) = map[key] as? String
    override fun getLong(key: String) = map[key] as? Long
    override fun getBoolean(key: String) = map[key] as? Boolean
    override fun getDouble(key: String) = map[key] as? Double
    @Suppress("UNCHECKED_CAST")
    override fun getStringList(key: String) = map[key] as? List<String>

    override fun edit(block: KeyValueStore.Editor.() -> Unit) {
        val e = object : KeyValueStore.Editor {
            override fun putString(key: String, v: String) { map[key] = v }
            override fun putLong(key: String, v: Long) { map[key] = v }
            override fun putBoolean(key: String, v: Boolean) { map[key] = v }
            override fun putDouble(key: String, v: Double) { map[key] = v }
            override fun putStringList(key: String, v: List<String>) { map[key] = v.toList() }
            override fun remove(key: String) { map.remove(key) }
        }
        e.block()
    }
}

/** SharedPreferences-Variante (App). Schreibt asynchron (`apply`). */
class SharedPrefsKeyValueStore(private val prefs: SharedPreferences) : KeyValueStore {
    override fun keys(): Set<String> = prefs.all.keys.mapTo(HashSet()) {
        when {
            it.startsWith(KeyValueStore.LIST_NS) -> it.substring(KeyValueStore.LIST_NS.length)
            it.startsWith(KeyValueStore.DOUBLE_NS) -> it.substring(KeyValueStore.DOUBLE_NS.length)
            else -> it
        }
    }

    override fun contains(key: String) = prefs.contains(key) ||
        prefs.contains(KeyValueStore.LIST_NS + key) || prefs.contains(KeyValueStore.DOUBLE_NS + key)

    // Typgerechte Einzelzugriffe (prefs.all würde jedes Mal die ganze Map kopieren).
    private inline fun <T> typed(key: String, f: () -> T): T? =
        if (!prefs.contains(key)) null else try { f() } catch (_: ClassCastException) { null }

    override fun getString(key: String) = typed(key) { prefs.getString(key, null) }
    override fun getLong(key: String) = typed(key) { prefs.getLong(key, 0L) }
    override fun getBoolean(key: String) = typed(key) { prefs.getBoolean(key, false) }
    override fun getDouble(key: String) =
        typed(KeyValueStore.DOUBLE_NS + key) { prefs.getString(KeyValueStore.DOUBLE_NS + key, null) }?.toDoubleOrNull()

    override fun getStringList(key: String) =
        typed(KeyValueStore.LIST_NS + key) { prefs.getString(KeyValueStore.LIST_NS + key, null) }
            ?.let { KeyValueStore.decodeList(it) }

    override fun edit(block: KeyValueStore.Editor.() -> Unit) {
        val ed = prefs.edit()
        val e = object : KeyValueStore.Editor {
            override fun putString(key: String, v: String) { clear(key); ed.putString(key, v) }
            override fun putLong(key: String, v: Long) { clear(key); ed.putLong(key, v) }
            override fun putBoolean(key: String, v: Boolean) { clear(key); ed.putBoolean(key, v) }
            override fun putDouble(key: String, v: Double) {
                clear(key); ed.putString(KeyValueStore.DOUBLE_NS + key, v.toString())
            }
            override fun putStringList(key: String, v: List<String>) {
                clear(key); ed.putString(KeyValueStore.LIST_NS + key, KeyValueStore.encodeList(v))
            }
            override fun remove(key: String) = clear(key)
            private fun clear(key: String) {
                ed.remove(key); ed.remove(KeyValueStore.LIST_NS + key); ed.remove(KeyValueStore.DOUBLE_NS + key)
            }
        }
        e.block()
        ed.apply()
    }
}
