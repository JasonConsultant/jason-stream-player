package de.jasonstream.player

import android.app.ActivityManager
import android.content.Context
import de.jasonstream.core.migration.FlutterMigration
import de.jasonstream.core.migration.FlutterPrefs
import de.jasonstream.core.prefs.KeyValueStore
import de.jasonstream.core.prefs.SharedPrefsKeyValueStore
import de.jasonstream.core.security.SecretCipher
import de.jasonstream.core.security.SecureBox
import de.jasonstream.core.storage.Storage
import de.jasonstream.data.cache.ListCache
import de.jasonstream.data.epg.EpgWindow
import java.io.File

/**
 * Manuelle Abhängigkeiten (kein Hilt – weniger Startzeit, weniger Code).
 * Alles Teure ([openStorage]) läuft auf Dispatchers.IO.
 */
class AppContainer(private val context: Context) {
    /** Native Einstellungen (gleiche Schlüssel wie die Flutter-App, ohne „flutter.“). */
    val prefs: KeyValueStore by lazy {
        SharedPrefsKeyValueStore(context.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE))
    }

    /** Keystore-Verschlüsselung, identisch zur Flutter-App (SecureBox.kt). */
    val cipher: SecretCipher = SecureBox

    val listCache: ListCache by lazy { ListCache(File(context.filesDir, "lists")) }

    /** Hier legte die Flutter-App ihre Zwischenspeicher ab (getApplicationSupportDirectory). */
    val flutterFilesDir: File get() = context.filesDir

    val memory: ActivityManager.MemoryInfo by lazy {
        val am = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        ActivityManager.MemoryInfo().also { am.getMemoryInfo(it) }
    }

    val isLowRam: Boolean by lazy {
        (context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager).isLowRamDevice ||
            memory.totalMem <= 1200L shl 20
    }

    @Volatile
    private var storage: Storage? = null

    /** Einmalige Übernahme der Flutter-Daten (falls noch nicht geschehen). */
    fun migrate(): FlutterMigration.Report? = FlutterMigration(prefs, cipher).runIfNeeded {
        val f = FlutterPrefs.file(context.dataDir)
        if (f.exists()) FlutterPrefs.read(f) else null
    }

    fun migrationReport(): FlutterMigration.Report? = FlutterMigration.report(prefs)

    /** Öffnet den Speicher (entschlüsselt Geheimnisse über den Keystore). Blockiert. */
    @Synchronized
    fun openStorage(): Storage = storage ?: Storage.open(prefs, cipher).also { storage = it }

    fun tuneForDevice() {
        EpgWindow.tuneForDevice(memory.totalMem, isLowRam)
    }

    companion object {
        const val PREFS_FILE = "jsp_prefs"
    }
}
