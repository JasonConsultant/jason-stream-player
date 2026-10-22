package de.jasonstream.core.migration

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import org.w3c.dom.Element
import java.io.ByteArrayInputStream
import java.io.File
import java.io.InputStream
import java.io.ObjectInputStream
import java.io.ObjectStreamClass
import java.math.BigInteger
import java.util.Base64
import javax.xml.parsers.DocumentBuilderFactory

/**
 * Liest die Einstellungen der Flutter-App
 * (`shared_prefs/FlutterSharedPreferences.xml`, Plugin
 * shared_preferences_android 2.4.x, „Legacy“-API) und liefert sie
 * **dekodiert und ohne das Präfix „flutter.“**:
 *
 * | Dart-Typ       | Ablage im XML                                           | Ergebnis        |
 * |----------------|---------------------------------------------------------|-----------------|
 * | String         | `<string>`                                              | String          |
 * | int            | `<long>`                                                | Long            |
 * | bool           | `<boolean>`                                             | Boolean         |
 * | double         | `<string>` „VGhpcyBpcyB0aGUgcHJlZml4IGZvciBEb3VibGUu“+Zahl | Double       |
 * | List<String>   | `<string>` LIST_PREFIX + „!“ + JSON (ab 2.3)             | List<String>    |
 * |                | `<string>` LIST_PREFIX + Base64(Java-Serialisierung) (alt) | List<String>  |
 * |                | `<set>` (sehr alt, setStringSet)                        | List<String>    |
 *
 * Die Datei wird nur gelesen, nie verändert.
 */
object FlutterPrefs {
    const val FILE_NAME = "FlutterSharedPreferences"
    const val KEY_PREFIX = "flutter."
    const val LIST_PREFIX = "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIGxpc3Qu"
    const val JSON_LIST_PREFIX = "$LIST_PREFIX!"
    const val DOUBLE_PREFIX = "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBEb3VibGUu"
    const val BIG_INTEGER_PREFIX = "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBCaWdJbnRlZ2Vy"

    /** Pfad relativ zum Datenverzeichnis der App. */
    fun file(dataDir: File) = File(dataDir, "shared_prefs/$FILE_NAME.xml")

    fun read(file: File): Map<String, Any> = file.inputStream().use { read(it) }

    /** XML → dekodierte Werte (nur Schlüssel mit „flutter.“). */
    fun read(input: InputStream): Map<String, Any> {
        val f = DocumentBuilderFactory.newInstance().apply {
            isNamespaceAware = false
            isExpandEntityReferences = false
            runCatching { setFeature("http://apache.org/xml/features/disallow-doctype-decl", true) }
        }
        val doc = f.newDocumentBuilder().parse(input)
        val raw = LinkedHashMap<String, Any>()
        val nodes = doc.documentElement.childNodes
        for (i in 0 until nodes.length) {
            val el = nodes.item(i) as? Element ?: continue
            val name = el.getAttribute("name") ?: continue
            val value: Any? = when (el.tagName) {
                "string" -> el.textContent ?: ""
                "long" -> el.getAttribute("value").toLongOrNull()
                "int" -> el.getAttribute("value").toLongOrNull()
                "boolean" -> el.getAttribute("value") == "true"
                "float" -> el.getAttribute("value").toDoubleOrNull()
                "set" -> {
                    val items = el.getElementsByTagName("string")
                    (0 until items.length).map { items.item(it).textContent ?: "" }
                }
                else -> null
            }
            if (value != null) raw[name] = value
        }
        return decodeAll(raw)
    }

    /** Wie `getAll(prefix)` des Plugins: nur „flutter.“-Schlüssel, Präfix entfernt. */
    fun decodeAll(raw: Map<String, Any?>): Map<String, Any> {
        val out = LinkedHashMap<String, Any>()
        for ((k, v) in raw) {
            if (v == null || !k.startsWith(KEY_PREFIX)) continue
            val decoded = decodeValue(v) ?: continue
            out[k.substring(KEY_PREFIX.length)] = decoded
        }
        return out
    }

