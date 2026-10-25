package de.jasonstream.exoplayer

import android.content.Context
import android.graphics.Bitmap
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.annotation.OptIn
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.common.Tracks
import androidx.media3.common.VideoSize
import androidx.media3.common.text.Cue
import androidx.media3.common.text.CueGroup
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.HttpDataSource
import androidx.media3.datasource.ResolvingDataSource
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.exoplayer.DecoderReuseEvaluation
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.analytics.AnalyticsListener
import androidx.media3.exoplayer.audio.AudioCapabilities
import androidx.media3.exoplayer.audio.AudioSink
import androidx.media3.exoplayer.audio.DefaultAudioSink
import androidx.media3.exoplayer.hls.DefaultHlsExtractorFactory
import androidx.media3.exoplayer.hls.HlsMediaSource
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector
import androidx.media3.exoplayer.mediacodec.MediaCodecUtil
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import androidx.media3.exoplayer.trackselection.DefaultTrackSelector
import androidx.media3.extractor.DefaultExtractorsFactory
import androidx.media3.extractor.text.DefaultSubtitleParserFactory
import androidx.media3.extractor.ts.DefaultTsPayloadReaderFactory
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.view.TextureRegistry
import okhttp3.OkHttpClient
import java.io.ByteArrayOutputStream
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/** Was den Aufbau des Players bestimmt; Änderung → Player neu bauen (Fläche bleibt). */
internal data class BuildConfig(
    val plan: BufferPlan,
    /** mpv hwdec=no: Software-Videodekoder zuerst. */
    val softwareVideo: Boolean,
    /** Dolby/DTS an Receiver durchreichen (Fähigkeiten des HDMI-Geräts). */
    val passthrough: Boolean,
)

/** Externer Untertitel (Medienserver). */
internal data class SideSubtitle(val url: String, val language: String?, val label: String?, val codec: String?)

/**
 * Ein ExoPlayer mit Flutter-Textur. Beim Zappen wird nur die Quelle getauscht
 * (Decoder und Fläche bleiben); bei geänderten Puffer-/Decoder-/Ton-Einstellungen
 * wird der Player neu gebaut. Nur vom Haupt-Thread benutzen.
 */
