package de.jasonstream.playback.stats

import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import java.util.Calendar
import java.util.Locale
import java.util.TimeZone

// ============================================================================
// Wiedergabe-Statistik (Abnahme-Kriterien des Architekturplans: Zeit bis zum
// ersten Bild, Umschaltzeit, Nachpuffern, Fehler/Abstürze).
//
// Reine Logik ohne Android: [StatsRecorder] bekommt die Ereignisse der Engine
// (Anfrage, erstes Bild, Puffern, Fehler …) und führt daraus die Sitzungs-
// Summen ([Totals]), die letzten 50 Ereignisse und eine Tages-Zusammenfassung
// (7 Tage, als kleines JSON für die Einstellungen). Es werden nur Sendernamen
// gespeichert – keine Adressen, keine Zugangsdaten.
// ============================================================================

/** Art eines Eintrags der Ereignisliste. */
enum class EventKind { open, firstFrame, rebuffer, error, reconnect, soak }

/**
 * Ein Ereignis. [valueMs]: Dauer in ms (erstes Bild / Umschalten / Nachpuffern),
 * sonst −1. [detail]: Fehlerklasse, Decoder/Auflösung, Dauertest-Ergebnis.
 */
data class StatEvent(
    val atMs: Long,
    val kind: EventKind,
    val channel: String,
    val valueMs: Long = -1,
    val detail: String = "",
)

/** Fehlerklassen (aus dem ExoPlayer-Fehlercode bzw. der Meldung). */
object ErrorCategory {
    const val NETWORK = "network"
    const val HTTP = "http"
    const val TIMEOUT = "timeout"
    const val DECODER = "decoder"
    const val SOURCE = "source"
    const val STALL = "stall"
    const val OTHER = "other"

    /** Aus der Fehlermeldung der Engine (ohne Zugangsdaten) – für Aufrufer ohne Fehlercode. */
    fun ofMessage(msg: String?): String {
        val m = msg?.lowercase() ?: return OTHER
        return when {
            "http error" in m -> HTTP
            "timed out" in m || "timeout" in m -> TIMEOUT
            "decoder" in m || "audio track" in m -> DECODER
            "connection" in m || "unable to connect" in m || "network" in m || "failed to open" in m -> NETWORK
            "eof" == m || "stall" in m -> STALL
            "parser" in m || "unrecognized" in m || "malformed" in m || "source" in m -> SOURCE
            else -> OTHER
        }
    }
}

/** Zustand eines geöffneten Streams (bis zum nächsten Öffnen). */
class OpenStream internal constructor(
    val channel: String,
    val live: Boolean,
    val reconnect: Boolean,
    /** Zeitpunkt der Anfrage an die Engine (Uhr des Recorders). */
    val requestedAt: Long,
    /** Tastendruck/Start des Umschaltens (vor Adressauflösung, PIN …) oder null. */
    val zapStartedAt: Long?,
    val outputMode: String,
) {
    var firstFrameAt: Long? = null; internal set
    var failed: String? = null; internal set
    var rebuffers = 0; internal set
    var rebufferMs = 0L; internal set
    var droppedFrames = 0L; internal set
    var decoder: String? = null; internal set
    var resolution: String? = null; internal set
    val firstFrameMs: Long? get() = firstFrameAt?.let { it - requestedAt }
    val zapMs: Long? get() = firstFrameAt?.let { f -> zapStartedAt?.let { f - it } }
}

