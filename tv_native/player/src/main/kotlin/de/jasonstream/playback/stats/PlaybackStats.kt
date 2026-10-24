package de.jasonstream.playback.stats

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.longOrNull

// ============================================================================
// Wiedergabe-Statistik (Einstellungen → „Wiedergabe-Statistik“)
//
// Zielwerte des Testplans (alpha4):
//   Fokus-Reaktion  ≤ 150 ms (P95)     App-Start   ≤ 3 s
//   Senderwechsel   ≤ 3 s (P90)        Abstürze    0
//   Stalls          ≤ 1 je 2 h         Fokusverluste 0
//
// Reine Logik ohne Android-Abhängigkeiten (Tests). Gezählt werden nur
// Zahlen und Zeiten – keine Sendernamen, Adressen oder Zugangsdaten.
// ============================================================================

/** Ampel. */
enum class Grade { none, green, yellow, red }

/** Die sechs Zielwerte (Reihenfolge = Anzeige). */
enum class Metric { focus, appStart, zap, crashes, stalls, focusLoss }

/** Zielwerte (ms bzw. Anzahl); gelb = bis [yellowFactor] × Ziel (bei Null-Zielen: ≤ [yellowCount]). */
object Targets {
    const val FOCUS_P95_MS = 150L
    const val APP_START_MS = 3_000L
    const val ZAP_P90_MS = 3_000L
    const val STALL_WINDOW_MS = 2L * 3600 * 1000
    const val YELLOW_FACTOR = 1.5
    const val YELLOW_COUNT = 2

    fun gradeMs(value: Long?, target: Long): Grade = when {
        value == null -> Grade.none
        value <= target -> Grade.green
        value <= (target * YELLOW_FACTOR).toLong() -> Grade.yellow
        else -> Grade.red
    }

    fun gradeCount(count: Int, allowed: Int = 0): Grade = when {
        count <= allowed -> Grade.green
        count <= allowed + YELLOW_COUNT -> Grade.yellow
        else -> Grade.red
    }

    /** Stalls: höchstens einer je 2 h Wiedergabe (ohne Wiedergabe: 0 erlaubt, 1 noch gelb). */
    fun gradeStalls(stalls: Int, watchMs: Long): Grade {
        val allowed = (watchMs / STALL_WINDOW_MS).toInt()
        return gradeCount(stalls, allowed)
    }
}

/** Ereignis (für den Dauertest und das Protokoll der Seite). */
enum class StatEventKind { zapStart, open, firstFrame, stall, reconnect, error, crash, focusLoss, focusMs, appStart, reset }

data class StatEvent(val kind: StatEventKind, val valueMs: Long = -1, val detail: String = "")

