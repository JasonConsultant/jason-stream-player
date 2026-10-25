package de.jasonstream.player

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.PowerManager
import android.os.StatFs
import android.provider.DocumentsContract
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.FileOutputStream
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

/**
 * Downloads (Filme/Folgen offline): Das Laden selbst macht die App (Dart,
 * HTTP mit Range). Dieser Vordergrunddienst (Typ dataSync) hält den
 * Prozess am Leben, wenn die App im Hintergrund ist oder der Bildschirm
 * aus geht, und zeigt Fortschritt mit Pause/Fortsetzen/Abbrechen.
 *
 * Keine Adressen hier – also auch keine Zugangsdaten im Log.
 */
class DownloadService : Service() {
    companion object {
        const val ACTION_UPDATE = "de.jasonstream.player.DL_UPDATE"
        const val ACTION_STOP = "de.jasonstream.player.DL_STOP"
        const val ACTION_PAUSE = "de.jasonstream.player.DL_PAUSE"
        const val ACTION_RESUME = "de.jasonstream.player.DL_RESUME"
        const val ACTION_CANCEL = "de.jasonstream.player.DL_CANCEL"
        private const val CHANNEL = "downloads"
        private const val NOTIF_ID = 4712
        const val PAUSED_ID = 4713

        @Volatile
        var active = false

        fun ensureChannel(ctx: Context) {
            val nm = ctx.getSystemService(NotificationManager::class.java)
            if (nm.getNotificationChannel(CHANNEL) == null) {
                nm.createNotificationChannel(
                    NotificationChannel(CHANNEL, ctx.getString(R.string.dl_channel), NotificationManager.IMPORTANCE_LOW)
                )
            }
        }

        /** Alles angehalten: normale Benachrichtigung (kein Vordergrunddienst, kein Wach-Halten). */
        fun showPaused(ctx: Context, title: String, text: String) {
            ensureChannel(ctx)
            fun action(a: String, req: Int) = PendingIntent.getService(
                ctx, req, Intent(ctx, DownloadService::class.java).setAction(a),
                PendingIntent.FLAG_IMMUTABLE
            )
            val open = PendingIntent.getActivity(
                ctx, 10, ctx.packageManager.getLaunchIntentForPackage(ctx.packageName),
                PendingIntent.FLAG_IMMUTABLE
            )
            val n = Notification.Builder(ctx, CHANNEL)
                .setSmallIcon(android.R.drawable.stat_sys_download_done)
                .setContentTitle(title)
                .setContentText(text)
                .setOngoing(false)
                .setOnlyAlertOnce(true)
                .setContentIntent(open)
                .addAction(Notification.Action.Builder(null, ctx.getString(R.string.dl_resume), action(ACTION_RESUME, 12)).build())
                .addAction(Notification.Action.Builder(null, ctx.getString(R.string.dl_cancel), action(ACTION_CANCEL, 13)).build())
                .build()
            try {
                ctx.getSystemService(NotificationManager::class.java).notify(PAUSED_ID, n)
            } catch (_: SecurityException) {
                // Benachrichtigungen nicht erlaubt.
            }
        }
    }

