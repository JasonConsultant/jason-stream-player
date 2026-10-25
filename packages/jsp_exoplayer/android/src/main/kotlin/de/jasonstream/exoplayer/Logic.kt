package de.jasonstream.exoplayer

import androidx.media3.common.PlaybackException

/**
 * Reine Logik ohne Android-Abhängigkeiten (Unit-Tests auf der JVM):
 * Fehler-Einordnung, Kopfzeilen, Decoder-Reihenfolge, Puffer, Schwärzen.
 */

/** Grobe Einordnung eines Media3-Fehlers – steuert in Dart Wiederverbinden bzw. Rückfall auf mpv. */
enum class ErrorCategory(val id: String) {
    NETWORK("network"),
    DECODER("decoder"),
    FORMAT("format"),
    CONTAINER("container"),
    DRM("drm"),
    OTHER("other");

    /** Lohnt ein Versuch mit der anderen Engine (mpv)? Netzfehler nicht – die laufen über Wiederverbinden. */
    val wantsCompat: Boolean get() = this == DECODER || this == FORMAT || this == CONTAINER

    companion object {
        fun of(code: Int): ErrorCategory = when (code) {
            PlaybackException.ERROR_CODE_TIMEOUT -> NETWORK
            in 2000..2999 -> NETWORK // ERROR_CODE_IO_* (inkl. HTTP-Status)
            PlaybackException.ERROR_CODE_PARSING_CONTAINER_MALFORMED,
            PlaybackException.ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED,
            -> CONTAINER
            PlaybackException.ERROR_CODE_PARSING_MANIFEST_MALFORMED,
            PlaybackException.ERROR_CODE_PARSING_MANIFEST_UNSUPPORTED,
            PlaybackException.ERROR_CODE_DECODING_FORMAT_EXCEEDS_CAPABILITIES,
            PlaybackException.ERROR_CODE_DECODING_FORMAT_UNSUPPORTED,
            -> FORMAT
            in 4000..4999 -> DECODER // Init/Abfrage/Dekodieren gescheitert
            in 5000..5999 -> DECODER // AudioTrack (Ausgabe des Dekoders)
            in 6000..6999 -> DRM
            in 7000..7999 -> DECODER // Video-Bildverarbeitung
            else -> OTHER
        }
    }
}

/** HTTP-Kopfzeilen für Streams säubern: keine Steuerzeichen, keine Verbindungs-Kopfzeilen, Namen kanonisch. */
object StreamHeaders {
    private val forbidden = setOf(
        "host", "content-length", "connection", "transfer-encoding", "keep-alive",
        "upgrade", "te", "trailer", "proxy-authorization", "proxy-connection", "range",
    )
    private val control = Regex("[\\x00-\\x1F\\x7F]")
    private val token = Regex("^[A-Za-z0-9!#$%&'*+.^_`|~-]+$")

    fun canonical(name: String): String = when (name.trim().lowercase()) {
        "user-agent", "useragent", "http-user-agent" -> "User-Agent"
        "referer", "referrer", "http-referrer", "http-referer" -> "Referer"
        "origin" -> "Origin"
        "cookie" -> "Cookie"
        else -> name.trim()
    }

    fun sanitize(input: Map<String, String?>): Map<String, String> {
        val out = LinkedHashMap<String, String>()
        for ((k, v) in input) {
            val name = canonical(k)
            if (name.isEmpty() || !token.matches(name)) continue
            if (name.lowercase() in forbidden) continue
            val value = control.replace(v ?: continue, "").trim()
            if (value.isEmpty() || value.length > 4096) continue
            // Gleicher Name in anderer Schreibweise: letzter gewinnt.
            out.keys.firstOrNull { it.equals(name, ignoreCase = true) }?.let { out.remove(it) }
            out[name] = value
        }
        return out
    }
}

/** Decoder-Reihenfolge: Standard = Gerät (Hardware zuerst), „Software“ (mpv hwdec=no) = Software zuerst. */
object DecoderOrder {
    fun <T> order(list: List<T>, preferSoftware: Boolean, isSoftware: (T) -> Boolean): List<T> {
        if (!preferSoftware || list.size < 2) return list
        // Stabile Sortierung: Reihenfolge innerhalb der Gruppen bleibt.
        return list.filter(isSoftware) + list.filterNot(isSoftware)
    }

    /** Software-Dekoder nach Namen (für Anzeige/Statistik, wenn MediaCodecInfo fehlt). */
    fun looksSoftware(name: String?): Boolean {
        if (name == null) return false
        val n = name.lowercase()
        return n.startsWith("omx.google.") || n.startsWith("c2.android.") ||
            n.startsWith("ffmpeg") || n.contains(".sw.") || n.startsWith("libgav1") ||
            n.startsWith("libvpx") || n.startsWith("libdav1d")
    }
}

