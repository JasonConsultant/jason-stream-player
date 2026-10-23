package de.jasonstream.playback.ui

import android.app.Activity
import android.content.Context
import android.content.res.Configuration
import androidx.annotation.OptIn
import androidx.annotation.StringRes
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.media3.common.C as MC
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import de.jasonstream.core.R as CR
import de.jasonstream.core.model.Channel
import de.jasonstream.core.model.EpgEntry
import de.jasonstream.core.security.Redactor
import de.jasonstream.core.security.UrlPolicy
import de.jasonstream.playback.R
import de.jasonstream.playback.api.NextUp
import de.jasonstream.playback.api.PlayRequest
import de.jasonstream.playback.api.PlayerDeps
import de.jasonstream.playback.engine.EngineCallbacks
import de.jasonstream.playback.engine.EngineConfig
import de.jasonstream.playback.engine.PlayerEngine
import de.jasonstream.playback.engine.StreamSpec
import de.jasonstream.playback.engine.TrackOption
import de.jasonstream.playback.logic.AspectMode
import de.jasonstream.playback.logic.DigitEntry
import de.jasonstream.playback.logic.DigitResult
import de.jasonstream.playback.logic.FailureKind
import de.jasonstream.playback.logic.HostCandidates
import de.jasonstream.playback.logic.NextUpState
import de.jasonstream.playback.logic.PlayerHeaders
import de.jasonstream.playback.logic.ReconnectPolicy
import de.jasonstream.playback.logic.RecoveryKind
import de.jasonstream.playback.logic.StallDetector
import de.jasonstream.playback.logic.StreamError
import de.jasonstream.playback.logic.SubtitleStyle
import de.jasonstream.playback.logic.TimeshiftState
import de.jasonstream.playback.logic.ZapBarState
import de.jasonstream.playback.logic.canSaveResume
import de.jasonstream.playback.logic.liveHoldWindowMs
import de.jasonstream.playback.logic.pickTrack
import de.jasonstream.playback.logic.resumeTargetMs
import de.jasonstream.playback.logic.wrapIndex
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.Locale

/** Auswahl-Fenster über dem Player. */
internal enum class Sheet { tracks, aspect, sleep, variants }

/**
 * Zustand und Verhalten des Players (Port von _PlayerScreenState). Hält
 * Compose-Zustand; alle Methoden auf dem Haupt-Thread.
 */
