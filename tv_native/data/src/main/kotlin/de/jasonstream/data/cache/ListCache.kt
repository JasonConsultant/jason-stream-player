package de.jasonstream.data.cache

import com.squareup.moshi.JsonReader
import de.jasonstream.core.model.Category
import de.jasonstream.core.model.Channel
import de.jasonstream.core.model.Portal
import de.jasonstream.core.model.VodItem
import de.jasonstream.core.security.SimpleUri
import de.jasonstream.data.LiveList
import de.jasonstream.data.VodList
import de.jasonstream.data.net.JsonStream
import okio.Buffer
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.EOFException
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.security.DigestOutputStream
import java.security.MessageDigest

/**
 * Zwischenspeicher für Senderliste, Filme und Serien – kompaktes
 * Binärformat (schneller und sparsamer als JSON auf 2-GB-Boxen).
 *
 * Wie in der Flutter-App (list_cache.dart) enthält die Datei **keine
 * Zugangsdaten**: Benutzername/Passwort/Tokens werden vor dem Schreiben
 * durch Platzhalter `\u0000S<i>\u0000` ersetzt und beim Lesen aus dem
 * verschlüsselten Speicher wieder eingesetzt. Ändern sich die Zugangsdaten
 * (Fingerabdruck), gilt der Speicher als ungültig.
 *
 * Aufbau: MAGIC, Version, saved(ms), Fingerabdruck, Inhalt …, MD5(Inhalt).
 *
 * Zusätzlich liest [importFlutterLive] den JSON-Zwischenspeicher der
 * Flutter-App (`files/live_<id>.json`): Nach dem Update ist die Senderliste
 * sofort da, ohne Netz.
 */
class ListCache(private val dir: File) {
    data class Cached<T>(val categories: List<Category>, val items: List<T>, val savedMs: Long, val hash: String)

    /** Ergebnis von store*: Prüfsumme; unchanged = gleich wie [prevHash], nichts geschrieben. */
    data class Stored(val hash: String, val unchanged: Boolean)

    companion object {
        private const val MAGIC = 0x4A535043 // "JSPC"
        private const val VERSION = 1
        const val KIND_LIVE = "live"
        const val KIND_MOVIES = "movies"
        const val KIND_SERIES = "series"

        fun fileName(kind: String, portalId: String, ext: String = "bin") =
            "${kind}_${portalId.replace(Regex("[^A-Za-z0-9_-]"), "_")}.$ext"

        /** Geheimnisse wie ListCache._secrets (Dart): längste zuerst. */
        fun secrets(p: Portal): List<String> {
            val out = ArrayList<String>()
            fun add(v: String?) {
                if (v == null || v.length < 2) return
                for (x in listOf(SimpleUri.encodeComponent(v), v)) if (x !in out) out.add(x)
            }
            add(p.username)
            add(p.password)
            for (u in listOf(p.url) + p.altUrls) {
                val q = SimpleUri.parse(u)?.queryParameters ?: emptyMap()
                for (k in listOf("username", "user", "password", "pass", "token", "key")) add(q[k])
            }
            return out.sortedByDescending { it.length }
        }

        /** sha256(secrets.join('\u0001')) als Hex – identisch zur Dart-Version. */
        fun fingerprint(secrets: List<String>): String =
            MessageDigest.getInstance("SHA-256").digest(secrets.joinToString("\u0001").toByteArray())
                .joinToString("") { "%02x".format(it) }

        internal fun mask(s: String, secrets: List<String>): String {
            var out = s
            secrets.forEachIndexed { i, x -> if (out.contains(x)) out = out.replace(x, "\u0000S$i\u0000") }
            return out
        }

        internal fun restore(s: String, secrets: List<String>): String {
            if (!s.contains('\u0000')) return s
            var out = s
            secrets.forEachIndexed { i, x -> out = out.replace("\u0000S$i\u0000", x) }
            return out
        }
    }

    private fun file(kind: String, p: Portal) = File(dir, fileName(kind, p.id))

    fun exists(kind: String, p: Portal) = file(kind, p).exists()

    fun clear(p: Portal) {
        for (k in listOf(KIND_LIVE, KIND_MOVIES, KIND_SERIES)) file(k, p).delete()
    }

    // ------------------------------------------------------------------ Schreiben

    private class Out(stream: java.io.OutputStream, val secrets: List<String>) : DataOutputStream(stream) {
        fun str(s: String?) {
            if (s == null) { writeInt(-1); return }
            val b = mask(s, secrets).toByteArray(Charsets.UTF_8)
            writeInt(b.size); write(b)
        }
        fun intOrNull(v: Int?) { writeBoolean(v != null); if (v != null) writeInt(v) }
        fun longOrNull(v: Long?) { writeBoolean(v != null); if (v != null) writeLong(v) }
        fun cats(c: List<Category>) { writeInt(c.size); c.forEach { str(it.id); str(it.name) } }
    }

