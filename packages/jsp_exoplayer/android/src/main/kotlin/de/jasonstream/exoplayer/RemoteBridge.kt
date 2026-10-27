package de.jasonstream.exoplayer

import android.content.Context
import android.media.AudioManager
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.net.Inet4Address
import java.net.InetAddress

/** Reine Hilfen (JVM-testbar) für die Ankündigung per mDNS/NSD. */
internal object RemoteLogic {
    const val SERVICE_TYPE = "_jsp-remote._tcp"

    /**
     * Dienstname für mDNS: höchstens 63 Bytes UTF-8, ohne Punkte und
     * Steuerzeichen (sonst lehnt NsdManager ab oder kürzt mitten im Zeichen).
     */
    fun serviceName(raw: String): String {
        val clean = raw.replace(Regex("[\\p{Cntrl}.]"), " ").replace(Regex("\\s+"), " ").trim()
        val base = clean.ifEmpty { "Jason Stream Player" }
        val sb = StringBuilder()
        var bytes = 0
        var i = 0
        while (i < base.length) {
            val cp = base.codePointAt(i)
            val s = String(Character.toChars(cp))
            val n = s.toByteArray(Charsets.UTF_8).size
            if (bytes + n > 63) break
            sb.append(s)
            bytes += n
            i += Character.charCount(cp)
        }
        return sb.toString().trim()
    }

    /** TXT-Einträge: nur kurze, druckbare Werte bekannter Schlüssel. */
    fun attrs(raw: Map<String, ByteArray?>): Map<String, String> {
        val out = HashMap<String, String>()
        for (k in listOf("id", "v")) {
            val v = raw[k] ?: continue
            if (v.size > 64) continue
            val s = String(v, Charsets.UTF_8)
            if (s.all { it.code in 0x21..0x7e }) out[k] = s
        }
        return out
    }

    /** Dienst-Typ, wie NsdManager ihn in Fundmeldungen liefert (mit Punkt). */
    fun sameType(found: String?): Boolean =
        found != null && found.trimEnd('.').removeSuffix(".local") == SERVICE_TYPE
}

/**
 * Handy als Fernbedienung (ab 2.4) – Kanal „de.jasonstream/remote“:
 *
 * - register/unregister: Fernseher kündigt seinen Dienst im WLAN an
 *   (Android NsdManager = mDNS/DNS-SD, kein UPnP, keine Port-Weiterleitung).
 * - discover/stopDiscover: Handy sucht Fernseher; Funde gehen als
 *   Ereignisse über „de.jasonstream/remote/events“ (found/lost).
 * - volume/volumeInfo: Lautstärke des Fernsehers (STREAM_MUSIC), sofern
 *   das Gerät sie nicht fest vorgibt (isVolumeFixed – z. B. HDMI-CEC-Boxen).
 */