/** Persistierter Stand (JSON). Listen begrenzt: Zaps 500, Fokus 400, Start 20. */
data class StatsData(
    val zapCount: Int = 0,
    val zapFailed: Int = 0,
    val zapMs: List<Long> = emptyList(),
    val stalls: Int = 0,
    val reconnects: Int = 0,
    val crashes: Int = 0,
    val focusLosses: Int = 0,
    val focusMs: List<Long> = emptyList(),
    val appStartMs: List<Long> = emptyList(),
    val watchMs: Long = 0,
    /** Letzter Dauertest (Zusammenfassung, nur Zahlen). */
    val lastSoak: String = "",
    val since: Long = 0,
) {
    val zapP50: Long? get() = percentile(zapMs, 50)
    val zapP90: Long? get() = percentile(zapMs, 90)
    val zapLast20: List<Long> get() = zapMs.takeLast(20)
    val focusP95: Long? get() = percentile(focusMs, 95)
    val focusP50: Long? get() = percentile(focusMs, 50)
    val lastAppStartMs: Long? get() = appStartMs.lastOrNull()
    val appStartWorstMs: Long? get() = appStartMs.maxOrNull()

    fun grade(m: Metric): Grade = when (m) {
        Metric.focus -> Targets.gradeMs(focusP95, Targets.FOCUS_P95_MS)
        Metric.appStart -> Targets.gradeMs(lastAppStartMs, Targets.APP_START_MS)
        Metric.zap -> Targets.gradeMs(zapP90, Targets.ZAP_P90_MS)
        Metric.crashes -> Targets.gradeCount(crashes)
        Metric.stalls -> Targets.gradeStalls(stalls, watchMs)
        Metric.focusLoss -> Targets.gradeCount(focusLosses)
    }

    /** Gesamtampel: schlechteste Einzelnote (ohne „keine Daten“). */
    val overall: Grade get() = Metric.entries.map(::grade).filter { it != Grade.none }.maxByOrNull { it.ordinal } ?: Grade.none

    operator fun plus(o: StatsData) = StatsData(
        zapCount + o.zapCount, zapFailed + o.zapFailed, (zapMs + o.zapMs).takeLast(MAX_ZAPS),
        stalls + o.stalls, reconnects + o.reconnects, crashes + o.crashes, focusLosses + o.focusLosses,
        (focusMs + o.focusMs).takeLast(MAX_FOCUS), (appStartMs + o.appStartMs).takeLast(MAX_STARTS),
        watchMs + o.watchMs, if (o.lastSoak.isNotEmpty()) o.lastSoak else lastSoak,
        if (since == 0L) o.since else if (o.since == 0L) since else minOf(since, o.since),
    )

    fun toJson(): String = buildJsonObject {
        put("v", JsonPrimitive(1))
        put("zapN", JsonPrimitive(zapCount)); put("zapF", JsonPrimitive(zapFailed))
        put("zap", buildJsonArray { zapMs.forEach { add(JsonPrimitive(it)) } })
        put("stalls", JsonPrimitive(stalls)); put("recon", JsonPrimitive(reconnects)); put("crash", JsonPrimitive(crashes))
        put("fLoss", JsonPrimitive(focusLosses))
        put("focus", buildJsonArray { focusMs.forEach { add(JsonPrimitive(it)) } })
        put("start", buildJsonArray { appStartMs.forEach { add(JsonPrimitive(it)) } })
        put("watch", JsonPrimitive(watchMs)); put("soak", JsonPrimitive(lastSoak)); put("since", JsonPrimitive(since))
    }.toString()

    companion object {
        const val MAX_ZAPS = 500
        const val MAX_FOCUS = 400
        const val MAX_STARTS = 20

        /** p-tes Perzentil (nächster Rang); leer → null. */
        fun percentile(l: List<Long>, p: Int): Long? {
            if (l.isEmpty()) return null
            val s = l.sorted()
            val rank = Math.ceil(p / 100.0 * s.size).toInt().coerceIn(1, s.size)
            return s[rank - 1]
        }

        fun fromJson(s: String?): StatsData {
            if (s.isNullOrBlank()) return StatsData()
            val o = runCatching { Json.parseToJsonElement(s).jsonObject }.getOrNull() ?: return StatsData()
            fun l(k: String) = (o[k] as? JsonPrimitive)?.longOrNull ?: 0L
            fun i(k: String) = l(k).toInt()
            fun arr(k: String) = (o[k] as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.longOrNull } ?: emptyList()
            return StatsData(
                i("zapN"), i("zapF"), arr("zap"), i("stalls"), i("recon"), i("crash"), i("fLoss"),
                arr("focus"), arr("start"), l("watch"), (o["soak"] as? JsonPrimitive)?.content ?: "", l("since"),
            )
        }
    }
}

/** Ablage (App: Storage-Option „playstats“; Tests: Speicher). */
interface StatsStore {
    fun load(): String?
    fun save(json: String)
}

/**
 * Sammelt die Ereignisse. Alle Aufrufe vom Haupt-Thread (außer [onCrashMarker]
 * beim Start). [clock]: monotone Millisekunden (SystemClock.uptimeMillis).
 */
class StatsRecorder(private val clock: () -> Long, private val wallClock: () -> Long = System::currentTimeMillis) {
    var data = StatsData(since = 0)
        private set

