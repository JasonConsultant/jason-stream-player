package de.jasonstream.playback.engine

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.view.SurfaceView
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
import androidx.media3.common.text.CueGroup
import androidx.media3.common.util.UnstableApi
import androidx.media3.common.util.Util
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
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import androidx.media3.exoplayer.trackselection.DefaultTrackSelector
import androidx.media3.extractor.DefaultExtractorsFactory
import androidx.media3.extractor.ts.DefaultTsPayloadReaderFactory
import androidx.media3.ui.SubtitleView
import de.jasonstream.core.security.Redactor
import de.jasonstream.data.net.Net
import de.jasonstream.playback.logic.TrackInfo
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import okhttp3.OkHttpClient
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/** Einstellungen, die den Aufbau des Players betreffen (aus set_*). */
data class EngineConfig(
    /** set_buffer: klein/normal/gross → 16/48/128 MB. */
    val bufferBytes: Int = 48 shl 20,
    /** set_passthrough: Dolby/DTS als Bitstream an Receiver/Soundbar. */
    val passthrough: Boolean = false,
    /** set_tunnel: getunnelte Wiedergabe (nur manche Boxen; Standard aus). */
    val tunneling: Boolean = false,
    /** Notlösung nach Decoder-Fehler: FFmpeg-Audio vor den Hardware-Dekodern. */
    val preferSoftwareAudio: Boolean = false,
) {
    companion object {
        /** Aus den Einstellungen (set_buffer, set_passthrough, set_tunnel) – gleiche Werte wie der Vollbild-Player. */
        fun fromStorage(storage: de.jasonstream.core.storage.Storage, preferSoftwareAudio: Boolean = false) = EngineConfig(
            bufferBytes = bufferBytesFor(storage.option("buffer", "normal")),
            passthrough = storage.flag("passthrough"),
            tunneling = storage.flag("tunnel"),
            preferSoftwareAudio = preferSoftwareAudio,
        )

        fun bufferBytesFor(option: String): Int = when (option) {
            "klein" -> 16
            "gross" -> 128
            else -> 48
        } shl 20
    }
}

/** Was geöffnet werden soll. */
data class StreamSpec(
    val url: String,
    val headers: Map<String, String>,
    val live: Boolean,
    /** > 0: Startposition (Filme/Folgen). */
    val startPositionMs: Long = 0,
)

/** Eine wählbare Spur. [group]/[track] = Position in Player.currentTracks. */
data class TrackOption(val group: Int, val track: Int, val info: TrackInfo, val selected: Boolean)

/** Rückmeldungen an die Oberfläche (Haupt-Thread). */
interface EngineCallbacks {
    /** Fehler (bereits ohne Zugangsdaten, mit „HTTP error 403“ usw. für die Einordnung). */
    fun onError(message: String) {}
    /** Ende des Streams (VOD fertig; live = Verbindung weg). */
    fun onEnded() {}
    /** Erste Bildrate des Videos (für AFR). */
    fun onFrameRate(fps: Float) {}
    /** Spuren geändert (bevorzugte Sprache anwenden). */
    fun onTracksChanged() {}
}

/**
 * Ein ExoPlayer für alle Sender: beim Zappen wird nur die Quelle getauscht
 * (Decoder/Surface bleiben), beim Verlassen ([release], onStop) wird er
 * freigegeben. Baut den Player neu, wenn sich Ton-Durchreichung oder die
 * Software-Notlösung ändern.
 *
 * Nur vom Haupt-Thread benutzen.
 */
@OptIn(UnstableApi::class)
class PlayerEngine(context: Context) {
    private val app = context.applicationContext
    private val main = Handler(Looper.getMainLooper())

    var player: ExoPlayer? = null
        private set
    private var trackSelector: DefaultTrackSelector? = null
    private var built: EngineConfig? = null

    /** Kopfzeilen der aktuellen Quelle (gelten für alle Teil-Anfragen, HLS-Segmente …). */
    private val headers = AtomicReference<Map<String, String>>(emptyMap())

    var callbacks: EngineCallbacks? = null
    private var surface: SurfaceView? = null
    private var subtitles: SubtitleView? = null

    /** Zählt bei jedem Player-Ereignis hoch – Oberfläche liest dann den Zustand neu. */
    private val _revision = MutableStateFlow(0L)
    val revision: StateFlow<Long> = _revision

    val stats = DebugStats()
    var lastSpec: StreamSpec? = null
        private set

    private val client: OkHttpClient by lazy {
        // Streams: Weiterleitungen folgen (Token-Server), kürzere Lese-Zeit
        // (Hänger früher erkennen).
        Net.client.newBuilder()
            .followRedirects(true)
            .followSslRedirects(true)
            .connectTimeout(10, TimeUnit.SECONDS)
            .readTimeout(15, TimeUnit.SECONDS)
            .build()
    }

