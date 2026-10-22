package de.jasonstream.playback.logic

/**
 * Zustand der Live-Pause (Port von timeshift.dart, zeitbasiert/Wanduhr).
 *
 * Native Umsetzung (siehe PlayerEngine):
 * * HLS mit DVR-Fenster: echtes Spulen im Fenster (ExoPlayer seekTo),
 *   [window] = Fensterlänge, Rückstand wird mit dem Player abgeglichen.
 * * MPEG-TS/progressiv: „Pause = Anhalten“. ExoPlayer puffert weiter, bis
 *   sein Puffer voll ist (≈ 50 s / set_buffer); danach staut sich die
 *   Verbindung. Weiter spielt ab der Pausenstelle; reißt die Verbindung
 *   ab, verbindet der Player neu (= live). Spulen ist dort nicht möglich.
 *   TODO(Phase 2b): Ringpuffer auf dem Datenträger für TS-Live (siehe API.md).
 */
class TimeshiftState(var windowMs: Long, nowMs: Long) {
    private var openedAt = nowMs
    private var pausedAt: Long? = null
    private var behindMs = 0L

    /** Spulen im Puffer möglich (HLS-DVR); sonst nur Anhalten. */
    var seekable = false

    val enabled: Boolean get() = windowMs > 0
    val paused: Boolean get() = pausedAt != null

    fun reset(nowMs: Long) {
        openedAt = nowMs
        pausedAt = null
        behindMs = 0
    }

    fun available(nowMs: Long): Long = minOf(nowMs - openedAt, windowMs).coerceAtLeast(0)

    private fun clamp(d: Long): Long = d.coerceIn(0, windowMs.coerceAtLeast(0))

    fun behind(nowMs: Long): Long {
        var b = behindMs
        pausedAt?.let { b += nowMs - it }
        return clamp(b)
    }

    fun isShifted(nowMs: Long): Boolean = paused || behind(nowMs) >= 2000

    fun pause(nowMs: Long) {
        if (!enabled) return
        if (pausedAt == null) pausedAt = nowMs
    }

    fun resume(nowMs: Long) {
        if (pausedAt == null) return
        behindMs = behind(nowMs)
        pausedAt = null
    }

    /** Spulen um [deltaMs] (negativ = zurück); liefert die tatsächliche Verschiebung. */
    fun seek(deltaMs: Long, nowMs: Long): Long {
        val cur = behind(nowMs)
        var target = (cur - deltaMs).coerceAtLeast(0)
        val avail = maxOf(available(nowMs), cur)
        if (target > avail) target = avail
        if (pausedAt != null) pausedAt = nowMs
        behindMs = target
        return cur - target
    }

    fun goLive() {
        behindMs = 0
        pausedAt = null
    }

    /** Rückstand vom Player übernehmen. */
    fun sync(behind: Long, nowMs: Long) {
        if (pausedAt != null) pausedAt = nowMs
        behindMs = clamp(behind)
    }

    /** Pause so lang, dass der Puffer sicher übergelaufen ist → besser neu öffnen. */
    fun overflowed(nowMs: Long): Boolean = enabled && !seekable && behind(nowMs) >= windowMs
}

/** „−12:34“ (ab 1 h „−1:02:03“). */
fun fmtBehind(ms: Long): String {
    val s = ms / 1000
    val h = s / 3600
    val m = (s % 3600) / 60
    val sec = s % 60
    fun two(v: Long) = v.toString().padStart(2, '0')
    return if (h > 0) "−$h:${two(m)}:${two(sec)}" else "−$m:${two(sec)}"
}

/** „1:02:03“ bzw. „12:34“ (fmtClock). */
fun fmtClock(ms: Long): String {
    val s = (ms / 1000).coerceAtLeast(0)
    val h = s / 3600
    val m = (s % 3600) / 60
    val sec = s % 60
    fun two(v: Long) = v.toString().padStart(2, '0')
    return if (h > 0) "$h:${two(m)}:${two(sec)}" else "${two(m)}:${two(sec)}"
}

/** Halte-Fenster für TS-Live-Pause in ms (Einstellung set_livebuffer: Minuten, 0 = aus). */
fun liveHoldWindowMs(minutes: Int): Long = if (minutes <= 0) 0 else minutes * 60_000L
