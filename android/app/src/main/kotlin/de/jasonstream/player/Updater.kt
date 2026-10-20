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
            "canInstall" to a.packageManager.canRequestPackageInstalls(),
        )
    }

    /** Einstellung „Unbekannte Apps installieren“ für diese App öffnen. */
    fun requestInstallPermission(a: Activity) {
        a.startActivity(
            Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES)
                .setData(Uri.parse("package:${a.packageName}"))
        )
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
