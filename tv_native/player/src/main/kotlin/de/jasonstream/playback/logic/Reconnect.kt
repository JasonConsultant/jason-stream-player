package de.jasonstream.playback.logic

/**
 * Automatisches Wiederverbinden – Port von lib/ui/player/reconnect.dart,
 * erweitert um Ersatz-Adressen des Portals ([HostFailover]).
 *
 * Ablauf je Störung:
 * 1. bis zu 3 Wiederholungen derselben Quelle (1 s, 2 s, 4 s),
 * 2. nächste Server-Adresse (nur bei Host-Fehlern und wenn das Portal
 *    Ersatz-Adressen hat; je Adresse 1 Versuch),
 * 3. nächste Variante des Senders (nur live; je Variante noch 1 Versuch),
 * 4. bei Decoder-Fehlern einmal Software-Dekodierung (FFmpeg bevorzugt),
 * 5. aufgeben (Fehlermeldung mit „Erneut versuchen“).
 *
 * Nach 60 s störungsfreier Wiedergabe beginnt alles von vorn. Fehler, bei
 * denen Wiederholen nichts bringt (401/403/404/451, von der App blockiert),
 * überspringen die Wiederholungen.
 */
enum class RecoveryKind { retry, nextHost, nextVariant, softwareDecode, giveUp }

data class RecoveryStep(val kind: RecoveryKind, val delayMs: Long = 0)

enum class FailureKind { error, stall }

class ReconnectPolicy {
    companion object {
        val backoffMs = longArrayOf(1000, 2000, 4000)
        const val HEALTHY_AFTER_MS = 60_000L
        const val RETRIES_PER_EXTRA_SOURCE = 1

        /** Fehler, bei denen dieselbe Quelle sofort wieder scheitert. */
        fun worthRetrying(message: String): Boolean = when (StreamError.classify(message)) {
            StreamErrorKind.geoBlocked, StreamErrorKind.forbidden, StreamErrorKind.unauthorized,
            StreamErrorKind.notFound, StreamErrorKind.blockedByApp -> false
            else -> true
        }

        /** Sieht der Fehler nach einem Decoder-Problem aus? */
        fun isDecoderError(message: String): Boolean {
            val m = message.lowercase()
            return m.contains("decod") || m.contains("codec") || m.contains("hwdec") ||
                m.contains("mediacodec") || m.contains("video output") || m.contains("vo:") ||
                m.contains("could not initialize") || m.contains("audiosink") || m.contains("audio track")
        }

        /** Könnte eine andere Server-Adresse helfen (nicht bei 401/403/451)? */
        fun isHostFailure(message: String?): Boolean {
            if (message == null) return true // Hänger/Ende des Streams
            return when (StreamError.classify(message)) {
                StreamErrorKind.unreachable, StreamErrorKind.notFound -> true
                StreamErrorKind.other -> StreamError.httpStatus(message)?.let { it == 408 || it == 429 || it >= 500 } ?: false
                else -> false
            }
        }
    }

    var retries = 0; private set
    var hostSwitches = 0; private set
    var variantSwitches = 0; private set
    var triedSoftware = false; private set
    private var goodSince: Long? = null

    val recovering: Boolean get() = retries > 0 || hostSwitches > 0 || variantSwitches > 0 || triedSoftware

    fun reset() {
        retries = 0; hostSwitches = 0; variantSwitches = 0; triedSoftware = false; goodSince = null
    }

    /** Wiedergabe läuft. Nach [HEALTHY_AFTER_MS] am Stück werden die Zähler zurückgesetzt. */
    fun markGood(nowMs: Long) {
        val since = goodSince ?: nowMs.also { goodSince = it }
        if (recovering && nowMs - since >= HEALTHY_AFTER_MS) {
            retries = 0; hostSwitches = 0; variantSwitches = 0; triedSoftware = false
        }
    }

