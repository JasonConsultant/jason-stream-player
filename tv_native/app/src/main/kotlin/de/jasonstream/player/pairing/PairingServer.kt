package de.jasonstream.player.pairing

import de.jasonstream.core.security.SimpleUri
import de.jasonstream.core.security.UrlPolicy
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.net.Inet4Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketException
import java.net.URLDecoder
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/** Vom Handy übertragene Zugangsdaten (Port von PairingResult). */
data class PairingResult(
    /** "xtream", "m3u" oder "stalker". */
    val type: String,
    val name: String,
    val url: String,
    val username: String? = null,
    val password: String? = null,
    val mac: String? = null,
    val epgUrl: String? = null,
) {
    override fun toString() = "PairingResult(type=$type, name=$name)" // nie Zugangsdaten loggen
}

/** Fehler der Kopplung (abgelaufen, abgebrochen, kein Netz). */
class PairingException(val reason: Reason) : Exception(reason.name) {
    enum class Reason { Expired, Cancelled, NoNetwork }
}

/** Prüffehler des Formulars auf dem Handy (Text aus [PairingTexts.errors]). */
enum class PairError {
    UrlMissingXtream, UrlMissingM3u, UrlMissingStalker, UrlScheme, EpgScheme,
    UserMissing, PassMissing, MacMissing, MacFormat, Unreadable,
}

/** Übersetzte Texte der Handy-Seite (aus den String-Ressourcen der App-Sprache). */
data class PairingTexts(
    val lang: String = "de",
    val pageTitle: String = "Mit Fernseher koppeln",
    val subtitle: String = "Zugangsdaten an den Fernseher senden",
    val loginType: String = "Zugangsart",
    val m3uPlaylist: String = "M3U-Playlist",
    val macPortal: String = "MAC-Portal",
    val name: String = "Name",
    val optional: String = "optional",
    val nameHint: String = "z. B. Mein Anbieter",
    val serverUrl: String = "Server-URL",
    val playlistUrl: String = "Playlist-URL",
    val portalUrl: String = "Portal-URL",
    val username: String = "Benutzername",
    val password: String = "Passwort",
    val macAddress: String = "MAC-Adresse",
    val send: String = "An Fernseher senden",
    val note: String = "Die Daten gehen nur an deinen Fernseher im selben Netzwerk – nicht ins Internet. Diese Seite funktioniert nur einmal und läuft nach 10 Minuten ab.",
    val doneTitle: String = "Fertig!",
    val doneText: String = "Fertig! Schau auf deinen Fernseher.",
    val notFoundTitle: String = "Nicht gefunden",
    val notFoundText: String = "Diese Adresse ist ungültig oder abgelaufen.",
    val notAllowedTitle: String = "Nicht erlaubt",
    val notAllowedText: String = "Diese Anfrage wird nicht unterstützt.",
    val badRequestTitle: String = "Ungültige Anfrage",
    val badFormatText: String = "Falsches Datenformat.",
    val tooLargeTitle: String = "Zu groß",
    val tooLargeText: String = "Die Eingaben sind zu umfangreich.",
    val expiredTitle: String = "Abgelaufen",
    val expiredText: String = "Diese Kopplung ist bereits beendet.",
    val errors: Map<PairError, String> = emptyMap(),
)

/**
 * Kopplungs-Sitzung auf dem Fernseher (Port von pairing_server.dart):
 * 1. [start] öffnet einen kleinen HTTP-Server auf der WLAN-Adresse (zufälliger Port).
 * 2. [url] (`http://<ip>:<port>/p/<token>`) als QR-Code anzeigen.
 * 3. Das Handy öffnet die Adresse im Browser und schickt das Formular ab.
 * 4. [onResult] bekommt die Zugangsdaten; der Server beendet sich danach.
 *
 * Sicherheit: nur der geheime Token-Pfad (128 Bit) wird beantwortet,
 * einmalige Nutzung, Ablauf nach [ttlMs], Größenlimit, strenge Header.
 */