    private var wake: PowerManager.WakeLock? = null
    private var wifi: WifiManager.WifiLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_UPDATE -> {
                show(intent)
                active = true
                acquireLocks()
            }
            ACTION_PAUSE -> DownloadBridge.sendAction("pause")
            ACTION_RESUME -> {
                DownloadBridge.sendAction("resume")
                if (!active) stopSelf()
            }
            ACTION_CANCEL -> {
                DownloadBridge.sendAction("cancel")
                if (!active) stopSelf()
            }
            ACTION_STOP -> finish()
            else -> if (!active) finish()
        }
        return START_NOT_STICKY
    }

    private fun show(i: Intent) {
        ensureChannel(this)
        val progress = i.getIntExtra("progress", -1)
        val paused = i.getBooleanExtra("paused", false)
        val open = PendingIntent.getActivity(
            this, 10, packageManager.getLaunchIntentForPackage(packageName),
            PendingIntent.FLAG_IMMUTABLE
        )
        fun action(a: String, req: Int) = PendingIntent.getService(
            this, req, Intent(this, DownloadService::class.java).setAction(a),
            PendingIntent.FLAG_IMMUTABLE
        )
        getSystemService(NotificationManager::class.java).cancel(PAUSED_ID)
        val b = Notification.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle(i.getStringExtra("title") ?: "")
            .setContentText(i.getStringExtra("text") ?: "")
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(Notification.CATEGORY_PROGRESS)
            .setContentIntent(open)
            .setProgress(1000, progress.coerceIn(0, 1000), progress < 0)
            .addAction(
                if (paused) Notification.Action.Builder(null, getString(R.string.dl_resume), action(ACTION_RESUME, 12)).build()
                else Notification.Action.Builder(null, getString(R.string.dl_pause), action(ACTION_PAUSE, 11)).build()
            )
            .addAction(Notification.Action.Builder(null, getString(R.string.dl_cancel), action(ACTION_CANCEL, 13)).build())
        val n = b.build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIF_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(NOTIF_ID, n)
        }
    }

    private fun acquireLocks() {
        if (wake == null) {
            wake = (getSystemService(Context.POWER_SERVICE) as PowerManager)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "jsp:download")
                .apply { setReferenceCounted(false); acquire(6 * 3_600_000L) }
        }
        if (wifi == null) {
            val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            @Suppress("DEPRECATION")
            wifi = wm.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "jsp:download").apply {
                setReferenceCounted(false); acquire()
            }
        }
    }

    private fun finish() {
        active = false
        wake?.let { if (it.isHeld) it.release() }
        wifi?.let { if (it.isHeld) it.release() }
        wake = null
        wifi = null
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    /** Android 15: Zeitlimit für dataSync erreicht → Dienst beenden (App lädt im Vordergrund weiter). */
    override fun onTimeout(startId: Int, fgsType: Int) {
        finish()
    }

    override fun onDestroy() {
        active = false
        wake?.let { if (it.isHeld) it.release() }
        wifi?.let { if (it.isHeld) it.release() }
        super.onDestroy()
    }
}

/** Brücke zu Dart: de.jasonstream.player/dl */
object DownloadBridge {
    private var channel: MethodChannel? = null
    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor()
    private val handles = ConcurrentHashMap<Int, Pair<ParcelFileDescriptor, FileOutputStream>>()
    private val next = AtomicInteger(1)

    fun sendAction(a: String) {
        main.post { channel?.invokeMethod("action", mapOf("action" to a)) }
    }