    private fun store(kind: String, p: Portal, prevHash: String?, savedMs: Long, body: Out.() -> Unit): Stored {
        dir.mkdirs()
        val secrets = secrets(p)
        val target = file(kind, p)
        val tmp = File(dir, target.name + ".tmp")
        val md5 = MessageDigest.getInstance("MD5")
        FileOutputStream(tmp).use { fos ->
            val bos = BufferedOutputStream(fos, 64 * 1024)
            val head = DataOutputStream(bos)
            head.writeInt(MAGIC); head.writeInt(VERSION); head.writeLong(savedMs); head.writeUTF(fingerprint(secrets))
            head.flush()
            val out = Out(DigestOutputStream(bos, md5), secrets)
            out.body()
            out.flush()
            bos.write(md5.digest())
            bos.flush()
        }
        // Prüfsumme steht am Dateiende (16 Byte).
        val hash = tmp.readTail16().hex()
        if (prevHash != null && prevHash == hash) {
            tmp.delete()
            return Stored(hash, unchanged = true)
        }
        if (!tmp.renameTo(target)) { target.delete(); tmp.renameTo(target) }
        return Stored(hash, unchanged = false)
    }

    private fun File.readTail16(): ByteArray = java.io.RandomAccessFile(this, "r").use { f ->
        f.seek(f.length() - 16); ByteArray(16).also { f.readFully(it) }
    }

    private fun ByteArray.hex() = joinToString("") { "%02x".format(it) }

    fun storeLive(p: Portal, l: LiveList, prevHash: String? = null, savedMs: Long = System.currentTimeMillis()) =
        store(KIND_LIVE, p, prevHash, savedMs) {
            cats(l.categories)
            writeInt(l.channels.size)
            for (c in l.channels) {
                str(c.id); str(c.name); str(c.logoUrl); str(c.categoryId); str(c.streamUrl); str(c.epgId)
                writeInt(c.catchupDays); writeInt(c.number); str(c.catchupMode); str(c.catchupSource)
                val h = c.headers
                writeInt(h?.size ?: -1)
                h?.forEach { (k, v) -> str(k); str(v) }
                writeInt(c.epgShift)
            }
        }

    fun storeVod(kind: String, p: Portal, l: VodList, prevHash: String? = null, savedMs: Long = System.currentTimeMillis()) =
        store(kind, p, prevHash, savedMs) {
            cats(l.categories)
            writeInt(l.items.size)
            for (m in l.items) {
                str(m.id); str(m.name); str(m.posterUrl); str(m.backdropUrl); str(m.categoryId); str(m.streamUrl)
                writeBoolean(m.rating != null); m.rating?.let { writeDouble(it) }
                intOrNull(m.year); str(m.plot); str(m.genre); longOrNull(m.addedMs); writeBoolean(m.isSeries)
                longOrNull(m.durationSec); str(m.cast); str(m.director); str(m.trailer)
            }
        }

    // ------------------------------------------------------------------ Lesen

    private class In(stream: java.io.InputStream, val secrets: List<String>) : DataInputStream(stream) {
        fun str(): String? {
            val n = readInt()
            if (n < 0) return null
            val b = ByteArray(n)
            readFully(b)
            return restore(String(b, Charsets.UTF_8), secrets)
        }
        fun strNN() = str() ?: ""
        fun intOrNull() = if (readBoolean()) readInt() else null
        fun longOrNull() = if (readBoolean()) readLong() else null
        fun cats(): List<Category> = List(readInt()) { Category(strNN(), strNN()) }
    }

    private fun <T> load(kind: String, p: Portal, body: In.() -> Pair<List<Category>, List<T>>): Cached<T>? {
        val f = file(kind, p)
        if (!f.exists() || f.length() < 32) return null
        val secrets = secrets(p)
        return try {
            DataInputStream(BufferedInputStream(FileInputStream(f), 64 * 1024)).use { head ->
                if (head.readInt() != MAGIC || head.readInt() != VERSION) throw EOFException()
                val saved = head.readLong()
                if (head.readUTF() != fingerprint(secrets)) return null // andere Zugangsdaten → neu laden
                val (cats, items) = In(head, secrets).body()
                Cached(cats, items, saved, f.readTail16().hex())
            }
        } catch (_: Exception) {
            f.delete() // beschädigt
            null
        }
    }

    fun loadLive(p: Portal): Cached<Channel>? = load(KIND_LIVE, p) {
        val cats = cats()
        val n = readInt()
        val list = ArrayList<Channel>(n)
        repeat(n) {
            val id = strNN(); val name = strNN(); val logo = str(); val cat = strNN(); val url = strNN(); val epg = str()
            val days = readInt(); val num = readInt(); val mode = str(); val src = str()
            val hn = readInt()
            val headers = if (hn < 0) null else LinkedHashMap<String, String>().also { m -> repeat(hn) { m[strNN()] = strNN() } }
            val shift = readInt()
            list.add(Channel(id, name, cat, url, logo, epg, days, num, mode, src, headers, shift))
        }
        cats to list
    }