/** Puffer-Einstellungen für LoadControl. */
data class BufferPlan(
    val minBufferMs: Int,
    val maxBufferMs: Int,
    val playbackMs: Int,
    val rebufferMs: Int,
    val targetBytes: Int,
    /** Rückpuffer (Live-Pause/Timeshift), 0 = aus. */
    val backBufferMs: Int,
) {
    companion object {
        /** Grobe Datenrate zum Umrechnen von Byte-Grenzen in Zeit (≈ 4 Mbit/s). */
        const val BYTES_PER_SECOND = 500_000

        /**
         * [bufferBytes]: Einstellung Puffer (16/48/128 MB). [backBytes] > 0:
         * Live-Pause aktiv (Rückpuffer). Wie tv_native: schneller Start mit 1 s,
         * nach einem Hänger 2 s; danach 15–50 s vorpuffern.
         */
        fun of(bufferBytes: Int, backBytes: Int, forwardBytes: Int = 0, careful: Boolean = false): BufferPlan {
            val bytes = maxOf(bufferBytes, forwardBytes).coerceIn(8 shl 20, 512 shl 20)
            val back = if (backBytes > 0) (backBytes.toLong() / BYTES_PER_SECOND * 1000L)
                .coerceIn(30_000L, 3 * 3600_000L).toInt() else 0
            // Live-Pause: weiter laden, solange pausiert wird (bis zur Byte-Grenze).
            val maxMs = if (back > 0) maxOf(50_000, (forwardBytes.toLong() / BYTES_PER_SECOND * 1000L)
                .coerceAtMost(3 * 3600_000L).toInt()) else 50_000
            // Vorsichtiger Start (Start-Leiter Stufe b): mehr Vorpuffer vor dem
            // ersten Bild und nach einem Hänger – langsamer, aber stabiler.
            return BufferPlan(
                minBufferMs = if (careful) 25_000 else 15_000,
                maxBufferMs = maxMs,
                playbackMs = if (careful) 3_000 else 1_000,
                rebufferMs = if (careful) 6_000 else 2_000,
                targetBytes = bytes,
                backBufferMs = back,
            )
        }
    }
}

/** Entfernt Adressen und Zugangsdaten aus Texten für Logcat und Fehlermeldungen. */
object Redact {
    private val url = Regex("\\b[a-zA-Z][a-zA-Z0-9+.-]*://[^\\s\"'<>]+")
    private val param = Regex("(username|password|pass|user|token|key|api_key|auth)=([^&\\s\"]+)", RegexOption.IGNORE_CASE)
    private val path = Regex("/(live|movie|series|timeshift)/[^/\\s]+/[^/\\s]+/")

    fun text(s: String?): String {
        if (s.isNullOrEmpty()) return ""
        var out = url.replace(s) { m ->
            val v = m.value
            val scheme = v.substringBefore("://")
            "$scheme://•••"
        }
        out = param.replace(out) { "${it.groupValues[1]}=•••" }
        out = path.replace(out) { "/${it.groupValues[1]}/•••/•••/" }
        return out.take(300)
    }
}

/** Typ einer Adresse und Untertitel-MIME-Typen. */
object MediaKind {
    fun isHls(url: String): Boolean {
        val l = url.lowercase().substringBefore('#')
        val path = l.substringBefore('?')
        return path.endsWith(".m3u8") || path.endsWith(".m3u") || l.contains("m3u8") ||
            l.contains("format=hls") || l.contains("type=m3u8")
    }

    fun isDash(url: String): Boolean = url.lowercase().substringBefore('?').endsWith(".mpd")

    /** MIME-Typ eines externen Untertitels nach Endung (Emby: …/Stream.srt). */
    fun subtitleMime(url: String, codec: String?): String {
        val c = (codec ?: url.substringBefore('?').substringAfterLast('.', "")).lowercase()
        return when (c) {
            "srt", "subrip" -> "application/x-subrip"
            "ass", "ssa" -> "text/x-ssa"
            "ttml", "dfxp", "xml" -> "application/ttml+xml"
            else -> "text/vtt"
        }
    }
}

/**
 * Datensparmodus: Obergrenze für die Videospur (HLS/DASH-Qualitätsstufen).
 * 0 = keine Grenze. Gibt es keine passende Stufe, nimmt Media3 die kleinste.
 */
data class VideoLimit(val maxBitrate: Int, val maxHeight: Int) {
    val active: Boolean get() = maxBitrate > 0 || maxHeight > 0

    /** Breite zur Höhe (16:9, großzügig gerundet), Int.MAX_VALUE = offen. */
    val maxWidth: Int get() = if (maxHeight > 0) (maxHeight * 16 + 8) / 9 else Int.MAX_VALUE
    val heightOrMax: Int get() = if (maxHeight > 0) maxHeight else Int.MAX_VALUE
    val bitrateOrMax: Int get() = if (maxBitrate > 0) maxBitrate else Int.MAX_VALUE

    companion object {
        val NONE = VideoLimit(0, 0)
        fun of(maxBitrate: Int, maxHeight: Int) =
            VideoLimit(maxBitrate.coerceAtLeast(0), maxHeight.coerceAtLeast(0))
    }
}
