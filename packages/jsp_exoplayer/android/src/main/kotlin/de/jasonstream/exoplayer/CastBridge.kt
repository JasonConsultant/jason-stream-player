package de.jasonstream.exoplayer

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.mediarouter.media.MediaRouteSelector
import androidx.mediarouter.media.MediaRouter
import com.google.android.gms.cast.CastMediaControlIntent
import com.google.android.gms.cast.HlsSegmentFormat
import com.google.android.gms.cast.HlsVideoSegmentFormat
import com.google.android.gms.cast.MediaInfo
import com.google.android.gms.cast.MediaLoadRequestData
import com.google.android.gms.cast.MediaMetadata
import com.google.android.gms.cast.MediaStatus
import com.google.android.gms.cast.framework.CastContext
import com.google.android.gms.cast.framework.CastOptions
import com.google.android.gms.cast.framework.CastSession
import com.google.android.gms.cast.framework.OptionsProvider
import com.google.android.gms.cast.framework.SessionManagerListener
import com.google.android.gms.cast.framework.SessionProvider
import com.google.android.gms.cast.framework.media.CastMediaOptions
import com.google.android.gms.cast.framework.media.RemoteMediaClient
import com.google.android.gms.common.images.WebImage
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * Cast-Optionen (Manifest-Eintrag OPTIONS_PROVIDER_CLASS_NAME): Default Media
 * Receiver, keine eigene Cast-Benachrichtigung/Mediensitzung – die App zeigt
 * „Läuft auf …“ über ihre eigene (audio_service).
 */
class JspCastOptionsProvider : OptionsProvider {
    override fun getCastOptions(context: Context): CastOptions = CastOptions.Builder()
        .setReceiverApplicationId(CastMediaControlIntent.DEFAULT_MEDIA_RECEIVER_APPLICATION_ID)
        .setStopReceiverApplicationWhenEndingSession(true)
        .setCastMediaOptions(
            CastMediaOptions.Builder()
                .setNotificationOptions(null)
                .setMediaSessionEnabled(false)
                .build(),
        )
        .build()

    override fun getAdditionalSessionProviders(context: Context): List<SessionProvider>? = null
}

/**
 * Google Cast über das Android-Framework: Gerätesuche (MediaRouter), Sitzung
 * (SessionManager) und Fernsteuerung (RemoteMediaClient). Kanal
 * „de.jasonstream/cast“, Ereignisse „de.jasonstream/cast/events“.
 *
 * Datenschutz: Adressen (mit Zugangsdaten) werden nie protokolliert.
 */