/** Summen einer Sitzung (oder eines Tages). */
data class Totals(
    val opens: Int = 0,
    val zaps: Int = 0,
    val reconnects: Int = 0,
    val failures: Int = 0,
    val watchMs: Long = 0,
    val firstFrameMs: List<Long> = emptyList(),
    val zapMs: List<Long> = emptyList(),
    val rebufferCount: Int = 0,
    val rebufferMs: Long = 0,
    val droppedFrames: Long = 0,
    val errors: Map<String, Int> = emptyMap(),
) {
    val errorCount: Int get() = errors.values.sum()
    val firstFrameAvg: Long get() = average(firstFrameMs)
    val firstFrameP95: Long get() = percentile(firstFrameMs, 95)
    val zapAvg: Long get() = average(zapMs)
    val zapP95: Long get() = percentile(zapMs, 95)
    /** Anteil Nachpuffern an der Wiedergabezeit (0..1). */
    val rebufferRatio: Double get() = if (watchMs <= 0) 0.0 else rebufferMs.toDouble() / (watchMs + rebufferMs)

    operator fun plus(o: Totals) = Totals(
        opens + o.opens, zaps + o.zaps, reconnects + o.reconnects, failures + o.failures, watchMs + o.watchMs,
        firstFrameMs + o.firstFrameMs, zapMs + o.zapMs, rebufferCount + o.rebufferCount, rebufferMs + o.rebufferMs,
        droppedFrames + o.droppedFrames, mergeCounts(errors, o.errors),
    )

    companion object {
        fun average(l: List<Long>): Long = if (l.isEmpty()) 0 else l.sum() / l.size

        /** p-tes Perzentil (nächster Rang, 0 < p ≤ 100); leer → 0. */
        fun percentile(l: List<Long>, p: Int): Long {
            if (l.isEmpty()) return 0
            val s = l.sorted()
            val rank = Math.ceil(p / 100.0 * s.size).toInt().coerceIn(1, s.size)
            return s[rank - 1]
        }

        fun mergeCounts(a: Map<String, Int>, b: Map<String, Int>): Map<String, Int> {
            if (b.isEmpty()) return a
            val m = LinkedHashMap(a)
            b.forEach { (k, v) -> m[k] = (m[k] ?: 0) + v }
            return m
        }
    }
}

/** Zusammenfassung eines Tages (ohne Einzelwerte: nur Anzahl, Summe, Maximum, p95 des Tages). */
data class DailySummary(
    val day: String,
    val opens: Int = 0,
    val zaps: Int = 0,
    val reconnects: Int = 0,
    val failures: Int = 0,
    val watchMs: Long = 0,
    val firstFrameCount: Int = 0,
    val firstFrameSumMs: Long = 0,
    val firstFrameP95Ms: Long = 0,
    val zapCount: Int = 0,
    val zapSumMs: Long = 0,
    val zapP95Ms: Long = 0,
    val rebufferCount: Int = 0,
    val rebufferMs: Long = 0,
    val droppedFrames: Long = 0,
    val errors: Map<String, Int> = emptyMap(),
) {
    val firstFrameAvg: Long get() = if (firstFrameCount == 0) 0 else firstFrameSumMs / firstFrameCount
    val zapAvg: Long get() = if (zapCount == 0) 0 else zapSumMs / zapCount
    val rebufferRatio: Double get() = if (watchMs <= 0) 0.0 else rebufferMs.toDouble() / (watchMs + rebufferMs)

    /** Tag mit den Summen der Sitzung aktualisieren ([t] = Sitzungs-Summen seit Sitzungsbeginn, gleicher Tag). */
    fun with(t: Totals, base: Totals): DailySummary {
        // Differenz Sitzung − zuletzt übernommener Stand, damit mehrfaches Sichern nicht doppelt zählt.
        val ff = t.firstFrameMs.drop(base.firstFrameMs.size)
        val zp = t.zapMs.drop(base.zapMs.size)
        val ffAll = firstFrameSumMs // p95 des Tages: aus Tageswerten + neuen Werten geschätzt (max der beiden p95)
        return copy(
            opens = opens + t.opens - base.opens,
            zaps = zaps + t.zaps - base.zaps,
            reconnects = reconnects + t.reconnects - base.reconnects,
            failures = failures + t.failures - base.failures,
            watchMs = watchMs + t.watchMs - base.watchMs,
            firstFrameCount = firstFrameCount + ff.size,
            firstFrameSumMs = ffAll + ff.sum(),
            firstFrameP95Ms = maxOf(firstFrameP95Ms, Totals.percentile(ff, 95)),
            zapCount = zapCount + zp.size,
            zapSumMs = zapSumMs + zp.sum(),
            zapP95Ms = maxOf(zapP95Ms, Totals.percentile(zp, 95)),
            rebufferCount = rebufferCount + t.rebufferCount - base.rebufferCount,
            rebufferMs = rebufferMs + t.rebufferMs - base.rebufferMs,
            droppedFrames = droppedFrames + t.droppedFrames - base.droppedFrames,
            errors = Totals.mergeCounts(errors, t.errors.mapValues { (k, v) -> v - (base.errors[k] ?: 0) }.filterValues { it > 0 }),
        )
    }

    fun toJson(): JsonObject = buildJsonObject {
        put("day", JsonPrimitive(day)); put("opens", JsonPrimitive(opens)); put("zaps", JsonPrimitive(zaps))
        put("reconnects", JsonPrimitive(reconnects)); put("failures", JsonPrimitive(failures)); put("watchMs", JsonPrimitive(watchMs))
        put("ffN", JsonPrimitive(firstFrameCount)); put("ffSum", JsonPrimitive(firstFrameSumMs)); put("ffP95", JsonPrimitive(firstFrameP95Ms))
        put("zapN", JsonPrimitive(zapCount)); put("zapSum", JsonPrimitive(zapSumMs)); put("zapP95", JsonPrimitive(zapP95Ms))
        put("rbN", JsonPrimitive(rebufferCount)); put("rbMs", JsonPrimitive(rebufferMs)); put("drop", JsonPrimitive(droppedFrames))
        put("errors", buildJsonObject { errors.forEach { (k, v) -> put(k, JsonPrimitive(v)) } })
    }

    companion object {
        fun fromJson(o: JsonObject): DailySummary? {
            fun l(k: String) = (o[k] as? JsonPrimitive)?.longOrNull ?: 0L
            fun i(k: String) = l(k).toInt()
            val day = (o["day"] as? JsonPrimitive)?.contentOrNull ?: return null
            val errors = (o["errors"] as? JsonObject)?.mapNotNull { (k, v) -> (v as? JsonPrimitive)?.longOrNull?.let { k to it.toInt() } }?.toMap() ?: emptyMap()
            return DailySummary(
                day, i("opens"), i("zaps"), i("reconnects"), i("failures"), l("watchMs"), i("ffN"), l("ffSum"), l("ffP95"),
                i("zapN"), l("zapSum"), l("zapP95"), i("rbN"), l("rbMs"), l("drop"), errors,
            )
        }

        /** Tagesschlüssel (lokale Zeit): yyyy-MM-dd. */
        fun dayKey(epochMs: Long, tz: TimeZone = TimeZone.getDefault()): String {
            val c = Calendar.getInstance(tz).apply { timeInMillis = epochMs }
            return String.format(Locale.ROOT, "%04d-%02d-%02d", c.get(Calendar.YEAR), c.get(Calendar.MONTH) + 1, c.get(Calendar.DAY_OF_MONTH))
        }
    }
}

