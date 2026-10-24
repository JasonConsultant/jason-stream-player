package de.jasonstream.playback.soak

import de.jasonstream.playback.stats.Totals

// ============================================================================
// Dauertest („Soak“): N Umschaltvorgänge nacheinander durch die aktuelle Gruppe
// mit dem echten Player. Reine Zustandsmaschine – der Treiber in der App
// schaltet um, meldet erstes Bild/Fehler und ruft [tick] im Sekundentakt.
// Läuft nie von selbst: erst [start]. Zurück/Hintergrund → [cancel].
// ============================================================================

/** Was der Treiber tun soll. */
sealed interface SoakAction {
    /** Auf Sender [index] der Testliste umschalten. */
    data class Zap(val index: Int, val step: Int) : SoakAction
    /** Test ist beendet (Ergebnis in [SoakMachine.result]). */
    data object Finish : SoakAction
}

/** Zustand des Dauertests. */
sealed interface SoakState {
    data object Idle : SoakState
    /** Umgeschaltet, wartet aufs erste Bild. */
    data class Waiting(val step: Int, val index: Int, val sinceMs: Long) : SoakState
    /** Erstes Bild da, Verweilzeit läuft. */
    data class Dwelling(val step: Int, val index: Int, val untilMs: Long) : SoakState
    data class Done(val result: SoakResult) : SoakState
}

/** Grund des Abbruchs. */
enum class SoakAbort { none, cancelled, background, stall, error }

/** Ergebnis (geht in die Statistik und den Zusammenfassungs-Dialog). */
data class SoakResult(
    val planned: Int,
    val zaps: Int,
    val ok: Int,
    val failed: Int,
    val firstFrameMs: List<Long>,
    val abort: SoakAbort,
    val abortDetail: String,
    val durationMs: Long,
) {
    val avgMs: Long get() = Totals.average(firstFrameMs)
    val p95Ms: Long get() = Totals.percentile(firstFrameMs, 95)
    val maxMs: Long get() = firstFrameMs.maxOrNull() ?: 0
    val completed: Boolean get() = abort == SoakAbort.none && zaps == planned

    /** Einzeilige Zusammenfassung (Ereignisliste, nur Zahlen). */
    fun summaryLine(): String =
        "soak $zaps/$planned ok=$ok fail=$failed avg=${avgMs}ms p95=${p95Ms}ms max=${maxMs}ms" +
            (if (abort != SoakAbort.none) " abort=$abort" else "") + " ${durationMs / 1000}s"
}

/**
 * [count] Umschaltvorgänge, [dwellMs] Verweilzeit nach dem ersten Bild,
 * [stallLimitMs] ohne Bild → Abbruch (ANR-ähnlicher Hänger). [listSize]:
 * Länge der Testliste (zyklisch ab [startIndex] + 1).
 */
class SoakMachine(
    val count: Int,
    val dwellMs: Long = DEFAULT_DWELL_MS,
    val stallLimitMs: Long = STALL_LIMIT_MS,
    private val listSize: Int,
    private val startIndex: Int = 0,
    /** Bei Fehlern (kein Bild) weitermachen statt abbrechen. Hänger brechen immer ab. */
    val continueOnError: Boolean = true,
) {
    var state: SoakState = SoakState.Idle
        private set
    var result: SoakResult? = null
        private set

    private var step = 0
    private var ok = 0
    private var failed = 0
    private val frames = ArrayList<Long>()
    private var startedAt = 0L
    private var lastIndex = startIndex

    val running: Boolean get() = state is SoakState.Waiting || state is SoakState.Dwelling
    val progress: Int get() = step
    val okCount: Int get() = ok
    val failedCount: Int get() = failed
    val lastFirstFrameMs: Long? get() = frames.lastOrNull()

    init {
        require(count > 0 && listSize > 0)
    }

    /** Start (einzig hier beginnt der Test). */
    fun start(now: Long): SoakAction {
        check(state is SoakState.Idle)
        startedAt = now
        return next(now)
    }

    private fun next(now: Long): SoakAction {
        if (step >= count) return finish(now, SoakAbort.none, "")
        step++
        lastIndex = (lastIndex + 1) % listSize
        state = SoakState.Waiting(step, lastIndex, now)
        return SoakAction.Zap(lastIndex, step)
    }

    /** Erstes Bild des aktuellen Senders. */
    fun onFirstFrame(now: Long) {
        val w = state as? SoakState.Waiting ?: return
        ok++
        frames += (now - w.sinceMs).coerceAtLeast(0)
        state = SoakState.Dwelling(w.step, w.index, now + dwellMs)
    }

    /** Fehler beim aktuellen Sender (vor dem ersten Bild). */
    fun onError(now: Long, detail: String): SoakAction? {
        val w = state as? SoakState.Waiting ?: return null
        failed++
        if (!continueOnError) return finish(now, SoakAbort.error, detail)
        // Kurze Verweilzeit, damit die Engine zur Ruhe kommt, dann weiter.
        state = SoakState.Dwelling(w.step, w.index, now + minOf(dwellMs, 1500))
        return null
    }

    /** Sekündlich: Verweilzeit abgelaufen → nächster Sender; Hänger → Abbruch. */
    fun tick(now: Long): SoakAction? = when (val s = state) {
        is SoakState.Waiting -> if (now - s.sinceMs >= stallLimitMs) {
            failed++
            finish(now, SoakAbort.stall, "step ${s.step}: ${(now - s.sinceMs) / 1000}s without frame")
        } else null
        is SoakState.Dwelling -> if (now >= s.untilMs) next(now) else null
        else -> null
    }

    /** Zurück-Taste / Hintergrund. */
    fun cancel(now: Long, reason: SoakAbort = SoakAbort.cancelled): SoakAction? {
        if (!running) return null
        return finish(now, reason, "")
    }

    private fun finish(now: Long, abort: SoakAbort, detail: String): SoakAction {
        val zapsDone = if (abort == SoakAbort.none) step else step
        val r = SoakResult(count, zapsDone, ok, failed, frames.toList(), abort, detail, now - startedAt)
        result = r
        state = SoakState.Done(r)
        return SoakAction.Finish
    }

    companion object {
        const val DEFAULT_COUNT = 100
        const val DEFAULT_DWELL_MS = 4_000L
        const val STALL_LIMIT_MS = 15_000L
        val COUNT_OPTIONS = listOf(20, 100, 300)
        val DWELL_OPTIONS_MS = listOf(2_000L, 4_000L, 8_000L)
    }
}
