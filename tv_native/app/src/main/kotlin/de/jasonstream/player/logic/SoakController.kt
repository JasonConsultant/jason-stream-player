package de.jasonstream.player.logic

import android.os.SystemClock
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import de.jasonstream.core.model.Channel
import de.jasonstream.core.security.UrlPolicy
import de.jasonstream.data.net.StreamHeaders
import de.jasonstream.playback.api.PlayerDeps
import de.jasonstream.playback.engine.EngineConfig
import de.jasonstream.playback.engine.PlayerEngine
import de.jasonstream.playback.engine.StreamSpec
import de.jasonstream.playback.soak.SoakAbort
import de.jasonstream.playback.soak.SoakAction
import de.jasonstream.playback.soak.SoakMachine
import de.jasonstream.playback.soak.SoakResult
import de.jasonstream.playback.stats.PlaybackStats
import de.jasonstream.playback.stats.StatEventKind
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Treiber des Dauertests: schaltet mit der Engine (ohne Vollbild-Player)
 * durch [channels], meldet erstes Bild/Fehler an die [SoakMachine] und
 * schreibt das Ergebnis in die Wiedergabe-Statistik. Gesperrte Sender (PIN)
 * werden vorher aussortiert; Standort-Sperren (403/451) zählen als Fehler
 * und werden nie umgangen.
 */
class SoakController(
    private val engine: PlayerEngine,
    private val deps: PlayerDeps,
    private val scope: CoroutineScope,
    private val portalId: String,
    channels: List<Channel>,
    startIndex: Int = 0,
) {
    val channels: List<Channel> = channels.filterNot { deps.isLocked(portalId, it) }
    private val start = channels.getOrNull(startIndex)?.let { c -> this.channels.indexOf(c) }?.coerceAtLeast(0) ?: 0

    var machine by mutableStateOf<SoakMachine?>(null); private set
    var result by mutableStateOf<SoakResult?>(null); private set
    /** Fortschritt (Compose). */
    var step by mutableIntStateOf(0); private set
    var ok by mutableIntStateOf(0); private set
    var failed by mutableIntStateOf(0); private set
    var lastMs by mutableStateOf<Long?>(null); private set
    var currentChannel by mutableStateOf<Channel?>(null); private set

    val running: Boolean get() = machine?.running == true

    private var job: Job? = null
    private var listenJob: Job? = null
    private var openJob: Job? = null

    private fun now() = SystemClock.uptimeMillis()

    fun start(count: Int, dwellMs: Long = SoakMachine.DEFAULT_DWELL_MS): Boolean {
        if (running || channels.isEmpty()) return false
        result = null
        val m = SoakMachine(count, dwellMs, listSize = channels.size, startIndex = (start - 1 + channels.size) % channels.size)
        machine = m
        listenJob = scope.launch {
            PlaybackStats.session.events.collect { e ->
                val mm = machine ?: return@collect
                when (e.kind) {
                    StatEventKind.firstFrame -> { mm.onFirstFrame(now()); sync() }
                    StatEventKind.error -> { mm.onError(now(), e.detail)?.let(::perform); sync() }
                    else -> Unit
                }
            }
        }
        job = scope.launch {
            perform(m.start(now()))
            while (isActive && machine?.running == true) {
                delay(1000)
                machine?.tick(now())?.let(::perform)
                sync()
            }
        }
        return true
    }

    /** Zurück / Hintergrund. */
    fun cancel(reason: SoakAbort = SoakAbort.cancelled) {
        val m = machine ?: return
        m.cancel(now(), reason)?.let(::perform)
    }

    private fun perform(a: SoakAction) {
        when (a) {
            is SoakAction.Zap -> zap(a.index)
            SoakAction.Finish -> finish()
        }
        sync()
    }

    private fun zap(index: Int) {
        val c = channels[index]
        currentChannel = c
        openJob?.cancel()
        openJob = scope.launch {
            val portal = deps.portal(portalId)
            val url = withContext(Dispatchers.IO) { runCatching { deps.resolveLiveUrl(portalId, c) }.getOrNull() }
            if (!isActive) return@launch
            if (portal == null || url.isNullOrEmpty() || !UrlPolicy.isStream(url)) {
                PlaybackStats.session.onZapStart()
                PlaybackStats.session.onOpen(zap = true, reconnect = false)
                PlaybackStats.session.onError("no url")
                return@launch
            }
            PlaybackStats.session.onZapStart()
            engine.open(StreamSpec(url, StreamHeaders.streamHeadersFor(portal, c), live = true), EngineConfig.fromStorage(deps.storage), zap = true)
        }
    }

    private fun finish() {
        val m = machine ?: return
        val r = m.result ?: return
        result = r
        job?.cancel(); job = null
        listenJob?.cancel(); listenJob = null
        openJob?.cancel(); openJob = null
        engine.stop()
        PlaybackStats.session.onSoakResult(r.summaryLine())
        machine = null
    }

    private fun sync() {
        val m = machine ?: return
        step = m.progress; ok = m.okCount; failed = m.failedCount; lastMs = m.lastFirstFrameMs
    }

    fun dispose() {
        cancel(SoakAbort.background)
        job?.cancel(); listenJob?.cancel(); openJob?.cancel()
    }
}
