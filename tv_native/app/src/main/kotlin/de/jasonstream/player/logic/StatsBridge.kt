package de.jasonstream.player.logic

import android.content.Context
import android.os.Process
import android.os.SystemClock
import de.jasonstream.core.storage.Storage
import de.jasonstream.playback.stats.PlaybackStats
import de.jasonstream.playback.stats.StatsStore
import java.io.File

/**
 * Anbindung der Wiedergabe-Statistik an die App: Ablage im Speicher
 * (Option „playstats“), Absturz-Marker und App-Startzeit.
 */
object StatsBridge {
    private const val MARKER = "crash.marker"
    private var appStartReported = false

    /** Speicher geöffnet → Statistik laden/sichern über die Option „playstats“. */
    fun attach(storage: Storage) {
        PlaybackStats.session.store = object : StatsStore {
            override fun load(): String? = storage.option("playstats", "").ifEmpty { null }
            override fun save(json: String) = storage.setOption("playstats", json)
        }
    }

    /**
     * Beim Prozessstart (Application.onCreate): Marker des letzten Absturzes
     * zählen und löschen; eigenen Handler vor den des Systems hängen, der nur
     * den Marker schreibt (Klassenname der Ausnahme – keine Meldungstexte).
     */
    fun installCrashMarker(context: Context) {
        val f = File(context.filesDir, MARKER)
        if (f.exists()) {
            PlaybackStats.session.onCrashMarker()
            runCatching { f.delete() }
        }
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { t, e ->
            runCatching { f.writeText("${System.currentTimeMillis()} ${e.javaClass.name}\n") }
            previous?.uncaughtException(t, e) ?: Process.killProcess(Process.myPid())
        }
    }

    /** Erstes Bild der Oberfläche: Zeit seit Prozessstart (nur einmal je Prozess). */
    fun reportFirstFrame() {
        if (appStartReported) return
        appStartReported = true
        val start = Process.getStartUptimeMillis()
        PlaybackStats.session.onAppStart(SystemClock.uptimeMillis() - start)
    }
}
