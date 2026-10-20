package de.jasonstream.player

import android.app.Activity
import android.content.Intent
import android.provider.OpenableColumns
import io.flutter.plugin.common.MethodChannel

/**
 * Datei speichern/öffnen über das Storage Access Framework (Systemdialog,
 * keine Speicher-Berechtigung nötig). Genutzt für Sicherungsdateien.
 *
 * Ablauf wie "pickPlaylist" in MainActivity: startActivityForResult, das
 * Ergebnis kommt über [onActivityResult] zurück.
 */
object FileIO {
    const val SAVE_REQUEST = 4712
    const val OPEN_REQUEST = 4713
    private const val MAX_BYTES = 50L * 1024 * 1024

    private var saveResult: MethodChannel.Result? = null
    private var saveBytes: ByteArray? = null
    private var openResult: MethodChannel.Result? = null

    /** Speichern-Dialog öffnen; Antwort: true (gespeichert) / false (abgebrochen). */
    fun saveFile(
        activity: Activity,
        suggestedName: String,
        mime: String,
        bytes: ByteArray,
        result: MethodChannel.Result,
    ) {
        saveResult?.success(false)
        saveResult = result
        saveBytes = bytes
        try {
            @Suppress("DEPRECATION")
            activity.startActivityForResult(
                Intent(Intent.ACTION_CREATE_DOCUMENT)
                    .addCategory(Intent.CATEGORY_OPENABLE)
                    .setType(mime)
                    .putExtra(Intent.EXTRA_TITLE, suggestedName),
                SAVE_REQUEST
            )
        } catch (e: Exception) {
            saveResult = null; saveBytes = null
            result.error("nopicker", "Kein Dateidialog verfügbar", null)
        }
    }

    /** Öffnen-Dialog; Antwort: {bytes, name} oder null (abgebrochen). */
    fun openFile(activity: Activity, result: MethodChannel.Result) {
        openResult?.success(null)
        openResult = result
        try {
            @Suppress("DEPRECATION")
            activity.startActivityForResult(
                Intent(Intent.ACTION_OPEN_DOCUMENT)
                    .addCategory(Intent.CATEGORY_OPENABLE)
                    .setType("*/*"),
                OPEN_REQUEST
            )
        } catch (e: Exception) {
            openResult = null
            result.error("nopicker", "Kein Dateidialog verfügbar", null)
        }
    }

    /** Liefert true, wenn der Request-Code hier behandelt wurde. */
    fun onActivityResult(activity: Activity, requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        when (requestCode) {
            SAVE_REQUEST -> {
                val result = saveResult ?: return true
                val bytes = saveBytes
                saveResult = null; saveBytes = null
                val uri = data?.data
                if (resultCode != Activity.RESULT_OK || uri == null || bytes == null) {
                    result.success(false); return true
                }
                Thread {
                    try {
                        activity.contentResolver.openOutputStream(uri, "wt")!!.use { it.write(bytes) }
                        activity.runOnUiThread { result.success(true) }
                    } catch (e: Exception) {
                        activity.runOnUiThread { result.error("write", e.javaClass.simpleName, null) }
                    }
                }.start()
                return true
            }
            OPEN_REQUEST -> {
                val result = openResult ?: return true
                openResult = null
                val uri = data?.data
                if (resultCode != Activity.RESULT_OK || uri == null) {
                    result.success(null); return true
                }
                Thread {
                    try {
                        val out = java.io.ByteArrayOutputStream()
                        activity.contentResolver.openInputStream(uri)!!.use { input ->
                            val buf = ByteArray(64 * 1024)
                            var total = 0L
                            while (true) {
                                val n = input.read(buf)
                                if (n < 0) break
                                total += n
                                if (total > MAX_BYTES) throw IllegalStateException("too large")
                                out.write(buf, 0, n)
                            }
                        }
                        var name: String? = null
                        activity.contentResolver.query(uri, null, null, null, null)?.use { c ->
                            val i = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                            if (i >= 0 && c.moveToFirst()) name = c.getString(i)
                        }
                        val bytes = out.toByteArray()
                        activity.runOnUiThread { result.success(mapOf("bytes" to bytes, "name" to name)) }
                    } catch (e: Exception) {
                        activity.runOnUiThread { result.error("read", e.javaClass.simpleName, null) }
                    }
                }.start()
                return true
            }
            else -> return false
        }
    }
}
