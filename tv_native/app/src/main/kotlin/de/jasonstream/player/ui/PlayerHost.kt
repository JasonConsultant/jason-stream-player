package de.jasonstream.player.ui

import android.view.SurfaceView
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.Stable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.foundation.focusable
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.onKeyEvent
import androidx.compose.ui.input.key.type
import de.jasonstream.core.model.Channel
import de.jasonstream.core.model.PortalType
import de.jasonstream.data.net.StreamHeaders
import de.jasonstream.playback.PlayerScreen
import de.jasonstream.playback.api.PlayRequest
import de.jasonstream.playback.api.PlayerDeps
import de.jasonstream.playback.engine.EngineConfig
import de.jasonstream.playback.engine.PlayerEngine
import de.jasonstream.playback.engine.StreamSpec
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Video der App: ein [PlayerEngine] (ein ExoPlayer) für Vollbild-Player
 * (Live TV) und Mini-Video (TV-Guide), damit beim Wechsel nichts neu
 * aufgebaut wird. In Bildschirmfotos/Tests ohne Engine → Platzhalter.
 */
@Stable
class PlayerHost(val engine: PlayerEngine?, val deps: PlayerDeps?, val fake: FakePlayerFocus? = null) {
    /** Vollbild-Player des Moduls :player (Tasten, Leisten, Zappen). */
    @Composable
    fun FullScreen(
        request: PlayRequest,
        onExit: () -> Unit,
        onOpenGuide: () -> Unit,
        onOpenChannelList: () -> Unit,
        onRequestChanged: (PlayRequest) -> Unit,
        modifier: Modifier = Modifier,
    ) {
        val d = deps
        if (d == null) {
            val f = fake
            if (f == null) {
                Box(modifier.fillMaxSize().background(PreviewVideo.brush))
                return
            }
            // Tests: verhält sich beim Fokus wie der echte Player (fokussierbar,
            // holt sich den Fokus bei neuer Anfrage, ◀ = Senderliste, Zurück = onExit).
            androidx.activity.compose.BackHandler { onExit() }
            LaunchedEffect(request) { f.requests++; f.grab() }
            Box(
                modifier.fillMaxSize().background(PreviewVideo.brush)
                    .focusRequester(f.requester)
                    .onKeyEvent { ev ->
                        if (ev.type != KeyEventType.KeyDown) return@onKeyEvent false
                        when (ev.nativeKeyEvent.keyCode) {
                            android.view.KeyEvent.KEYCODE_DPAD_LEFT -> { onOpenChannelList(); true }
                            android.view.KeyEvent.KEYCODE_DPAD_UP, android.view.KeyEvent.KEYCODE_DPAD_DOWN,
                            android.view.KeyEvent.KEYCODE_DPAD_RIGHT, android.view.KeyEvent.KEYCODE_DPAD_CENTER -> { f.keys++; true }
                            else -> false
                        }
                    }
                    .focusable(),
            )
            return
        }
        PlayerScreen(
            request = request, deps = d, onExit = onExit, onOpenGuide = onOpenGuide,
            onOpenChannelList = onOpenChannelList, modifier = modifier, engine = engine,
            onRequestChanged = onRequestChanged,
        )
    }

    /**
     * Kleines Live-Bild (TV-Guide). Läuft der Sender schon in der Engine,
     * wird nur die Ausgabe umgehängt; sonst wird er stumm-frei geöffnet.
     */
    @Composable
    fun Mini(channel: Channel?, portalId: String?, modifier: Modifier = Modifier) {
        val e = engine
        val d = deps
        if (e == null || d == null || channel == null || portalId == null) {
            Box(modifier.background(PreviewVideo.brush))
            return
        }
        LaunchedEffect(channel.id) {
            val spec = e.lastSpec
            val playing = e.player?.let { it.isPlaying || it.playbackState == androidx.media3.common.Player.STATE_BUFFERING } == true
            if (playing && spec != null && spec.url.isNotEmpty() && spec.live && e.lastChannelId == channel.id) return@LaunchedEffect
            val portal = d.portal(portalId) ?: return@LaunchedEffect
            val url = withContext(Dispatchers.IO) { runCatching { d.resolveLiveUrl(portalId, channel) }.getOrNull() } ?: return@LaunchedEffect
            if (portal.type == PortalType.demo && url.isEmpty()) return@LaunchedEffect
            e.lastChannelId = channel.id
            e.open(StreamSpec(url, StreamHeaders.streamHeadersFor(portal, channel), live = true), EngineConfig())
        }
        Box(modifier.background(Color.Black)) {
            AndroidView(factory = { ctx -> SurfaceView(ctx).also { e.attachSurface(it) } }, modifier = Modifier.fillMaxSize())
        }
        DisposableEffect(e) { onDispose { e.attachSurface(null) } }
    }
}

/**
 * Nur für Tests ohne Engine: ein fokussierbarer Platzhalter-Player, der sich
 * wie der echte den Fokus holt ([grab] = z. B. Ausblend-Zeitgeber des Players).
 */
class FakePlayerFocus {
    val requester = androidx.compose.ui.focus.FocusRequester()
    var requests = 0
    var keys = 0
    fun grab(): Boolean = runCatching { requester.requestFocus() }.getOrDefault(false)
}

/** Sender, den die Engine zuletzt für das Mini-Video geöffnet hat. */
private val channelIds = java.util.WeakHashMap<PlayerEngine, String>()
var PlayerEngine.lastChannelId: String?
    get() = channelIds[this]
    set(v) { if (v == null) channelIds.remove(this) else channelIds[this] = v }

/** Platzhalter-„Video“ (Bildschirmfotos, keine Engine): grüner Verlauf wie im Entwurf. */
object PreviewVideo {
    val brush = androidx.compose.ui.graphics.Brush.radialGradient(
        listOf(Color(0xFF3A6B3F), Color(0xFF1D3A24), Color(0xFF0B140E)),
    )
}