    /** Zählt bei jeder Änderung hoch (Compose liest den Stand darüber). */
    var revision by mutableLongStateOf(0L)
        private set

    private val _events = MutableSharedFlow<StatEvent>(extraBufferCapacity = 64)
    /** Ereignisse live (Dauertest wartet auf erstes Bild / Fehler). */
    val events: SharedFlow<StatEvent> = _events

    var store: StatsStore? = null
        set(v) {
            field = v
            if (v != null) {
                // Vor dem Laden gezählte Ereignisse (Absturz-Marker, App-Start) dazuzählen.
                data = StatsData.fromJson(v.load()) + data
                if (data.since == 0L) data = data.copy(since = wallClock())
                dirty = true
                persist(force = true)
            }
        }

    // ---- Umschalten
    private var zapStartAt: Long? = null
    private var zapOpenPending = false
    /** Erstes Bild des aktuellen Streams schon gezählt. */
    private var framePending = false

    // ---- Wiedergabezeit / Stalls
    private var playingSince: Long? = null
    private var wasReady = false
    private var buffering = false

    // ---- Fokus-Reaktion
    private var keyAt: Long? = null
    private var keyEventTime = Long.MIN_VALUE

    private var dirty = false
    private var lastSaveAt = 0L

    // ===================================================================== Zaps
    /** Umschalt-Taste gedrückt (vor PIN/Adressauflösung). */
    fun onZapStart(at: Long = clock()) {
        zapStartAt = at
        zapOpenPending = true
        emit(StatEvent(StatEventKind.zapStart))
    }

    /**
     * Neuer Stream wird geöffnet. [zap]: Senderwechsel (zählt, Zeit ab [onZapStart]
     * bzw. jetzt). [reconnect]: stille Wiederverbindung (zählt als Reconnect,
     * das erste Bild danach ist kein Zap).
     */
    fun onOpen(zap: Boolean, reconnect: Boolean) {
        val now = clock()
        if (reconnect) {
            data = data.copy(reconnects = data.reconnects + 1)
            zapStartAt = null
            zapOpenPending = false
            emit(StatEvent(StatEventKind.reconnect))
        } else if (zap) {
            if (zapStartAt == null || !zapOpenPending) zapStartAt = now
            zapOpenPending = false
            data = data.copy(zapCount = data.zapCount + 1)
            emit(StatEvent(StatEventKind.open))
        } else {
            zapStartAt = null
            zapOpenPending = false
            emit(StatEvent(StatEventKind.open))
        }
        framePending = true
        wasReady = false
        buffering = false
        flushWatch(now)
        changed()
    }

    /** Erstes gerendertes Bild des aktuellen Streams. */
    fun onFirstFrame() {
        if (!framePending) return
        framePending = false
        val now = clock()
        val s = zapStartAt
        zapStartAt = null
        if (s != null) {
            val ms = (now - s).coerceAtLeast(0)
            data = data.copy(zapMs = (data.zapMs + ms).takeLast(StatsData.MAX_ZAPS))
            emit(StatEvent(StatEventKind.firstFrame, ms))
        } else emit(StatEvent(StatEventKind.firstFrame))
        changed()
    }

    /** Fehler der Engine (ohne Zugangsdaten; [category] z. B. „http 403“). */
    fun onError(category: String) {
        if (framePending && zapStartAt != null) {
            data = data.copy(zapFailed = data.zapFailed + 1)
            zapStartAt = null
        }
        framePending = false
        flushWatch(clock())
        emit(StatEvent(StatEventKind.error, -1, category.take(40)))
        changed()
    }

    // ===================================================================== Wiedergabe
    /** Player.STATE_*: 1 idle, 2 buffering, 3 ready, 4 ended. Nachpuffern nach „ready“ = Stall. */
    fun onPlaybackState(state: Int) {
        when (state) {
            2 -> if (wasReady && !buffering) { buffering = true; onStall() }
            3 -> { wasReady = true; buffering = false }
            1, 4 -> { buffering = false; flushWatch(clock()) }
        }
    }