    fun register(messenger: BinaryMessenger, context: Context) {
        val ctx = context.applicationContext
        val ch = MethodChannel(messenger, "de.jasonstream.player/dl")
        channel = ch
        ch.setMethodCallHandler { call, result ->
            fun bg(f: () -> Any?) {
                io.execute {
                    try {
                        val r = f()
                        main.post { result.success(r) }
                    } catch (e: Exception) {
                        // Nur der Fehlertyp – keine Pfade/Adressen.
                        main.post { result.error("dl", e.javaClass.simpleName, null) }
                    }
                }
            }
            try {
                when (call.method) {
                    "update" -> {
                        if (call.argument<Boolean>("paused") == true) {
                            if (DownloadService.active) {
                                ctx.startService(
                                    Intent(ctx, DownloadService::class.java).setAction(DownloadService.ACTION_STOP)
                                )
                            }
                            DownloadService.showPaused(
                                ctx, call.argument<String>("title") ?: "", call.argument<String>("text") ?: ""
                            )
                            result.success(true)
                            return@setMethodCallHandler
                        }
                        val i = Intent(ctx, DownloadService::class.java)
                            .setAction(DownloadService.ACTION_UPDATE)
                            .putExtra("title", call.argument<String>("title") ?: "")
                            .putExtra("text", call.argument<String>("text") ?: "")
                            .putExtra("progress", call.argument<Int>("progress") ?: -1)
                            .putExtra("paused", call.argument<Boolean>("paused") ?: false)
                        if (DownloadService.active) ctx.startService(i) else ctx.startForegroundService(i)
                        result.success(true)
                    }
                    "stop" -> {
                        ctx.getSystemService(android.app.NotificationManager::class.java)
                            .cancel(DownloadService.PAUSED_ID)
                        if (DownloadService.active) {
                            ctx.startService(
                                Intent(ctx, DownloadService::class.java).setAction(DownloadService.ACTION_STOP)
                            )
                        }
                        result.success(null)
                    }
                    "freeSpace" -> bg {
                        StatFs(call.argument<String>("path")!!).availableBytes
                    }
                    "safCreate" -> bg {
                        safCreate(
                            ctx, Uri.parse(call.argument<String>("tree")!!),
                            call.argument<String>("dir") ?: "Downloads",
                            call.argument<String>("name")!!,
                            call.argument<String>("mime") ?: "video/x-matroska"
                        )
                    }
                    "safSize" -> bg { safSize(ctx, Uri.parse(call.argument<String>("uri")!!)) }
                    "safDelete" -> bg {
                        try {
                            DocumentsContract.deleteDocument(ctx.contentResolver, Uri.parse(call.argument<String>("uri")!!))
                        } catch (_: Exception) {
                            false
                        }
                    }
                    "safOpen" -> bg {
                        val uri = Uri.parse(call.argument<String>("uri")!!)
                        val append = call.argument<Boolean>("append") ?: false
                        val pfd = if (append) {
                            // Anhängen kann nicht jeder Anbieter → Dart lädt dann von vorne.
                            try { ctx.contentResolver.openFileDescriptor(uri, "wa") } catch (_: Exception) { null }
                                ?: return@bg -1
                        } else {
                            (try { ctx.contentResolver.openFileDescriptor(uri, "wt") } catch (_: Exception) { null })
                                ?: ctx.contentResolver.openFileDescriptor(uri, "w")
                                ?: throw IllegalStateException("open")
                        }
                        val h = next.getAndIncrement()
                        handles[h] = pfd to FileOutputStream(pfd.fileDescriptor)
                        h
                    }
                    "safWrite" -> {
                        val h = call.argument<Int>("handle")!!
                        val bytes = call.argument<ByteArray>("bytes")!!
                        bg {
                            val s = handles[h] ?: throw IllegalStateException("closed")
                            s.second.write(bytes)
                            null
                        }
                    }
                    "safClose" -> {
                        val h = call.argument<Int>("handle")!!
                        bg {
                            handles.remove(h)?.let { (pfd, out) ->
                                try { out.flush(); out.close() } finally { pfd.close() }
                            }
                            null
                        }
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("dl", e.javaClass.simpleName, null)
            }
        }
    }

    /** Unterordner [dir] im Baum (mit .nomedia) und darin eine neue Datei. */
    private fun safCreate(ctx: Context, tree: Uri, dir: String, name: String, mime: String): String {
        val root = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
        val folder = findChild(ctx, tree, DocumentsContract.getDocumentId(root), dir, true)
            ?: DocumentsContract.createDocument(ctx.contentResolver, root, DocumentsContract.Document.MIME_TYPE_DIR, dir)
            ?: throw IllegalStateException("mkdir")
        val folderId = DocumentsContract.getDocumentId(folder)
        // Nicht in der Galerie anzeigen.
        if (findChild(ctx, tree, folderId, ".nomedia", false) == null) {
            try {
                DocumentsContract.createDocument(ctx.contentResolver, folder, "application/octet-stream", ".nomedia")
            } catch (_: Exception) {}
        }
        val doc = DocumentsContract.createDocument(ctx.contentResolver, folder, mime, name)
            ?: throw IllegalStateException("create")
        return doc.toString()
    }

    private fun findChild(ctx: Context, tree: Uri, parentId: String, name: String, dir: Boolean): Uri? {
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, parentId)
        val cols = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
        )
        ctx.contentResolver.query(children, cols, null, null, null)?.use { c ->
            while (c.moveToNext()) {
                val isDir = c.getString(2) == DocumentsContract.Document.MIME_TYPE_DIR
                if (c.getString(1) == name && isDir == dir) {
                    return DocumentsContract.buildDocumentUriUsingTree(tree, c.getString(0))
                }
            }
        }
        return null
    }

    private fun safSize(ctx: Context, uri: Uri): Long {
        return try {
            ctx.contentResolver.query(uri, arrayOf(DocumentsContract.Document.COLUMN_SIZE), null, null, null)?.use { c ->
                if (c.moveToFirst()) (if (c.isNull(0)) 0L else c.getLong(0)) else -1L
            } ?: -1L
        } catch (_: Exception) {
            -1L
        }
    }
}