    fun loadVod(kind: String, p: Portal): Cached<VodItem>? = load(kind, p) {
        val cats = cats()
        val n = readInt()
        val list = ArrayList<VodItem>(n)
        repeat(n) {
            val id = strNN(); val name = strNN(); val poster = str(); val backdrop = str(); val cat = strNN(); val url = strNN()
            val rating = if (readBoolean()) readDouble() else null
            val year = intOrNull(); val plot = str(); val genre = str(); val added = longOrNull(); val isSeries = readBoolean()
            val dur = longOrNull(); val cast = str(); val director = str(); val trailer = str()
            list.add(VodItem(id, name, cat, url, poster, backdrop, rating, year, plot, genre, cast, director, dur, added, trailer, isSeries))
        }
        cats to list
    }

    // ------------------------------------------------------------------ Flutter-Import

    /**
     * Liest `live_<id>.json` der Flutter-App (Format v1 aus list_cache.dart):
     * `{"v":1,"saved":…,"fp":"<sha256>","h":"<md5>","cats":[[id,name]…],
     * "ch":[[id,name,logo,cat,url,epg,catchupDays,number,mode,source,headers,shift]…]}`
     * mit maskierten Zugangsdaten. Falscher Fingerabdruck/beschädigt → null.
     */
    fun importFlutterLive(flutterFilesDir: File, p: Portal, maxBytes: Long = 64L * 1024 * 1024): Cached<Channel>? {
        val f = File(flutterFilesDir, fileName(KIND_LIVE, p.id, "json"))
        if (!f.exists() || f.length() > maxBytes) return null
        return try {
            val secrets = secrets(p)
            val raw = f.readText()
            val fpAt = raw.indexOf("\"fp\":\"")
            if (fpAt < 0 || raw.length < fpAt + 6 + 64 || raw.substring(fpAt + 6, fpAt + 6 + 64) != fingerprint(secrets)) {
                return null
            }
            val restored = restore(raw, secrets)
            decodeFlutterLive(restored)
        } catch (_: Exception) {
            null
        }
    }

    internal fun decodeFlutterLive(json: String): Cached<Channel>? {
        val r = JsonStream.reader(Buffer().writeUtf8(json))
        var saved: Long? = null
        var hash = ""
        var cats: List<Category> = emptyList()
        var chans: ArrayList<Channel>? = null
        r.beginObject()
        while (r.hasNext()) {
            when (r.nextName()) {
                "saved" -> saved = r.nextString().toDoubleOrNull()?.toLong()
                "h" -> hash = r.nextString()
                "cats" -> cats = (JsonStream.readValue(r) as? List<*>).orEmpty().mapNotNull { c ->
                    val l = c as? List<*> ?: return@mapNotNull null
                    val id = l.getOrNull(0) as? String ?: return@mapNotNull null
                    val name = l.getOrNull(1) as? String ?: return@mapNotNull null
                    Category(id, name)
                }
                "ch" -> {
                    if (r.peek() != JsonReader.Token.BEGIN_ARRAY) return null
                    val out = ArrayList<Channel>()
                    r.beginArray()
                    while (r.hasNext()) {
                        val c = JsonStream.readValue(r) as? List<*> ?: continue
                        flutterChannel(c)?.let(out::add)
                    }
                    r.endArray()
                    chans = out
                }
                else -> r.skipValue()
            }
        }
        r.endObject()
        if (saved == null || chans == null) return null
        return Cached(cats, chans!!, saved!!, hash)
    }

    /** Ein Eintrag wie in ListCache._decodeLive; Strings sind Strings, Zahlen als Text. */
    private fun flutterChannel(c: List<*>): Channel? {
        if (c.size < 10) return null
        // JsonStream liefert Zahlen als Text: nur echte JSON-Strings zählen als String.
        fun s(i: Int) = c.getOrNull(i) as? String
        val id = s(0) ?: return null
        val name = s(1) ?: return null
        val cat = s(3) ?: return null
        val url = s(4) ?: return null
        fun i(idx: Int) = (c.getOrNull(idx) as? String)?.toDoubleOrNull()?.toInt()
        val h = c.getOrNull(10) as? Map<*, *>
        return Channel(
            id = id, name = name, logoUrl = s(2), categoryId = cat, streamUrl = url, epgId = s(5),
            catchupDays = i(6) ?: 0, number = i(7) ?: 0, catchupMode = s(8), catchupSource = s(9),
            headers = h?.entries?.mapNotNull { (k, v) -> if (k is String && v is String) k to v else null }?.toMap(),
            epgShift = if (c.size > 11) i(11) ?: 0 else 0,
        )
    }
}