class PairingSession private constructor(
    private val server: ServerSocket,
    private val path: String,
    val url: String,
    private val texts: PairingTexts,
    private val onResult: (Result<PairingResult>) -> Unit,
) {
    private val closed = AtomicBoolean(false)
    private val pool = Executors.newFixedThreadPool(3) { r -> Thread(r, "pairing").apply { isDaemon = true } }
    private val timer = Executors.newSingleThreadScheduledExecutor { r -> Thread(r, "pairing-timer").apply { isDaemon = true } }

    val isActive: Boolean get() = !closed.get()

    private fun begin(ttlMs: Long) {
        timer.schedule({ finish(Result.failure(PairingException(PairingException.Reason.Expired))) }, ttlMs, TimeUnit.MILLISECONDS)
        Thread({
            while (!closed.get()) {
                val s = try { server.accept() } catch (_: Exception) { break }
                try { pool.execute { handleSafely(s) } } catch (_: Exception) { runCatching { s.close() } }
            }
        }, "pairing-accept").apply { isDaemon = true }.start()
    }

    /** Vorzeitig beenden (Bildschirm verlassen). */
    fun cancel() = finish(Result.failure(PairingException(PairingException.Reason.Cancelled)))

    private fun finish(r: Result<PairingResult>) {
        if (!closed.compareAndSet(false, true)) return
        runCatching { server.close() }
        timer.shutdownNow()
        pool.shutdown()
        onResult(r)
    }

    // ------------------------------------------------------------------ HTTP

    private class Request(val method: String, val target: String, val headers: Map<String, String>, val input: InputStream)

    private fun handleSafely(s: Socket) {
        try {
            s.soTimeout = 15_000
            s.use { handle(it) }
        } catch (_: Exception) {
            // Verbindungsfehler einzelner Anfragen ignorieren.
        }
    }

    private fun handle(s: Socket) {
        val input = s.getInputStream().buffered()
        val out = s.getOutputStream()
        val req = readHead(input) ?: return send(out, 400, messagePage(texts.badRequestTitle, texts.badFormatText))
        val reqPath = req.target.substringBefore('?')
        val hasQuery = req.target.contains('?')
        if (closed.get() || hasQuery || !constantTimeEquals(reqPath, path)) {
            return send(out, 404, messagePage(texts.notFoundTitle, texts.notFoundText))
        }
        when (req.method) {
            "GET" -> send(out, 200, formPage())
            "POST" -> handlePost(req, out)
            else -> send(out, 405, messagePage(texts.notAllowedTitle, texts.notAllowedText), extra = mapOf("Allow" to "GET, POST"))
        }
    }

    private fun handlePost(req: Request, out: OutputStream) {
        val ct = req.headers["content-type"]?.substringBefore(';')?.trim()?.lowercase()
        if (ct != "application/x-www-form-urlencoded") {
            return send(out, 415, messagePage(texts.badRequestTitle, texts.badFormatText))
        }
        val len = req.headers["content-length"]?.trim()?.toLongOrNull()
            ?: return send(out, 411, messagePage(texts.badRequestTitle, texts.badFormatText))
        if (len > MAX_BODY || len < 0) return send(out, 413, messagePage(texts.tooLargeTitle, texts.tooLargeText))
        val body = ByteArray(len.toInt())
        var n = 0
        while (n < body.size) {
            val r = req.input.read(body, n, body.size - n)
            if (r < 0) break
            n += r
        }
        if (closed.get()) return send(out, 410, messagePage(texts.expiredTitle, texts.expiredText))
        val fields = try {
            parseForm(String(body, 0, n, Charsets.UTF_8))
        } catch (_: Exception) {
            return send(out, 400, formPage(error = texts.errors[PairError.Unreadable] ?: texts.badFormatText))
        }
        val form = PairForm.from(fields)
        val err = form.validate()
        if (err != null) return send(out, 422, formPage(form, texts.errors[err] ?: err.name))
        send(out, 200, messagePage(texts.doneTitle, texts.doneText, success = true))
        finish(Result.success(form.toResult()))
    }

    private fun readHead(input: InputStream): Request? {
        val head = ByteArrayOutputStream()
        var last4 = 0
        while (true) {
            val b = input.read()
            if (b < 0) return null
            head.write(b)
            last4 = (last4 shl 8) or b
            if (last4 == 0x0D0A0D0A) break
            if (head.size() > MAX_HEAD) return null
        }
        val lines = head.toString(Charsets.ISO_8859_1.name()).split("\r\n")
        val parts = lines.first().split(' ')
        if (parts.size < 3 || !parts[2].startsWith("HTTP/")) return null
        val headers = HashMap<String, String>()
        for (l in lines.drop(1)) {
            val i = l.indexOf(':')
            if (i > 0) headers[l.substring(0, i).trim().lowercase()] = l.substring(i + 1).trim()
        }
        return Request(parts[0], parts[1], headers, input)
    }

    private fun send(out: OutputStream, status: Int, html: String, extra: Map<String, String> = emptyMap()) {
        val bytes = html.toByteArray(Charsets.UTF_8)
        val sb = StringBuilder()
        sb.append("HTTP/1.1 ").append(status).append(' ').append(reason(status)).append("\r\n")
        val headers = LinkedHashMap(SECURITY_HEADERS)
        headers["Content-Type"] = "text/html; charset=utf-8"
        headers["Content-Length"] = bytes.size.toString()
        headers["Connection"] = "close"
        headers.putAll(extra)
        for ((k, v) in headers) sb.append(k).append(": ").append(v).append("\r\n")
        sb.append("\r\n")
        out.write(sb.toString().toByteArray(Charsets.ISO_8859_1))
        out.write(bytes)
        out.flush()
    }

    // ------------------------------------------------------------------ HTML

    private fun page(title: String, body: String) = "<!doctype html><html lang=\"${e(texts.lang)}\"><head><meta charset=\"utf-8\">" +
        "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">" +
        "<meta name=\"referrer\" content=\"no-referrer\">" +
        "<title>${e(title)}</title><style>$CSS</style></head><body><main>$body</main></body></html>"

    private fun messagePage(title: String, text: String, success: Boolean = false): String {
        val icon = if (success) "<div class=\"ok\">&#10003;</div>" else ""
        return page(title, "$icon<h1>${e(title)}</h1><p class=\"sub\">${e(text)}</p>")
    }

    private fun formPage(form: PairForm? = null, error: String? = null): String {
        val f = form ?: PairForm()
        val type = f.type
        fun opt(v: String, label: String) = "<option value=\"$v\"${if (type == v) " selected" else ""}>${e(label)}</option>"
        fun hiddenUnless(t: String) = if (type == t) "" else " hidden"
        val urlLabel = when (type) { "m3u" -> texts.playlistUrl; "stalker" -> texts.portalUrl; else -> texts.serverUrl }
        val b = StringBuilder()
        b.append("<h1>Jason Stream Player</h1><p class=\"sub\">${e(texts.subtitle)}</p>")
        if (error != null) b.append("<div class=\"err\" role=\"alert\">${e(error)}</div>")
        b.append("<form method=\"post\" action=\"${e(path)}\" autocomplete=\"off\">")
        b.append("<label for=\"type\">${e(texts.loginType)}</label><select id=\"type\" name=\"type\">")
        b.append(opt("xtream", "Xtream Codes")).append(opt("m3u", texts.m3uPlaylist)).append(opt("stalker", texts.macPortal))
        b.append("</select>")
        b.append("<label for=\"name\">${e(texts.name)} <span class=\"opt\">(${e(texts.optional)})</span></label>")
        b.append("<input id=\"name\" name=\"name\" maxlength=\"100\" value=\"${e(f.name)}\" placeholder=\"${e(texts.nameHint)}\">")
        b.append("<label for=\"url\" id=\"urlLabel\">${e(urlLabel)}</label>")
        b.append("<input id=\"url\" name=\"url\" type=\"url\" inputmode=\"url\" required maxlength=\"2000\" autocapitalize=\"off\" spellcheck=\"false\" value=\"${e(f.safeUrl)}\" placeholder=\"http://…\">")
        b.append("<div id=\"xtream\"${hiddenUnless("xtream")}>")
        b.append("<label for=\"username\">${e(texts.username)}</label>")
        b.append("<input id=\"username\" name=\"username\" maxlength=\"200\" autocapitalize=\"off\" spellcheck=\"false\" value=\"${e(f.username)}\">")
        b.append("<label for=\"password\">${e(texts.password)}</label>")
        b.append("<input id=\"password\" name=\"password\" type=\"password\" maxlength=\"200\" autocomplete=\"new-password\">")
        b.append("</div><div id=\"stalker\"${hiddenUnless("stalker")}>")
        b.append("<label for=\"mac\">${e(texts.macAddress)}</label>")
        b.append("<input id=\"mac\" name=\"mac\" maxlength=\"17\" autocapitalize=\"characters\" spellcheck=\"false\" placeholder=\"00:1A:79:XX:XX:XX\" pattern=\"[0-9A-Fa-f]{2}([:\\-][0-9A-Fa-f]{2}){5}\" value=\"${e(f.mac)}\">")
        b.append("</div>")
        b.append("<label for=\"epg\">EPG-URL <span class=\"opt\">(${e(texts.optional)})</span></label>")
        b.append("<input id=\"epg\" name=\"epg\" type=\"url\" inputmode=\"url\" maxlength=\"2000\" autocapitalize=\"off\" spellcheck=\"false\" value=\"${e(f.epgUrl)}\" placeholder=\"http://…\">")
        b.append("<button type=\"submit\">${e(texts.send)}</button></form>")
        b.append("<p class=\"note\">${e(texts.note)}</p>")
        b.append("<script>").append(js()).append("</script>")
        return page(texts.pageTitle, b.toString())
    }

    private fun js(): String {
        fun j(s: String) = "\"" + s.replace("\\", "\\\\").replace("\"", "\\\"").replace("<", "\\u003c").replace("\n", " ") + "\""
        val labels = "{\"xtream\":${j(texts.serverUrl)},\"m3u\":${j(texts.playlistUrl)},\"stalker\":${j(texts.portalUrl)}}"
        return """
(function(){
var t=document.getElementById("type"),l=document.getElementById("urlLabel"),
x=document.getElementById("xtream"),s=document.getElementById("stalker"),
u=document.getElementById("username"),p=document.getElementById("password"),
m=document.getElementById("mac");
var labels=$labels;
function upd(){var v=t.value;l.textContent=labels[v]||"URL";
x.hidden=v!=="xtream";s.hidden=v!=="stalker";
u.required=p.required=v==="xtream";m.required=v==="stalker";}
t.addEventListener("change",upd);upd();
})();
"""
    }

    companion object {
        const val TTL_MS = 10 * 60_000L
        const val MAX_BODY = 16 * 1024
        private const val MAX_HEAD = 8 * 1024

        private val SECURITY_HEADERS = linkedMapOf(
            "Cache-Control" to "no-store",
            "Pragma" to "no-cache",
            "Content-Security-Policy" to "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; form-action 'self'",
            "X-Content-Type-Options" to "nosniff",
            "Referrer-Policy" to "no-referrer",
            "X-Frame-Options" to "DENY",
        )

        /**
         * Startet die Sitzung (blockiert kurz – nicht auf dem Haupt-Thread).
         * [bindAddress] nur für Tests (Loopback); sonst die WLAN-/LAN-Adresse.
         */
        fun start(
            texts: PairingTexts,
            bindAddress: InetAddress? = null,
            ttlMs: Long = TTL_MS,
            onResult: (Result<PairingResult>) -> Unit,
        ): PairingSession {
            val address = bindAddress ?: findLanAddress() ?: throw PairingException(PairingException.Reason.NoNetwork)
            val server = ServerSocket()
            server.reuseAddress = true
            server.bind(InetSocketAddress(address, 0), 8)
            val path = "/p/" + newToken()
            val url = "http://${address.hostAddress}:${server.localPort}$path"
            return PairingSession(server, path, url, texts, onResult).also { it.begin(ttlMs) }
        }

        fun findLanAddress(): InetAddress? = try {
            pickLanAddress(NetworkInterface.getNetworkInterfaces()?.toList().orEmpty()
                .filter { runCatching { it.isUp && !it.isLoopback }.getOrDefault(false) }
                .flatMap { it.inetAddresses.toList() })
        } catch (_: SocketException) {
            null
        }

        /** Private Bereiche (192.168/16, 10/8, 172.16/12) zuerst, sonst andere IPv4 außer Loopback/Link-Local. */
        fun pickLanAddress(addresses: List<InetAddress>): InetAddress? {
            val c = addresses.filter { it is Inet4Address && !it.isLoopbackAddress && !it.isLinkLocalAddress && it.address[0].toInt() != 0 }
            fun rank(a: InetAddress): Int {
                val b = a.address.map { it.toInt() and 0xff }
                return when {
                    b[0] == 192 && b[1] == 168 -> 0
                    b[0] == 10 -> 1
                    b[0] == 172 && b[1] in 16..31 -> 2
                    else -> 3
                }
            }
            return c.minByOrNull { rank(it) }
        }

        /** 128 Bit Zufall, base64url ohne Auffüllzeichen. */
        fun newToken(): String {
            val b = ByteArray(16).also { SecureRandom().nextBytes(it) }
            return Base64.getUrlEncoder().withoutPadding().encodeToString(b)
        }

        private fun constantTimeEquals(a: String, b: String) =
            MessageDigest.isEqual(a.toByteArray(Charsets.UTF_8), b.toByteArray(Charsets.UTF_8))

        fun parseForm(s: String): Map<String, String> {
            val out = HashMap<String, String>()
            if (s.isEmpty()) return out
            for (pair in s.split('&')) {
                if (pair.isEmpty()) continue
                val i = pair.indexOf('=')
                val k = URLDecoder.decode(if (i < 0) pair else pair.substring(0, i), "UTF-8")
                val v = if (i < 0) "" else URLDecoder.decode(pair.substring(i + 1), "UTF-8")
                out.putIfAbsent(k, v)
            }
            return out
        }

        private fun e(s: String?): String = buildString {
            for (ch in s.orEmpty()) when (ch) {
                '&' -> append("&amp;"); '<' -> append("&lt;"); '>' -> append("&gt;")
                '"' -> append("&quot;"); '\'' -> append("&#39;")
                else -> append(ch)
            }
        }

        private fun reason(s: Int) = when (s) {
            200 -> "OK"; 400 -> "Bad Request"; 404 -> "Not Found"; 405 -> "Method Not Allowed"
            410 -> "Gone"; 411 -> "Length Required"; 413 -> "Payload Too Large"; 415 -> "Unsupported Media Type"
            422 -> "Unprocessable Entity"; else -> "Status"
        }

        private const val CSS = """
*{box-sizing:border-box}
body{margin:0;background:#0f1115;color:#e8eaf0;font:16px/1.45 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
main{max-width:480px;margin:0 auto;padding:24px 16px 40px}
h1{font-size:1.5rem;margin:0 0 4px}
p.sub{color:#9aa1b2;margin:0 0 20px}
label{display:block;font-size:.9rem;color:#b9bfcc;margin:14px 0 6px}
input,select{width:100%;padding:12px;border-radius:10px;border:1px solid #2a2f3a;background:#181b22;color:#e8eaf0;font-size:1rem}
input:focus,select:focus{outline:2px solid #4f8cff;border-color:transparent}
button{width:100%;margin-top:22px;padding:14px;border:0;border-radius:10px;background:#4f8cff;color:#fff;font-size:1.05rem;font-weight:600}
.err{background:#3a1d22;border:1px solid #7a2d38;color:#ffc9d0;padding:12px;border-radius:10px;margin-bottom:8px}
.ok{font-size:3rem;margin:24px 0 8px}
.note{color:#8a90a0;font-size:.85rem;margin-top:20px}
.opt{color:#7d8392;font-weight:400}
[hidden]{display:none!important}
"""
    }
}

