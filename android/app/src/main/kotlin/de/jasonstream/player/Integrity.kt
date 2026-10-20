package de.jasonstream.player

import android.content.Context
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.os.Build
import android.os.Debug
import java.io.File
import java.security.MessageDigest

/**
 * Selbstschutz der App:
 * - Signatur-Prüfung: Wurde die APK verändert und neu signiert (z. B. mit
 *   eingebauter Schadsoftware), stimmt das Zertifikat nicht mehr.
 * - Hinweise auf Root, Debugger oder Debug-Build.
 */
object Integrity {
    fun check(ctx: Context): Map<String, Any> = mapOf(
        "signatureOk" to signatureOk(ctx),
        "rooted" to isRooted(),
        "debugger" to (Debug.isDebuggerConnected() || Debug.waitingForDebugger()),
        "debuggable" to ((ctx.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0),
    )

    private fun signatureOk(ctx: Context): Boolean {
        // keytool/apksigner geben „AB:CD:…“ aus – Trennzeichen ignorieren.
        val expected = BuildConfig.EXPECTED_SIG.filter { it.isLetterOrDigit() }.uppercase()
        if (expected.isEmpty()) return true // eigener Build ohne Release-Schlüssel
        return try {
            val certs: List<ByteArray> = if (Build.VERSION.SDK_INT >= 28) {
                val info = ctx.packageManager.getPackageInfo(
                    ctx.packageName, PackageManager.GET_SIGNING_CERTIFICATES
                )
                val si = info.signingInfo ?: return false
                // Bei Schlüsselwechsel (v3-Rotation) steht der Release-Schlüssel
                // in der Historie; mehrere Signierer → alle aktuellen prüfen.
                (if (si.hasMultipleSigners()) si.apkContentsSigners
                    else si.signingCertificateHistory).map { it.toByteArray() }
            } else {
                // Android 8: kennt keine Schlüssel-Rotation, sieht nur den
                // ursprünglichen Schlüssel (v2-Signatur).
                @Suppress("DEPRECATION")
                val info = ctx.packageManager.getPackageInfo(
                    ctx.packageName, PackageManager.GET_SIGNATURES
                )
                @Suppress("DEPRECATION")
                (info.signatures ?: return false).map { it.toByteArray() }
            }
            val ok = setOf(expected, ORIGINAL_SIG)
            certs.any { sha256(it) in ok }
        } catch (e: Exception) {
            false
        }
    }

    /** Ursprünglicher Schlüssel (vor dem Wechsel) – steht in der Rotation. */
    private const val ORIGINAL_SIG =
        "1F93C51C96BCD000EFFE599BB5F4BC446AC22E64CD9EA0794F77A9B1CEA3B68C"

    private fun sha256(b: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(b)
            .joinToString("") { "%02X".format(it) }

    private fun isRooted(): Boolean {
        if (Build.TAGS?.contains("test-keys") == true) return true
        val paths = listOf(
            "/system/bin/su", "/system/xbin/su", "/sbin/su", "/su/bin/su",
            "/system/sd/xbin/su", "/data/local/xbin/su", "/data/local/bin/su",
            "/system/app/Superuser.apk", "/data/adb/magisk", "/data/adb/ksu",
            "/system/bin/.ext/su",
        )
        if (paths.any { File(it).exists() }) return true
        return System.getenv("PATH")?.split(":")?.any { File(it, "su").exists() } == true
    }
}
