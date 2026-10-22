package de.jasonstream.data.net

import com.squareup.moshi.JsonReader
import okio.BufferedSource

/**
 * Streaming-JSON (Moshi JsonReader auf okio) für große Listen: Es wird immer
 * nur **ein** Listeneintrag als kleine Map gehalten.
 *
 * Werte wie in Dart nach `'$v'`: Zahlen bleiben als Originaltext („123“,
 * „1.0“), Wahrheitswerte als Boolean, null als null, Objekte/Listen als
 * Map/List.
 */
object JsonStream {
    fun reader(source: BufferedSource): JsonReader = JsonReader.of(source).apply { isLenient = true }

    /** Ein beliebiger Wert (Zahlen als Text). */
    fun readValue(r: JsonReader): Any? = when (r.peek()) {
        JsonReader.Token.BEGIN_OBJECT -> {
            val m = LinkedHashMap<String, Any?>()
            r.beginObject()
            while (r.hasNext()) m[r.nextName()] = readValue(r)
            r.endObject()
            m
        }
        JsonReader.Token.BEGIN_ARRAY -> {
            val l = ArrayList<Any?>()
            r.beginArray()
            while (r.hasNext()) l.add(readValue(r))
            r.endArray()
            l
        }
        JsonReader.Token.STRING, JsonReader.Token.NUMBER -> r.nextString()
        JsonReader.Token.BOOLEAN -> r.nextBoolean()
        JsonReader.Token.NULL -> r.nextNull<Any>()
        else -> { r.skipValue(); null }
    }

    /**
     * Ruft [onItem] für jedes Objekt einer Liste auf (Wurzel = Liste).
     * Andere Wurzeln (Objekt, leer, Fehlermeldung) → keine Einträge.
     */
    fun forEachObject(source: BufferedSource, onItem: (Map<String, Any?>) -> Unit) {
        if (source.exhausted()) return
        val r = reader(source)
        if (r.peek() != JsonReader.Token.BEGIN_ARRAY) {
            r.skipValue(); return
        }
        r.beginArray()
        while (r.hasNext()) {
            if (r.peek() == JsonReader.Token.BEGIN_OBJECT) {
                @Suppress("UNCHECKED_CAST")
                onItem(readValue(r) as Map<String, Any?>)
            } else {
                r.skipValue() // kaputte Einträge kippen nicht die ganze Liste
            }
        }
        r.endArray()
    }

    /** Ganze (kleine) Antwort lesen; leer → leere Liste wie in Dart. */
    fun parse(source: BufferedSource): Any? {
        if (source.exhausted()) return emptyList<Any?>()
        return readValue(reader(source))
    }

    fun parse(text: String): Any? = parse(okio.Buffer().writeUtf8(text))

    // ---------- Dart-ähnliche Helfer ----------
    /** Dart `'$v'` (null → „null“). */
    fun s(v: Any?): String = when (v) {
        null -> "null"
        is Map<*, *> -> "{…}"
        is List<*> -> "[…]"
        else -> v.toString()
    }

    /** Dart `_str`: getrimmt, leer/„null“ → null. */
    fun str(v: Any?): String? {
        if (v == null) return null
        val t = s(v).trim()
        return if (t.isEmpty() || t == "null") null else t
    }

    /** Dart `int.tryParse('$v')`. */
    fun int(v: Any?): Int? = (v as? String ?: v?.toString())?.trim()?.toIntOrNull()
    fun long(v: Any?): Long? = (v as? String ?: v?.toString())?.trim()?.toLongOrNull()
}
