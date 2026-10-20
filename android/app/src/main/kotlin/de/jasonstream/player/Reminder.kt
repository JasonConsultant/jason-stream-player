package de.jasonstream.player

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject

/**
 * Programm-Erinnerungen: Wecker kurz vor Sendungsbeginn → Benachrichtigung.
 * Gespeichert werden nur Sendername, Titel, Zeit und Sender-ID – keine
 * Adressen oder Zugangsdaten.
 */
object ReminderStore {
    private const val PREFS = "jsp_rem"
    private const val KEY = "entries"

    @Synchronized
    fun all(ctx: Context): MutableList<JSONObject> {
        val raw = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY, "[]")
        val arr = try { JSONArray(raw) } catch (_: Exception) { JSONArray() }
        return MutableList(arr.length()) { arr.getJSONObject(it) }
    }

    @Synchronized
    fun save(ctx: Context, list: List<JSONObject>) {
        val arr = JSONArray()
        list.forEach { arr.put(it) }
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString(KEY, arr.toString()).apply()
    }

    fun get(ctx: Context, id: String) = all(ctx).firstOrNull { it.optString("id") == id }

    @Synchronized
    fun put(ctx: Context, e: JSONObject) {
        val id = e.optString("id")
        save(ctx, all(ctx).filter { it.optString("id") != id } + e)
    }

    @Synchronized
    fun remove(ctx: Context, id: String) = save(ctx, all(ctx).filter { it.optString("id") != id })
}

object ReminderAlarms {
    private fun pending(ctx: Context, id: String): PendingIntent {
        val i = Intent(ctx, ReminderReceiver::class.java)
            .setAction("de.jasonstream.player.REMINDER")
            .setData(Uri.parse("jsp-rem://${Uri.encode(id)}"))
            .putExtra("id", id)
        return PendingIntent.getBroadcast(
            ctx, id.hashCode(), i,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    /** Exakt, wenn erlaubt – sonst ungefähr (für Erinnerungen ausreichend). */
    fun set(ctx: Context, id: String, at: Long) {
        val am = ctx.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val pi = pending(ctx, id)
        try {
            if (RecAlarms.canExact(ctx)) {
                am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi)
            } else {
                am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi)
            }
        } catch (_: SecurityException) {
            am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi)
        }
    }

    fun cancel(ctx: Context, id: String) {
        (ctx.getSystemService(Context.ALARM_SERVICE) as AlarmManager).cancel(pending(ctx, id))
        ctx.getSystemService(NotificationManager::class.java)?.cancel(ReminderReceiver.TAG, id.hashCode())
    }

    /** Nach Neustart/Update: vergangene entfernen, übrige neu setzen. */
    fun restoreAll(ctx: Context) {
        val now = System.currentTimeMillis()
        val keep = ReminderStore.all(ctx).filter { it.optLong("start") > now }
        ReminderStore.save(ctx, keep)
        for (e in keep) set(ctx, e.optString("id"), maxOf(e.optLong("at"), now + 5_000))
    }
}

class ReminderReceiver : BroadcastReceiver() {
    companion object {
        const val CHANNEL = "reminders"
        const val TAG = "jsp_rem"
    }

    override fun onReceive(ctx: Context, intent: Intent) {
        val id = intent.getStringExtra("id") ?: return
        val e = ReminderStore.get(ctx, id) ?: return
        ReminderStore.remove(ctx, id)
        val nm = ctx.getSystemService(NotificationManager::class.java) ?: return
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL, ctx.getString(R.string.rem_channel), NotificationManager.IMPORTANCE_HIGH)
        )
        val launch = (ctx.packageManager.getLaunchIntentForPackage(ctx.packageName)
            ?: Intent(ctx, MainActivity::class.java))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            .putExtra("jsp_action", "play")
            .putExtra("jsp_channel", e.optString("channel"))
            .putExtra("jsp_portal", e.optString("portal"))
        val open = PendingIntent.getActivity(
            ctx, id.hashCode(), launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val time = android.text.format.DateFormat.getTimeFormat(ctx)
            .format(java.util.Date(e.optLong("start")))
        val n = Notification.Builder(ctx, CHANNEL)
            .setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
            .setContentTitle(e.optString("title"))
            .setContentText(ctx.getString(R.string.rem_text, time, e.optString("channelName")))
            .setCategory(Notification.CATEGORY_REMINDER)
            .setAutoCancel(true)
            .setContentIntent(open)
            .build()
        try {
            nm.notify(TAG, id.hashCode(), n)
        } catch (_: SecurityException) {
            // Keine Benachrichtigungs-Erlaubnis.
        }
    }
}

object ReminderBridge {
    fun register(messenger: BinaryMessenger, ctx: Context) {
        val app = ctx.applicationContext
        MethodChannel(messenger, "de.jasonstream.player/reminders").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "schedule" -> {
                        val id = call.argument<String>("id")!!
                        val start = call.argument<Number>("start")!!.toLong()
                        val at = call.argument<Number>("at")!!.toLong()
                        ReminderStore.put(
                            app, JSONObject()
                                .put("id", id)
                                .put("title", call.argument<String>("title") ?: "")
                                .put("channelName", call.argument<String>("channelName") ?: "")
                                .put("channel", call.argument<String>("channel") ?: "")
                                .put("portal", call.argument<String>("portal") ?: "")
                                .put("start", start)
                                .put("at", at)
                        )
                        ReminderAlarms.set(app, id, maxOf(at, System.currentTimeMillis() + 1_000))
                        result.success(true)
                    }
                    "cancel" -> {
                        val id = call.argument<String>("id")!!
                        ReminderAlarms.cancel(app, id)
                        ReminderStore.remove(app, id)
                        result.success(null)
                    }
                    "list" -> result.success(ReminderStore.all(app).map { it.optString("id") })
                    "restore" -> { ReminderAlarms.restoreAll(app); result.success(null) }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("rem", e.javaClass.simpleName, null)
            }
        }
    }
}
