package de.jasonstream.playback.ui

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.os.Build
import android.view.Display
import de.jasonstream.playback.logic.DisplayModeInfo
import de.jasonstream.playback.logic.FrameRateMatch

/**
 * Automatische Bildwiederholrate (AFR) – Port von MainActivity.setFrameRate
 * der Flutter-App: Anzeigemodus gleicher Auflösung wählen, dessen Hz ein
 * ganzzahliges Vielfaches der Bildrate ist (25 → 50 Hz, 23,976 → 23,976 Hz).
 * fps = 0 setzt auf den Standard zurück.
 */
internal object Afr {
    fun apply(activity: Activity?, fps: Double): Boolean {
        val a = activity ?: return false
        val display: Display = (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) a.display else null)
            ?: @Suppress("DEPRECATION") a.windowManager.defaultDisplay
            ?: return false
        val attrs = a.window.attributes
        if (fps <= 0.0) {
            if (attrs.preferredDisplayModeId != 0) {
                attrs.preferredDisplayModeId = 0
                a.window.attributes = attrs
            }
            return true
        }
        val cur = display.mode
        fun info(m: Display.Mode) = DisplayModeInfo(m.modeId, m.physicalWidth, m.physicalHeight, m.refreshRate)
        val best = FrameRateMatch.pick(info(cur), display.supportedModes.map(::info), fps) ?: return false
        if (best.id == cur.modeId) return true
        attrs.preferredDisplayModeId = best.id
        a.window.attributes = attrs
        return true
    }
}

internal tailrec fun Context.findActivity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.findActivity()
    else -> null
}
