package de.jasonstream.player

import android.app.PictureInPictureParams
import android.app.UiModeManager
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.os.Build
import android.util.Rational
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
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
                    "integrity" -> result.success(Integrity.check(this))
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

    private fun isTelevision(): Boolean {
        val ui = getSystemService(Context.UI_MODE_SERVICE) as UiModeManager
        if (ui.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION) return true
        return packageManager.hasSystemFeature("android.software.leanback")
    }
}
