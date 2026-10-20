package de.jasonstream.player

import android.app.UiModeManager
import android.content.ContentUris
import android.content.Context
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.tvprovider.media.tv.Channel
import androidx.tvprovider.media.tv.ChannelLogoUtils
import androidx.tvprovider.media.tv.PreviewProgram
import androidx.tvprovider.media.tv.TvContractCompat
import io.flutter.plugin.common.MethodChannel

/**
 * Android-TV-Startbildschirm: eigener Vorschau-Kanal („… – Favoriten“) mit
 * den Lieblingssendern des Nutzers und der gerade laufenden Sendung.
 * Ein Klick auf eine Kachel öffnet `jsp://play?channel=<id>&portal=<id>`
 * (siehe MainActivity.readLaunch). Nur Android TV ab API 26 – sonst No-op.
 */
object TvChannels {
    private const val PREFS = "jsp_tv"
    private const val KEY_CHANNEL = "channel_id"

    /** Vorschau-Kanäle gibt es nur auf Android TV (Oreo+) mit TV-Provider. */
    fun supported(ctx: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        val ui = ctx.getSystemService(Context.UI_MODE_SERVICE) as? UiModeManager
        val tv = ui?.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION ||
            ctx.packageManager.hasSystemFeature("android.software.leanback")
        if (!tv) return false
        return ctx.packageManager.resolveContentProvider(TvContractCompat.AUTHORITY, 0) != null
    }

    /**
     * Vom Flutter-Kanal: Kanal anlegen/aktualisieren und alle Programme
     * ersetzen. [items]: channelId, name, logoUrl, title (läuft gerade),
     * portal. [displayName] = Kanaltitel (lokalisiert, ohne App-Namen).
     */
    fun syncAsync(ctx: Context, displayName: String?, items: List<Map<String, Any?>>?,
                  result: MethodChannel.Result) {
        val app = ctx.applicationContext
        val main = Handler(Looper.getMainLooper())
        Thread {
            val ok = try {
                sync(app, displayName ?: "Favoriten", items ?: emptyList())
            } catch (e: Exception) {
                false
            }
            main.post {
                // Nur beim ersten Anlegen: Launcher fragt den Nutzer, ob die
                // Zeile angezeigt werden soll. Startet eine Activity → braucht
                // den Activity-Kontext und den Hauptthread (sonst
                // AndroidRuntimeException ab targetSdk 28, still verschluckt).
                val newId = pendingBrowsable
                if (newId != null) {
                    pendingBrowsable = null
                    try { TvContractCompat.requestChannelBrowsable(ctx, newId) } catch (_: Exception) {}
                }
                result.success(ok)
            }
        }.start()
    }

    /** Frisch angelegter Kanal, für den der Launcher noch gefragt werden muss. */
    @Volatile private var pendingBrowsable: Long? = null

    fun clearAsync(ctx: Context, result: MethodChannel.Result) {
        val app = ctx.applicationContext
        val main = Handler(Looper.getMainLooper())
        Thread {
            try { clear(app) } catch (_: Exception) {}
            main.post { result.success(null) }
        }.start()
    }

    /** Liefert true, wenn der Kanal geschrieben wurde. */
    fun sync(ctx: Context, displayName: String, items: List<Map<String, Any?>>): Boolean {
        if (!supported(ctx)) return false
        val appName = try { ctx.getString(R.string.app_name) } catch (_: Exception) { "Jason Stream Player" }
        val channelId = ensureChannel(ctx, "$appName – $displayName") ?: return false
        val cr = ctx.contentResolver
        deletePrograms(ctx, channelId)
        if (items.isEmpty()) return true
        val values = ArrayList<android.content.ContentValues>(items.size)
        items.forEachIndexed { index, item ->
            val id = item["channelId"]?.toString() ?: return@forEachIndexed
            val name = item["name"]?.toString() ?: id
            val logo = item["logoUrl"]?.toString()
            val title = item["title"]?.toString()
            val portal = item["portal"]?.toString() ?: ""
            val link = Uri.Builder().scheme("jsp").authority("play")
                .appendQueryParameter("channel", id)
                .appendQueryParameter("portal", portal)
                .build()
            val b = PreviewProgram.Builder()
                .setChannelId(channelId)
                .setType(TvContractCompat.PreviewPrograms.TYPE_CHANNEL)
                .setTitle(name)
                .setInternalProviderId(id)
                .setIntentUri(link)
                .setWeight(items.size - index)
                .setPosterArtAspectRatio(TvContractCompat.PreviewPrograms.ASPECT_RATIO_1_1)
            if (!title.isNullOrBlank()) b.setDescription(title)
            if (!logo.isNullOrBlank()) b.setPosterArtUri(Uri.parse(logo))
            values.add(b.build().toContentValues())
        }
        if (values.isNotEmpty()) {
            cr.bulkInsert(TvContractCompat.PreviewPrograms.CONTENT_URI, values.toTypedArray())
        }
        return true
    }

