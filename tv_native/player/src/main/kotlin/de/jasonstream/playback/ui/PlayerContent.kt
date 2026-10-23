package de.jasonstream.playback.ui

import de.jasonstream.playback.nav.keyGate
import android.graphics.Color as AColor
import android.view.Gravity
import android.view.KeyEvent as AKey
import android.view.SurfaceView
import android.widget.FrameLayout
import androidx.activity.compose.BackHandler
import androidx.annotation.OptIn
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.key.KeyEvent
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.onKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.res.ResourcesCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.media3.common.util.UnstableApi
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.CaptionStyleCompat
import androidx.media3.ui.SubtitleView
import de.jasonstream.core.ui.AppPalette
import de.jasonstream.playback.api.PlayRequest
import de.jasonstream.playback.api.PlayerDeps
import de.jasonstream.playback.engine.PlayerEngine
import de.jasonstream.playback.logic.AspectMode
import de.jasonstream.playback.logic.SubtitleStyle
import de.jasonstream.playback.logic.fmtBehind
import kotlinx.coroutines.delay

@OptIn(UnstableApi::class)
@Composable
internal fun PlayerContent(
    request: PlayRequest,
    deps: PlayerDeps,
    onExit: () -> Unit,
    onOpenGuide: () -> Unit,
    onOpenChannelList: () -> Unit,
    modifier: Modifier,
    engine: PlayerEngine?,
    onRequestChanged: ((PlayRequest) -> Unit)?,
    keepPlayingOnExit: Boolean = false,
) {
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    val eng = remember(engine) { engine ?: PlayerEngine(ctx) }
    val c = remember(eng, deps) { PlayerController(ctx, deps, eng, scope, request) }
    c.onExit = onExit
    c.onOpenGuide = onOpenGuide
    c.onOpenChannelList = onOpenChannelList
    c.onRequestChanged = onRequestChanged

    LaunchedEffect(request) {
        c.setRequest(request)
        c.grabFocus()
    }
    LaunchedEffect(eng) { eng.revision.collect { c.onPlayerEvent() } }
    LaunchedEffect(deps) { deps.epgRevision.collect { c.epgRev = it } }

    val owner = LocalLifecycleOwner.current
    DisposableEffect(owner, c) {
        val obs = LifecycleEventObserver { _, e ->
            when (e) {
                Lifecycle.Event.ON_START -> c.start()
                Lifecycle.Event.ON_STOP -> c.stop()
                else -> Unit
            }
        }
        owner.lifecycle.addObserver(obs)
        onDispose {
            owner.lifecycle.removeObserver(obs)
            c.dispose()
            c.savePosition()
            if (engine == null) eng.release() else if (!keepPlayingOnExit) eng.stop()
        }
    }

    BackHandler { c.onBack() }

    val accent = Color(AppPalette.accent(c.accentKey))
    var rootFocused by remember { mutableStateOf(false) }
    var overlayFocused by remember { mutableStateOf(false) }
    var infoLong by remember { mutableStateOf(false) }

    fun handleKey(e: KeyEvent): Boolean {
        // Gehaltene ▲▼/CH± losgelassen: auf den in der Leiste gezeigten Sender umschalten.
        if (e.type == KeyEventType.KeyUp && c.holdBrowsing && isZapKey(e.nativeKeyEvent.keyCode)) {
            c.holdBrowsing = false
            c.confirmBar()
            return true
        }
        if (e.type != KeyEventType.KeyDown) return false
        if (c.sheet != null) return false
        val k = e.nativeKeyEvent.keyCode
        val repeat = e.nativeKeyEvent.repeatCount
        if (c.nextUpShowing) return k == AKey.KEYCODE_DPAD_UP || k == AKey.KEYCODE_DPAD_DOWN
        return onKey(c, k, repeat, rootFocused, overlayFocused, infoLong) { infoLong = it }
    }

    LaunchedEffect(c.sheet, c.error, c.nextUpShowing) {
        if (c.sheet == null && c.error == null && !c.nextUpShowing) {
            // Leiste inzwischen ausgeblendet → beim nächsten Einblenden nicht auf den alten Knopf.
            if (!c.overlay) c.refocusTop = false
            c.grabFocus()
            if (c.overlay) c.showOverlay() // Ausblend-Zeit neu starten
        }
    }

    Box(
        modifier
            .fillMaxSize()
            .background(Color.Black)
            // Tasten-Tor: gehaltene Pfeil-/Kanaltasten gedrosselt (auch ohne App-Hülle).
            .keyGate()
            .focusRequester(c.rootFocus)
            .onFocusChanged { rootFocused = it.isFocused }
            .onKeyEvent(::handleKey)
            .focusable(),
    ) {
        VideoSurface(c, eng)
        SubtitleLayer(eng, c.subStyle)

        // Grafik mit Senderlogo, bis das erste Bild da ist
        AnimatedVisibility(!c.hasVideo, enter = fadeIn(), exit = fadeOut()) { LoadingArt(c) }

        if (c.debug) DebugLayer(eng)

        if (c.buffering && c.error == null) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { Spinner(accent, 44.dp, 3.dp) }
        }
        c.error?.let { ErrorBox(c, it, accent) }

        AnimatedVisibility(c.overlay && c.sheet == null, enter = fadeIn(), exit = fadeOut()) {
            Box(Modifier.fillMaxSize().onFocusChanged { overlayFocused = it.hasFocus }) {
                val ch = if (c.live) c.channels.getOrNull(c.index) else null
                if (ch != null) LiveOverlay(c, ch, accent) else if (!c.live) VodOverlay(c, accent)
            }
        }

        c.barChannel?.let { ZapBar(c, it, accent) }

        val status = c.status
        if (status != null && c.error == null) {
            Box(
                Modifier.fillMaxSize().padding(top = if (c.overlay) 104.dp else 0.dp, bottom = if (c.overlay) 0.dp else 48.dp),
                contentAlignment = if (c.overlay) Alignment.TopCenter else Alignment.BottomCenter,
            ) { StatusPill(status, accent, busy = true) }
        }
        if (c.shifted() && !c.overlay && c.error == null) {
            Box(Modifier.fillMaxSize().padding(top = 32.dp, start = 40.dp)) {
                StatusPill(
                    c.str(de.jasonstream.core.R.string.timeshifted, fmtBehind(c.behindMs())), accent,
                    icon = if (c.userPaused) Icons.pause else Icons.history,
                )
            }
        }
        if (c.sleepWarning && c.sleepAtMs != null) SleepWarning(c, accent)
        c.toast?.let { ToastView(it, c.toastIcon, accent) }
        if (c.digits.isNotEmpty()) {
            Box(Modifier.fillMaxSize().padding(top = 32.dp, end = 40.dp), contentAlignment = Alignment.TopEnd) {
                DigitsBox(c.digits, accent)
            }
        }
        if (c.nextUpShowing) NextEpisodeCard(c, accent)
        c.sheet?.let { SheetFor(c, it, accent) }
    }
}

