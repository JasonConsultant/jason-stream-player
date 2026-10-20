package de.jasonstream.player

import android.Manifest
import android.app.Activity
import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.ConcurrentHashMap

/**
 * Aufnahmen, die auch bei geschlossener App und ausgeschaltetem Bildschirm
 * laufen: Wecker (AlarmManager) startet zur Startzeit einen Vordergrund-
 * Dienst, der den Stream unverändert in eine Datei schreibt.
 *
 * Die Stream-Adresse (enthält Zugangsdaten) wird nur verschlüsselt
 * (Android-Keystore, siehe [SecureBox]) gespeichert.
 */
object RecStore {
    private const val PREFS = "jsp_rec"
    private const val KEY = "entries"

    @Synchronized
    fun all(ctx: Context): MutableList<JSONObject> {
        val raw = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY, "[]")
        val arr = JSONArray(raw)
        return MutableList(arr.length()) { arr.getJSONObject(it) }
    }

    @Synchronized
    fun save(ctx: Context, list: List<JSONObject>) {
        // Alte, fertige Einträge (älter als 30 Tage) aufräumen.
        val cutoff = System.currentTimeMillis() - 30L * 86_400_000
        val keep = list.filter { it.optLong("end") > cutoff || it.optString("state") == "scheduled" }
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString(KEY, JSONArray(keep).toString()).apply()
    }

    fun get(ctx: Context, id: String) = all(ctx).firstOrNull { it.optString("id") == id }

    @Synchronized
    fun put(ctx: Context, e: JSONObject) {
        val list = all(ctx).filter { it.optString("id") != e.optString("id") }.toMutableList()
        list.add(e)
        save(ctx, list)
    }

    @Synchronized
    fun update(ctx: Context, id: String, f: (JSONObject) -> Unit) {
        val list = all(ctx)
        list.firstOrNull { it.optString("id") == id }?.let(f)
        save(ctx, list)
    }

    @Synchronized
    fun remove(ctx: Context, id: String) = save(ctx, all(ctx).filter { it.optString("id") != id })
}

object RecAlarms {
    private fun pending(ctx: Context, id: String): PendingIntent {
        val i = Intent(ctx, RecordingAlarmReceiver::class.java)
            .setAction("de.jasonstream.player.REC_START")
            .setData(Uri.parse("jsp-rec://$id"))
            .putExtra("id", id)
        return PendingIntent.getBroadcast(
            ctx, id.hashCode(), i,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    fun canExact(ctx: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
        return (ctx.getSystemService(Context.ALARM_SERVICE) as AlarmManager).canScheduleExactAlarms()
    }

    /** true = zuverlässiger Wecker gesetzt. */
    fun set(ctx: Context, id: String, at: Long): Boolean {
        if (!canExact(ctx)) return false
        val am = ctx.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        return try {
            am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pending(ctx, id))
            true
        } catch (e: SecurityException) {
            false
        }
    }

    fun cancel(ctx: Context, id: String) {
        (ctx.getSystemService(Context.ALARM_SERVICE) as AlarmManager).cancel(pending(ctx, id))
    }

    /** Nach Neustart oder App-Update alle Wecker neu setzen. */
    fun restoreAll(ctx: Context) {
        val now = System.currentTimeMillis()
        for (e in RecStore.all(ctx)) {
            if (e.optString("state") != "scheduled") continue
            val start = e.optLong("start")
            val end = e.optLong("end")
            when {
                end <= now -> RecStore.update(ctx, e.optString("id")) {
                    it.put("state", "error").put("err", "missed")
                }
                // Läuft eigentlich schon → in Kürze starten.
                else -> set(ctx, e.optString("id"), maxOf(start, now + 5_000))
            }
        }
    }
}

class RecordingAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        val id = intent.getStringExtra("id") ?: return
        val i = Intent(ctx, RecordingService::class.java)
            .setAction(RecordingService.ACTION_START).putExtra("id", id)
        try {
            ctx.startForegroundService(i)
        } catch (e: Exception) {
            RecStore.update(ctx, id) { it.put("state", "error").put("err", "start") }
        }
    }
}

class RecordingBootReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
            "android.app.action.SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED" -> {
                RecAlarms.restoreAll(ctx)
                ReminderAlarms.restoreAll(ctx)
            }
        }
    }
}

class RecordingService : Service() {
    companion object {
        const val ACTION_START = "de.jasonstream.player.REC_RUN"
        const val ACTION_STOP = "de.jasonstream.player.REC_STOP"
        private const val CHANNEL = "recordings"
        private const val NOTIF_ID = 4711
        val running = ConcurrentHashMap<String, Thread>()
        private val stopFlags = ConcurrentHashMap<String, Boolean>()
    }

