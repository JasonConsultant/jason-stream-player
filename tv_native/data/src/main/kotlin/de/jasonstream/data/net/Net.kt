package de.jasonstream.data.net

import de.jasonstream.core.model.RepositoryException
import de.jasonstream.core.security.UrlPolicy
import okhttp3.Call
import okhttp3.Dispatcher
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okio.Buffer
import okio.BufferedSource
import okio.ForwardingSource
import okio.buffer
import java.io.Closeable
import java.util.concurrent.TimeUnit

/**
 * Sichere HTTP-Abrufe für Portal, Playlist und EPG (Port von net.dart):
 * - nur http/https,
 * - Größenlimit (manipulierte Antworten fluten nicht den Speicher),
 * - Weiterleitungen selbst verfolgt: höchstens 5, nie https → http.
 *
 * Antworten werden als Datenstrom geliefert ([open]) – große Listen werden
 * gestreamt geparst und nie komplett im Speicher gehalten.
 */
object Net {
    const val USER_AGENT = "JasonStreamPlayer/0.9"

    /** Ein Client für die ganze App (Verbindungs-Pool, Threads). In Tests ersetzbar. */
    @Volatile
    var client: OkHttpClient = defaultClient()

    fun defaultClient(): OkHttpClient = OkHttpClient.Builder()
        .followRedirects(false)
        .followSslRedirects(false)
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .retryOnConnectionFailure(true)
        .dispatcher(Dispatcher().apply { maxRequestsPerHost = 6 })
        .build()

    /** Geöffnete Antwort: Datenstrom + angekündigte Größe. Immer schließen. */
    class Body(private val response: Response, val source: BufferedSource, val declaredLength: Long?) : Closeable {
        val finalUrl: String get() = response.request.url.toString()
        override fun close() = response.close()
    }

    fun open(
        url: String,
        headers: Map<String, String> = emptyMap(),
        timeoutMs: Long = 30_000,
        maxBytes: Long = 64L * 1024 * 1024,
    ): Body {
        var current = url
        for (hop in 0..5) {
            if (!UrlPolicy.isWeb(current)) throw RepositoryException("Unsichere Adresse blockiert.")
            val httpUrl = current.toHttpUrlOrNull() ?: throw RepositoryException("Ungültige Adresse.")
            val req = Request.Builder().url(httpUrl).header("User-Agent", USER_AGENT).apply {
                headers.forEach { (k, v) -> header(k, v) } // darf User-Agent ersetzen
            }.build()
            val call: Call = client.newBuilder()
                .readTimeout(timeoutMs, TimeUnit.MILLISECONDS)
                .callTimeout(0, TimeUnit.MILLISECONDS)
                .build().newCall(req)
            val res = call.execute()
            val code = res.code
            if (code in 300..399) {
                val loc = res.header("Location")
                res.close()
                if (loc == null) throw RepositoryException("Ungültige Weiterleitung vom Server.")
                val next = httpUrl.resolve(loc)?.toString()
                    ?: throw RepositoryException("Ungültige Weiterleitung vom Server.")
                if (httpUrl.isHttps && !next.startsWith("https:")) {
                    throw RepositoryException("Weiterleitung auf unverschlüsselte Verbindung blockiert.")
                }
                current = next
                continue
            }
            when {
                code == 451 -> { res.close(); throw RepositoryException("An deinem Standort nicht verfügbar (HTTP 451).", 451) }
                code == 401 || code == 403 -> { res.close(); throw RepositoryException("Zugriff verweigert – Zugangsdaten prüfen (HTTP $code).", code) }
                code != 200 -> { res.close(); throw RepositoryException("Server antwortet mit HTTP $code.", code) }
            }
            val body = res.body ?: run { res.close(); throw RepositoryException("Leere Antwort.") }
            val declared = body.contentLength().takeIf { it > 0 }
            if (declared != null && declared > maxBytes) {
                res.close(); throw RepositoryException("Antwort des Servers ist zu groß.")
            }
            return Body(res, LimitedSource(body.source(), maxBytes).buffer(), declared)
        }
        throw RepositoryException("Zu viele Weiterleitungen.")
    }

    /** Komplett laden (kleine Antworten). */
    fun get(
        url: String,
        headers: Map<String, String> = emptyMap(),
        timeoutMs: Long = 30_000,
        maxBytes: Long = 64L * 1024 * 1024,
    ): ByteArray = open(url, headers, timeoutMs, maxBytes).use { it.source.readByteArray() }

    private class LimitedSource(src: okio.Source, private val max: Long) : ForwardingSource(src) {
        private var n = 0L
        override fun read(sink: Buffer, byteCount: Long): Long {
            val r = super.read(sink, byteCount)
            if (r > 0) {
                n += r
                if (n > max) throw TooLarge()
            }
            return r
        }
    }

    /** Kein Host-Fehler (anderer Spiegel liefert dieselbe Größe). */
    class TooLarge : RepositoryException("Antwort des Servers ist zu groß.")
}