    /** Kanal samt Programmen entfernen (Einstellung ausgeschaltet). */
    fun clear(ctx: Context) {
        if (!supported(ctx)) return
        val prefs = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val id = prefs.getLong(KEY_CHANNEL, -1L)
        if (id < 0) return
        try {
            ctx.contentResolver.delete(TvContractCompat.buildChannelUri(id), null, null)
        } finally {
            prefs.edit().remove(KEY_CHANNEL).apply()
        }
    }

    // ---------- intern ----------

    private fun ensureChannel(ctx: Context, name: String): Long? {
        val prefs = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val cr = ctx.contentResolver
        val stored = prefs.getLong(KEY_CHANNEL, -1L)
        if (stored >= 0 && channelExists(ctx, stored)) {
            // Name ggf. aktualisieren (Sprachwechsel).
            val v = Channel.Builder().setDisplayName(name).build().toContentValues()
            v.remove(TvContractCompat.Channels._ID)
            try { cr.update(TvContractCompat.buildChannelUri(stored), v, null, null) } catch (_: Exception) {}
            return stored
        }
        val channel = Channel.Builder()
            .setType(TvContractCompat.Channels.TYPE_PREVIEW)
            .setDisplayName(name)
            .setAppLinkIntentUri(Uri.parse("jsp://play"))
            .build()
        val uri = cr.insert(TvContractCompat.Channels.CONTENT_URI, channel.toContentValues())
            ?: return null
        val id = ContentUris.parseId(uri)
        prefs.edit().putLong(KEY_CHANNEL, id).apply()
        appIcon(ctx)?.let { try { ChannelLogoUtils.storeChannelLogo(ctx, id, it) } catch (_: Exception) {} }
        pendingBrowsable = id // siehe syncAsync
        return id
    }

    private fun channelExists(ctx: Context, id: Long): Boolean {
        return try {
            ctx.contentResolver.query(
                TvContractCompat.buildChannelUri(id),
                arrayOf(TvContractCompat.Channels._ID), null, null, null
            )?.use { it.moveToFirst() } ?: false
        } catch (_: Exception) {
            false
        }
    }

    private fun deletePrograms(ctx: Context, channelId: Long) {
        val cr = ctx.contentResolver
        val ids = ArrayList<Long>()
        try {
            cr.query(
                TvContractCompat.buildPreviewProgramsUriForChannel(channelId),
                arrayOf(TvContractCompat.PreviewPrograms._ID), null, null, null
            )?.use { c ->
                while (c.moveToNext()) ids.add(c.getLong(0))
            }
        } catch (_: Exception) {
            return
        }
        for (id in ids) {
            try { cr.delete(TvContractCompat.buildPreviewProgramUri(id), null, null) } catch (_: Exception) {}
        }
    }

    private fun appIcon(ctx: Context): Bitmap? {
        return try {
            val d = ctx.packageManager.getApplicationIcon(ctx.packageName)
            if (d is BitmapDrawable && d.bitmap != null) return d.bitmap
            val size = 256
            val bmp = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bmp)
            d.setBounds(0, 0, size, size)
            d.draw(canvas)
            bmp
        } catch (_: Exception) {
            null
        }
    }
}
