package de.jasonstream.player.update

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import androidx.core.content.FileProvider
import de.jasonstream.core.model.RepositoryException
import de.jasonstream.data.net.Net
import de.jasonstream.player.BuildConfig
import de.jasonstream.player.logic.UpdateInfo
import de.jasonstream.player.logic.UpdateLogic
import java.io.File

/**
 * Selbst-Update über GitHub-Releases (Port von updater.dart + Updater.kt der
 * Flutter-App): neueste Version abfragen, TV-APK laden, Android-Installer
 * öffnen. Android installiert nur mit gleichem Signaturschlüssel.
 * Alle Funktionen außer [install]/[requestInstallPermission] blockieren (IO).
 */
object Updater {
    /** Ergebnis der Prüfung. */
    sealed interface Check {
        data object UpToDate : Check
        data object Busy : Check
        data class Available(val info: UpdateInfo) : Check
        data class Failed(val message: String) : Check
    }

    /** Test-Build (tvtest): Updater komplett aus – nie eine APK laden oder installieren. */
    val enabled: Boolean get() = BuildConfig.UPDATER_ENABLED

    fun check(ctx: Context, current: String = BuildConfig.VERSION_NAME): Check = if (!enabled) Check.UpToDate else try {
        val body = Net.get(UpdateLogic.LATEST_URL, mapOf("Accept" to "application/vnd.github+json"), maxBytes = 1L shl 20)
        UpdateLogic.parseLatest(String(body, Charsets.UTF_8), current, ctx.packageName)
            ?.let { Check.Available(it) } ?: Check.UpToDate
    } catch (e: RepositoryException) {
        when (e.statusCode) {
            404 -> Check.UpToDate // noch keine Veröffentlichung
            403, 429 -> Check.Busy // GitHub begrenzt anonyme Abfragen
            else -> Check.Failed(e.message ?: "?")
        }
    } catch (e: Exception) {
        Check.Failed(e.message ?: e.javaClass.simpleName)
    }

    fun canInstall(ctx: Context) = ctx.packageManager.canRequestPackageInstalls()

    /** Einstellung „Unbekannte Apps installieren“ für diese App öffnen. */
    fun requestInstallPermission(ctx: Context) {
        val tries = listOf(
            Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES).setData(Uri.parse("package:${ctx.packageName}")),
            Intent(Settings.ACTION_SECURITY_SETTINGS),
            Intent(Settings.ACTION_SETTINGS),
        )
        for (i in tries) {
            if (runCatching { ctx.startActivity(i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }.isSuccess) return
        }
    }

    private fun dir(ctx: Context) = File(ctx.cacheDir, "updates").also { it.mkdirs() }

    /** APK herunterladen (Fortschritt 0–100). */
    fun download(ctx: Context, u: UpdateInfo, onProgress: (Int) -> Unit): File {
        check(enabled) { "Updater disabled" }
        val f = File(dir(ctx), "update.apk")
        Net.open(u.apkUrl, timeoutMs = 60_000, maxBytes = 200L shl 20).use { body ->
            val total = body.declaredLength ?: u.size.takeIf { it > 0 }
            f.outputStream().use { out ->
                val buf = ByteArray(64 * 1024)
                var n = 0L
                var last = -1
                val input = body.source.inputStream()
                while (true) {
                    val r = input.read(buf)
                    if (r < 0) break
                    out.write(buf, 0, r)
                    n += r
                    if (total != null) {
                        val p = (n * 100 / total).toInt().coerceIn(0, 100)
                        if (p != last) { last = p; onProgress(p) }
                    }
                }
            }
        }
        return f
    }

    /** Installer starten (nur Dateien aus dem Update-Ordner). */
    fun install(ctx: Context, f: File): Boolean {
        if (!enabled) return false
        val d = dir(ctx).canonicalFile
        val file = f.canonicalFile
        if (!file.path.startsWith(d.path) || !file.exists()) return false
        val uri = FileProvider.getUriForFile(ctx, "${ctx.packageName}.updates", file)
        ctx.startActivity(
            Intent(Intent.ACTION_VIEW)
                .setDataAndType(uri, "application/vnd.android.package-archive")
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK),
        )
        return true
    }
}