    private val dataSourceFactory: DataSource.Factory by lazy {
        val http = OkHttpDataSource.Factory(client) // User-Agent kommt aus den Kopfzeilen
        ResolvingDataSource.Factory(http) { spec ->
            val h = headers.get()
            if (h.isEmpty()) spec else spec.withAdditionalHeaders(h)
        }
    }

    private val tsFlags = DefaultTsPayloadReaderFactory.FLAG_ALLOW_NON_IDR_KEYFRAMES or
        DefaultTsPayloadReaderFactory.FLAG_DETECT_ACCESS_UNITS

    private val listener = object : Player.Listener {
        override fun onEvents(player: Player, events: Player.Events) {
            _revision.value++
        }

        override fun onPlayerError(error: PlaybackException) {
            val p = player ?: return
            if (error.errorCode == PlaybackException.ERROR_CODE_BEHIND_LIVE_WINDOW) {
                // Zu weit hinter dem Live-Fenster: still an den Rand springen.
                p.seekToDefaultPosition()
                p.prepare()
                return
            }
            callbacks?.onError(describe(error))
        }

        override fun onPlaybackStateChanged(playbackState: Int) {
            if (playbackState == Player.STATE_ENDED) callbacks?.onEnded()
        }

        override fun onTracksChanged(tracks: Tracks) {
            callbacks?.onTracksChanged()
        }

        override fun onCues(cueGroup: CueGroup) {
            subtitles?.setCues(cueGroup.cues)
        }
    }

    private val analytics = object : AnalyticsListener {
        override fun onVideoDecoderInitialized(t: AnalyticsListener.EventTime, name: String, initializedTimestampMs: Long, initializationDurationMs: Long) {
            stats.videoDecoder = name
        }

        override fun onAudioDecoderInitialized(t: AnalyticsListener.EventTime, name: String, initializedTimestampMs: Long, initializationDurationMs: Long) {
            stats.audioDecoder = name
        }

        override fun onDroppedVideoFrames(t: AnalyticsListener.EventTime, droppedFrames: Int, elapsedMs: Long) {
            stats.droppedFrames += droppedFrames
        }

        override fun onBandwidthEstimate(t: AnalyticsListener.EventTime, totalLoadTimeMs: Int, totalBytesLoaded: Long, bitrateEstimate: Long) {
            stats.bandwidth = bitrateEstimate
        }

        override fun onVideoInputFormatChanged(t: AnalyticsListener.EventTime, format: Format, decoderReuseEvaluation: DecoderReuseEvaluation?) {
            if (format.frameRate > 1f) {
                val fps = format.frameRate
                main.post { callbacks?.onFrameRate(fps) }
            }
        }
    }

    /** Player holen (bei Bedarf neu bauen). */
    fun obtain(config: EngineConfig): ExoPlayer {
        val cur = player
        val needsRebuild = built?.let { it.passthrough != config.passthrough || it.preferSoftwareAudio != config.preferSoftwareAudio || it.bufferBytes != config.bufferBytes } ?: true
        if (cur != null && !needsRebuild) {
            if (built?.tunneling != config.tunneling) {
                trackSelector?.let { ts -> ts.setParameters(ts.buildUponParameters().setTunnelingEnabled(config.tunneling)) }
                built = config
            }
            return cur
        }
        val keepVolume = cur?.volume
        releasePlayer()
        return build(config).also { p ->
            keepVolume?.let { p.volume = it }
        }
    }

