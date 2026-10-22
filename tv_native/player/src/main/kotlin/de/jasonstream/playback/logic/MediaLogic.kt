package de.jasonstream.playback.logic

import de.jasonstream.core.model.Channel
import de.jasonstream.core.model.HostFailover
import de.jasonstream.core.model.Portal
import de.jasonstream.data.net.StreamHeaders

// ---------------------------------------------------------------------------
// Kopfzeilen (stream_open_headers.dart)
// ---------------------------------------------------------------------------
object PlayerHeaders {
    /** Standard-User-Agent des Players, wenn weder Portal noch Sender einen setzen. */
    val defaults = mapOf("User-Agent" to "JasonStreamPlayer/0.4")

    /**
     * Kopfzeilen beim Öffnen eines Streams: Portal (User-Agent, Referer),
     * überschrieben vom Sender (#EXTVLCOPT …) und ggf. vom „|Header=…“-Anhang
     * der Adresse. Erlaubt sind nur User-Agent, Referer, Origin und Cookie.
     */
    fun forStream(portal: Portal?, channel: Channel?, url: String): Pair<String, Map<String, String>> {
        val h = LinkedHashMap<String, String>()
        if (portal != null) h.putAll(StreamHeaders.streamHeadersFor(portal, channel))
        else channel?.headers?.forEach { (k, v) -> StreamHeaders.canonical(k)?.let { c -> h[c] = v } }
        val (clean, pipe) = StreamHeaders.splitPipeHeaders(url)
        h.putAll(pipe)
        if (headerValue(h, "User-Agent") == null) h.putAll(defaults)
        return clean to h
    }

    fun headerValue(h: Map<String, String>, name: String): String? =
        h.entries.firstOrNull { it.key.equals(name, ignoreCase = true) }?.value
}

// ---------------------------------------------------------------------------
// Ersatz-Adressen für einen Stream
// ---------------------------------------------------------------------------
/**
 * Abspiel-Adressen einer Quelle in Versuchsreihenfolge (bevorzugte
 * Server-Adresse zuerst) – siehe [HostFailover.streamCandidates].
 */
class HostCandidates(private val portal: Portal?, url: String) {
    /** (Adresse, Index der Server-Adresse im Portal) ohne Doppelte. */
    private val entries: List<Pair<String, Int>> = buildList {
        if (portal != null) {
            for (i in HostFailover.order(portal)) {
                val r = HostFailover.rewriteTo(portal, url, i)
                if (none { it.first == r }) add(r to i)
            }
        }
        if (isEmpty()) add(url to 0)
    }
    val urls: List<String> get() = entries.map { it.first }
    var pos = 0; private set

    val current: String get() = entries[pos].first
    val left: Int get() = entries.size - 1 - pos

    fun next(): Boolean {
        if (pos + 1 >= entries.size) return false
        pos++
        return true
    }

    /** Läuft → diese Server-Adresse für das Portal merken. */
    fun markWorking() {
        val p = portal ?: return
        if (entries.size <= 1) return
        HostFailover.markWorking(p, entries[pos].second)
    }
}

// ---------------------------------------------------------------------------
// Sprachen (languages.dart)
// ---------------------------------------------------------------------------
data class TrackLanguage(val code: String, val label: String, val aliases: List<String>) {
    fun matches(lang: String?, title: String? = null): Boolean {
        for (raw in listOf(lang, title)) {
            val c = raw?.lowercase()?.trim().orEmpty()
            if (c.isEmpty()) continue
            for (a in aliases) {
                if (c == a || c.startsWith("$a-") || c.startsWith("${a}_")) return true
                if (a.length > 3 && c.contains(a)) return true
            }
        }
        return false
    }

    companion object {
        val all = listOf(
            TrackLanguage("de", "Deutsch", listOf("de", "deu", "ger", "german", "deutsch")),
            TrackLanguage("en", "English", listOf("en", "eng", "english", "englisch")),
            TrackLanguage("tr", "Türkçe", listOf("tr", "tur", "turkish", "türkçe", "turkce", "türkisch")),
            TrackLanguage("fr", "Français", listOf("fr", "fra", "fre", "french", "français")),
            TrackLanguage("es", "Español", listOf("es", "spa", "spanish", "español")),
            TrackLanguage("it", "Italiano", listOf("it", "ita", "italian", "italiano")),
            TrackLanguage("pl", "Polski", listOf("pl", "pol", "polish", "polski")),
            TrackLanguage("ru", "Русский", listOf("ru", "rus", "russian", "русский")),
            TrackLanguage("ar", "العربية", listOf("ar", "ara", "arabic", "العربية")),
            TrackLanguage("sq", "Shqip", listOf("sq", "sqi", "alb", "albanian", "shqip")),
            TrackLanguage(
                "hr", "Hrvatski / Srpski / Bosanski",
                listOf("hr", "hrv", "scr", "sr", "srp", "scc", "bs", "bos", "croatian", "serbian", "bosnian"),
            ),
            TrackLanguage("ku", "Kurdî", listOf("ku", "kur", "kurdish", "kurdî")),
        )

        fun byCode(code: String?) = all.firstOrNull { it.code == code }

        /** Lesbarer Name einer Spur: Sprache + ggf. Titel. */
        fun describe(lang: String?, title: String?, fallback: String): String {
            val hit = all.firstOrNull { it.matches(lang) }
            val t = title?.trim().orEmpty()
            if (hit == null) {
                val parts = listOfNotNull(t.ifEmpty { null }, lang?.ifEmpty { null })
                return if (parts.isEmpty()) fallback else parts.joinToString(" · ")
            }
            if (t.isEmpty() || t.lowercase() in hit.aliases) return hit.label
            return "${hit.label} · $t"
        }
    }
}