/** Formularinhalt mit Prüfung (Port von _FormData). */
data class PairForm(
    val type: String = "xtream",
    val name: String = "",
    val url: String = "",
    val username: String = "",
    val password: String = "",
    val mac: String = "",
    val epgUrl: String = "",
) {
    /** URL nur zurückgeben, wenn sie keine Zugangsdaten enthält. */
    val safeUrl: String
        get() {
            val u = SimpleUri.parse(url) ?: return ""
            return if (u.userInfo.isNotEmpty() || u.query != null) "" else url
        }

    fun validate(): PairError? {
        if (url.isEmpty()) return when (type) {
            "m3u" -> PairError.UrlMissingM3u
            "stalker" -> PairError.UrlMissingStalker
            else -> PairError.UrlMissingXtream
        }
        if (!UrlPolicy.isWeb(url)) return PairError.UrlScheme
        if (epgUrl.isNotEmpty() && !UrlPolicy.isWeb(epgUrl)) return PairError.EpgScheme
        when (type) {
            "xtream" -> {
                if (username.isEmpty()) return PairError.UserMissing
                if (password.isEmpty()) return PairError.PassMissing
            }
            "stalker" -> {
                if (mac.isEmpty()) return PairError.MacMissing
                if (!MAC_RE.matches(mac)) return PairError.MacFormat
            }
        }
        return null
    }

    fun toResult(): PairingResult {
        val host = SimpleUri.parse(url)?.host.orEmpty()
        return PairingResult(
            type = type,
            name = name.ifEmpty { host },
            url = url,
            username = if (type == "xtream") username else null,
            password = if (type == "xtream") password else null,
            mac = if (type == "stalker") mac else null,
            epgUrl = epgUrl.ifEmpty { null },
        )
    }

    companion object {
        private val MAC_RE = Regex("^[0-9A-F]{2}(:[0-9A-F]{2}){5}$")
        private val TYPES = setOf("xtream", "m3u", "stalker")

        fun from(f: Map<String, String>): PairForm {
            fun v(k: String, max: Int = 2000): String {
                val s = (f[k] ?: "").trim()
                return if (s.length > max) s.substring(0, max) else s
            }
            val rawType = v("type", 20)
            return PairForm(
                type = if (rawType in TYPES) rawType else "xtream",
                name = v("name", 100),
                url = v("url"),
                username = v("username", 200),
                password = v("password", 200),
                mac = v("mac", 17).uppercase().replace('-', ':'),
                epgUrl = v("epg"),
            )
        }
    }
}
