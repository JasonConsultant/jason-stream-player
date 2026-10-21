package de.jasonstream.player

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri

/** Trailer in der YouTube-App öffnen (TV: YouTube für Android TV), sonst im Browser. */
object Trailer {
    private val idPattern = Regex("^[A-Za-z0-9_-]{11}$")

    fun open(activity: Activity, id: String?, tv: Boolean): Boolean {
        if (id == null || !idPattern.matches(id)) return false
        val web = Uri.parse("https://www.youtube.com/watch?v=$id")
        val attempts = mutableListOf<Intent>()
        if (tv) {
            attempts += Intent(Intent.ACTION_VIEW, web).setPackage("com.google.android.youtube.tv")
            attempts += Intent(Intent.ACTION_VIEW, web).setPackage("com.google.android.youtube.googletv")
        }
        attempts += Intent(Intent.ACTION_VIEW, Uri.parse("vnd.youtube:$id"))
        attempts += Intent(Intent.ACTION_VIEW, web)
        for (i in attempts) {
            try {
                activity.startActivity(i)
                return true
            } catch (e: ActivityNotFoundException) {
            } catch (e: SecurityException) {
            }
        }
        return false
    }
}