private fun isZapKey(k: Int) = k == AKey.KEYCODE_DPAD_UP || k == AKey.KEYCODE_DPAD_DOWN ||
    k == AKey.KEYCODE_CHANNEL_UP || k == AKey.KEYCODE_CHANNEL_DOWN

/** Tasten der Fernbedienung (Port von _onKey). true = verbraucht. */
private fun onKey(
    c: PlayerController,
    k: Int,
    repeat: Int,
    rootFocused: Boolean,
    overlayFocused: Boolean,
    infoLong: Boolean,
    setInfoLong: (Boolean) -> Unit,
): Boolean {
    val live = c.live
    val up = k == AKey.KEYCODE_DPAD_UP
    val down = k == AKey.KEYCODE_DPAD_DOWN
    val left = k == AKey.KEYCODE_DPAD_LEFT
    val right = k == AKey.KEYCODE_DPAD_RIGHT
    val arrow = up || down || left || right
    val ok = k == AKey.KEYCODE_DPAD_CENTER || k == AKey.KEYCODE_ENTER || k == AKey.KEYCODE_NUMPAD_ENTER
    val onControl = !rootFocused
    val playing = c.engine.player?.let { it.playWhenReady && !c.userPaused } ?: false

    // Schlaf-Timer-Warnung: OK = weiterschauen.
    if (c.sleepWarning && ok) { c.setSleep(0); return true }
    // Direktwahl läuft: OK bestätigt sofort.
    if (live && ok && c.digits.isNotEmpty()) { c.commitDigits(); return true }
    // Zapping-Leiste: ◀▶ blättern, OK schaltet um (Zurück: BackHandler).
    if (live && c.barVisible) {
        if (left || right) { c.browse(if (left) -1 else 1); return true }
        if (ok) { c.confirmBar(); return true }
    }
    // Farbtasten (live).
    if (live) {
        when (k) {
            AKey.KEYCODE_PROG_RED -> { c.record(); return true }
            AKey.KEYCODE_PROG_GREEN -> { c.toggleFavorite(); return true }
            AKey.KEYCODE_PROG_YELLOW -> { c.startOverKey(); return true }
            AKey.KEYCODE_PROG_BLUE, AKey.KEYCODE_GUIDE -> { c.onOpenGuide(); return true }
        }
    }
    // Info lange gedrückt: Diagnose-Anzeige an/aus.
    if (k == AKey.KEYCODE_INFO && repeat > 0) {
        if (!infoLong) { setInfoLong(true); c.toggleDebug() }
        return true
    }
    if (k == AKey.KEYCODE_INFO) setInfoLong(false)
    if (live && k == AKey.KEYCODE_INFO) {
        if (c.barVisible) c.hideBar() else c.showBar()
        return true
    }
    // Sichtbare Bedienelemente: erste Pfeiltaste holt den Fokus hinein.
    if (c.overlay && arrow && !overlayFocused) {
        if (runCatching { c.mainFocus.requestFocus() }.isSuccess) {
            c.showOverlay()
            return true
        }
    }
    // OK auf einem fokussierten Knopf löst ihn aus.
    if (onControl && ok) {
        if (c.overlay) c.showOverlay()
        return false
    }
    val digit = when (k) {
        in AKey.KEYCODE_0..AKey.KEYCODE_9 -> k - AKey.KEYCODE_0
        in AKey.KEYCODE_NUMPAD_0..AKey.KEYCODE_NUMPAD_9 -> k - AKey.KEYCODE_NUMPAD_0
        else -> null
    }
    if (live && digit != null) { c.digit(digit); return true }
    if (live && (k == AKey.KEYCODE_LAST_CHANNEL || k == AKey.KEYCODE_DEL)) { c.zapBack(); return true }
    // Gehalten (Wiederholungen): nur die Leiste blättern (Vorschau), Umschalten beim
    // Loslassen – nicht bei jeder Wiederholung einen Stream öffnen.
    val zapDir = when {
        k == AKey.KEYCODE_CHANNEL_UP || (up && !c.overlay) -> 1
        k == AKey.KEYCODE_CHANNEL_DOWN || (down && !c.overlay) -> -1
        else -> 0
    }
    if (live && zapDir != 0 && repeat > 0 && !c.overlay) {
        c.holdBrowsing = true
        c.browse(zapDir)
        return true
    }
    // ▲▼ / CH± schalten sofort um; ausgeblendet mit Zapping-Leiste. Vom zuletzt
    // gewählten Ziel aus (schnelle Drücke: jeder genau ein Sender).
    if (live && zapDir != 0) { c.zapStep(zapDir, bar = !c.overlay); return true }
    // Zeitversetzt (DVR): ◀▶ spulen im Puffer.
    if (live && !c.overlay && c.shifted() && (left || right) && c.engine.player?.isCurrentMediaItemSeekable == true) {
        c.seekShift(if (left) -10_000 else 10_000); return true
    }
    if (live && left && !c.overlay) { c.onOpenChannelList(); return true }
    if (live && right && !c.overlay) { c.browse(1); return true }
    if (!live && !c.overlay && (left || right)) { c.seekBy(if (left) -10_000 else 10_000); c.showOverlay(); return true }
    if (k == AKey.KEYCODE_TV_ZOOM_MODE || k == AKey.KEYCODE_ZOOM_IN || k == AKey.KEYCODE_Z) { c.cycleAspect(); return true }
    if (k == AKey.KEYCODE_MEDIA_PLAY_PAUSE || k == AKey.KEYCODE_SPACE ||
        (k == AKey.KEYCODE_MEDIA_PAUSE && playing) || (k == AKey.KEYCODE_MEDIA_PLAY && !playing)
    ) { c.togglePause(); c.showOverlay(); return true }
    if (k == AKey.KEYCODE_MEDIA_PAUSE || k == AKey.KEYCODE_MEDIA_PLAY) return true
    if (live && k == AKey.KEYCODE_MEDIA_FAST_FORWARD) { if (c.shifted()) c.goLiveEdge(); return true }
    if (live && c.shifted() && k == AKey.KEYCODE_MEDIA_REWIND) { c.seekShift(-30_000); return true }
    if (k == AKey.KEYCODE_MEDIA_FAST_FORWARD) { c.seekBy(30_000); return true }
    if (live && (k == AKey.KEYCODE_MEDIA_REWIND || k == AKey.KEYCODE_MEDIA_SKIP_BACKWARD || k == AKey.KEYCODE_MEDIA_PREVIOUS)) {
        c.restartShow(); return true
    }
    if (c.replay && (k == AKey.KEYCODE_MEDIA_PREVIOUS || k == AKey.KEYCODE_MEDIA_SKIP_BACKWARD || k == AKey.KEYCODE_CHANNEL_DOWN)) {
        c.replayStepAsync(-1); return true
    }
    if (c.replay && (k == AKey.KEYCODE_MEDIA_NEXT || k == AKey.KEYCODE_MEDIA_SKIP_FORWARD || k == AKey.KEYCODE_CHANNEL_UP)) {
        c.replayStepAsync(1); return true
    }
    if (c.replay && k == AKey.KEYCODE_MEDIA_STOP) { c.goLive(); return true }
    if (k == AKey.KEYCODE_MEDIA_REWIND) { c.seekBy(-30_000); return true }
    if (!c.overlay && (ok || k == AKey.KEYCODE_INFO || up || down)) { c.showOverlay(); return true }
    if (c.overlay) c.showOverlay() // Zeit verlängern bei Bedienung
    return false
}