/** Eine Spur für die Auswahl (id = Gruppen-/Spur-Index als Text). */
data class TrackInfo(val id: String, val language: String?, val title: String?)

/**
 * Passende Spur nach Vorliebe: null = nichts ändern, −1 = ausschalten,
 * sonst Index in [tracks]. [pref]: Sprachcode, „auto“ oder „off“.
 */
fun pickTrack(tracks: List<TrackInfo>, pref: String, allowOff: Boolean = false): Int? {
    if (pref == "auto") return null
    if (pref == "off") return if (allowOff) -1 else null
    val lang = TrackLanguage.byCode(pref) ?: return null
    for (i in tracks.indices) {
        val t = tracks[i]
        if (t.id == "auto" || t.id == "no") continue
        if (lang.matches(t.language, t.title)) return i
    }
    return if (allowOff) -1 else null
}

// ---------------------------------------------------------------------------
// Untertitel-Aussehen (subtitle_style.dart)
// ---------------------------------------------------------------------------
data class SubtitleStyle(
    val size: String = "normal",
    val color: String = "weiss",
    val box: Boolean = false,
    val outline: Boolean = true,
) {
    /** Bezogen auf 720p-Höhe (mpv sub-font-size). */
    val fontSize: Int get() = when (size) { "klein" -> 36; "gross" -> 60; "sehrgross" -> 72; else -> 48 }

    /**
     * Anteil der Bildhöhe für SubtitleView.setFractionalTextSize: wie die
     * Flutter-Untertitel (fontSize·2/3 logische Pixel bei 540 dp Höhe).
     */
    val fraction: Float get() = fontSize * 2f / 3f / 540f

    val colorArgb: Int get() = when (color) { "gelb" -> 0xFFFFFF00.toInt(); "cyan" -> 0xFF00FFFF.toInt(); else -> 0xFFFFFFFF.toInt() }
    val backArgb: Int get() = if (box) 0x80000000.toInt() else 0x00000000

    companion object {
        val sizes = listOf("klein", "normal", "gross", "sehrgross")
        val colors = listOf("weiss", "gelb", "cyan")

        /** Aus Storage-Optionen (set_sub_size …; unbekannte Werte → Standard). */
        fun fromOptions(option: (String, String) -> String) = SubtitleStyle(
            size = option("sub_size", "normal").takeIf { it in sizes } ?: "normal",
            color = option("sub_color", "weiss").takeIf { it in colors } ?: "weiss",
            box = option("sub_bg", "none") == "box",
            outline = option("sub_outline", "on") != "off",
        )
    }
}

// ---------------------------------------------------------------------------
// Bildformat (aspect.dart) – gleiche IDs ('set_fit', 'aspect_<portal>_<sender>')
// ---------------------------------------------------------------------------
enum class AspectMode(val id: String, val ratio: Float?, val scale: Float) {
    original("original", null, 1f),
    fill("cover", null, 1f),
    stretch("stretch", null, 1f),
    r16x9("16x9", 16f / 9f, 1f),
    r4x3("4x3", 4f / 3f, 1f),
    cinema("cinema", null, (21f / 9f) / (16f / 9f)),
    zoom("zoom", null, 1.15f);

    val next: AspectMode get() = entries[(ordinal + 1) % entries.size]

    companion object {
        fun fromId(id: String?): AspectMode = when (id) {
            null, "contain" -> original
            "fill" -> stretch
            else -> entries.firstOrNull { it.id == id } ?: original
        }
    }
}

// ---------------------------------------------------------------------------
// Bildwiederholrate (AFR) – Port von MainActivity.setFrameRate
// ---------------------------------------------------------------------------
data class DisplayModeInfo(val id: Int, val width: Int, val height: Int, val refreshRate: Float)

object FrameRateMatch {
    fun score(hz: Float, fps: Double): Double {
        val ratio = hz / fps
        val mult = Math.round(ratio)
        if (mult < 1 || mult > 4) return Double.MAX_VALUE
        return Math.abs(ratio - mult) * 100 + mult * 0.01
    }

    /** Passender Modus gleicher Auflösung (Hz = ganzzahliges Vielfaches) oder null. */
    fun pick(current: DisplayModeInfo, modes: List<DisplayModeInfo>, fps: Double): DisplayModeInfo? {
        if (fps <= 1) return null
        val best = modes.filter { it.width == current.width && it.height == current.height }
            .minByOrNull { score(it.refreshRate, fps) } ?: return null
        return if (score(best.refreshRate, fps) > 0.5) null else best
    }
}