    private var wake: PowerManager.WakeLock? = null
    private var wifi: WifiManager.WifiLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startInForeground()
        val id = intent?.getStringExtra("id")
        when (intent?.action) {
            ACTION_STOP -> {
                if (id != null) stopFlags[id] = true else running.keys.forEach { stopFlags[it] = true }
            }
            ACTION_START -> if (id != null) begin(id)
        }
        if (running.isEmpty()) finish()
        return START_NOT_STICKY
    }

    private fun startInForeground() {
        val nm = getSystemService(NotificationManager::class.java)
        if (nm.getNotificationChannel(CHANNEL) == null) {
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL, getString(R.string.rec_channel), NotificationManager.IMPORTANCE_LOW)
            )
        }
        val n = notification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIF_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(NOTIF_ID, n)
        }
    }

    private fun notification(): Notification {
        val titles = running.keys.mapNotNull { RecStore.get(this, it)?.optString("title") }
        val open = PendingIntent.getActivity(
            this, 0, packageManager.getLaunchIntentForPackage(packageName),
            PendingIntent.FLAG_IMMUTABLE
        )
        val stop = PendingIntent.getService(
            this, 1, Intent(this, RecordingService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE
        )
        return Notification.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.presence_video_online)
            .setContentTitle(getString(R.string.rec_running))
            .setContentText(titles.joinToString(" · ").ifEmpty { "…" })
            .setOngoing(true)
            .setContentIntent(open)
            .addAction(Notification.Action.Builder(null, getString(R.string.rec_stop), stop).build())
            .build()
    }

    private fun refreshNotification() {
        if (running.isNotEmpty()) {
            getSystemService(NotificationManager::class.java).notify(NOTIF_ID, notification())
        }
    }

    private fun begin(id: String) {
        if (running.containsKey(id)) return
        val e = RecStore.get(this, id) ?: return
        if (e.optString("state") == "done" || e.optLong("end") <= System.currentTimeMillis()) return
        acquireLocks()
        stopFlags[id] = false
        RecStore.update(this, id) { it.put("state", "running") }
        val t = Thread({ record(id, e) }, "rec-$id")
        running[id] = t
        refreshNotification()
        t.start()
    }

    private fun record(id: String, e: JSONObject) {
        var bytes = 0L
        var lastErr: String? = null
        try {
            val url = SecureBox.decrypt(e.getString("enc"))
            val end = e.getLong("end")
            val (out0, startBytes) = openOutput(id, e)
            out0.use { out ->
                bytes = startBytes
                var lastSave = 0L
                val buf = ByteArray(64 * 1024)
                while (System.currentTimeMillis() < end && stopFlags[id] != true) {
                    var conn: HttpURLConnection? = null
                    try {
                        conn = (URL(url).openConnection() as HttpURLConnection).apply {
                            connectTimeout = 10_000
                            readTimeout = 15_000
                            instanceFollowRedirects = true // nie https → http
                            setRequestProperty("User-Agent", "JasonStreamPlayer/0.9")
                        }
                        val code = conn.responseCode
                        if (code !in 200..299) {
                            lastErr = "HTTP $code"
                            Thread.sleep(4_000)
                            continue
                        }
                        conn.inputStream.use { input ->
                            while (System.currentTimeMillis() < end && stopFlags[id] != true) {
                                val n = input.read(buf)
                                if (n < 0) break
                                out.write(buf, 0, n)
                                bytes += n
                                val now = System.currentTimeMillis()
                                if (now - lastSave > 5_000) {
                                    lastSave = now
                                    RecStore.update(this, id) { it.put("bytes", bytes) }
                                }
                            }
                        }
                        lastErr = null
                    } catch (ex: InterruptedException) {
                        break
                    } catch (ex: Exception) {
                        // Nur der Fehlertyp – nie die Adresse (Zugangsdaten).
                        lastErr = ex.javaClass.simpleName
                        try { Thread.sleep(3_000) } catch (_: InterruptedException) { break }
                    } finally {
                        conn?.disconnect()
                    }
                }
            }
        } catch (ex: Exception) {
            lastErr = if (ex is NoSpace) "nospace" else ex.javaClass.simpleName
        } finally {
            val ok = bytes > 0
            RecStore.update(this, id) {
                it.put("bytes", bytes)
                it.put("state", if (ok) "done" else "error")
                if (!ok) it.put("err", lastErr ?: "empty")
            }
            running.remove(id)
            stopFlags.remove(id)
            if (running.isEmpty()) finish() else refreshNotification()
        }
    }

    private class NoSpace : Exception("nospace")

    /**
     * Ausgabe öffnen: bei "treeUri" (USB-Stick/Netzlaufwerk über SAF) eine
     * neue Datei im gewählten Ordner, sonst – wie bisher – die Datei unter
     * "path" im App-Ordner (anhängend). Scheitert der Baum, fällt die
     * Aufnahme in den App-Ordner zurück ("fallback": true). Vorher wird
     * geprüft, ob mindestens 500 MB frei sind ("nospace").
     */
    private fun openOutput(id: String, e: JSONObject): Pair<java.io.OutputStream, Long> {
        val minFree = 500L * 1024 * 1024
        val tree = e.optString("treeUri")
        val path = e.getString("path")
        if (tree.isNotEmpty()) {
            try {
                val treeUri = Uri.parse(tree)
                if (!RecStorage.hasPermission(this, tree)) throw SecurityException("no permission")
                val free = RecStorage.freeSpace(this, treeUri)
                if (free in 0 until minFree) throw NoSpace()
                val name = File(path).name
                val (doc, stream) = RecStorage.openOutput(this, treeUri, name)
                RecStore.update(this, id) { it.put("docUri", doc.toString()) }
                return stream to 0L
            } catch (ex: NoSpace) {
                throw ex
            } catch (ex: Exception) {
                RecStore.update(this, id) { it.put("fallback", true) }
            }
        }
        val file = File(path)
        file.parentFile?.mkdirs()
        try {
            val dir = file.parentFile ?: file
            if (android.os.StatFs(dir.path).availableBytes < minFree) throw NoSpace()
        } catch (ex: NoSpace) {
            throw ex
        } catch (_: Exception) {
            // Freier Platz nicht ermittelbar → trotzdem versuchen.
        }
        return FileOutputStream(file, true) to file.length()
    }

    private fun acquireLocks() {
        if (wake == null) {
            wake = (getSystemService(Context.POWER_SERVICE) as PowerManager)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "jsp:recording")
                .apply { setReferenceCounted(false); acquire(12 * 3_600_000L) }
        }
        if (wifi == null) {
            val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            @Suppress("DEPRECATION")
            val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)
                WifiManager.WIFI_MODE_FULL_LOW_LATENCY else WifiManager.WIFI_MODE_FULL_HIGH_PERF
            wifi = wm.createWifiLock(mode, "jsp:recording").apply {
                setReferenceCounted(false); acquire()
            }
        }
    }

    private fun finish() {
        wake?.let { if (it.isHeld) it.release() }
        wifi?.let { if (it.isHeld) it.release() }
        wake = null
        wifi = null
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        running.keys.forEach { stopFlags[it] = true }
        super.onDestroy()
    }
}

