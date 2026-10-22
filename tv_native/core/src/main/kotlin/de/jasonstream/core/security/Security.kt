package de.jasonstream.core.security

import java.security.SecureRandom
import java.util.Base64
import java.util.concurrent.ConcurrentHashMap
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * Schutz von Zugangsdaten und Eingaben – Port von lib/core/security.dart.
 *
 * - [Redactor] entfernt Benutzername/Passwort aus allem, was angezeigt oder
 *   geloggt wird.
 * - [UrlPolicy] lässt nur sichere Adress-Schemata zu.
 * - [PinHasher] speichert die Kindersicherungs-PIN nur als Hash.
 */
object Redactor {
    private val secrets: MutableSet<String> = ConcurrentHashMap.newKeySet()

    /** Zugangsdaten eines Portals merken, damit sie überall ausgeblendet werden. */
    fun register(username: String?, password: String?) {
        for (s in listOf(username, password)) {
            if (s == null || s.length < 2) continue
            secrets.add(s)
            secrets.add(SimpleUri.encodeComponent(s))
            secrets.add(SimpleUri.encodeQueryComponent(s))
        }
    }

    /** Zugangsdaten aus einer Playlist-Adresse (…?username=…&password=…). */
    fun registerUrl(url: String) {
        val u = SimpleUri.parse(url) ?: return
        val q = u.queryParameters
        register(q["username"] ?: q["user"], q["password"] ?: q["pass"])
        if (u.userInfo.isNotEmpty()) {
            val parts = u.userInfo.split(':')
            register(parts.first(), parts.getOrNull(1))
        }
        for (k in listOf("token", "key", "auth")) {
            q[k]?.let { register(it, null) }
        }
    }

    fun clear() = secrets.clear()

    private val paramRe = Regex("(username|password|pass|user|token|key)=([^&\\s\"]+)", RegexOption.IGNORE_CASE)
    private val pathRe = Regex("/(live|movie|series|timeshift)/[^/\\s]+/[^/\\s]+/")

    /** Text ohne Zugangsdaten. */
    fun redact(text: String): String {
        var out = text
        for (s in secrets.sortedByDescending { it.length }) out = out.replace(s, "•••")
        out = paramRe.replace(out) { "${it.groupValues[1]}=•••" }
        out = pathRe.replace(out) { "/${it.groupValues[1]}/•••/•••/" }
        return out
    }
}

object UrlPolicy {
    /** Erlaubt für Portal, Playlist, EPG und Bilder. */
    fun isWeb(url: String?): Boolean {
        val u = SimpleUri.parse(url) ?: return false
        return (u.scheme == "http" || u.scheme == "https") && u.host.isNotEmpty()
    }

    private val streamSchemes = setOf(
        "http", "https", "rtmp", "rtmps", "rtsp", "rtsps", "rtp", "udp", "mms", "mmsh", "srt",
    )

    /** Erlaubt für Streams. Blockiert u. a. file:, content:, data:, javascript:. */
    fun isStream(url: String?): Boolean {
        val u = SimpleUri.parse(url) ?: return false
        if (u.scheme !in streamSchemes) return false
        return u.host.isNotEmpty() || u.scheme == "udp" || u.scheme == "rtp"
    }

    /** Bild-URL nur, wenn http(s) – sonst null. */
    fun image(url: String?): String? = if (isWeb(url)) url!!.trim() else null

    fun isUnencrypted(url: String) = SimpleUri.parse(url)?.scheme == "http"
}

/** PBKDF2-HMAC-SHA256 (ein Block, 30 000 Runden) – identisch zur Dart-Version. */
object PinHasher {
    const val ITERATIONS = 30000
    private val rnd = SecureRandom()

    fun newSalt(): String {
        val b = ByteArray(16)
        rnd.nextBytes(b)
        return Base64.getEncoder().encodeToString(b)
    }

    fun hash(pin: String, salt: String): String {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(pin.toByteArray(Charsets.UTF_8).let { if (it.isEmpty()) ByteArray(1) else it }, "HmacSHA256"))
        val saltBytes = Base64.getDecoder().decode(salt)
        var u = mac.doFinal(saltBytes + byteArrayOf(0, 0, 0, 1))
        val out = u.copyOf()
        for (i in 1 until ITERATIONS) {
            u = mac.doFinal(u)
            for (j in out.indices) out[j] = (out[j].toInt() xor u[j].toInt()).toByte()
        }
        return Base64.getEncoder().encodeToString(out)
    }

    /** Vergleich in konstanter Zeit. */
    fun equals(a: String, b: String): Boolean {
        if (a.length != b.length) return false
        var diff = 0
        for (i in a.indices) diff = diff or (a[i].code xor b[i].code)
        return diff == 0
    }
}
