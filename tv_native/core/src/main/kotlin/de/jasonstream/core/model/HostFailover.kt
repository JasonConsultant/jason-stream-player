package de.jasonstream.core.model

import java.io.IOException
import java.io.InterruptedIOException
import java.util.concurrent.ConcurrentHashMap

/** Fehler einer Quelle mit verständlicher Meldung (ohne Zugangsdaten). */
open class RepositoryException(message: String, val statusCode: Int? = null) : Exception(message)

/**
 * Ersatz-Adressen eines Portals ([Portal.altUrls]) – Port von
 * lib/data/host_failover.dart. Antwortet die Hauptadresse nicht
 * (Zeitüberschreitung, Verbindungsfehler, HTTP 404/408/429/5xx), wird die
 * nächste probiert; die zuletzt funktionierende wird gemerkt.
 */
object HostFailover {
    /** Portal-ID → Index der zuletzt funktionierenden Adresse in [bases]. */
    private val active = ConcurrentHashMap<String, Int>()

    /** Speichert die Wahl dauerhaft (setzt Storage beim Öffnen). */
    @Volatile
    var persist: ((portalId: String, index: Int) -> Unit)? = null

    fun restore(portalId: String, index: Int) { active[portalId] = index }
    fun reset() = active.clear()
    fun forget(portalId: String) { active.remove(portalId) }

    /** Alle Adressen: Hauptadresse zuerst, dann Ersatz-Adressen (ohne Doppelte). */
    fun bases(p: Portal): List<String> {
        val out = ArrayList<String>()
        for (u in listOf(p.url) + p.altUrls) {
            val t = u.trim()
            if (t.isNotEmpty() && t !in out) out.add(t)
        }
        return out
    }

    fun activeIndex(p: Portal): Int {
        val i = active[p.id] ?: 0
        return if (i < bases(p).size) i else 0
    }

    fun activeBase(p: Portal): String {
        val b = bases(p)
        return if (b.isEmpty()) p.url.trim() else b[activeIndex(p)]
    }

    /** Reihenfolge der Versuche: bevorzugte zuerst, dann die übrigen. */
    fun order(p: Portal): List<Int> {
        val n = bases(p).size
        val a = activeIndex(p)
        return listOf(a) + (0 until n).filter { it != a }
    }

    fun markWorking(p: Portal, index: Int) {
        if (active[p.id] == index) return
        if (index == 0 && !active.containsKey(p.id)) return
        active[p.id] = index
        persist?.invoke(p.id, index)
    }

    /** Fehler, bei dem eine andere Adresse helfen könnte (nicht 401/403). */
    fun isHostFailure(e: Throwable): Boolean {
        if (e is RepositoryException) {
            val s = e.statusCode ?: return false
            return s == 404 || s == 408 || s == 429 || s >= 500
        }
        return e is IOException || e is InterruptedIOException
    }

    /** [f] mit der bevorzugten Adresse ausführen, bei Host-Fehlern mit den übrigen. */
    inline fun <T> run(p: Portal, f: (base: String) -> T): T {
        val b = bases(p)
        if (b.size <= 1) return f(if (b.isEmpty()) p.url.trim() else b.first())
        var first: Throwable? = null
        for (i in order(p)) {
            try {
                val r = f(b[i])
                markWorking(p, i)
                return r
            } catch (e: Throwable) {
                if (!isHostFailure(e)) throw e
                if (first == null) first = e
            }
        }
        throw first!!
    }

    /** Stream-Adresse auf die bevorzugte Adresse umschreiben. */
    fun rewrite(p: Portal, url: String): String {
        if (bases(p).size <= 1) return url
        return rewriteTo(p, url, activeIndex(p))
    }

    fun rewriteTo(p: Portal, url: String, target: Int): String {
        val b = bases(p).map { it.trimEnd('/') }
        if (target < 0 || target >= b.size) return url
        // 1) Gleiches Präfix (Xtream: http://host:port/pfad)
        for (i in b.indices) {
            if (i != target && b[i].isNotEmpty() && url.startsWith("${b[i]}/")) {
                return b[target] + url.substring(b[i].length)
            }
        }
        // 2) Gleicher Host (M3U: Playlist und Streams auf demselben Server)
        val u = de.jasonstream.core.security.SimpleUri.parse(url) ?: return url
        val t = de.jasonstream.core.security.SimpleUri.parse(b[target]) ?: return url
        if (u.scheme.isEmpty() || t.host.isEmpty()) return url
        val o = u.origin
        if (!url.lowercase().startsWith(o)) return url
        for (i in b.indices) {
            if (i == target) continue
            val bi = de.jasonstream.core.security.SimpleUri.parse(b[i]) ?: continue
            if (bi.host.isEmpty()) continue
            if (bi.origin == o) return t.origin + url.substring(o.length)
        }
        return url
    }

    /** Alle Varianten einer Stream-Adresse (bevorzugte zuerst). */
    fun streamCandidates(p: Portal, url: String): List<String> {
        val out = ArrayList<String>()
        for (i in order(p)) {
            val r = rewriteTo(p, url, i)
            if (r !in out) out.add(r)
        }
        if (out.isEmpty()) out.add(url)
        return out
    }
}
