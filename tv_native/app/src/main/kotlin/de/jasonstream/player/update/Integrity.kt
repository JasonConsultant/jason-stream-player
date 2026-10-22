package de.jasonstream.player.update

import android.content.Context
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.os.Build
import android.os.Debug
import de.jasonstream.player.BuildConfig
import java.io.File
import java.security.MessageDigest

/**
 * Selbstschutz (Port von Integrity.kt der Flutter-App):
 * - Signatur: veränderte, neu signierte APK → Zertifikat passt nicht.
 * - Hinweise auf Root oder Debugger.
 * Die Signaturprüfung gilt nur für Release-Builds mit bekanntem Schlüssel
 * ([BuildConfig.EXPECTED_SIG] leer → aus).
 */
object Integrity {
    data class Result(val signatureOk: Boolean, val rooted: Boolean, val debugger: Boolean, val debuggable: Boolean)

    /** Ursprünglicher Schlüssel (vor dem Wechsel) – steht in der Rotation. */
    private const val ORIGINAL_SIG = "1F93C51C96BCD000EFFE599BB5F4BC446AC22E64CD9EA0794F77A9B1CEA3B68C"

    fun check(ctx: Context): Result = Result(
        signatureOk = BuildConfig.DEBUG || signatureOk(ctx),
        rooted = isRooted(),
        debugger = Debug.isDebuggerConnected() || Debug.waitingForDebugger(),
        debuggable = (ctx.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0,
    )

    private fun signatureOk(ctx: Context): Boolean {
        val expected = BuildConfig.EXPECTED_SIG.filter { it.isLetterOrDigit() }.uppercase()
        if (expected.isEmpty()) return true // eigener Build ohne Release-Schlüssel
        return try {
            val certs: List<ByteArray> = if (Build.VERSION.SDK_INT >= 28) {
                val info = ctx.packageManager.getPackageInfo(ctx.packageName, PackageManager.GET_SIGNING_CERTIFICATES)
                val si = info.signingInfo ?: return false
                (if (si.hasMultipleSigners()) si.apkContentsSigners else si.signingCertificateHistory).map { it.toByteArray() }
            } else {
                @Suppress("DEPRECATION")
                val info = ctx.packageManager.getPackageInfo(ctx.packageName, PackageManager.GET_SIGNATURES)
                @Suppress("DEPRECATION")
                (info.signatures ?: return false).map { it.toByteArray() }
            }
            val ok = setOf(expected, ORIGINAL_SIG)
            certs.any { sha256(it) in ok }
        } catch (_: Exception) {
            false
        }
    }

    private fun sha256(b: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(b).joinToString("") { "%02X".format(it) }

    private fun isRooted(): Boolean {
        if (Build.TAGS?.contains("test-keys") == true) return true
        val paths = listOf(
            "/system/bin/su", "/system/xbin/su", "/sbin/su", "/su/bin/su", "/system/sd/xbin/su",
            "/data/local/xbin/su", "/data/local/bin/su", "/system/app/Superuser.apk", "/data/adb/magisk",
            "/data/adb/ksu", "/system/bin/.ext/su",
        )
        if (paths.any { File(it).exists() }) return true
        return System.getenv("PATH")?.split(":")?.any { File(it, "su").exists() } == true
    }
}