@OptIn(UnstableApi::class)
internal class ExoSession(
    context: Context,
    val id: Long,
    private val producer: TextureRegistry.SurfaceProducer,
    messenger: BinaryMessenger,
    private val client: OkHttpClient,
) : TextureRegistry.SurfaceProducer.Callback, EventChannel.StreamHandler {
    private val app = context.applicationContext
    private val main = Handler(Looper.getMainLooper())
    private val channel = EventChannel(messenger, "de.jasonstream/exoplayer/events/$id")
    private var sink: EventChannel.EventSink? = null

    private var player: ExoPlayer? = null
    private var trackSelector: DefaultTrackSelector? = null
    private var built: BuildConfig? = null
    private var needsSurface = true
    private var released = false

    /** Kopfzeilen der aktuellen Quelle (für alle Teil-Anfragen, HLS-Segmente …). */
    private val headers = AtomicReference<Map<String, String>>(emptyMap())

    /** Dekodername → Hardware? (aus der Decoder-Auswahl). */
    private val hwByName = ConcurrentHashMap<String, Boolean>()
    private var videoDecoder: String? = null
    private var audioDecoder: String? = null
    private var droppedFrames = 0L
    private var bandwidth = 0L
    private var videoOff = false
    private var lastPos = -1L
    private var lastDur = -1L
    private var lastBuf = -1L

    val textureId: Long get() = producer.id()

    init {
        channel.setStreamHandler(this)
        producer.setCallback(this)
    }

    // ---------- EventChannel ----------
    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
        sendState()
        sendTracks()
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    private fun send(map: Map<String, Any?>) {
        if (released) return
        sink?.success(map)
    }

    // ---------- Fläche ----------
    override fun onSurfaceAvailable() {
        if (needsSurface) {
            player?.setVideoSurface(producer.surface)
            needsSurface = false
        }
    }

    override fun onSurfaceCleanup() {
        player?.setVideoSurface(null)
        needsSurface = true
    }

    // ---------- Aufbau ----------
    private val dataSourceFactory: DataSource.Factory by lazy {
        // User-Agent kommt aus den Kopfzeilen (Dart setzt immer einen).
        val http = OkHttpDataSource.Factory(client)
        ResolvingDataSource.Factory(http) { spec ->
            val h = headers.get()
            if (h.isEmpty()) spec else spec.withAdditionalHeaders(h)
        }
    }

    private val tsFlags = DefaultTsPayloadReaderFactory.FLAG_ALLOW_NON_IDR_KEYFRAMES or
        DefaultTsPayloadReaderFactory.FLAG_DETECT_ACCESS_UNITS

    private fun extractors() = DefaultExtractorsFactory()
        .setTsExtractorFlags(tsFlags)
        .setConstantBitrateSeekingEnabled(true)
        // Untertitel beim Auslesen parsen (Media3 ≥ 1.4 dekodiert Text sonst nicht).
        .setSubtitleParserFactory(DefaultSubtitleParserFactory())
        .setTextTrackTranscodingEnabled(true)

    private fun obtain(config: BuildConfig): ExoPlayer {
        val cur = player
        if (cur != null && built == config) return cur
        val volume = cur?.volume
        releasePlayer()
        val p = build(config)
        volume?.let { p.volume = it }
        return p
    }

    private fun build(config: BuildConfig): ExoPlayer {
        val selector = MediaCodecSelector { mime, secure, tunneling ->
            val list = MediaCodecUtil.getDecoderInfos(mime, secure, tunneling)
            for (i in list) hwByName[i.name] = i.hardwareAccelerated
            if (MimeTypes.isVideo(mime)) {
                DecoderOrder.order(list, config.softwareVideo) { it.softwareOnly }
            } else {
                list
            }
        }
        val renderers = object : DefaultRenderersFactory(app) {
            override fun buildAudioSink(
                context: Context,
                enableFloatOutput: Boolean,
                enableAudioTrackPlaybackParams: Boolean,
            ): AudioSink {
                val b = DefaultAudioSink.Builder(context)
                    .setEnableFloatOutput(enableFloatOutput)
                    .setEnableAudioTrackPlaybackParams(enableAudioTrackPlaybackParams)
                // Durchreichen aus: nur PCM → AC3/E-AC3/DTS werden dekodiert
                // (Gerät oder FFmpeg). An: Fähigkeiten des HDMI-Geräts.
                @Suppress("DEPRECATION")
                if (!config.passthrough) b.setAudioCapabilities(AudioCapabilities.DEFAULT_AUDIO_CAPABILITIES)
                return b.build()
            }
        }
            .setMediaCodecSelector(selector)
            // Gerätedecoder zuerst, FFmpeg-Software danach (DTS/AC3/E-AC3/TrueHD/MP2
            // auch ohne Hardware-Dekoder).
            .setExtensionRendererMode(DefaultRenderersFactory.EXTENSION_RENDERER_MODE_ON)
            .setEnableDecoderFallback(true)

        val ts = DefaultTrackSelector(app)
        // Tunneling nicht: Ausgabe über eine Flutter-Textur.
        ts.setParameters(ts.buildUponParameters().setTunnelingEnabled(false))
        val plan = config.plan
        val load = DefaultLoadControl.Builder()
            .setBufferDurationsMs(plan.minBufferMs, plan.maxBufferMs, plan.playbackMs, plan.rebufferMs)
            .setTargetBufferBytes(plan.targetBytes)
            .setPrioritizeTimeOverSizeThresholds(false)
            .apply { if (plan.backBufferMs > 0) setBackBuffer(plan.backBufferMs, true) }
            .build()

        val p = ExoPlayer.Builder(app, renderers)
            .setTrackSelector(ts)
            .setLoadControl(load)
            // Audio-Fokus und Kopfhörer regelt die App (audio_session) – wie bei mpv.
            .setAudioAttributes(
                AudioAttributes.Builder().setUsage(C.USAGE_MEDIA).setContentType(C.AUDIO_CONTENT_TYPE_MOVIE).build(),
                false,
            )
            .setHandleAudioBecomingNoisy(false)
            .setWakeMode(C.WAKE_MODE_NETWORK)
            .build()
        p.addListener(listener)
        p.addAnalyticsListener(analytics)
        val surface = producer.surface
        if (surface != null) {
            p.setVideoSurface(surface)
            needsSurface = false
        } else {
            needsSurface = true
        }
        if (videoOff) {
            ts.setParameters(ts.buildUponParameters().setTrackTypeDisabled(C.TRACK_TYPE_VIDEO, true))
        }
        player = p
        trackSelector = ts
        built = config
        return p
    }

    private fun releasePlayer() {
        val p = player ?: return
        main.removeCallbacks(ticker)
        p.removeListener(listener)
        p.removeAnalyticsListener(analytics)
        p.setVideoSurface(null)
        p.release()
        player = null
        trackSelector = null
        built = null
        needsSurface = true
    }

    // ---------- Bedienung ----------
    fun open(
        url: String,
        rawHeaders: Map<String, String?>,
        live: Boolean,
        startMs: Long,
        play: Boolean,
        subtitles: List<SideSubtitle>,
        config: BuildConfig,
        limit: VideoLimit = VideoLimit.NONE,
    ) {
        val p = obtain(config)
        headers.set(StreamHeaders.sanitize(rawHeaders))
        videoDecoder = null
        audioDecoder = null
        droppedFrames = 0
        lastPos = -1
        lastDur = -1
        lastBuf = -1
        // Vorgaben je Quelle: keine alten Spur-Overrides, Untertitel erlaubt.
        trackSelector?.let { ts ->
            ts.setParameters(
                ts.buildUponParameters()
                    .clearOverrides()
                    .setTrackTypeDisabled(C.TRACK_TYPE_TEXT, false)
                    .setTrackTypeDisabled(C.TRACK_TYPE_AUDIO, false)
                    .setTrackTypeDisabled(C.TRACK_TYPE_VIDEO, videoOff)
                    // Datensparmodus: niedrige/mittlere HLS-Stufe (ohne passende
                    // Stufe nimmt Media3 die kleinste).
                    .setMaxVideoBitrate(limit.bitrateOrMax)
                    .setMaxVideoSize(limit.maxWidth, limit.heightOrMax),
            )
        }
        send(mapOf("e" to "cues", "cues" to emptyList<Any>()))
        val source = mediaSource(url, live, subtitles)
        if (startMs > 0) p.setMediaSource(source, startMs) else p.setMediaSource(source, true)
        p.prepare()
        p.playWhenReady = play
        main.removeCallbacks(ticker)
        main.post(ticker)
        Log.i(TAG, "open #$id live=$live hls=${MediaKind.isHls(url)} subs=${subtitles.size} saver=${limit.active}")
    }

    private fun mediaSource(url: String, live: Boolean, subs: List<SideSubtitle>): MediaSource {
        val hls = MediaKind.isHls(url)
        val dash = MediaKind.isDash(url)
        val item = MediaItem.Builder().setUri(Uri.parse(url))
        if (hls) item.setMimeType(MimeTypes.APPLICATION_M3U8)
        if (dash) item.setMimeType(MimeTypes.APPLICATION_MPD)
        if (live) {
            // Nah am Live-Rand bleiben (leicht schneller/langsamer abspielen).
            item.setLiveConfiguration(
                MediaItem.LiveConfiguration.Builder()
                    .setMinPlaybackSpeed(0.97f)
                    .setMaxPlaybackSpeed(1.03f)
                    .build(),
            )
        }
        if (subs.isNotEmpty()) {
            item.setSubtitleConfigurations(
                subs.map { s ->
                    MediaItem.SubtitleConfiguration.Builder(Uri.parse(s.url))
                        .setMimeType(MediaKind.subtitleMime(s.url, s.codec))
                        .setLanguage(s.language)
                        .setLabel(s.label)
                        .build()
                },
            )
        }
        val mi = item.build()
        return when {
            subs.isNotEmpty() || dash ->
                DefaultMediaSourceFactory(dataSourceFactory, extractors()).createMediaSource(mi)
            hls -> HlsMediaSource.Factory(dataSourceFactory)
                .setExtractorFactory(DefaultHlsExtractorFactory(tsFlags, true))
                .createMediaSource(mi)
            else -> ProgressiveMediaSource.Factory(dataSourceFactory, extractors())
                .setContinueLoadingCheckIntervalBytes(256 * 1024)
                .createMediaSource(mi)
        }
    }

    fun play() {
        player?.let { p ->
            if (p.playbackState == Player.STATE_IDLE) p.prepare()
            if (p.playbackState == Player.STATE_ENDED) p.seekToDefaultPosition()
            p.playWhenReady = true
        }
    }

    fun pause() {
        player?.playWhenReady = false
    }

    fun stop() {
        player?.stop()
        main.removeCallbacks(ticker)
        send(mapOf("e" to "cues", "cues" to emptyList<Any>()))
    }

    fun seek(ms: Long) {
        player?.seekTo(ms.coerceAtLeast(0))
        send(mapOf("e" to "cues", "cues" to emptyList<Any>()))
    }

    fun setVolume(v: Double) {
        player?.volume = v.toFloat().coerceIn(0f, 1f)
    }

    fun setVideoEnabled(enabled: Boolean) {
        videoOff = !enabled
        val ts = trackSelector ?: return
        ts.setParameters(ts.buildUponParameters().setTrackTypeDisabled(C.TRACK_TYPE_VIDEO, !enabled))
    }

    /** [trackId]: „auto“, „no“ oder „typ:gruppe:spur“ aus dem Spuren-Ereignis. */
    fun selectTrack(type: String, trackId: String) {
        val p = player ?: return
        val ts = trackSelector ?: return
        val t = when (type) {
            "audio" -> C.TRACK_TYPE_AUDIO
            "video" -> C.TRACK_TYPE_VIDEO
            else -> C.TRACK_TYPE_TEXT
        }
        val b = ts.buildUponParameters()
        when (trackId) {
            "auto" -> b.clearOverridesOfType(t).setTrackTypeDisabled(t, false)
            "no" -> b.clearOverridesOfType(t).setTrackTypeDisabled(t, true)
            else -> {
                val parts = trackId.split(':')
                val gi = parts.getOrNull(1)?.toIntOrNull() ?: return
                val ti = parts.getOrNull(2)?.toIntOrNull() ?: return
                val g = p.currentTracks.groups.getOrNull(gi) ?: return
                if (ti !in 0 until g.length) return
                b.setTrackTypeDisabled(t, false)
                    .setOverrideForType(TrackSelectionOverride(g.mediaTrackGroup, ti))
            }
        }
        ts.setParameters(b)
        if (t == C.TRACK_TYPE_TEXT) send(mapOf("e" to "cues", "cues" to emptyList<Any>()))
    }

    fun stats(): Map<String, Any?> {
        val p = player ?: return emptyMap()
        val v = p.videoFormat
        val a = p.audioFormat
        val dec = videoDecoder
        val hw = dec?.let { hwByName[it] ?: !DecoderOrder.looksSoftware(it) }
        val adec = audioDecoder
        // Zähler für die Wachhunde: gezeigte Bilder / verarbeitete Tonpuffer.
        val vc = p.videoDecoderCounters?.also { it.ensureUpdated() }
        val ac = p.audioDecoderCounters?.also { it.ensureUpdated() }
        return mapOf(
            "videoFrames" to vc?.renderedOutputBufferCount,
            "audioBuffers" to ac?.let { it.renderedOutputBufferCount + it.skippedOutputBufferCount },
            "videoDecoder" to dec,
            "videoHw" to hw,
            "audioDecoder" to adec,
            "audioHw" to adec?.let { hwByName[it] ?: !DecoderOrder.looksSoftware(it) },
            "videoMime" to v?.sampleMimeType,
            "videoCodecs" to v?.codecs,
            "audioMime" to a?.sampleMimeType,
            "audioChannels" to a?.channelCount?.takeIf { it > 0 },
            "sampleRate" to a?.sampleRate?.takeIf { it > 0 },
            "width" to v?.width?.takeIf { it > 0 },
            "height" to v?.height?.takeIf { it > 0 },
            "fps" to v?.frameRate?.takeIf { it > 0 }?.toDouble(),
            "dropped" to droppedFrames,
            "bufferedMs" to (p.bufferedPosition - p.currentPosition).coerceAtLeast(0),
            "bufferedPositionMs" to p.bufferedPosition,
            "positionMs" to p.currentPosition,
            "bitrate" to (v?.bitrate?.takeIf { it > 0 }),
            "audioBitrate" to (a?.bitrate?.takeIf { it > 0 }),
            "bandwidth" to bandwidth.takeIf { it > 0 },
            "softwarePreferred" to (built?.softwareVideo ?: false),
            "passthrough" to (built?.passthrough ?: false),
            "live" to p.isCurrentMediaItemLive,
        )
    }

    fun dispose() {
        if (released) return
        releasePlayer()
        released = true
        main.removeCallbacksAndMessages(null)
        channel.setStreamHandler(null)
        sink = null
        producer.setCallback(null)
        producer.release()
    }

    // ---------- Ereignisse ----------
    private val ticker = object : Runnable {
        override fun run() {
            val p = player ?: return
            sendPosition(p)
            if (p.playbackState != Player.STATE_IDLE) main.postDelayed(this, 250)
        }
    }

    private fun sendPosition(p: Player) {
        val pos = p.currentPosition
        val dur = p.duration.let { if (it == C.TIME_UNSET || it < 0) 0 else it }
        val buf = p.bufferedPosition
        if (pos == lastPos && dur == lastDur && buf == lastBuf) return
        lastPos = pos
        lastDur = dur
        lastBuf = buf
        send(mapOf("e" to "pos", "pos" to pos, "dur" to dur, "buf" to buf))
    }

    private fun sendState() {
        val p = player
        val st = when (p?.playbackState) {
            Player.STATE_BUFFERING -> "buffering"
            Player.STATE_READY -> "ready"
            Player.STATE_ENDED -> "ended"
            else -> "idle"
        }
        send(
            mapOf(
                "e" to "state",
                "state" to st,
                "playing" to (p?.playWhenReady ?: false),
                "isPlaying" to (p?.isPlaying ?: false),
            ),
        )
    }

    private fun sendTracks() {
        val p = player ?: return
        val out = ArrayList<Map<String, Any?>>()
        p.currentTracks.groups.forEachIndexed { gi, g ->
            val type = when (g.type) {
                C.TRACK_TYPE_AUDIO -> "audio"
                C.TRACK_TYPE_VIDEO -> "video"
                C.TRACK_TYPE_TEXT -> "text"
                else -> return@forEachIndexed
            }
            for (ti in 0 until g.length) {
                val f: Format = g.getTrackFormat(ti)
                out.add(
                    mapOf(
                        "id" to "$type:$gi:$ti",
                        "type" to type,
                        "language" to f.language?.takeIf { it != C.LANGUAGE_UNDETERMINED && it != "und" },
                        "label" to f.label,
                        "mime" to (f.sampleMimeType ?: f.containerMimeType),
                        "codecs" to f.codecs,
                        "channels" to f.channelCount.takeIf { it > 0 },
                        "width" to f.width.takeIf { it > 0 },
                        "height" to f.height.takeIf { it > 0 },
                        "bitrate" to f.bitrate.takeIf { it > 0 },
                        "selected" to g.isTrackSelected(ti),
                        "supported" to g.isTrackSupported(ti, true),
                    ),
                )
            }
        }
        send(mapOf("e" to "tracks", "tracks" to out))
    }

    private fun sendCues(group: CueGroup) {
        val list = ArrayList<Map<String, Any?>>()
        for (c in group.cues) {
            val text = c.text?.toString()
            val bmp = c.bitmap
            if (!text.isNullOrBlank()) {
                list.add(mapOf("text" to text, "line" to c.line.takeIf { c.lineType == Cue.LINE_TYPE_FRACTION && it != Cue.DIMEN_UNSET }?.toDouble()))
            } else if (bmp != null) {
                list.add(
                    mapOf(
                        "png" to png(bmp),
                        "x" to c.position.takeIf { it != Cue.DIMEN_UNSET }?.toDouble(),
                        "y" to c.line.takeIf { it != Cue.DIMEN_UNSET && c.lineType == Cue.LINE_TYPE_FRACTION }?.toDouble(),
                        "w" to c.size.takeIf { it != Cue.DIMEN_UNSET }?.toDouble(),
                        "h" to c.bitmapHeight.takeIf { it != Cue.DIMEN_UNSET }?.toDouble(),
                    ),
                )
            }
        }
        send(mapOf("e" to "cues", "pos" to (player?.currentPosition ?: 0L), "cues" to list))
    }

    private fun png(b: Bitmap): ByteArray {
        val out = ByteArrayOutputStream()
        b.compress(Bitmap.CompressFormat.PNG, 100, out)
        return out.toByteArray()
    }

    private fun sendError(e: PlaybackException) {
        val cat = ErrorCategory.of(e.errorCode)
        var http: Int? = null
        var c: Throwable? = e
        while (c != null) {
            if (c is HttpDataSource.InvalidResponseCodeException) {
                http = c.responseCode
                break
            }
            c = c.cause
        }
        val msg = describe(e, http)
        Log.w(TAG, "error #$id ${e.errorCodeName} (${cat.id})")
        send(
            mapOf(
                "e" to "error",
                "category" to cat.id,
                "code" to e.errorCode,
                "codeName" to e.errorCodeName,
                "http" to http,
                "message" to msg,
            ),
        )
    }

    private val listener = object : Player.Listener {
        override fun onPlaybackStateChanged(playbackState: Int) {
            sendState()
            if (playbackState != Player.STATE_IDLE) {
                main.removeCallbacks(ticker)
                main.post(ticker)
            }
        }

        override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) = sendState()

        override fun onIsPlayingChanged(isPlaying: Boolean) = sendState()

        override fun onPlayerError(error: PlaybackException) {
            val p = player ?: return
            if (error.errorCode == PlaybackException.ERROR_CODE_BEHIND_LIVE_WINDOW) {
                // Zu weit hinter dem Live-Fenster: still an den Rand springen.
                p.seekToDefaultPosition()
                p.prepare()
                return
            }
            sendError(error)
        }

        override fun onTracksChanged(tracks: Tracks) = sendTracks()

        override fun onVideoSizeChanged(videoSize: VideoSize) {
            send(
                mapOf(
                    "e" to "size",
                    "width" to videoSize.width,
                    "height" to videoSize.height,
                    "par" to videoSize.pixelWidthHeightRatio.toDouble(),
                ),
            )
        }

        override fun onCues(cueGroup: CueGroup) = sendCues(cueGroup)

        override fun onRenderedFirstFrame() {
            send(mapOf("e" to "firstFrame"))
        }
    }

    private val analytics = object : AnalyticsListener {
        override fun onVideoDecoderInitialized(
            eventTime: AnalyticsListener.EventTime,
            decoderName: String,
            initializedTimestampMs: Long,
            initializationDurationMs: Long,
        ) {
            videoDecoder = decoderName
        }

        override fun onAudioDecoderInitialized(
            eventTime: AnalyticsListener.EventTime,
            decoderName: String,
            initializedTimestampMs: Long,
            initializationDurationMs: Long,
        ) {
            audioDecoder = decoderName
        }

        override fun onDroppedVideoFrames(eventTime: AnalyticsListener.EventTime, droppedFrames: Int, elapsedMs: Long) {
            this@ExoSession.droppedFrames += droppedFrames
        }

        override fun onBandwidthEstimate(
            eventTime: AnalyticsListener.EventTime,
            totalLoadTimeMs: Int,
            totalBytesLoaded: Long,
            bitrateEstimate: Long,
        ) {
            bandwidth = bitrateEstimate
        }

        override fun onVideoInputFormatChanged(
            eventTime: AnalyticsListener.EventTime,
            format: Format,
            decoderReuseEvaluation: DecoderReuseEvaluation?,
        ) {
            if (format.frameRate > 1f) send(mapOf("e" to "fps", "fps" to format.frameRate.toDouble()))
        }
    }

    companion object {
        private const val TAG = "JspExo"

        /** Fehlermeldung ohne Adressen/Zugangsdaten; HTTP-Status als „HTTP error 403“ (Dart ordnet daran ein). */
        fun describe(e: PlaybackException, http: Int?): String {
            if (http != null) return "HTTP error $http"
            val cause = Redact.text(e.cause?.message ?: e.message)
            val msg = when (ErrorCategory.of(e.errorCode)) {
                ErrorCategory.NETWORK -> when (e.errorCode) {
                    PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT -> "Connection timed out"
                    PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_FAILED -> "Failed to open: connection failed"
                    else -> "${e.errorCodeName}: $cause"
                }
                ErrorCategory.DECODER -> "Decoder error (${e.errorCodeName}): $cause"
                ErrorCategory.FORMAT -> "Unsupported format (${e.errorCodeName}): $cause"
                ErrorCategory.CONTAINER -> "Container error (${e.errorCodeName}): $cause"
                ErrorCategory.DRM -> "DRM protected (${e.errorCodeName})"
                ErrorCategory.OTHER -> "${e.errorCodeName}: $cause"
            }
            return Redact.text(msg).trimEnd(' ', ':')
        }

        /** Gemeinsamer Stream-Client: Weiterleitungen folgen (Token-Server), Hänger früh erkennen. */
        fun newClient(): OkHttpClient = OkHttpClient.Builder()
            .followRedirects(true)
            .followSslRedirects(true)
            .connectTimeout(10, TimeUnit.SECONDS)
            .readTimeout(15, TimeUnit.SECONDS)
            .build()
    }
}