    fun decodeValue(v: Any): Any? = when (v) {
        is String -> when {
            v.startsWith(JSON_LIST_PREFIX) -> decodeJsonList(v.substring(JSON_LIST_PREFIX.length))
            v.startsWith(LIST_PREFIX) -> decodeJavaList(v.substring(LIST_PREFIX.length))
            v.startsWith(BIG_INTEGER_PREFIX) ->
                runCatching { BigInteger(v.substring(BIG_INTEGER_PREFIX.length), Character.MAX_RADIX).toLong() }.getOrNull()
            v.startsWith(DOUBLE_PREFIX) -> v.substring(DOUBLE_PREFIX.length).toDoubleOrNull()
            else -> v
        }
        is Int -> v.toLong()
        is Float -> v.toDouble()
        is Set<*> -> v.map { it.toString() }
        else -> v
    }

    private fun decodeJsonList(s: String): List<String>? = try {
        Json.parseToJsonElement(s).jsonArray.map { (it as JsonPrimitive).content }
    } catch (_: Exception) {
        null
    }

    /** Alte Ablage: java.io-Serialisierung einer ArrayList<String>, Base64 (android.util DEFAULT). */
    private fun decodeJavaList(s: String): List<String>? = try {
        val bytes = Base64.getMimeDecoder().decode(s)
        SafeListInput(ByteArrayInputStream(bytes)).use { stream ->
            @Suppress("UNCHECKED_CAST")
            (stream.readObject() as List<*>).map { it.toString() }
        }
    } catch (_: Exception) {
        null
    }

    /** Nur String-Listen zulassen (wie StringListObjectInputStream des Plugins). */
    private class SafeListInput(input: InputStream) : ObjectInputStream(input) {
        private val allow = setOf(
            "java.util.Arrays\$ArrayList", "java.util.ArrayList", "java.lang.String", "[Ljava.lang.String;",
        )
        override fun resolveClass(desc: ObjectStreamClass): Class<*> {
            if (desc.name !in allow) throw ClassNotFoundException(desc.name)
            return super.resolveClass(desc)
        }
    }

    // ---------- Für Tests: Werte so kodieren, wie das Plugin sie schreibt ----------
    fun encodeXml(values: Map<String, Any>, legacyLists: Boolean = false): String {
        val sb = StringBuilder("<?xml version='1.0' encoding='utf-8' standalone='yes' ?>\n<map>\n")
        fun esc(s: String) = s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;")
        for ((k0, v) in values) {
            val k = esc(KEY_PREFIX + k0)
            when (v) {
                is String -> sb.append("    <string name=\"$k\">${esc(v)}</string>\n")
                is Boolean -> sb.append("    <boolean name=\"$k\" value=\"$v\" />\n")
                is Int, is Long -> sb.append("    <long name=\"$k\" value=\"$v\" />\n")
                is Double -> sb.append("    <string name=\"$k\">${esc(DOUBLE_PREFIX + v)}</string>\n")
                is List<*> -> {
                    val enc = if (legacyLists) LIST_PREFIX + encodeJavaList(v.map { it.toString() })
                    else JSON_LIST_PREFIX + kotlinx.serialization.json.JsonArray(v.map { JsonPrimitive(it.toString()) })
                    sb.append("    <string name=\"$k\">${esc(enc)}</string>\n")
                }
                else -> error("Typ ${v::class}")
            }
        }
        return sb.append("</map>\n").toString()
    }

    private fun encodeJavaList(l: List<String>): String {
        val bos = java.io.ByteArrayOutputStream()
        java.io.ObjectOutputStream(bos).use { it.writeObject(ArrayList(l)) }
        // android.util.Base64.DEFAULT bricht nach 76 Zeichen um.
        return Base64.getMimeEncoder(76, "\n".toByteArray()).encodeToString(bos.toByteArray()) + "\n"
    }
}
