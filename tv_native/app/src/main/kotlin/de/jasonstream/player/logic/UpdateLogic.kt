package de.jasonstream.player.logic

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.longOrNull

/** Neue Version aus den GitHub-Releases. */
data class UpdateInfo(val version: String, val notes: String, val apkUrl: String, val size: Long)

/** Reine Logik des Selbst-Updates (Port von lib/core/updater.dart). */
object UpdateLogic {
    const val REPO = "JasonConsultant/jason-stream-player"
    const val LATEST_URL = "https://api.github.com/repos/$REPO/releases/latest"

    private fun parts(v: String): Pair<List<Int>, String?> {
        val s = v.trim().removePrefix("v").substringBefore('+')
        val pre = s.substringAfter('-', "").ifEmpty { null }
        val nums = s.substringBefore('-').split('.').map { it.toIntOrNull() ?: 0 }
        return nums to pre
    }

    /**
     * 0.9.10 > 0.9.4 (Zahlen, nicht Text). Vorabversionen („2.0.0-alpha1“)
     * sind älter als die fertige Version mit gleichen Zahlen.
     */
    fun compareVersions(a: String, b: String): Int {
        val (x, px) = parts(a)
        val (y, py) = parts(b)
        for (i in 0 until 4) {
            val d = x.getOrElse(i) { 0 } - y.getOrElse(i) { 0 }
            if (d != 0) return Integer.signum(d)
        }
        return when {
            px == null && py == null -> 0
            px == null -> 1
            py == null -> -1
            else -> Integer.signum(comparePre(px, py))
        }
    }

    private fun comparePre(a: String, b: String): Int {
        val na = a.filter { it.isDigit() }.toIntOrNull()
        val nb = b.filter { it.isDigit() }.toIntOrNull()
        val la = a.filter { it.isLetter() }
        val lb = b.filter { it.isLetter() }
        if (la != lb) return la.compareTo(lb) // alpha < beta < rc
        return (na ?: 0) - (nb ?: 0)
    }

    /** Native TV-App: immer die TV-APK (beide Architekturen). */
    fun assetFor(packageName: String, version: String): String {
        val tr = packageName.endsWith(".tr")
        return "JasonStreamPlayer${if (tr) "_TR" else ""}_TV_$version.apk"
    }

    /** Antwort von releases/latest auswerten; null = aktuell oder keine passende Datei. */
    fun parseLatest(body: String, current: String, packageName: String): UpdateInfo? {
        val j = Json.parseToJsonElement(body).jsonObject
        val latest = (j["tag_name"] as? JsonPrimitive)?.content.orEmpty().removePrefix("v")
        if (latest.isEmpty() || compareVersions(latest, current) <= 0) return null
        val want = assetFor(packageName, latest)
        val assets = j["assets"] as? JsonArray ?: return null
        for (a in assets) {
            val o = a as? JsonObject ?: continue
            if ((o["name"] as? JsonPrimitive)?.content != want) continue
            val url = (o["browser_download_url"] as? JsonPrimitive)?.content ?: return null
            if (!url.startsWith("https://")) return null
            return UpdateInfo(
                latest,
                (j["body"] as? JsonPrimitive)?.content?.trim().orEmpty(),
                url,
                (o["size"] as? JsonPrimitive)?.longOrNull ?: 0,
            )
        }
        return null
    }
}
