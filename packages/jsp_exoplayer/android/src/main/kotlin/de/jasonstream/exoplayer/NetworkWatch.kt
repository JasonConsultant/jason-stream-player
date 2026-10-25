package de.jasonstream.exoplayer

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Art der Verbindung (für den Datensparmodus). */
internal data class NetState(val connected: Boolean, val metered: Boolean, val cellular: Boolean) {
    fun toMap(): Map<String, Any?> = mapOf("connected" to connected, "metered" to metered, "cellular" to cellular)

    companion object {
        val NONE = NetState(connected = false, metered = false, cellular = false)

        /** Aus den Fähigkeiten: gemessen = ohne NOT_METERED (bzw. Mobilfunk). */
        fun of(notMetered: Boolean, cellular: Boolean) =
            NetState(connected = true, metered = !notMetered, cellular = cellular)
    }
}

/**
 * Standard-Netz beobachten (ConnectivityManager): Kanal
 * „de.jasonstream/network“ (Methode „status“) und Ereignisse
 * „de.jasonstream/network/events“ bei jeder Änderung.
 */
internal class NetworkWatch(context: Context, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private val cm = context.applicationContext.getSystemService(ConnectivityManager::class.java)
    private val main = Handler(Looper.getMainLooper())
    private val method = MethodChannel(messenger, "de.jasonstream/network")
    private val events = EventChannel(messenger, "de.jasonstream/network/events")
    private var sink: EventChannel.EventSink? = null
    private var registered = false
    private var last: NetState? = null

    init {
        method.setMethodCallHandler(this)
        events.setStreamHandler(this)
    }

    fun dispose() {
        unregister()
        method.setMethodCallHandler(null)
        events.setStreamHandler(null)
    }

    private fun current(): NetState {
        val c = cm ?: return NetState.NONE
        return try {
            val n = c.activeNetwork ?: return NetState.NONE
            val caps = c.getNetworkCapabilities(n) ?: return NetState.NONE
            fromCaps(caps)
        } catch (_: Exception) {
            NetState.NONE
        }
    }

    private fun fromCaps(caps: NetworkCapabilities) = NetState.of(
        notMetered = caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED) ||
            caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_TEMPORARILY_NOT_METERED),
        cellular = caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR),
    )

    private fun emit(s: NetState) {
        main.post {
            if (s == last) return@post
            last = s
            sink?.success(s.toMap())
        }
    }

    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) = emit(fromCaps(caps))
        override fun onLost(network: Network) = emit(current())
        override fun onAvailable(network: Network) = emit(current())
    }

    private fun register() {
        if (registered) return
        try {
            cm?.registerDefaultNetworkCallback(callback)
            registered = true
        } catch (_: Exception) {
        }
    }

    private fun unregister() {
        if (!registered) return
        try {
            cm?.unregisterNetworkCallback(callback)
        } catch (_: Exception) {
        }
        registered = false
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
        last = null
        register()
        emit(current())
    }

    override fun onCancel(arguments: Any?) {
        sink = null
        unregister()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "status" -> result.success(current().toMap())
            else -> result.notImplemented()
        }
    }
}