    /**
     * Nächster Schritt nach einer Störung.
     * [hostsLeft]: weitere, noch nicht probierte Server-Adressen dieser Variante.
     * [variantsLeft]: weitere, noch nicht probierte Varianten (live).
     */
    fun onFailure(kind: FailureKind, message: String?, live: Boolean, variantsLeft: Int = 0, hostsLeft: Int = 0): RecoveryStep {
        goodSince = null
        val hopeless = kind == FailureKind.error && message != null && !worthRetrying(message)
        val maxRetries = if (hostSwitches == 0 && variantSwitches == 0) backoffMs.size else RETRIES_PER_EXTRA_SOURCE
        if (!hopeless && retries < maxRetries) {
            val d = backoffMs[retries.coerceIn(0, backoffMs.size - 1)]
            retries++
            return RecoveryStep(RecoveryKind.retry, d)
        }
        if (hostsLeft > 0 && isHostFailure(if (kind == FailureKind.stall) null else message)) {
            hostSwitches++
            retries = 0
            return RecoveryStep(RecoveryKind.nextHost)
        }
        if (live && variantsLeft > 0) {
            variantSwitches++
            retries = 0
            return RecoveryStep(RecoveryKind.nextVariant)
        }
        if (!triedSoftware && message != null && isDecoderError(message)) {
            triedSoftware = true
            retries = 0
            return RecoveryStep(RecoveryKind.softwareDecode)
        }
        return RecoveryStep(RecoveryKind.giveUp)
    }
}

/** Hänger-Erkennung: Position bewegt sich nicht, obwohl abgespielt werden soll. */
class StallDetector(val limitMs: Long = 12_000, val startupLimitMs: Long = 25_000) {
    private var lastPos: Long? = null
    private var since: Long? = null
    private var started = false

    fun reset() { lastPos = null; since = null; started = false }

    /** true, sobald ein Hänger erkannt ist (danach [reset] nötig). */
    fun sample(posMs: Long, nowMs: Long, active: Boolean): Boolean {
        if (!active) {
            since = null
            lastPos = posMs
            return false
        }
        val lp = lastPos
        if (lp == null || posMs != lp) {
            if (lp != null && posMs > lp) started = true
            lastPos = posMs
            since = nowMs
            return false
        }
        val s = since ?: nowMs.also { since = it }
        return nowMs - s >= if (started) limitMs else startupLimitMs
    }
}

enum class StreamErrorKind { geoBlocked, forbidden, unauthorized, notFound, unreachable, blockedByApp, other }

/** Fehlerart aus einer Fehlermeldung (Port von stream_errors.dart). */
object StreamError {
    private val statusRe = Regex("(?:http(?:\\s*error)?|server returned|status(?:\\s*code)?)[\\s:]*([1-5]\\d\\d)\\b")

    fun httpStatus(message: String): Int? = statusRe.find(message.lowercase())?.groupValues?.get(1)?.toIntOrNull()

    fun classify(message: String): StreamErrorKind {
        val m = message.lowercase()
        val code = httpStatus(m)
        return when {
            m.contains("sicherheitsgründen") || m.contains("security reasons") || m.contains("güvenlik nedeniyle") ->
                StreamErrorKind.blockedByApp
            code == 451 || m.contains("unavailable for legal reasons") -> StreamErrorKind.geoBlocked
            code == 403 || m.contains("forbidden") -> StreamErrorKind.forbidden
            code == 401 || m.contains("unauthorized") -> StreamErrorKind.unauthorized
            code == 404 || m.contains("not found") -> StreamErrorKind.notFound
            m.contains("timed out") || m.contains("timeout") || m.contains("connection refused") ||
                m.contains("failed to resolve") || m.contains("host lookup") ||
                m.contains("network is unreachable") || m.contains("failed to open") -> StreamErrorKind.unreachable
            else -> StreamErrorKind.other
        }
    }

    fun isLocationRelated(message: String): Boolean =
        classify(message).let { it == StreamErrorKind.geoBlocked || it == StreamErrorKind.forbidden }
}