@OptIn(UnstableApi::class)
internal class PlayerController(
    baseContext: Context,
    val deps: PlayerDeps,
    val engine: PlayerEngine,
    private val scope: CoroutineScope,
    initial: PlayRequest,
) : EngineCallbacks {
    var onExit: () -> Unit = {}
    var onOpenGuide: () -> Unit = {}
    var onOpenChannelList: () -> Unit = {}
    var onRequestChanged: ((PlayRequest) -> Unit)? = null
    var activity: Activity? = baseContext.findActivity()

    /** Texte in der App-Sprache (set_applang), sonst Systemsprache. */
    val res: Context = localized(baseContext, deps.appLanguage())
    fun str(@StringRes id: Int, vararg args: Any?): String = res.getString(id, *args)

    val rootFocus = FocusRequester()
    val mainFocus = FocusRequester()

    // ---------- Compose-Zustand ----------
    var req by mutableStateOf(initial); private set
    val live get() = req.isLive
    val replay get() = req.isReplay
    val channels: List<Channel> get() = req.channels
    val index: Int get() = req.index.coerceIn(0, (channels.size - 1).coerceAtLeast(0))

    var overlay by mutableStateOf(true)
    var buffering by mutableStateOf(true); private set
    var hasVideo by mutableStateOf(false); private set
    var error by mutableStateOf<String?>(null); private set
    var status by mutableStateOf<String?>(null); private set
    var toast by mutableStateOf<String?>(null); private set
    var toastIcon by mutableStateOf<ImageVector?>(null); private set
    var digits by mutableStateOf(""); private set
    var aspect by mutableStateOf(AspectMode.original); private set
    var subStyle by mutableStateOf(SubtitleStyle()); private set
    var debug by mutableStateOf(false); private set
    var sleepAtMs by mutableStateOf<Long?>(null); private set
    var sleepWarning by mutableStateOf(false); private set
    var userPaused by mutableStateOf(false); private set
    var sheet by mutableStateOf<Sheet?>(null)
    var barVisible by mutableStateOf(false); private set
    var barIndex by mutableIntStateOf(0); private set
    /** Sekundentakt (Uhr, Fortschritt, Zeitversatz). */
    var clock by mutableLongStateOf(System.currentTimeMillis()); private set
    var positionMs by mutableLongStateOf(0); private set
    var durationMs by mutableLongStateOf(0); private set
    var accentKey by mutableStateOf(deps.storage.option("accent", "orange")); private set
    var nextUpShowing by mutableStateOf(false); private set
    var nextUpSeconds by mutableIntStateOf(10); private set
    var nextUpData by mutableStateOf<NextUp?>(null); private set
    var prevChannelId by mutableStateOf<String?>(null); private set
    var hasVariants by mutableStateOf(false); private set
    var favRevision by mutableIntStateOf(0); private set
    /** EPG-Stand der App (Neuzeichnen von Leiste/Overlay). */
    var epgRev by mutableLongStateOf(0L)

    // ---------- Intern ----------
    private val recon = ReconnectPolicy()
    private val stall = StallDetector()
    private val zapBar = ZapBarState()
    private val digitEntry = DigitEntry()
    private val ts = TimeshiftState(0, System.currentTimeMillis())
    private var openGen = 0
    private var opening = false
    private var retryJob: Job? = null
    private var hideJob: Job? = null
    private var barJob: Job? = null
    private var toastJob: Job? = null
    private var digitJob: Job? = null
    private var sleepJob: Job? = null
    private var nextUpJob: Job? = null
    private var tickJob: Job? = null
    private var variants: List<Channel> = emptyList()
    private var variantPos = 0
    private var hosts: HostCandidates? = null
    private var hostsFor: String? = null
    private var hostMarked = false
    private var preferSoftware = false
    private var curChannelId: String? = null
    private var userPickedTracks = false
    private var vodResumeAtMs: Long? = null
    private var lastPos = 0L
    private var lastSaveMs = 0L
    private var afrFps = 0f
    private var errorWhilePaused = false
    private var liveGapMs: Long? = null
    private var stopped = false

    init {
        engine.callbacks = this
        debug = deps.storage.flag("playerdebug")
    }

    // =====================================================================
    // Lebenszyklus
    // =====================================================================
    fun start() {
        stopped = false
        engine.callbacks = this
        open()
        tickJob?.cancel()
        tickJob = scope.launch {
            while (isActive) {
                delay(1000)
                watch()
            }
        }
    }

    /** onStop: Stelle merken, Player freigeben (die Engine baut ihn beim nächsten Öffnen neu). */
    fun stop() {
        savePosition()
        stopped = true
        tickJob?.cancel()
        retryJob?.cancel(); retryJob = null
        engine.release()
    }

    fun dispose() {
        if (afrFps > 0) Afr.apply(activity, 0.0)
        if (!stopped) savePosition()
        listOf(tickJob, retryJob, hideJob, barJob, toastJob, digitJob, sleepJob, nextUpJob).forEach { it?.cancel() }
        if (engine.callbacks === this) engine.callbacks = null
    }

    /** Neue Anfrage von der App (z. B. Auswahl in deren Senderliste). */
    fun setRequest(r: PlayRequest) {
        if (sameTarget(r, req)) return
        savePosition()
        req = r
        resetNextUp()
        open()
    }

    private fun publish() {
        onRequestChanged?.invoke(req)
    }

    // =====================================================================
    // Öffnen
    // =====================================================================
    /** Live: gerade gespielte Variante (sonst der Sender selbst). */
    val playingChannel: Channel?
        get() {
            if (!live || channels.isEmpty()) return null
            if (variants.isEmpty()) return channels[index]
            return variants[variantPos.coerceIn(0, variants.size - 1)]
        }

    private fun config() = EngineConfig.fromStorage(deps.storage, preferSoftware)

    /**
     * [quiet]: nach dem Zappen per Leiste nicht die Bedienelemente zeigen.
     * [recover]: stiller Wiederverbindungsversuch (gleicher Sender, ggf.
     * andere Variante/Server-Adresse) – kein Verlauf, Zähler bleiben.
     */
    fun open(quiet: Boolean = false, recover: Boolean = false) {
        val gen = ++openGen
        if (!recover) {
            opening = true
            retryJob?.cancel(); retryJob = null
            recon.reset()
            vodResumeAtMs = null
            variants = if (live && channels.isNotEmpty()) playOrderFor(channels[index]) else emptyList()
            variantPos = 0
            hosts = null
            preferSoftware = false
            userPickedTracks = false
        }
        hasVariants = live && channels.isNotEmpty() && deps.variantIndex().countOf(channels[index].id) > 1
        stall.reset()
        val now = System.currentTimeMillis()
        ts.reset(now)
        ts.seekable = false
        ts.windowMs = if (live) liveHoldWindowMs(deps.storage.option("livebuffer", "10").toIntOrNull() ?: 10) else 0
        liveGapMs = null
        userPaused = false
        errorWhilePaused = false
        lastPos = 0
        hostMarked = false
        error = null
        buffering = true
        hasVideo = false
        if (!recover) status = null
        subStyle = SubtitleStyle.fromOptions { k, f -> deps.storage.option(k, f) }
        aspect = resolveAspect()
        accentKey = deps.storage.option("accent", "orange")
        val r = req
        val playing = playingChannel
        if (live && !recover && playing != null) {
            val cur = channels[index].id
            if (curChannelId != null && curChannelId != cur) prevChannelId = curChannelId
            curChannelId = cur
        }
        scope.launch {
            val url: String? = try {
                when (r.kind) {
                    PlayRequest.Kind.LIVE -> withContext(Dispatchers.IO) { deps.resolveLiveUrl(r.portalId, playing!!) }
                    PlayRequest.Kind.CATCHUP -> r.url ?: r.catchup?.let { cu ->
                        withContext(Dispatchers.IO) { deps.catchupUrl(r.portalId, cu.channel, cu.entry) }
                    }
                    else -> r.url
                }
            } catch (e: Exception) {
                if (gen != openGen) return@launch
                failure(FailureKind.error, Redactor.redact(e.message ?: e.javaClass.simpleName))
                return@launch
            }
            if (gen != openGen) return@launch
            if (url == null) {
                buffering = false; status = null
                error = str(CR.string.replayNotAvailable)
                return@launch
            }
            if (!UrlPolicy.isStream(url)) {
                buffering = false; status = null
                error = str(CR.string.streamAddressWas)
                return@launch
            }
            val portal = deps.portal(r.portalId)
            val headerChannel = if (live) playing else r.catchup?.channel
            val (clean, headers) = PlayerHeaders.forStream(portal, headerChannel, url)
            if (hosts == null || hostsFor != clean) {
                hosts = HostCandidates(portal, clean)
                hostsFor = clean
            }
            var start = 0L
            var resumed: Long? = null
            if (!live) {
                val v = vodResumeAtMs
                start = when {
                    recover && v != null -> v
                    r.startPositionMs > 0 && !recover -> r.startPositionMs
                    !recover && r.resumeKey != null -> resumeTargetMs(deps.storage.resume(r.resumeKey))?.also { resumed = it } ?: 0
                    else -> 0
                }
            }
            if (stopped) return@launch
            engine.open(StreamSpec(hosts!!.current, headers, live, start), config())
            if (!recover) engine.clearTrackOverrides(preferredAudioLang())
            if (live && !recover && playing != null) {
                deps.onChannelStarted(r.portalId, channels[index])
            }
            resumed?.let { showToast(str(CR.string.resumedAt, de.jasonstream.playback.logic.fmtClock(it)), Icons.history) }
            opening = false
            if (recover) return@launch
            grabFocus()
            if (!quiet) showOverlay()
        }
    }

    private fun preferredAudioLang(): String? =
        deps.storage.option("alang", "auto").takeIf { it != "auto" && it != "off" }

    private fun playOrderFor(c: Channel): List<Channel> {
        val g = deps.variantIndex().groupOf(c.id) ?: return listOf(c)
        return g.playOrder(deps.variantChoices(req.portalId)[g.key])
    }

    // =====================================================================
    // Engine-Rückmeldungen
    // =====================================================================
    override fun onError(message: String) {
        if (error != null || retryJob != null) return
        if (userPaused) {
            errorWhilePaused = true // zeigt sich beim Weiterspielen
            return
        }
        failure(FailureKind.error, message)
    }

    override fun onEnded() {
        if (live) {
            if (error == null && retryJob == null) failure(FailureKind.stall, "eof")
            return
        }
        if (replay) {
            scope.launch { replayStep(1, endOfShow = true) }
            return
        }
        handleNextUp(if (req.nextUp != null) nextUpState.onCompleted() else NextUpState.Action.Exit)
    }

    override fun onFrameRate(fps: Float) {
        if (!deps.storage.flag("afr")) return
        if (Math.abs(fps - afrFps) < 0.01f) return
        afrFps = fps
        Afr.apply(activity, fps.toDouble())
    }

    override fun onTracksChanged() {
        applyPreferredTracks()
    }

    private fun applyPreferredTracks() {
        if (userPickedTracks) return
        val audio = engine.tracks(MC.TRACK_TYPE_AUDIO)
        val ai = pickTrack(audio.map { it.info }, deps.storage.option("alang", "auto"))
        if (ai != null && ai >= 0 && !audio[ai].selected) engine.select(MC.TRACK_TYPE_AUDIO, audio[ai])
        val subs = engine.tracks(MC.TRACK_TYPE_TEXT)
        val si = pickTrack(subs.map { it.info }, deps.storage.option("slang", "auto"), allowOff = true)
        if (si == -1) {
            if (!engine.isTypeDisabled(MC.TRACK_TYPE_TEXT)) engine.select(MC.TRACK_TYPE_TEXT, null)
        } else if (si != null && !subs[si].selected) {
            engine.select(MC.TRACK_TYPE_TEXT, subs[si])
        }
    }

    // =====================================================================
    // Wiederverbinden
    // =====================================================================
    private fun showStatus(text: String?) {
        status = text
        if (text != null) {
            error = null
            buffering = true
        }
    }

    private fun schedule(delayMs: Long, f: () -> Unit) {
        retryJob?.cancel()
        val gen = openGen
        retryJob = scope.launch {
            delay(delayMs)
            retryJob = null
            if (gen != openGen) return@launch
            f()
        }
    }

    /** Störung: still neu verbinden, Server/Variante wechseln, FFmpeg – erst dann Fehlermeldung. */
    fun failure(kind: FailureKind, msg: String?) {
        stall.reset()
        val p = engine.player
        if (!live && p != null) {
            val pos = maxOf(p.currentPosition, lastPos)
            if (pos > 1000) vodResumeAtMs = pos
        }
        val left = if (live && variants.isNotEmpty()) variants.size - 1 - variantPos else 0
        val step = recon.onFailure(kind, if (msg == "eof") null else msg, live, left, hosts?.left ?: 0)
        when (step.kind) {
            RecoveryKind.retry -> {
                showStatus(str(CR.string.reconnecting))
                schedule(step.delayMs) { open(recover = true) }
            }
            RecoveryKind.nextHost -> {
                hosts?.next()
                showStatus(str(CR.string.reconnecting))
                schedule(400) { open(recover = true) }
            }
            RecoveryKind.nextVariant -> {
                variantPos++
                hosts = null
                showStatus(str(CR.string.switchingTo, variants[variantPos].name))
                schedule(400) { open(recover = true) }
            }
            RecoveryKind.softwareDecode -> {
                showStatus(str(CR.string.tryingSoftwareDecode))
                preferSoftware = true
                schedule(400) { open(recover = true) }
            }
            RecoveryKind.giveUp -> {
                retryJob?.cancel(); retryJob = null
                status = null
                error = if (msg == null || msg == "eof") str(CR.string.connectionLost) else msg
                buffering = false
                if (msg != null && StreamError.isLocationRelated(msg)) {
                    playingChannel?.let { deps.setUnavailable(req.portalId, channels[index], true) }
                }
                engine.stop()
            }
        }
    }

    /** „Erneut versuchen“. */
    fun retry() {
        open()
    }

    /** Sekündlich: Hänger erkennen, gute Wiedergabe vermerken, Fortschritt, Zeitversatz. */
    private fun watch() {
        val now = System.currentTimeMillis()
        clock = now
        sleepTick(now)
        val p = engine.player ?: return
        val pos = p.currentPosition
        positionMs = pos
        durationMs = p.duration.takeIf { it != MC.TIME_UNSET } ?: 0
        if (pos > lastPos) {
            recon.markGood(now)
            if (status != null && retryJob == null) showStatus(null)
            if (!hostMarked && hasVideo) {
                hostMarked = true
                hosts?.markWorking()
                if (live) playingChannel?.let { deps.setUnavailable(req.portalId, channels[index], false) }
            }
        }
        lastPos = pos
        val waiting = error != null || retryJob != null
        if (stall.sample(pos, now, active = !waiting && p.playWhenReady && !userPaused)) {
            failure(FailureKind.stall, null)
            return
        }
        if (live) syncTimeshift(p, now)
        if (!live && !replay && req.nextUp != null) handleNextUp(nextUpState.onPosition(pos, durationMs))
        if (now - lastSaveMs >= 10_000) {
            lastSaveMs = now
            savePosition()
        }
    }

    /** Zustand vom Player übernehmen (Ereignisse). */
    fun onPlayerEvent() {
        val p = engine.player ?: return
        buffering = p.playbackState == Player.STATE_BUFFERING || (p.playbackState == Player.STATE_IDLE && error == null)
        val v = p.videoSize
        val has = v.width > 0 || (p.playbackState == Player.STATE_READY && p.videoFormat == null && p.audioFormat != null)
        if (has != hasVideo) hasVideo = has
        durationMs = p.duration.takeIf { it != MC.TIME_UNSET } ?: 0
        positionMs = p.currentPosition
    }

    fun savePosition() {
        val p = engine.player ?: return
        val key = req.resumeKey ?: return
        val pos = p.currentPosition / 1000
        val total = (p.duration.takeIf { it != MC.TIME_UNSET } ?: 0) / 1000
        if (!canSaveResume(live, opening, pos, total)) return
        deps.storage.setResume(key, pos.toInt(), total.toInt())
        deps.onResumeSaved(key)
    }

    // =====================================================================
    // Bedienelemente, Leiste, Hinweise
    // =====================================================================
    fun grabFocus() {
        runCatching { rootFocus.requestFocus() }
    }

    fun showOverlay() {
        barJob?.cancel()
        overlay = true
        barVisible = false
        hideJob?.cancel()
        hideJob = scope.launch {
            delay(5000)
            if (sheet == null) {
                overlay = false
                grabFocus()
            }
        }
    }

    fun hideOverlay() {
        hideJob?.cancel()
        overlay = false
        grabFocus()
    }

    fun toggleOverlay() = if (overlay) hideOverlay() else showOverlay()

    fun showToast(text: String, icon: ImageVector? = null) {
        toastJob?.cancel()
        toast = text
        toastIcon = icon
        toastJob = scope.launch {
            delay(1600)
            toast = null
        }
    }

    val barChannel: Channel? get() = if (barVisible && live && channels.isNotEmpty()) channels[wrapIndex(barIndex, channels.size)] else null
    val barPreview: Boolean get() = zapBar.isPreview(index, channels.size)

    fun showBar(at: Int? = null) {
        if (!live || channels.isEmpty()) return
        barJob?.cancel()
        hideJob?.cancel()
        zapBar.show(at ?: index, channels.size)
        barVisible = true
        barIndex = zapBar.index
        overlay = false
        deps.wantEpg(channels[barIndex])
        barJob = scope.launch {
            delay(4000)
            hideBar()
        }
    }

    fun hideBar() {
        barJob?.cancel()
        zapBar.hide(index)
        barVisible = false
        barIndex = index
    }

    fun browse(dir: Int) {
        zapBar.browse(dir, pendingZap ?: index, channels.size)
        showBar(zapBar.index)
    }

    fun confirmBar() {
        val t = zapBar.confirm(index, channels.size)
        if (t != null) zapTo(t, bar = true) else {
            hideBar()
            showOverlay()
        }
    }

    // =====================================================================
    // Zappen
    // =====================================================================
    /**
     * Ziel des letzten Umschaltens, solange es noch nicht übernommen ist –
     * schnelle Drücke (auch gestaut im selben Bild) bauen darauf auf, statt
     * mehrmals vom alten Sender aus denselben Nachbarn zu wählen.
     */
    private var pendingZap: Int? = null

    /** Zuletzt fokussierter Knopf der Kopfzeile (bleibt über Ein-/Ausblenden erhalten). */
    var topIndex = 0
    /** Nach dem Schließen einer Auswahl den Fokus auf den öffnenden Knopf zurück. */
    var refocusTop = false

    /** Auswahl aus der Kopfzeile öffnen (danach Fokus zurück auf den Knopf). */
    fun openSheet(s: Sheet) {
        refocusTop = true
        sheet = s
    }

    /** Gehaltene ▲▼: Leiste blättert, Umschalten erst beim Loslassen. */
    var holdBrowsing = false

    /** Einen Sender weiter (+1) bzw. zurück (−1), vom zuletzt gewählten Ziel aus. */
    fun zapStep(dir: Int, bar: Boolean) = zapTo((pendingZap ?: index) + dir, bar = bar)

    fun zapTo(i: Int, bar: Boolean = false, list: List<Channel>? = null) {
        val chs = list ?: channels
        if (chs.isEmpty()) return
        val wi = wrapIndex(i, chs.size)
        val target = chs[wi]
        pendingZap = if (list == null) wi else null
        scope.launch {
            if (deps.isLocked(req.portalId, target) && !deps.confirmPin(target)) {
                if (pendingZap == wi) pendingZap = null
                return@launch
            }
            if (pendingZap == wi) pendingZap = null
            savePosition()
            req = PlayRequest.live(req.portalId, chs, chs.indexOf(target))
            resetNextUp()
            publish()
            if (bar) {
                overlay = false
                showBar()
            }
            open(quiet = bar)
        }
    }

    fun zapBack() {
        val id = prevChannelId
        val i = if (id == null) -1 else channels.indexOfFirst { it.id == id }
        if (i < 0) {
            showToast(str(CR.string.noPreviousChannel))
            return
        }
        zapTo(i)
    }

    fun digit(d: Int) {
        digitJob?.cancel()
        digits = digitEntry.push(d)
        digitJob = scope.launch {
            delay(DigitEntry.TIMEOUT_MS)
            commitDigits()
        }
    }

    fun commitDigits() {
        digitJob?.cancel()
        val bar = !overlay
        val pid = req.portalId
        val r = digitEntry.commit(channels, deps.allChannels(pid), deps.rawChannels(pid), deps.variantIndex())
        digits = ""
        when (r) {
            is DigitResult.InList -> if (r.index != index) zapTo(r.index, bar = bar) else if (bar) showBar()
            is DigitResult.InOther -> zapTo(r.index, bar = bar, list = r.list)
            is DigitResult.NotFound -> showToast(str(CR.string.channelNumberNotFound, r.number), Icons.dialpad)
            DigitResult.Empty -> Unit
        }
    }

    // =====================================================================
    // Farbtasten / Aktionen
    // =====================================================================
    /** Sender für Aufnahme/Favorit: der in der Leiste gezeigte, sonst der laufende. */
    val actionChannel: Channel?
        get() = if (!live || channels.isEmpty()) null else channels[if (barVisible) wrapIndex(barIndex, channels.size) else index]

    fun nowOf(c: Channel?, at: Long = clock): EpgEntry? {
        if (c == null) return null
        epgRev // gelesen → Neuzeichnen, wenn das EPG kommt
        val list = deps.epgOf(c)
        var lo = 0
        var hi = list.size - 1
        var found = -1
        while (lo <= hi) {
            val mid = (lo + hi) ushr 1
            if (list[mid].startMs <= at) { found = mid; lo = mid + 1 } else hi = mid - 1
        }
        if (found < 0) return null
        return list[found].takeIf { it.isNowAt(at) }
    }

    fun nextOf(c: Channel?, cur: EpgEntry?): EpgEntry? {
        if (c == null || cur == null) return null
        val list = deps.epgOf(c)
        val i = list.indexOf(cur)
        return if (i >= 0 && i + 1 < list.size) list[i + 1] else null
    }

    fun record(c: Channel? = actionChannel) {
        val ch = c ?: return
        val msg = deps.onRecord(req.portalId, ch, nowOf(ch)) ?: str(R.string.pl_record_soon)
        showToast(msg, Icons.record)
    }

    fun isFavorite(c: Channel): Boolean {
        favRevision // gelesen → Neuzeichnen nach Umschalten
        return deps.isFavorite(req.portalId, c)
    }

    fun toggleFavorite(c: Channel? = actionChannel) {
        val ch = c ?: return
        val was = deps.isFavorite(req.portalId, ch)
        if (!deps.toggleFavorite(req.portalId, ch)) {
            showToast(str(CR.string.guestOnHint), Icons.person)
            return
        }
        favRevision++
        showToast(
            if (was) str(CR.string.favouriteRemovedNamed, ch.name) else str(CR.string.favouriteAddedNamed, ch.name),
            if (was) Icons.starBorder else Icons.star,
        )
    }

    fun canStartOver(): Boolean {
        val c = if (live) channels.getOrNull(index) else null
        return c != null && c.hasCatchup && nowOf(c) != null
    }

    /** Gelb: laufende Sendung von Anfang (Catch-up), sonst Hinweis. */
    fun startOverKey() {
        if (!live || channels.isEmpty()) return
        if (barVisible) hideBar()
        if (canStartOver()) {
            showToast(str(CR.string.fromStart), Icons.replay)
            restartShow()
        } else {
            showToast(str(CR.string.startOverUnavailable), Icons.replay)
        }
    }

    private val replayChannel: Channel? get() = req.catchup?.channel ?: channels.getOrNull(index)

    fun restartShow() {
        val c = replayChannel ?: return
        if (!c.hasCatchup) return
        val now = nowOf(c) ?: return
        startReplay(c, now)
    }

    private fun startReplay(c: Channel, e: EpgEntry) {
        savePosition()
        scope.launch {
            val url = withContext(Dispatchers.IO) { runCatching { deps.catchupUrl(req.portalId, c, e) }.getOrNull() }
            if (url == null) {
                showToast(str(CR.string.replayNotAvailable), Icons.replay)
                return@launch
            }
            req = PlayRequest.catchup(req.portalId, c, e, channels, url)
            publish()
            open()
        }
    }

    /** Vorherige (−1) oder nächste (+1) Sendung im Replay. */
    suspend fun replayStep(dir: Int, endOfShow: Boolean = false) {
        val c = replayChannel ?: return
        val cur = req.catchup?.entry ?: return
        val list = withContext(Dispatchers.IO) { runCatching { deps.channelEpg(c) }.getOrDefault(emptyList()) }
        val i = list.indexOfFirst { it.startMs == cur.startMs }
        val j = i + dir
        val now = System.currentTimeMillis()
        val limit = now - c.catchupDays * 86_400_000L
        if (i < 0 || j < 0 || j >= list.size) {
            if (dir > 0) goLive()
            return
        }
        val target = list[j]
        if (target.startMs > now) {
            goLive()
            return
        }
        if (target.startMs < limit) {
            if (!endOfShow) showToast(str(CR.string.olderProgrammesNo))
            return
        }
        startReplay(c, target)
    }

    fun replayStepAsync(dir: Int) {
        scope.launch { replayStep(dir) }
    }

    /** Film/Folge/Replay: relativ spulen. */
    fun seekBy(deltaMs: Long) {
        val p = engine.player ?: return
        val d = p.duration.takeIf { it != MC.TIME_UNSET && it > 0 }
        var t = (p.currentPosition + deltaMs).coerceAtLeast(0)
        if (d != null) t = t.coerceAtMost(d)
        p.seekTo(t)
        positionMs = t
        stall.reset()
    }

    fun goLive() {
        val c = replayChannel ?: return
        savePosition()
        val list = channels.ifEmpty { listOf(c) }
        req = PlayRequest.live(req.portalId, list, list.indexOfFirst { it.id == c.id }.coerceAtLeast(0))
        publish()
        open()
    }

    // =====================================================================
    // Live-Pause (Timeshift)
    // =====================================================================
    val timeshiftEnabled: Boolean get() = live && ts.enabled
    fun shifted(now: Long = clock): Boolean = live && ts.isShifted(now)
    fun behindMs(now: Long = clock): Long = ts.behind(now)

    fun togglePause() {
        val p = engine.player ?: return
        val now = System.currentTimeMillis()
        if (p.playWhenReady && !userPaused) {
            p.pause()
            userPaused = true
            if (live) ts.pause(now)
        } else {
            userPaused = false
            stall.reset()
            if (errorWhilePaused || p.playbackState == Player.STATE_IDLE) {
                errorWhilePaused = false
                open(quiet = true, recover = !live)
                return
            }
            if (live && ts.overflowed(now)) {
                goLiveEdge()
                return
            }
            p.play()
            if (live) ts.resume(now)
        }
        clock = now
    }

    /** ◀▶ im Zeitversatz: im DVR-Fenster spulen (nicht über Live hinaus). */
    fun seekShift(deltaMs: Long) {
        val p = engine.player ?: return
        if (!ts.seekable) return
        val now = System.currentTimeMillis()
        val eff = ts.seek(deltaMs, now)
        if (eff != 0L) p.seekTo((p.currentPosition + eff).coerceAtLeast(0))
        if (!ts.isShifted(now)) ts.goLive()
        stall.reset()
        clock = now
    }

    fun goLiveEdge() {
        val p = engine.player
        ts.goLive()
        userPaused = false
        stall.reset()
        if (p != null && ts.seekable && p.playbackState != Player.STATE_IDLE) {
            p.seekToDefaultPosition()
            p.play()
        } else {
            open(quiet = true)
        }
        showToast(str(CR.string.liveShort), Icons.circle)
    }

    private fun syncTimeshift(p: Player, now: Long) {
        // HLS mit DVR-Fenster: echtes Spulen möglich.
        val dvr = p.isCurrentMediaItemDynamic && p.isCurrentMediaItemSeekable && p.duration != MC.TIME_UNSET && p.duration > 30_000
        if (dvr && !ts.seekable) {
            ts.seekable = true
            ts.windowMs = p.duration
        }
        if (!ts.seekable || ts.paused) return
        val gap = p.duration - p.currentPosition
        if (liveGapMs == null && hasVideo) liveGapMs = gap
        val base = liveGapMs ?: return
        val behind = gap - base
        if (behind < 3000) ts.goLive() else ts.sync(behind, now)
    }

    // =====================================================================
    // Varianten, Spuren, Bildformat, Schlaf-Timer
    // =====================================================================
    val variantLabel: String?
        get() {
            if (variants.size < 2) return null
            val c = playingChannel ?: return null
            val l = deps.variantIndex().groupOf(c.id)?.labelOf(c)
            if (l == null || l == c.name) return str(CR.string.sourceOf, variantPos + 1, variants.size)
            return l
        }

    val playingVariantId: String? get() = playingChannel?.id

    fun pickVariant(c: Channel) {
        sheet = null
        grabFocus()
        deps.chooseVariant(req.portalId, c)
        if (c.id == playingChannel?.id) return
        open(quiet = true)
        showToast(str(CR.string.sourceIs, c.name), Icons.layers)
    }

    fun audioTracks(): List<TrackOption> = engine.tracks(MC.TRACK_TYPE_AUDIO)
    fun subtitleTracks(): List<TrackOption> = engine.tracks(MC.TRACK_TYPE_TEXT)
    fun subtitlesOff(): Boolean = engine.isTypeDisabled(MC.TRACK_TYPE_TEXT) || subtitleTracks().none { it.selected }

    fun selectTrack(type: Int, t: TrackOption?) {
        userPickedTracks = true
        engine.select(type, t)
        sheet = null
        grabFocus()
    }

    private fun aspectChannel(): Channel? = if (live) channels.getOrNull(index) else req.catchup?.channel

    private fun resolveAspect(): AspectMode {
        val c = aspectChannel()
        if (c != null) deps.storage.channelAspectId(req.portalId, c.id)?.let { return AspectMode.fromId(it) }
        return AspectMode.fromId(deps.storage.defaultAspectId())
    }

    val aspectRememberLabel: String? get() = aspectChannel()?.let { str(CR.string.rememberForChannel, it.name) }

    fun applyAspect(m: AspectMode, remember: Boolean) {
        aspect = m
        sheet = null
        grabFocus()
        showToast(str(CR.string.aspectRatioToast, aspectLabel(m)), Icons.aspect)
        val c = aspectChannel()
        if (remember && c != null) deps.storage.setChannelAspectId(req.portalId, c.id, m.id)
    }

    fun cycleAspect() = applyAspect(aspect.next, remember = aspectChannel() != null)

    fun aspectLabel(m: AspectMode): String = when (m) {
        AspectMode.original -> str(CR.string.original)
        AspectMode.fill -> str(CR.string.fill)
        AspectMode.stretch -> str(CR.string.stretch)
        AspectMode.r16x9 -> "16:9"
        AspectMode.r4x3 -> "4:3"
        AspectMode.cinema -> str(CR.string.aspectCinema)
        AspectMode.zoom -> str(CR.string.aspectZoom115)
    }

    fun aspectHint(m: AspectMode): String = when (m) {
        AspectMode.original -> str(CR.string.undistortedBordersIf)
        AspectMode.fill -> str(CR.string.fullScreenEdges)
        AspectMode.stretch -> str(CR.string.fullScreenPicture)
        AspectMode.r16x9 -> str(CR.string.forceWidescreen)
        AspectMode.r4x3 -> str(CR.string.olderChannelsShows)
        AspectMode.cinema -> str(CR.string.removesBlackBars)
        AspectMode.zoom -> str(CR.string.slightlyEnlargedE)
    }

    fun setSleep(minutes: Int) {
        sleepJob?.cancel()
        sheet = null
        grabFocus()
        sleepWarning = false
        if (minutes <= 0) {
            sleepAtMs = null
            showToast(str(CR.string.sleepTimerOff), Icons.bedtime)
            return
        }
        sleepAtMs = System.currentTimeMillis() + minutes * 60_000L
        showToast(str(CR.string.sleepTimerMinutes, minutes), Icons.bedtime)
    }

    private fun sleepTick(now: Long) {
        val at = sleepAtMs ?: return
        if (!sleepWarning && now >= at - 60_000) sleepWarning = true
        if (now >= at) {
            sleepAtMs = null
            sleepWarning = false
            engine.player?.pause()
            onExit()
        }
    }

    // =====================================================================
    // Nächste Folge
    // =====================================================================
    private fun resetNextUp() {
        nextUpJob?.cancel()
        nextUpShowing = false
        nextUpData = null
        nextUpState = NextUpState { deps.storage.flag("autonext", fallback = true) }
    }

    private var nextUpState: NextUpState = NextUpState { deps.storage.flag("autonext", fallback = true) }

    private fun handleNextUp(a: NextUpState.Action) {
        when (a) {
            NextUpState.Action.None -> Unit
            NextUpState.Action.Exit -> onExit()
            NextUpState.Action.Resolve -> {
                val f = req.nextUp ?: return handleNextUp(nextUpState.onResolved(false))
                nextUpJob?.cancel()
                nextUpJob = scope.launch {
                    val n = runCatching { f() }.getOrNull()
                    nextUpData = n
                    handleNextUp(nextUpState.onResolved(n != null))
                    if (nextUpState.showing) {
                        nextUpShowing = true
                        nextUpSeconds = nextUpState.secondsLeft
                        while (isActive && nextUpState.showing) {
                            delay(1000)
                            val act = nextUpState.tick()
                            nextUpSeconds = nextUpState.secondsLeft
                            if (act != NextUpState.Action.None) {
                                handleNextUp(act)
                                break
                            }
                        }
                    }
                }
            }
            NextUpState.Action.Play -> {
                nextUpShowing = false
                val n = nextUpData ?: return
                req.resumeKey?.let { deps.storage.setWatched(it) }
                n.onStart?.invoke()
                req = n.request
                nextUpJob?.cancel()
                nextUpData = null
                nextUpState = NextUpState { deps.storage.flag("autonext", fallback = true) }
                publish()
                grabFocus()
                open()
            }
        }
    }

    fun nextUpPlay() = handleNextUp(nextUpState.commit())
    fun nextUpCancel() {
        nextUpShowing = false
        grabFocus()
        handleNextUp(nextUpState.cancel())
    }

    // =====================================================================
    // Diagnose
    // =====================================================================
    fun toggleDebug() {
        debug = !debug
        deps.storage.setFlag("playerdebug", debug)
    }

    /** Zurück-Taste. */
    fun onBack() {
        when {
            sheet != null -> { sheet = null; grabFocus() }
            nextUpShowing -> nextUpCancel()
            barVisible -> hideBar()
            else -> onExit()
        }
    }

    companion object {
        /** Gleiches Ziel (die App reicht unsere gemeldete Anfrage evtl. leicht verändert zurück). */
        fun sameTarget(a: PlayRequest, b: PlayRequest): Boolean {
            if (a === b) return true
            if (a.kind != b.kind || a.portalId != b.portalId) return false
            return when (a.kind) {
                PlayRequest.Kind.LIVE -> a.channel?.id == b.channel?.id && a.channels.size == b.channels.size &&
                    (a.channels === b.channels || a.channels.map { it.id } == b.channels.map { it.id })
                PlayRequest.Kind.CATCHUP -> a.catchup?.channel?.id == b.catchup?.channel?.id &&
                    a.catchup?.entry?.startMs == b.catchup?.entry?.startMs
                else -> a.url == b.url && a.resumeKey == b.resumeKey && a.startPositionMs == b.startPositionMs
            }
        }

        fun localized(ctx: Context, lang: String): Context {
            val code = when (lang) {
                "de", "en", "tr" -> lang
                else -> return ctx
            }
            val conf = Configuration(ctx.resources.configuration)
            conf.setLocale(Locale.forLanguageTag(code))
            return ctx.createConfigurationContext(conf)
        }
    }
}