internal class RemoteBridge(context: Context, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private val nsd = context.applicationContext.getSystemService(Context.NSD_SERVICE) as? NsdManager
    private val audio = context.applicationContext.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
    private val main = Handler(Looper.getMainLooper())
    private val method = MethodChannel(messenger, "de.jasonstream/remote")
    private val events = EventChannel(messenger, "de.jasonstream/remote/events")
    private var sink: EventChannel.EventSink? = null

    private var registration: NsdManager.RegistrationListener? = null
    private var discovery: NsdManager.DiscoveryListener? = null

    /** NsdManager löst nur einen Dienst gleichzeitig auf → Warteschlange. */
    private val resolveQueue = ArrayDeque<NsdServiceInfo>()
    private var resolving = false

    init {
        method.setMethodCallHandler(this)
        events.setStreamHandler(this)
    }

    fun dispose() {
        unregister()
        stopDiscovery()
        method.setMethodCallHandler(null)
        events.setStreamHandler(null)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    private fun emit(m: Map<String, Any?>) = main.post { sink?.success(m) }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "register" -> register(call, result)
                "unregister" -> { unregister(); result.success(null) }
                "discover" -> { startDiscovery(); result.success(nsd != null) }
                "stopDiscover" -> { stopDiscovery(); result.success(null) }
                "volume" -> result.success(volume(call.argument<Number>("dir")?.toInt() ?: 0))
                "volumeInfo" -> result.success(mapOf("controllable" to volumeControllable()))
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("remote", e.javaClass.simpleName, null)
        }
    }

    // ------------------------------------------------------------ Ankündigen

    private fun register(call: MethodCall, result: MethodChannel.Result) {
        val m = nsd ?: return result.error("remote", "nsd", null)
        unregister()
        val port = call.argument<Number>("port")?.toInt() ?: return result.error("remote", "port", null)
        val info = NsdServiceInfo().apply {
            serviceName = RemoteLogic.serviceName(call.argument<String>("name") ?: "")
            serviceType = RemoteLogic.SERVICE_TYPE
            setPort(port)
            val attrs = call.argument<Map<String, String>>("attrs") ?: emptyMap()
            for ((k, v) in attrs) {
                if (k in setOf("id", "v") && v.length <= 64) setAttribute(k, v)
            }
        }
        var answered = false
        val l = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(si: NsdServiceInfo) {
                main.post {
                    if (!answered) { answered = true; result.success(si.serviceName) }
                }
            }

            override fun onRegistrationFailed(si: NsdServiceInfo, errorCode: Int) {
                main.post {
                    if (registration === this) registration = null
                    if (!answered) { answered = true; result.error("remote", "register $errorCode", null) }
                }
            }

            override fun onServiceUnregistered(si: NsdServiceInfo) {}
            override fun onUnregistrationFailed(si: NsdServiceInfo, errorCode: Int) {}
        }
        registration = l
        m.registerService(info, NsdManager.PROTOCOL_DNS_SD, l)
    }

    private fun unregister() {
        val l = registration ?: return
        registration = null
        runCatching { nsd?.unregisterService(l) }
    }

    // ------------------------------------------------------------ Suchen

    private fun startDiscovery() {
        val m = nsd ?: return
        if (discovery != null) return
        val l = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) {}
            override fun onDiscoveryStopped(serviceType: String) {}

            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                main.post {
                    if (discovery === this) discovery = null
                    emit(mapOf("type" to "error", "code" to errorCode))
                }
            }

            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}

            override fun onServiceFound(si: NsdServiceInfo) {
                if (!RemoteLogic.sameType(si.serviceType)) return
                main.post { enqueueResolve(si) }
            }

            override fun onServiceLost(si: NsdServiceInfo) {
                emit(mapOf("type" to "lost", "name" to si.serviceName))
            }
        }
        discovery = l
        m.discoverServices(RemoteLogic.SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, l)
    }

    private fun stopDiscovery() {
        val l = discovery ?: return
        discovery = null
        resolveQueue.clear()
        runCatching { nsd?.stopServiceDiscovery(l) }
    }

    private fun enqueueResolve(si: NsdServiceInfo) {
        if (resolveQueue.any { it.serviceName == si.serviceName }) return
        resolveQueue.addLast(si)
        nextResolve()
    }

    @Suppress("DEPRECATION")
    private fun nextResolve() {
        val m = nsd ?: return
        if (resolving || discovery == null) return
        val si = resolveQueue.removeFirstOrNull() ?: return
        resolving = true
        m.resolveService(si, object : NsdManager.ResolveListener {
            override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) {
                main.post { resolving = false; nextResolve() }
            }

            override fun onServiceResolved(info: NsdServiceInfo) {
                val host: InetAddress? = info.host
                val addr = host?.hostAddress
                val attrs = RemoteLogic.attrs(info.attributes ?: emptyMap())
                if (addr != null) {
                    emit(
                        mapOf(
                            "type" to "found",
                            "name" to info.serviceName,
                            "host" to addr,
                            "ipv4" to (host is Inet4Address),
                            "port" to info.port,
                            "attrs" to attrs,
                        ),
                    )
                }
                main.post { resolving = false; nextResolve() }
            }
        })
    }

    // ------------------------------------------------------------ Lautstärke

    private fun volumeControllable(): Boolean {
        val a = audio ?: return false
        return !a.isVolumeFixed
    }

    private fun volume(dir: Int): Boolean {
        val a = audio ?: return false
        if (a.isVolumeFixed) return false
        val adj = when {
            dir > 0 -> AudioManager.ADJUST_RAISE
            dir < 0 -> AudioManager.ADJUST_LOWER
            else -> AudioManager.ADJUST_TOGGLE_MUTE
        }
        a.adjustStreamVolume(AudioManager.STREAM_MUSIC, adj, AudioManager.FLAG_SHOW_UI)
        return true
    }
}