/** Rollierende Tages-Zusammenfassungen (höchstens [keepDays], älteste fallen weg). */
class RollingDaily(days: List<DailySummary> = emptyList(), val keepDays: Int = 7) {
    private val list = days.sortedBy { it.day }.takeLast(keepDays).toMutableList()
    val days: List<DailySummary> get() = list.toList()

    fun get(day: String): DailySummary? = list.firstOrNull { it.day == day }

    fun put(s: DailySummary) {
        list.removeAll { it.day == s.day }
        list.add(s)
        list.sortBy { it.day }
        while (list.size > keepDays) list.removeAt(0)
    }

    fun toJson(): String = buildJsonArray { list.forEach { add(it.toJson()) } }.toString()

    companion object {
        fun fromJson(s: String?, keepDays: Int = 7): RollingDaily {
            if (s.isNullOrBlank()) return RollingDaily(keepDays = keepDays)
            val arr = runCatching { Json.parseToJsonElement(s) as? JsonArray }.getOrNull() ?: return RollingDaily(keepDays = keepDays)
            return RollingDaily(arr.mapNotNull { runCatching { DailySummary.fromJson(it.jsonObject) }.getOrNull() }, keepDays)
        }
    }
}

/** Ablage der Tages-Zusammenfassung (die App: Storage-Option; Tests: Speicher). */
interface StatsStore {
    fun load(): String?
    fun save(json: String)
}