/** Brücke zu Dart: de.jasonstream.player/rec */
object RecBridge {
    fun register(messenger: BinaryMessenger, activity: Activity) {
        val ctx = activity.applicationContext
        MethodChannel(messenger, "de.jasonstream.player/rec").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "schedule" -> {
                        val id = call.argument<String>("id")!!
                        val start = call.argument<Number>("start")!!.toLong()
                        val e = JSONObject()
                            .put("id", id)
                            .put("title", call.argument<String>("title") ?: "")
                            .put("enc", call.argument<String>("enc")!!)
                            .put("path", call.argument<String>("path")!!)
                            .put("treeUri", call.argument<String>("treeUri") ?: "")
                            .put("start", start)
                            .put("end", call.argument<Number>("end")!!.toLong())
                            .put("state", "scheduled")
                        RecStore.put(ctx, e)
                        val now = System.currentTimeMillis()
                        if (start <= now) {
                            // Sofort: App ist im Vordergrund → Dienst direkt starten.
                            activity.startForegroundService(
                                Intent(ctx, RecordingService::class.java)
                                    .setAction(RecordingService.ACTION_START).putExtra("id", id)
                            )
                            result.success(true)
                        } else {
                            result.success(RecAlarms.set(ctx, id, start))
                        }
                    }
                    "cancel" -> {
                        val id = call.argument<String>("id")!!
                        RecAlarms.cancel(ctx, id)
                        if (RecordingService.running.containsKey(id)) {
                            activity.startService(
                                Intent(ctx, RecordingService::class.java)
                                    .setAction(RecordingService.ACTION_STOP).putExtra("id", id)
                            )
                        }
                        RecStore.remove(ctx, id)
                        result.success(null)
                    }
                    "status" -> {
                        val out = HashMap<String, Any?>()
                        for (e in RecStore.all(ctx)) {
                            out[e.optString("id")] = mapOf(
                                "state" to e.optString("state"),
                                "err" to e.optString("err").ifEmpty { null },
                                "bytes" to e.optLong("bytes"),
                                "fallback" to e.optBoolean("fallback"),
                                "docUri" to e.optString("docUri").ifEmpty { null },
                            )
                        }
                        result.success(out)
                    }
                    "canExact" -> result.success(RecAlarms.canExact(ctx))
                    "requestExact" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                            try {
                                activity.startActivity(
                                    Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM)
                                        .setData(Uri.parse("package:${ctx.packageName}"))
                                )
                            } catch (_: Exception) {
                                // Manche TV-Boxen haben diese Einstellungsseite nicht.
                                result.success(false); return@setMethodCallHandler
                            }
                        }
                        result.success(true)
                    }
                    "requestNotify" -> {
                        if (Build.VERSION.SDK_INT >= 33 &&
                            activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)
                            != PackageManager.PERMISSION_GRANTED
                        ) {
                            activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 77)
                        }
                        result.success(null)
                    }
                    "restore" -> { RecAlarms.restoreAll(ctx); result.success(null) }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("rec", e.javaClass.simpleName, null)
            }
        }
    }
}
