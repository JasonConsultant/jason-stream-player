package de.jasonstream.player

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import java.io.File

/** Selbst-Update: Android-Installer für eine heruntergeladene APK öffnen. */
object Updater {
    fun info(a: Activity): Map<String, Any?> {
        val pi = a.packageManager.getPackageInfo(a.packageName, 0)
        return mapOf(
            "version" to pi.versionName,
            "package" to a.packageName,
            "abis" to Build.SUPPORTED_ABIS.toList(),
            "universal" to isUniversal(a),
            "canInstall" to a.packageManager.canRequestPackageInstalls(),
            // Gerätename für Medienserver (Emby: „Device“).
            "model" to "${Build.MANUFACTURER} ${Build.MODEL}".trim(),
        )
    }

    /**
     * Installierte APK enthält 32- und 64-Bit-Bibliotheken (TV-Build)?
     * Dann muss das Update wieder die TV-APK sein: Die Split-APKs tragen
     * einen um 1000/2000 erhöhten versionCode – nach einem Split-Update
     * ließe sich keine TV-APK mehr darüber installieren (Downgrade).
     */
    private fun isUniversal(a: Activity): Boolean = try {
        java.util.zip.ZipFile(a.applicationInfo.sourceDir).use { z ->
            var v7 = false
            var v8 = false
            val en = z.entries()
            while (en.hasMoreElements() && !(v7 && v8)) {
                val n = en.nextElement().name
                if (n.startsWith("lib/armeabi-v7a/")) v7 = true
                else if (n.startsWith("lib/arm64-v8a/")) v8 = true
            }
            v7 && v8
        }
    } catch (e: Exception) {
        false
    }

    /** Einstellung „Unbekannte Apps installieren“ für diese App öffnen. */
    fun requestInstallPermission(a: Activity) {
        try {
            a.startActivity(
                Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES)
                    .setData(Uri.parse("package:${a.packageName}"))
            )
        } catch (e: Exception) {
            // Manche TV-Boxen haben diese Seite nicht → allgemeine Einstellungen.
            try {
                a.startActivity(Intent(Settings.ACTION_SECURITY_SETTINGS))
            } catch (e2: Exception) {
                a.startActivity(Intent(Settings.ACTION_SETTINGS))
            }
        }
    }

    /**
     * Installer starten. Android prüft dabei selbst, dass die neue APK mit
     * demselben Schlüssel signiert ist – eine fremde APK kann die App nicht
     * ersetzen.
     */
    fun install(a: Activity, path: String): Boolean {
        val dir = File(a.cacheDir, "updates").canonicalFile
        val f = File(path).canonicalFile
        if (!f.path.startsWith(dir.path) || !f.exists()) return false
        val uri = FileProvider.getUriForFile(a, "${a.packageName}.updates", f)
        a.startActivity(
            Intent(Intent.ACTION_VIEW)
                .setDataAndType(uri, "application/vnd.android.package-archive")
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        )
        return true
    }
}
