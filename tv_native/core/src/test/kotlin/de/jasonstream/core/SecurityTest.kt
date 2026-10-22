package de.jasonstream.core

import de.jasonstream.core.model.Portal
import de.jasonstream.core.model.PortalType
import de.jasonstream.core.model.normalizeRating
import de.jasonstream.core.security.AesGcmFormat
import de.jasonstream.core.security.PinHasher
import de.jasonstream.core.security.Redactor
import de.jasonstream.core.security.SimpleUri
import de.jasonstream.core.security.UrlPolicy
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import javax.crypto.spec.SecretKeySpec

/** Port von test/security_test.dart + Format-Tests für SecureBox. */
class SecurityTest {
    @Before fun setUp() = Redactor.clear()

    @Test fun `Redactor entfernt registriertes Passwort und Benutzername`() {
        Redactor.register("jason77", "Geheim!123")
        val msg = Redactor.redact(
            "ClientException: Connection failed, uri=http://srv.example:8080/player_api.php?username=jason77&password=Geheim%21123",
        )
        assertFalse(msg.contains("jason77"))
        assertFalse(msg.contains("Geheim"))
    }

    @Test fun `Redactor maskiert Parameter und Xtream-Pfade`() {
        val msg = Redactor.redact("get.php?username=bob&password=xyz789&type=m3u")
        assertTrue(msg.contains("username=•••"))
        assertTrue(msg.contains("password=•••"))
        assertFalse(msg.contains("xyz789"))
        val p = Redactor.redact("Fehler bei http://h:80/live/bob/pw42/123.ts")
        assertFalse(p.contains("pw42"))
        assertTrue(p.contains("/live/•••/•••/"))
    }

    @Test fun `Zugangsdaten aus M3U-Adresse`() {
        Redactor.registerUrl("http://h.example/get.php?username=anna&password=s3cr3t&type=m3u_plus")
        assertEquals("Login ••• für •••", Redactor.redact("Login s3cr3t für anna"))
    }

    @Test fun `UrlPolicy`() {
        assertTrue(UrlPolicy.isStream("http://a.b/1.ts"))
        assertTrue(UrlPolicy.isStream("https://a.b/x.m3u8"))
        assertTrue(UrlPolicy.isStream("rtmp://a.b/live"))
        assertTrue(UrlPolicy.isStream("udp://@239.0.0.1:1234"))
        assertFalse(UrlPolicy.isStream("file:///data/data/de.jasonstream.player/x"))
        assertFalse(UrlPolicy.isStream("content://media/external/1"))
        assertFalse(UrlPolicy.isStream("javascript:alert(1)"))
        assertFalse(UrlPolicy.isStream("data:text/plain,hi"))
        assertTrue(UrlPolicy.isWeb("https://x.y/logo.png"))
        assertFalse(UrlPolicy.isWeb("file:///sdcard/a.png"))
        assertFalse(UrlPolicy.isWeb("http://"))
        assertNull(UrlPolicy.image("ftp://a/b.png"))
        assertTrue(UrlPolicy.isUnencrypted("http://a.b"))
        assertFalse(UrlPolicy.isUnencrypted("https://a.b"))
        // Nachsichtig wie Dart: Leerzeichen/„|“ im Pfad.
        assertTrue(UrlPolicy.isStream("http://cdn.tv/a b|x.ts"))
    }

    @Test fun `SimpleUri`() {
        val u = SimpleUri.parse("HTTP://User:Pw@Host.Example:8080/p/a?username=a%20b&x=1+2#f")!!
        assertEquals("http", u.scheme)
        assertEquals("host.example", u.host)
        assertEquals(8080, u.port)
        assertEquals("User:Pw", u.userInfo)
        assertEquals("/p/a", u.path)
        assertEquals("a b", u.queryParameters["username"])
        assertEquals("1 2", u.queryParameters["x"])
        assertEquals("http://host.example:8080", u.origin)
        assertEquals("http://h", SimpleUri.parse("http://h:80/x")!!.origin)
        assertEquals("a%20b%21", SimpleUri.encodeComponent("a b!").replace("!", "%21"))
        assertEquals("a+b%21", SimpleUri.encodeQueryComponent("a b!"))
    }

    @Test fun `PinHasher entspricht PBKDF2-HMAC-SHA256 der Dart-Version`() {
        val salt = "AAECAwQFBgcICQoLDA0ODw=="
        assertEquals("WiHdQHK3oE68BC4tD2QawN/Hg+Qui9FbNWwWAKUgkMM=", PinHasher.hash("1234", salt))
        assertEquals("CN5cNwnqYwqsXB238SfihVYnjRy1lmNAK0UfYpphQBU=", PinHasher.hash("", salt))
        assertNotEquals(PinHasher.hash("0000", PinHasher.newSalt()), PinHasher.hash("0000", PinHasher.newSalt()))
        assertTrue(PinHasher.equals("abc", "abc"))
        assertFalse(PinHasher.equals("abc", "abd"))
    }

    @Test fun `SecureBox-Format k1 IV CT`() {
        val key = SecretKeySpec(ByteArray(32) { it.toByte() }, "AES")
        val c = AesGcmFormat.encrypt(key, "{\"url\":\"http://x\"}")
        assertTrue(c.startsWith("k1:"))
        val parts = c.removePrefix("k1:").split(":")
        assertEquals(2, parts.size)
        assertEquals(12, java.util.Base64.getDecoder().decode(parts[0]).size) // GCM-IV
        assertEquals("{\"url\":\"http://x\"}", AesGcmFormat.decrypt(key, c))
        // Von der Flutter-App (android.util.Base64 NO_WRAP) erzeugter Wert, fester Schlüssel/IV:
        val fixed = "k1:AAAAAAAAAAAAAAAA:" + java.util.Base64.getEncoder().encodeToString(
            javax.crypto.Cipher.getInstance("AES/GCM/NoPadding").run {
                init(javax.crypto.Cipher.ENCRYPT_MODE, key, javax.crypto.spec.GCMParameterSpec(128, ByteArray(12)))
                doFinal("hallo".toByteArray())
            },
        )
        assertEquals("hallo", AesGcmFormat.decrypt(key, fixed))
    }

    @Test fun `Portal-Extras wie Portal_withExtras`() {
        val j = Json.parseToJsonElement(
            """{"ua":"  ","referer":" https://r/ ","alt":["a"," ",3,"b"],"autoRefresh":2.5,"epgOffsets":{"portal":-60,"x":"1","y":30.7}}""",
        ).jsonObject
        val p = Portal.withExtras(Portal("i", "n", PortalType.xtream, "u"), j)
        assertNull(p.userAgent)
        assertEquals("https://r/", p.referer)
        assertEquals(listOf("a", "b"), p.altUrls)
        assertEquals(0, p.autoRefreshHours)
        assertEquals(mapOf("portal" to -60, "y" to 30), p.epgOffsets)
        assertEquals(listOf("a", "b"), Portal("i", "n", PortalType.m3u, "u", epgUrl = "a\n|b|").epgSources)
        assertEquals(listOf("portal"), Portal("i", "n", PortalType.m3u, "u").epgSources)
        assertEquals(p, Portal.withExtras(Portal("i", "n", PortalType.xtream, "u"), p.extrasToJson()))
    }

    @Test fun `normalizeRating`() {
        assertEquals(8.4, normalizeRating("84")!!, 1e-9)
        assertEquals(7.5, normalizeRating(7.5)!!, 1e-9)
        assertNull(normalizeRating(0))
        assertNull(normalizeRating("abc"))
        assertNull(normalizeRating(101))
    }
}
