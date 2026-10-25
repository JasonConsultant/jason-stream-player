package de.jasonstream.player

import android.app.PictureInPictureParams
import android.app.UiModeManager
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.os.Build
import android.util.Rational
import android.view.WindowManager
import com.ryanheise.audioservice.AudioServiceFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// AudioServiceFragmentActivity = FlutterFragmentActivity mit der von
// audio_service geteilten Flutter-Engine (Medien-Benachrichtigung).
class MainActivity : AudioServiceFragmentActivity() {
    private val channel = "de.jasonstream.player/platform"
    private var autoPip = false
    private var platformChannel: MethodChannel? = null
    /** Startaktion aus einer Benachrichtigung (z. B. Erinnerung → Sender abspielen). */
    private var pendingLaunch: Map<String, String>? = null
    private var launchRead = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        SecureBox.register(flutterEngine.dartExecutor.binaryMessenger)
        RecBridge.register(flutterEngine.dartExecutor.binaryMessenger, this)
        DownloadBridge.register(flutterEngine.dartExecutor.binaryMessenger, this)
        ReminderBridge.register(flutterEngine.dartExecutor.binaryMessenger, this)
        platformChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channel)
        platformChannel!!
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "takeLaunchAction" -> {
                        if (!launchRead) {
                            launchRead = true
                            if (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY == 0) {
                                readLaunch(intent)?.let { pendingLaunch = it }
                            }
                        }
                        result.success(pendingLaunch)
                        pendingLaunch = null
                    }
                    "isTv" -> result.success(isTelevision())
                    "tvSync" -> TvChannels.syncAsync(this, call.argument<String>("name"),
                        call.argument<List<Map<String, Any?>>>("items"), result)
                    "tvClear" -> TvChannels.clearAsync(this, result)
                    "integrity" -> result.success(Integrity.check(this))
                    "pickPlaylist" -> pickPlaylist(result)
                    "saveFile" -> FileIO.saveFile(this, call.argument<String>("name") ?: "backup.bin", call.argument<String>("mime") ?: "application/octet-stream", call.argument<ByteArray>("bytes") ?: ByteArray(0), result)
                    "openFile" -> FileIO.openFile(this, result)
                    "voiceAvailable" -> result.success(VoiceSearch.available(this))
                    "voiceSearch" -> VoiceSearch.start(this, call.argument<String>("lang"),
                        call.argument<String>("prompt"), result)
                    "pickRecTree" -> RecStorage.pickTree(this, result)
                    "recTreeInfo" -> recTreeCall(result) { RecStorage.info(this, call.argument<String>("uri") ?: "") }
                    "listRecTree" -> recTreeCall(result) { RecStorage.listRecordings(this, android.net.Uri.parse(call.argument<String>("uri")!!)) }
                    "deleteRecDoc" -> recTreeCall(result) { RecStorage.deleteRecording(this, android.net.Uri.parse(call.argument<String>("uri")!!)) }
                    "appInfo" -> result.success(Updater.info(this))
                    "updateDir" -> result.success(
                        java.io.File(cacheDir, "updates").apply { mkdirs() }.path)
                    "requestInstallPermission" -> {
                        Updater.requestInstallPermission(this); result.success(null)
                    }
                    "installApk" -> result.success(
                        Updater.install(this, call.argument<String>("path") ?: ""))
                    "setSecure" -> {
                        if (call.argument<Boolean>("on") == true) {
                            window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        } else {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        }
                        result.success(null)
                    }
                    "enterPip" -> {
                        val w = call.argument<Int>("w") ?: 16
                        val h = call.argument<Int>("h") ?: 9
                        result.success(enterPip(w, h))
                    }
                    "setFrameRate" -> {
                        result.success(setFrameRate(call.argument<Double>("fps") ?: 0.0))
                    }
                    "memInfo" -> {
                        // Für den Live-Puffer (Timeshift): freier Arbeitsspeicher.
                        val am = getSystemService(Context.ACTIVITY_SERVICE) as android.app.ActivityManager
                        val mi = android.app.ActivityManager.MemoryInfo()
                        am.getMemoryInfo(mi)
                        result.success(mapOf(
                            "avail" to mi.availMem,
                            "total" to mi.totalMem,
                            "lowRam" to (am.isLowRamDevice || mi.lowMemory),
                            "heapMb" to am.largeMemoryClass
                        ))
                    }
                    "openTrailer" -> result.success(
                        Trailer.open(this, call.argument<String>("id"), isTelevision()))
                    "setAutoPip" -> {
                        autoPip = call.argument<Boolean>("enabled") ?: false
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && !isTelevision()) {
                            setPictureInPictureParams(
                                PictureInPictureParams.Builder()
                                    .setAspectRatio(Rational(16, 9))
                                    .setAutoEnterEnabled(autoPip)
                                    .build()
                            )
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val a = readLaunch(intent) ?: return
        launchRead = true
        pendingLaunch = a
        platformChannel?.invokeMethod("launchActionAvailable", null)
    }

    private fun readLaunch(i: Intent): Map<String, String>? {
        // Deep-Link vom TV-Startbildschirm (jsp://play?channel=X&portal=Y)
        // auf denselben Mechanismus wie Benachrichtigungen abbilden.
        val data = i.data
        if (data != null && data.scheme == "jsp" && data.host == "play") {
            i.data = null
            val ch = data.getQueryParameter("channel") ?: ""
            if (ch.isEmpty()) return null
            return mapOf(
                "action" to "play",
                "channel" to ch,
                "portal" to (data.getQueryParameter("portal") ?: ""),
            )
        }
        val action = i.getStringExtra("jsp_action") ?: return null
        val m = mapOf(
            "action" to action,
            "channel" to (i.getStringExtra("jsp_channel") ?: ""),
            "portal" to (i.getStringExtra("jsp_portal") ?: ""),
        )
        i.removeExtra("jsp_action")
        return m
    }

    /// Android 10/11: beim Drücken der Home-Taste selbst in PiP wechseln.
    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (autoPip && Build.VERSION.SDK_INT < Build.VERSION_CODES.S && !isTelevision()) {
            enterPip(16, 9)
        }
    }

    private fun enterPip(w: Int, h: Int): Boolean {
        if (!packageManager.hasSystemFeature("android.software.picture_in_picture")) return false
        return try {
            enterPictureInPictureMode(
                PictureInPictureParams.Builder().setAspectRatio(Rational(w, h)).build()
            )
        } catch (e: Exception) {
            false
        }
    }

    /**
     * Automatische Bildwiederholrate (AFR): passenden Anzeigemodus mit
     * gleicher Auflösung wählen, dessen Hz ein ganzzahliges Vielfaches der
     * Bildrate ist (25 → 50 Hz, 23,976 → 23,976/47,95 Hz, 30 → 60 Hz).
     * fps = 0 setzt auf den Standard zurück.
     */
    private fun setFrameRate(fps: Double): Boolean {
        val display = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) display else
            @Suppress("DEPRECATION") windowManager.defaultDisplay
        display ?: return false
        val attrs = window.attributes
        if (fps <= 0.0) {
            if (attrs.preferredDisplayModeId != 0) {
                attrs.preferredDisplayModeId = 0
                window.attributes = attrs
            }
            return true
        }
        val current = display.mode
        val candidates = display.supportedModes.filter {
            it.physicalWidth == current.physicalWidth && it.physicalHeight == current.physicalHeight
        }
        fun score(hz: Float): Double {
            val ratio = hz / fps
            val mult = Math.round(ratio)
            if (mult < 1 || mult > 4) return Double.MAX_VALUE
            // Abweichung vom Vielfachen + kleiner Bonus für niedrigere Vielfache
            return Math.abs(ratio - mult) * 100 + mult * 0.01
        }
        val best = candidates.minByOrNull { score(it.refreshRate) } ?: return false
        if (score(best.refreshRate) > 0.5) return false // nichts Passendes
        if (best.modeId == current.modeId) return true
        attrs.preferredDisplayModeId = best.modeId
        window.attributes = attrs
        return true
    }

    // ---------- M3U-Datei vom Gerät ----------
    private var pickResult: MethodChannel.Result? = null
    private val pickRequest = 4711

    private fun pickPlaylist(result: MethodChannel.Result) {
        pickResult?.success(null)
        pickResult = result
        try {
            @Suppress("DEPRECATION")
            startActivityForResult(
                android.content.Intent(android.content.Intent.ACTION_OPEN_DOCUMENT)
                    .addCategory(android.content.Intent.CATEGORY_OPENABLE)
                    .setType("*/*"),
                pickRequest
            )
        } catch (e: Exception) {
            pickResult = null
            result.error("nopicker", "Kein Dateiauswahl-Dialog verfügbar", null)
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: android.content.Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        if (RecStorage.onActivityResult(this, requestCode, resultCode, data)) return // 4720: Aufnahme-Ordner
        if (FileIO.onActivityResult(this, requestCode, resultCode, data)) return
        if (VoiceSearch.onActivityResult(requestCode, resultCode, data)) return
        if (requestCode != pickRequest) return
        val result = pickResult ?: return
        pickResult = null
        val uri = data?.data
        if (resultCode != RESULT_OK || uri == null) {
            result.success(null); return
        }
        Thread {
            try {
                // Kopie im App-Ordner: bleibt lesbar, auch wenn die Original-
                // Datei verschoben wird, und kein Dauer-Zugriff nötig.
                val dir = java.io.File(filesDir, "playlists").apply { mkdirs() }
                val out = java.io.File(dir, java.util.UUID.randomUUID().toString() + ".m3u")
                var total = 0L
                contentResolver.openInputStream(uri)!!.use { input ->
                    out.outputStream().use { o ->
                        val buf = ByteArray(64 * 1024)
                        while (true) {
                            val n = input.read(buf)
                            if (n < 0) break
                            total += n
                            if (total > 80L * 1024 * 1024) throw IllegalStateException("too large")
                            o.write(buf, 0, n)
                        }
                    }
                }
                var name: String? = null
                contentResolver.query(uri, null, null, null, null)?.use { c ->
                    val i = c.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
                    if (i >= 0 && c.moveToFirst()) name = c.getString(i)
                }
                runOnUiThread { result.success(mapOf("path" to out.path, "name" to name)) }
            } catch (e: Exception) {
                runOnUiThread { result.error("read", e.javaClass.simpleName, null) }
            }
        }.start()
    }

    /** SAF-Zugriffe (Netzlaufwerk!) können dauern → nicht im UI-Thread. */
    private fun recTreeCall(result: MethodChannel.Result, f: () -> Any?) {
        Thread {
            try {
                val v = f()
                runOnUiThread { result.success(v) }
            } catch (e: Exception) {
                runOnUiThread { result.error("rectree", e.javaClass.simpleName, null) }
            }
        }.start()
    }

    private fun isTelevision(): Boolean {
        val ui = getSystemService(Context.UI_MODE_SERVICE) as UiModeManager
        if (ui.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION) return true
        if (packageManager.hasSystemFeature("android.software.leanback")) return true
        // Manche Boxen melden weder TV-Modus noch Leanback: kein Touchscreen
        // + großer Bildschirm → Fernseher.
        val noTouch = !packageManager.hasSystemFeature("android.hardware.touchscreen")
        val large = (resources.configuration.screenLayout and
            Configuration.SCREENLAYOUT_SIZE_MASK) >= Configuration.SCREENLAYOUT_SIZE_LARGE
        return noTouch && large
    }
}