    /** Hänger (Position läuft nicht weiter) – vom Player gemeldet. */
    fun onStall() {
        data = data.copy(stalls = data.stalls + 1)
        emit(StatEvent(StatEventKind.stall))
        changed()
    }

    fun onIsPlaying(playing: Boolean) {
        val now = clock()
        if (playing) { if (playingSince == null) playingSince = now } else flushWatch(now)
    }

    /** Sekündlich (Wiedergabezeit sichern). */
    fun tick() {
        val now = clock()
        if (playingSince != null) {
            flushWatch(now)
            playingSince = now
        }
        persist()
    }

    // ===================================================================== App / Fokus
    /** Absturz-Marker vom letzten Lauf gefunden. */
    fun onCrashMarker() {
        data = data.copy(crashes = data.crashes + 1)
        emit(StatEvent(StatEventKind.crash))
        changed()
    }

    /** Nichts fokussiert, obwohl eine Taste kam (bzw. Fokus musste zurückgeholt werden). */
    fun onFocusLost() {
        data = data.copy(focusLosses = data.focusLosses + 1)
        emit(StatEvent(StatEventKind.focusLoss))
        changed()
    }

    /** Pfeiltaste gedrückt (eventTime der Taste, uptime). Mehrfachmeldungen derselben Taste zählen einmal. */
    fun onNavKeyDown(eventTime: Long) {
        if (eventTime == keyEventTime) return
        keyEventTime = eventTime
        keyAt = eventTime
    }

    /** Ein Element hat den Fokus bekommen. */
    fun onFocusGained() {
        val k = keyAt ?: return
        keyAt = null
        val ms = clock() - k
        if (ms < 0 || ms > 2_000) return // keine Antwort auf diese Taste
        data = data.copy(focusMs = (data.focusMs + ms).takeLast(StatsData.MAX_FOCUS))
        emit(StatEvent(StatEventKind.focusMs, ms))
        changed(light = true)
    }

    /** Prozessstart → erstes Bild. */
    fun onAppStart(ms: Long) {
        if (ms <= 0 || ms > 120_000) return
        data = data.copy(appStartMs = (data.appStartMs + ms).takeLast(StatsData.MAX_STARTS))
        emit(StatEvent(StatEventKind.appStart, ms))
        changed()
    }

    fun onSoakResult(summary: String) {
        data = data.copy(lastSoak = summary)
        changed()
    }

    /** „Zurücksetzen“. */
    fun reset() {
        data = StatsData(since = wallClock())
        zapStartAt = null; zapOpenPending = false; framePending = false
        playingSince = null; wasReady = false; buffering = false; keyAt = null
        dirty = true
        persist(force = true)
        emit(StatEvent(StatEventKind.reset))
        revision++
    }

    /** onStop: Wiedergabezeit und Stand sichern. */
    fun flush() {
        val now = clock()
        if (playingSince != null) { flushWatch(now); playingSince = now }
        persist(force = true)
    }

    // ===================================================================== intern
    private fun flushWatch(now: Long) {
        val s = playingSince ?: return
        data = data.copy(watchMs = data.watchMs + (now - s).coerceAtLeast(0))
        playingSince = null
        dirty = true
    }

    private fun emit(e: StatEvent) { _events.tryEmit(e) }

    private fun changed(light: Boolean = false) {
        dirty = true
        revision++
        if (!light) persist(force = true) else persist()
    }

    private fun persist(force: Boolean = false) {
        val st = store ?: return
        if (!dirty) return
        val now = clock()
        if (!force && now - lastSaveAt < 3_000) return
        lastSaveAt = now
        dirty = false
        runCatching { st.save(data.toJson()) }
    }
}

/** Prozessweite Sitzung: Engine/Player schreiben, die Einstellungen lesen. */
object PlaybackStats {
    val session = StatsRecorder(clock = { android.os.SystemClock.uptimeMillis() })
}