/** Video: SurfaceView in AspectRatioFrameLayout; Bildformat wie aspect.dart. */
@OptIn(UnstableApi::class)
@Composable
private fun VideoSurface(c: PlayerController, eng: PlayerEngine) {
    val m = c.aspect
    val rev by eng.revision.collectAsState() // Neuzeichnen bei neuer Videogröße
    AndroidView(
        factory = { ctx ->
            FrameLayout(ctx).apply {
                setBackgroundColor(AColor.BLACK)
                val afl = AspectRatioFrameLayout(ctx)
                val sv = SurfaceView(ctx).apply { keepScreenOn = true }
                afl.addView(sv, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
                addView(afl, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT, Gravity.CENTER))
                eng.attachSurface(sv)
                tag = afl
            }
        },
        update = { v ->
            rev.hashCode()
            val afl = v.tag as AspectRatioFrameLayout
            val p = eng.player
            val vs = p?.videoSize
            val natural = if (vs != null && vs.width > 0 && vs.height > 0) vs.width * vs.pixelWidthHeightRatio / vs.height else 16f / 9f
            afl.resizeMode = when (m) {
                AspectMode.fill -> AspectRatioFrameLayout.RESIZE_MODE_ZOOM
                AspectMode.stretch -> AspectRatioFrameLayout.RESIZE_MODE_FILL
                else -> AspectRatioFrameLayout.RESIZE_MODE_FIT
            }
            afl.setAspectRatio(m.ratio ?: natural)
        },
        onRelease = { v -> ((v.tag as? AspectRatioFrameLayout)?.getChildAt(0) as? SurfaceView)?.let { eng.detachSurface(it) } },
        modifier = Modifier.fillMaxSize().graphicsLayer {
            scaleX = m.scale
            scaleY = m.scale
        },
    )
}