/**
 * Sammelt die Ereignisse einer Sitzung. Alle Aufrufe vom Haupt-Thread.
 * [clock]: Millisekunden-Uhr für Dauern (monoton), [wallClock]: Epoche für Tag/Zeitstempel.
 */
class StatsRecorder(
    private val clock: () -> Long = System::currentTimeMillis,
    private val wallClock: () -> Long = System::currentTimeMillis,
    val maxEvents: Int = 50,
) {
    var store: StatsStore? = null
        set(v) {
            field = v
            daily = RollingDaily.fromJson(v?.load())
            persistedBase = Totals()
            persistedDay = null
        }

    private var daily = RollingDaily()
    private var persistedBase = Totals()
    private var persistedDay: String? = null

    /** Summen der Sitzung (Compose-frei; die Oberfläche liest über [revision]). */
    var totals = Totals(); private set
    private val eventsList = ArrayDeque<StatEvent>()
    val events: List<StatEvent> get() = eventsList.toList()
    var current: OpenStream? = null; private set

    /** Zählt bei jeder Änderung hoch (Oberfläche). */
    var revision = 0L; private set

    private val _live = MutableSharedFlow<StatEvent>(extraBufferCapacity = 64)
    /** Ereignisse live (Dauertest wartet auf erstes Bild / Fehler). */
    val live: SharedFlow<StatEvent> = _live

    private var playingSince: Long? = null
    private var bufferingSince: Long? = null
    private var wasReady = false
    private var lastPersistAt = 0L

    /** Umschalt-Beginn (Tastendruck), bevor die Adresse aufgelöst ist. */
    private var pendingZapAt: Long? = null

    fun markZapStart(at: Long = clock()) { pendingZapAt = at }

    /**
     * Neue Quelle wird geöffnet. [zap]: Umschalten (zählt als Zap; Umschaltzeit ab
     * [markZapStart] bzw. jetzt). [reconnect]: stiller Wiederverbindungsversuch.
     */
    fun onOpen(channel: String, live: Boolean, reconnect: Boolean, zap: Boolean, outputMode: String = "") {
        finishCurrent()
        val now = clock()
        val zapAt = if (zap) (pendingZapAt ?: now) else null
        pendingZapAt = null
        current = OpenStream(channel, live, reconnect, now, zapAt, outputMode)
        wasReady = false
        bufferingSince = null
        totals = totals.copy(
            opens = totals.opens + 1,
            zaps = totals.zaps + (if (zap) 1 else 0),
            reconnects = totals.reconnects + (if (reconnect) 1 else 0),
        )
        add(StatEvent(wallClock(), if (reconnect) EventKind.reconnect else EventKind.open, channel))
    }

    fun onFirstFrame() {
        val c = current ?: return
        if (c.firstFrameAt != null) return
        val now = clock()
        c.firstFrameAt = now
        val ff = c.firstFrameMs!!
        val zap = c.zapMs
        totals = totals.copy(
            firstFrameMs = totals.firstFrameMs + ff,
            zapMs = if (zap != null) totals.zapMs + zap else totals.zapMs,
        )
        add(StatEvent(wallClock(), EventKind.firstFrame, c.channel, ff, if (zap != null) "zap ${zap}ms" else ""))
        persistMaybe()
    }

    /** Spielt / spielt nicht (Wiedergabezeit). */
    fun onIsPlaying(playing: Boolean) {
        val now = clock()
        if (playing) {
            if (playingSince == null) playingSince = now
        } else {
            flushWatch(now)
        }
    }

    /** Zustand der Engine: 1 idle, 2 buffering, 3 ready, 4 ended (Player.STATE_*). */
    fun onPlaybackState(state: Int) {
        val now = clock()
        when (state) {
            2 -> if (wasReady && bufferingSince == null) bufferingSince = now
            3 -> {
                wasReady = true
                val since = bufferingSince
                if (since != null) {
                    bufferingSince = null
                    val d = now - since
                    current?.let { it.rebuffers++; it.rebufferMs += d }
                    totals = totals.copy(rebufferCount = totals.rebufferCount + 1, rebufferMs = totals.rebufferMs + d)
                    add(StatEvent(wallClock(), EventKind.rebuffer, current?.channel ?: "", d))
                    persistMaybe()
                }
            }
            1, 4 -> {
                bufferingSince = null
                flushWatch(now)
            }
        }
    }

    fun onError(category: String, message: String = "") {
        val c = current
        if (c != null && c.failed == null) {
            c.failed = category
            if (c.firstFrameAt == null) totals = totals.copy(failures = totals.failures + 1)
        }
        totals = totals.copy(errors = Totals.mergeCounts(totals.errors, mapOf(category to 1)))
        add(StatEvent(wallClock(), EventKind.error, c?.channel ?: "", -1, if (message.isEmpty()) category else "$category · ${message.take(60)}"))
        flushWatch(clock())
        persistMaybe(force = true)
    }

    fun onDroppedFrames(n: Int) {
        current?.let { it.droppedFrames += n }
        totals = totals.copy(droppedFrames = totals.droppedFrames + n)
        revision++
    }

    fun onDecoder(name: String) { current?.decoder = name; revision++ }
    fun onResolution(w: Int, h: Int) { if (w > 0 && h > 0) { current?.resolution = "${w}×$h"; revision++ } }

    /** Dauertest-Ergebnis als Ereignis. */
    fun onSoakResult(summary: String) {
        add(StatEvent(wallClock(), EventKind.soak, "", -1, summary))
        persistMaybe(force = true)
    }

    /** Sekündlich von außen (Wiedergabezeit laufend sichern). */
    fun tick() {
        val now = clock()
        if (playingSince != null && now - lastPersistAt >= 60_000) {
            flushWatch(now)
            playingSince = now
            persistMaybe(force = true)
        }
    }

    /** Sitzung zurücksetzen (Einstellungen → Zurücksetzen): auch die Tages-Zusammenfassung. */
    fun reset() {
        totals = Totals()
        eventsList.clear()
        current = null
        playingSince = null
        bufferingSince = null
        wasReady = false
        daily = RollingDaily(keepDays = daily.keepDays)
        persistedBase = Totals()
        persistedDay = null
        store?.save(daily.toJson())
        revision++
    }

    /** Alle Tage (gespeichert, inkl. heute mit der laufenden Sitzung). */
    fun dailySummaries(): List<DailySummary> {
        flushWatch(clock())
        if (playingSince != null) playingSince = clock()
        persistMaybe(force = true)
        return daily.days
    }

    /** Wiedergabezeit beim Beenden sichern (onStop). */
    fun flush() {
        flushWatch(clock())
        if (playingSince != null) playingSince = clock()
        persistMaybe(force = true)
    }

    // ----------------------------------------------------------------- intern
    private fun finishCurrent() {
        val c = current ?: return
        if (c.firstFrameAt == null && c.failed == null) {
            // Vor dem ersten Bild weitergeschaltet/abgebrochen – kein Fehler, zählt nicht.
        }
        bufferingSince = null
        flushWatch(clock())
    }

    private fun flushWatch(now: Long) {
        val s = playingSince ?: return
        totals = totals.copy(watchMs = totals.watchMs + (now - s).coerceAtLeast(0))
        playingSince = null
        revision++
    }

    private fun add(e: StatEvent) {
        eventsList.addLast(e)
        while (eventsList.size > maxEvents) eventsList.removeFirst()
        revision++
        _live.tryEmit(e)
    }

    private fun persistMaybe(force: Boolean = false) {
        val st = store ?: return
        val now = clock()
        if (!force && now - lastPersistAt < 10_000) return
        lastPersistAt = now
        val day = DailySummary.dayKey(wallClock())
        if (persistedDay != null && persistedDay != day) {
            // Tageswechsel: ab jetzt zählt die Differenz zum neuen Tag.
            persistedBase = totals
        }
        persistedDay = day
        val cur = daily.get(day) ?: DailySummary(day)
        daily.put(cur.with(totals, persistedBase))
        persistedBase = totals
        runCatching { st.save(daily.toJson()) }
    }
}

/** Prozessweite Sitzung (Engine schreibt, Einstellungen lesen). */
object PlaybackStats {
    val session = StatsRecorder(clock = { android.os.SystemClock.uptimeMillis() })

    /** Umschalttaste gedrückt (Umschaltzeit beginnt). */
    fun markZapStart() = session.markZapStart()
}
