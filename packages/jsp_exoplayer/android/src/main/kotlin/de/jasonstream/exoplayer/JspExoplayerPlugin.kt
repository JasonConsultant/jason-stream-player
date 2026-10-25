package de.jasonstream.exoplayer

import android.content.Context
import android.os.Build
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import okhttp3.OkHttpClient

/**
 * Kanal „de.jasonstream/exoplayer“: legt Player an (je Player eine Textur und
 * ein Ereigniskanal „…/events/<id>“) und reicht Befehle weiter.
 */
class JspExoplayerPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private var context: Context? = null
    private var textures: TextureRegistry? = null
    private var messenger: BinaryMessenger? = null
    private val sessions = HashMap<Long, ExoSession>()
    private var nextId = 1L
    private val client: OkHttpClient by lazy { ExoSession.newClient() }
    private var cast: CastBridge? = null
    private var network: NetworkWatch? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        textures = binding.textureRegistry
        messenger = binding.binaryMessenger
        channel = MethodChannel(binding.binaryMessenger, "de.jasonstream/exoplayer").also {
            it.setMethodCallHandler(this)
        }
        // Chromecast (nur auf Anfrage aktiv) und Verbindungsart (Datensparmodus).
        cast = CastBridge(binding.applicationContext, binding.binaryMessenger)
        network = NetworkWatch(binding.applicationContext, binding.binaryMessenger)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        for (s in sessions.values) s.dispose()
        sessions.clear()
        cast?.dispose()
        cast = null
        network?.dispose()
        network = null
        channel?.setMethodCallHandler(null)
        channel = null
        context = null
        textures = null
        messenger = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            handle(call, result)
        } catch (e: Exception) {
            result.error("exo", Redact.text(e.message ?: e.javaClass.simpleName), null)
        }
    }

    private fun session(call: MethodCall): ExoSession? =
        call.argument<Number>("id")?.toLong()?.let { sessions[it] }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "create" -> {
                val ctx = context ?: return result.error("exo", "not attached", null)
                val tex = textures ?: return result.error("exo", "not attached", null)
                val msg = messenger ?: return result.error("exo", "not attached", null)
                val id = nextId++
                val s = ExoSession(ctx, id, tex.createSurfaceProducer(), msg, client)
                sessions[id] = s
                result.success(mapOf("id" to id, "textureId" to s.textureId))
            }
            "open" -> {
                val s = session(call) ?: return result.success(null)
                val url = call.argument<String>("url") ?: return result.error("exo", "url missing", null)
                @Suppress("UNCHECKED_CAST")
                val headers = (call.argument<Map<String, Any?>>("headers") ?: emptyMap())
                    .mapValues { it.value?.toString() }
                @Suppress("UNCHECKED_CAST")
                val subs = (call.argument<List<Map<String, Any?>>>("subtitles") ?: emptyList()).mapNotNull {
                    val u = it["url"] as? String ?: return@mapNotNull null
                    SideSubtitle(u, it["language"] as? String, it["label"] as? String, it["codec"] as? String)
                }
                val config = BuildConfig(
                    plan = BufferPlan.of(
                        bufferBytes = call.argument<Number>("bufferBytes")?.toInt() ?: (48 shl 20),
                        backBytes = call.argument<Number>("backBytes")?.toInt() ?: 0,
                        forwardBytes = call.argument<Number>("forwardBytes")?.toInt() ?: 0,
                        careful = call.argument<Boolean>("careful") ?: false,
                    ),
                    softwareVideo = call.argument<Boolean>("softwareVideo") ?: false,
                    passthrough = call.argument<Boolean>("passthrough") ?: false,
                )
                val limit = VideoLimit.of(
                    maxBitrate = call.argument<Number>("maxVideoBitrate")?.toInt() ?: 0,
                    maxHeight = call.argument<Number>("maxVideoHeight")?.toInt() ?: 0,
                )
                s.open(
                    url = url,
                    rawHeaders = headers,
                    live = call.argument<Boolean>("live") ?: false,
                    startMs = call.argument<Number>("startMs")?.toLong() ?: 0L,
                    play = call.argument<Boolean>("play") ?: true,
                    subtitles = subs,
                    config = config,
                    limit = limit,
                )
                result.success(null)
            }
            "play" -> { session(call)?.play(); result.success(null) }
            "pause" -> { session(call)?.pause(); result.success(null) }
            "stop" -> { session(call)?.stop(); result.success(null) }
            "seek" -> {
                session(call)?.seek(call.argument<Number>("ms")?.toLong() ?: 0L)
                result.success(null)
            }
            "setVolume" -> {
                session(call)?.setVolume(call.argument<Number>("volume")?.toDouble() ?: 1.0)
                result.success(null)
            }
            "setVideoEnabled" -> {
                session(call)?.setVideoEnabled(call.argument<Boolean>("enabled") ?: true)
                result.success(null)
            }
            "selectTrack" -> {
                session(call)?.selectTrack(
                    call.argument<String>("type") ?: "audio",
                    call.argument<String>("track") ?: "auto",
                )
                result.success(null)
            }
            "stats" -> result.success(session(call)?.stats() ?: emptyMap<String, Any?>())
            "dispose" -> {
                val id = call.argument<Number>("id")?.toLong()
                if (id != null) sessions.remove(id)?.dispose()
                result.success(null)
            }
            "info" -> result.success(mapOf("sdk" to Build.VERSION.SDK_INT, "players" to sessions.size))
            else -> result.notImplemented()
        }
    }
}