/** Untertitel mit Aussehen aus den Einstellungen (CaptionStyleCompat). */
@OptIn(UnstableApi::class)
@Composable
private fun SubtitleLayer(eng: PlayerEngine, s: SubtitleStyle) {
    AndroidView(
        factory = { ctx ->
            SubtitleView(ctx).also { eng.attachSubtitles(it) }
        },
        update = { v ->
            val typeface = runCatching { ResourcesCompat.getFont(v.context, de.jasonstream.core.R.font.inter_semibold) }.getOrNull()
            v.setStyle(
                CaptionStyleCompat(
                    s.colorArgb, s.backArgb, AColor.TRANSPARENT,
                    if (s.outline) CaptionStyleCompat.EDGE_TYPE_OUTLINE else CaptionStyleCompat.EDGE_TYPE_NONE,
                    AColor.BLACK, typeface,
                ),
            )
            v.setApplyEmbeddedStyles(false)
            v.setApplyEmbeddedFontSizes(false)
            v.setFractionalTextSize(s.fraction)
            v.setBottomPaddingFraction(0.08f)
        },
        onRelease = { v -> eng.detachSubtitles(v) },
        modifier = Modifier.fillMaxSize(),
    )
}

@Composable
private fun DebugLayer(eng: PlayerEngine) {
    var lines by remember { mutableStateOf(eng.debugLines()) }
    LaunchedEffect(eng) {
        while (true) {
            lines = eng.debugLines()
            delay(1000)
        }
    }
    Box(Modifier.padding(16.dp)) { DebugPanel(lines) }
}