    private fun build(config: EngineConfig): ExoPlayer {
        val renderers = object : DefaultRenderersFactory(app) {
            override fun buildAudioSink(context: Context, enableFloatOutput: Boolean, enableAudioTrackPlaybackParams: Boolean): AudioSink {
                val b = DefaultAudioSink.Builder(context)
                    .setEnableFloatOutput(enableFloatOutput)
                    .setEnableAudioTrackPlaybackParams(enableAudioTrackPlaybackParams)
                // Durchreichung aus: nur PCM → AC3/E-AC3/DTS werden dekodiert
                // (Hardware oder FFmpeg). An: Fähigkeiten des HDMI-Geräts.
                @Suppress("DEPRECATION")
                if (!config.passthrough) b.setAudioCapabilities(AudioCapabilities.DEFAULT_AUDIO_CAPABILITIES)
                return b.build()
            }
        }
            .setExtensionRendererMode(
                if (config.preferSoftwareAudio) DefaultRenderersFactory.EXTENSION_RENDERER_MODE_PREFER
                else DefaultRenderersFactory.EXTENSION_RENDERER_MODE_ON,
            )
            .setEnableDecoderFallback(true)

        val ts = DefaultTrackSelector(app)
        ts.setParameters(ts.buildUponParameters().setTunnelingEnabled(config.tunneling))

        val load = DefaultLoadControl.Builder()
            // Schneller Start: 1 s Puffer genügt zum Losspielen, nach einem
            // Hänger 2 s; danach bis 15–50 s (bzw. set_buffer) vorpuffern.
            .setBufferDurationsMs(15_000, 50_000, 1_000, 2_000)
            .setTargetBufferBytes(config.bufferBytes)
            .setPrioritizeTimeOverSizeThresholds(false)
            .build()

        val p = ExoPlayer.Builder(app, renderers)
            .setTrackSelector(ts)
            .setLoadControl(load)
            .setAudioAttributes(
                AudioAttributes.Builder().setUsage(C.USAGE_MEDIA).setContentType(C.AUDIO_CONTENT_TYPE_MOVIE).build(),
                true,
            )
            .setHandleAudioBecomingNoisy(true)
            .setWakeMode(C.WAKE_MODE_NETWORK)
            .build()
        p.addListener(listener)
        p.addAnalyticsListener(analytics)
        surface?.let { p.setVideoSurfaceView(it) }
        player = p
        trackSelector = ts
        built = config
        return p
    }

    /** Video-Ausgabe (von der Oberfläche); bleibt über Neubauten erhalten. */
    fun attachSurface(view: SurfaceView?) {
        if (surface === view) return
        surface?.let { player?.clearVideoSurfaceView(it) }
        surface = view
        view?.let { player?.setVideoSurfaceView(it) }
    }

    /** Nur lösen, wenn [view] noch die aktuelle Ausgabe ist (ein anderer Bildschirm kann sie schon übernommen haben). */
    fun detachSurface(view: SurfaceView) {
        if (surface === view) attachSurface(null)
    }

    fun detachSubtitles(view: SubtitleView) {
        if (subtitles === view) subtitles = null
    }

    fun attachSubtitles(view: SubtitleView?) {
        subtitles = view
        view?.setCues(player?.currentCues?.cues ?: emptyList())
    }

    /** Quelle öffnen (Zappen: gleicher Player, neue Quelle). */
    fun open(spec: StreamSpec, config: EngineConfig): ExoPlayer {
        val p = obtain(config)
        headers.set(spec.headers)
        lastSpec = spec
        stats.reset()
        subtitles?.setCues(emptyList())
        val source = mediaSourceFor(spec)
        if (spec.startPositionMs > 0) p.setMediaSource(source, spec.startPositionMs) else p.setMediaSource(source, true)
        p.prepare()
        p.playWhenReady = true
        return p
    }

    /** Typ nach Adresse: HLS (.m3u8) oder progressiv (MPEG-TS, MP4, MKV …). */
    fun mediaSourceFor(spec: StreamSpec): MediaSource {
        val uri = Uri.parse(spec.url)
        val hls = isHls(spec.url)
        val item = MediaItem.Builder().setUri(uri).apply { if (hls) setMimeType(MimeTypes.APPLICATION_M3U8) }.build()
        return if (hls) {
            HlsMediaSource.Factory(dataSourceFactory)
                .setExtractorFactory(DefaultHlsExtractorFactory(tsFlags, true))
                .setAllowChunklessPreparation(true)
                .createMediaSource(item)
        } else {
            val extractors = DefaultExtractorsFactory()
                .setTsExtractorFlags(tsFlags)
                .setConstantBitrateSeekingEnabled(true)
            ProgressiveMediaSource.Factory(dataSourceFactory, extractors)
                .setContinueLoadingCheckIntervalBytes(256 * 1024)
                .createMediaSource(item)
        }
    }

    fun stop() {
        player?.stop()
    }

    /** Player freigeben (onStop). Der nächste [open] baut ihn neu. */
    fun release() {
        releasePlayer()
    }

    private fun releasePlayer() {
        val p = player ?: return
        p.removeListener(listener)
        p.removeAnalyticsListener(analytics)
        surface?.let { p.clearVideoSurfaceView(it) }
        p.release()
        player = null
        trackSelector = null
        built = null
    }

    // ---------- Spuren ----------
    fun tracks(type: Int): List<TrackOption> {
        val p = player ?: return emptyList()
        val out = ArrayList<TrackOption>()
        p.currentTracks.groups.forEachIndexed { gi, g ->
            if (g.type != type) return@forEachIndexed
            for (ti in 0 until g.length) {
                if (!g.isTrackSupported(ti, true)) continue
                val f = g.getTrackFormat(ti)
                out.add(TrackOption(gi, ti, TrackInfo("${out.size + 1}", f.language, f.label), g.isTrackSelected(ti)))
            }
        }
        return out
    }