internal class CastBridge(context: Context, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private val app = context.applicationContext
    private val main = Handler(Looper.getMainLooper())
    private val method = MethodChannel(messenger, "de.jasonstream/cast")
    private val events = EventChannel(messenger, "de.jasonstream/cast/events")
    private var sink: EventChannel.EventSink? = null

    private var cast: CastContext? = null
    private var unavailable = false
    private var router: MediaRouter? = null
    private val selector: MediaRouteSelector = MediaRouteSelector.Builder()
        .addControlCategory(
            CastMediaControlIntent.categoryForCast(CastMediaControlIntent.DEFAULT_MEDIA_RECEIVER_APPLICATION_ID),
        )
        .build()
    private var discovering = false
    private var client: RemoteMediaClient? = null

    init {
        method.setMethodCallHandler(this)
        events.setStreamHandler(this)
    }

    fun dispose() {
        stopDiscovery()
        detachClient()
        try {
            cast?.sessionManager?.removeSessionManagerListener(sessionListener, CastSession::class.java)
        } catch (_: Exception) {
        }
        method.setMethodCallHandler(null)
        events.setStreamHandler(null)
    }

    // ---------- EventChannel ----------
    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
        sendDevices()
        sendSession()
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    private fun send(map: Map<String, Any?>) {
        main.post { sink?.success(map) }
    }

    // ---------- Initialisierung ----------
    /** CastContext asynchron holen (ohne Google-Play-Dienste: „nicht verfügbar“). */
    private fun ensureContext(done: (CastContext?) -> Unit) {
        cast?.let { return done(it) }
        if (unavailable) return done(null)
        try {
            CastContext.getSharedInstance(app, Executors.newSingleThreadExecutor())
                .addOnSuccessListener { c ->
                    main.post {
                        if (cast == null) {
                            cast = c
                            c.sessionManager.addSessionManagerListener(sessionListener, CastSession::class.java)
                            c.sessionManager.currentCastSession?.let { attachClient(it) }
                        }
                        sendSession()
                        done(cast)
                    }
                }
                .addOnFailureListener {
                    main.post {
                        unavailable = true
                        Log.i(TAG, "cast unavailable: ${it.javaClass.simpleName}")
                        send(mapOf("e" to "unavailable"))
                        done(null)
                    }
                }
        } catch (e: Exception) {
            unavailable = true
            Log.i(TAG, "cast unavailable: ${e.javaClass.simpleName}")
            done(null)
        }
    }

    // ---------- Gerätesuche ----------
    private val routerCallback = object : MediaRouter.Callback() {
        override fun onRouteAdded(router: MediaRouter, route: MediaRouter.RouteInfo) = sendDevices()
        override fun onRouteRemoved(router: MediaRouter, route: MediaRouter.RouteInfo) = sendDevices()
        override fun onRouteChanged(router: MediaRouter, route: MediaRouter.RouteInfo) = sendDevices()
    }

    private fun castRoutes(): List<MediaRouter.RouteInfo> {
        val r = router ?: return emptyList()
        return r.routes.filter { !it.isDefaultOrBluetooth && it.isEnabled && it.matchesSelector(selector) }
    }

    private fun sendDevices() {
        val list = castRoutes().map { mapOf("id" to it.id, "name" to it.name) }
        send(mapOf("e" to "devices", "devices" to list))
    }

    private fun startDiscovery() {
        ensureContext { c ->
            if (c == null || discovering) return@ensureContext
            val r = router ?: MediaRouter.getInstance(app).also { router = it }
            r.addCallback(selector, routerCallback, MediaRouter.CALLBACK_FLAG_REQUEST_DISCOVERY)
            discovering = true
            sendDevices()
        }
    }

    private fun stopDiscovery() {
        if (!discovering) return
        router?.removeCallback(routerCallback)
        discovering = false
    }

    // ---------- Sitzung ----------
    private var connecting = false

    private val sessionListener = object : SessionManagerListener<CastSession> {
        override fun onSessionStarting(session: CastSession) {
            connecting = true
            sendSession()
        }

        override fun onSessionStarted(session: CastSession, sessionId: String) {
            connecting = false
            attachClient(session)
            sendSession()
        }

        override fun onSessionStartFailed(session: CastSession, error: Int) {
            connecting = false
            Log.i(TAG, "session start failed: $error")
            send(mapOf("e" to "session", "state" to "failed", "code" to error))
        }

        override fun onSessionEnding(session: CastSession) {
            // Letzte Position für die Rückgabe an das Handy.
            val c = session.remoteMediaClient
            if (c != null) send(mapOf("e" to "pos", "ms" to c.approximateStreamPosition))
        }

        override fun onSessionEnded(session: CastSession, error: Int) {
            connecting = false
            detachClient()
            send(mapOf("e" to "session", "state" to "ended", "code" to error))
        }

        override fun onSessionResuming(session: CastSession, sessionId: String) {
            connecting = true
            sendSession()
        }

        override fun onSessionResumed(session: CastSession, wasSuspended: Boolean) {
            connecting = false
            attachClient(session)
            sendSession()
        }

        override fun onSessionResumeFailed(session: CastSession, error: Int) {
            connecting = false
            send(mapOf("e" to "session", "state" to "ended", "code" to error))
        }

        override fun onSessionSuspended(session: CastSession, reason: Int) = sendSession()
    }

    private fun currentSession(): CastSession? = try {
        cast?.sessionManager?.currentCastSession
    } catch (_: Exception) {
        null
    }

    private fun sendSession() {
        val s = currentSession()
        val state = when {
            s != null && s.isConnected -> "connected"
            connecting || (s != null && s.isConnecting) -> "connecting"
            else -> "idle"
        }
        send(mapOf("e" to "session", "state" to state, "device" to s?.castDevice?.friendlyName))
    }

    private val mediaCallback = object : RemoteMediaClient.Callback() {
        override fun onStatusUpdated() = sendStatus()
    }

    private val progress = RemoteMediaClient.ProgressListener { pos, _ ->
        send(mapOf("e" to "pos", "ms" to pos))
    }

    private fun attachClient(session: CastSession) {
        val c = session.remoteMediaClient ?: return
        if (c === client) return
        detachClient()
        client = c
        c.registerCallback(mediaCallback)
        c.addProgressListener(progress, 1000)
    }

    private fun detachClient() {
        val c = client ?: return
        c.unregisterCallback(mediaCallback)
        c.removeProgressListener(progress)
        client = null
    }

    private fun sendStatus() {
        val c = client ?: return
        val state = when (c.playerState) {
            MediaStatus.PLAYER_STATE_PLAYING -> "playing"
            MediaStatus.PLAYER_STATE_PAUSED -> "paused"
            MediaStatus.PLAYER_STATE_BUFFERING, MediaStatus.PLAYER_STATE_LOADING -> "buffering"
            else -> "idle"
        }
        val reason = when (c.idleReason) {
            MediaStatus.IDLE_REASON_FINISHED -> "finished"
            MediaStatus.IDLE_REASON_ERROR -> "error"
            MediaStatus.IDLE_REASON_CANCELED -> "canceled"
            MediaStatus.IDLE_REASON_INTERRUPTED -> "interrupted"
            else -> null
        }
        send(mapOf("e" to "status", "state" to state, "idle" to reason, "ms" to c.approximateStreamPosition))
    }

    // ---------- Befehle ----------
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            handle(call, result)
        } catch (e: Exception) {
            result.error("cast", e.javaClass.simpleName, null)
        }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "startDiscovery" -> {
                startDiscovery(); result.success(null)
            }
            "stopDiscovery" -> {
                stopDiscovery(); result.success(null)
            }
            "connect" -> {
                val id = call.argument<String>("id") ?: return result.error("cast", "id missing", null)
                ensureContext { c ->
                    val route = castRoutes().firstOrNull { it.id == id }
                    if (c == null || route == null) {
                        result.success(false)
                    } else {
                        connecting = true
                        sendSession()
                        (router ?: MediaRouter.getInstance(app)).selectRoute(route)
                        result.success(true)
                    }
                }
            }
            "disconnect" -> {
                try {
                    cast?.sessionManager?.endCurrentSession(true)
                } catch (_: Exception) {
                }
                result.success(null)
            }
            "load" -> load(call, result)
            "play" -> {
                client?.play(); result.success(null)
            }
            "pause" -> {
                client?.pause(); result.success(null)
            }
            "stop" -> {
                client?.stop(); result.success(null)
            }
            "seek" -> {
                client?.seek(call.argument<Number>("ms")?.toLong() ?: 0L)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun load(call: MethodCall, result: MethodChannel.Result) {
        val c = currentSession()?.remoteMediaClient ?: return result.success(mapOf("ok" to false, "code" to -1))
        attachClient(currentSession()!!)
        val url = call.argument<String>("url") ?: return result.error("cast", "url missing", null)
        val mime = call.argument<String>("mime") ?: "video/mp4"
        val live = call.argument<Boolean>("live") ?: false
        val meta = MediaMetadata(if (live) MediaMetadata.MEDIA_TYPE_GENERIC else MediaMetadata.MEDIA_TYPE_MOVIE)
        call.argument<String>("title")?.let { meta.putString(MediaMetadata.KEY_TITLE, it) }
        call.argument<String>("subtitle")?.let { meta.putString(MediaMetadata.KEY_SUBTITLE, it) }
        call.argument<String>("image")?.let { meta.addImage(WebImage(Uri.parse(it))) }
        val info = MediaInfo.Builder(url)
            .setContentUrl(url)
            .setContentType(mime)
            .setStreamType(if (live) MediaInfo.STREAM_TYPE_LIVE else MediaInfo.STREAM_TYPE_BUFFERED)
            .setMetadata(meta)
            .apply {
                // IPTV-/Medienserver-HLS liefert fast immer MPEG-TS-Segmente.
                if (CastMime.isHls(mime)) {
                    setHlsSegmentFormat(HlsSegmentFormat.TS)
                    setHlsVideoSegmentFormat(HlsVideoSegmentFormat.MPEG2_TS)
                }
            }
            .build()
        val req = MediaLoadRequestData.Builder()
            .setMediaInfo(info)
            .setAutoplay(true)
            .apply { if (!live) setCurrentTime(call.argument<Number>("positionMs")?.toLong() ?: 0L) }
            .build()
        Log.i(TAG, "cast load live=$live type=$mime")
        c.load(req).setResultCallback { r ->
            val st = r.status
            if (!st.isSuccess) Log.i(TAG, "cast load failed: ${st.statusCode}")
            main.post { result.success(mapOf("ok" to st.isSuccess, "code" to st.statusCode)) }
        }
    }

    companion object {
        private const val TAG = "JspCast"
    }
}

/** MIME-Hilfen (auch in JVM-Tests). */
internal object CastMime {
    fun isHls(mime: String): Boolean {
        val m = mime.lowercase()
        return m == "application/x-mpegurl" || m == "application/vnd.apple.mpegurl"
    }
}