    fun select(type: Int, option: TrackOption?) {
        val p = player ?: return
        val ts = trackSelector ?: return
        val b = ts.buildUponParameters()
        if (option == null) {
            b.setTrackTypeDisabled(type, true)
        } else {
            val g = p.currentTracks.groups.getOrNull(option.group) ?: return
            b.setTrackTypeDisabled(type, false)
                .setOverrideForType(TrackSelectionOverride(g.mediaTrackGroup, option.track))
        }
        ts.setParameters(b)
    }

    fun isTypeDisabled(type: Int): Boolean = trackSelector?.parameters?.disabledTrackTypes?.contains(type) == true

    /** Vorgaben je neuer Quelle: Untertitel wieder erlaubt, keine alten Overrides. */
    fun clearTrackOverrides(preferredAudio: String?) {
        val ts = trackSelector ?: return
        ts.setParameters(
            ts.buildUponParameters()
                .clearOverrides()
                .setTrackTypeDisabled(C.TRACK_TYPE_TEXT, false)
                .setPreferredAudioLanguage(preferredAudio),
        )
    }

    // ---------- Diagnose ----------
    fun debugLines(): List<String> {
        val p = player ?: return emptyList()
        val v = p.videoFormat
        val a = p.audioFormat
        val bufS = (p.bufferedPosition - p.currentPosition).coerceAtLeast(0) / 1000.0
        val br = (v?.bitrate?.takeIf { it > 0 } ?: stats.bandwidth.toInt().takeIf { it > 0 })
        return listOf(
            "dec ${stats.videoDecoder ?: "–"}",
            "audio ${stats.audioDecoder ?: "–"} ${a?.sampleMimeType?.substringAfter('/') ?: ""}".trimEnd(),
            "${v?.sampleMimeType?.substringAfter('/') ?: "–"} ${v?.width ?: "–"}×${v?.height ?: "–"}",
            "fps ${v?.frameRate?.takeIf { it > 0 }?.let { "%.2f".format(it) } ?: "–"}",
            "drop ${stats.droppedFrames}",
            "bitrate ${br?.let { "%.1f Mbit/s".format(it / 1e6) } ?: "–"} · net ${if (stats.bandwidth > 0) "%.1f".format(stats.bandwidth / 1e6) else "–"}",
            "buffer ${"%.1f".format(bufS)} s",
        )
    }

    companion object {
        fun isHls(url: String): Boolean {
            val path = Uri.parse(url).path.orEmpty().lowercase()
            if (path.endsWith(".m3u8") || path.endsWith(".m3u")) return true
            if (Util.inferContentType(Uri.parse(url)) == C.CONTENT_TYPE_HLS) return true
            return url.lowercase().contains("m3u8")
        }

        /** Fehlermeldung ohne Zugangsdaten; HTTP-Status als „HTTP error 403“. */
        fun describe(e: PlaybackException): String {
            var c: Throwable? = e
            while (c != null) {
                if (c is HttpDataSource.InvalidResponseCodeException) {
                    return Redactor.redact("HTTP error ${c.responseCode} ${c.responseMessage ?: ""}".trim())
                }
                c = c.cause
            }
            val msg = when (e.errorCode) {
                PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT -> "Connection timed out"
                PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_FAILED -> "Failed to open: connection failed"
                PlaybackException.ERROR_CODE_DECODER_INIT_FAILED,
                PlaybackException.ERROR_CODE_DECODER_QUERY_FAILED,
                PlaybackException.ERROR_CODE_DECODING_FAILED,
                PlaybackException.ERROR_CODE_DECODING_FORMAT_EXCEEDS_CAPABILITIES,
                PlaybackException.ERROR_CODE_DECODING_FORMAT_UNSUPPORTED,
                -> "Decoder error (${e.errorCodeName}): ${e.cause?.message ?: e.message ?: ""}"
                PlaybackException.ERROR_CODE_AUDIO_TRACK_INIT_FAILED,
                PlaybackException.ERROR_CODE_AUDIO_TRACK_WRITE_FAILED,
                -> "Audio track / decoder error (${e.errorCodeName})"
                else -> "${e.errorCodeName}: ${e.cause?.message ?: e.message ?: ""}"
            }
            return Redactor.redact(msg)
        }
    }
}

/** Zähler für die Diagnose-Anzeige. */
class DebugStats {
    @Volatile var videoDecoder: String? = null
    @Volatile var audioDecoder: String? = null
    @Volatile var droppedFrames: Long = 0
    @Volatile var bandwidth: Long = 0

    fun reset() {
        droppedFrames = 0
    }
}
