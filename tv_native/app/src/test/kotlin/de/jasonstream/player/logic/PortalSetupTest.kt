package de.jasonstream.player.logic

import de.jasonstream.core.R as CoreR
import de.jasonstream.core.model.Portal
import de.jasonstream.core.model.PortalType
import de.jasonstream.core.model.RepositoryException
import de.jasonstream.player.R
import de.jasonstream.player.pairing.PairError
import de.jasonstream.player.pairing.PairForm
import de.jasonstream.player.pairing.PairingException
import de.jasonstream.player.pairing.PairingResult
import de.jasonstream.player.pairing.PairingSession
import de.jasonstream.player.pairing.PairingTexts
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.SocketTimeoutException
import java.net.URL
import java.net.UnknownHostException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

class PortalSetupTest {
    @Test fun xtreamValidation() {
        val e = PortalForm(type = PortalType.xtream).validate()
        assertEquals(FieldError.UrlMissing, e[PortalField.Url])
        assertEquals(FieldError.Required, e[PortalField.User])
        assertEquals(FieldError.Required, e[PortalField.Pass])
        assertNull(e[PortalField.Name]) // Name optional
        val ok = PortalForm(type = PortalType.xtream, url = "server.de:8080", user = "u", pass = "p")
        assertTrue(ok.validate().isEmpty())
        val p = ok.toPortal(newId = { "id1" })
        assertEquals("http://server.de:8080", p.url)
        assertEquals("server.de", p.name)
        assertEquals("u", p.username)
        assertEquals("p", p.password)
        assertTrue(ok.unencrypted)
        assertFalse(ok.copy(url = "https://x.de").unencrypted)
    }

    @Test fun invalidUrlAndEpg() {
        val e = PortalForm(type = PortalType.m3u, url = "ftp://x.de/list.m3u", epg = "nope://").validate()
        assertEquals(FieldError.UrlInvalid, e[PortalField.Url])
        assertEquals(FieldError.EpgInvalid, e[PortalField.Epg])
        val m = PortalForm(type = PortalType.m3u, url = "https://x.de/a.m3u", epg = "epg.de/x.xml")
        assertTrue(m.validate().isEmpty())
        val p = m.toPortal(newId = { "m" })
        assertNull(p.username)
        assertNull(p.password)
        assertEquals("http://epg.de/x.xml", p.epgUrl)
    }

    @Test fun macNormalization() {
        assertEquals("00:1A:79:12:34:56", PortalForm.normalizeMac("00-1a-79-12-34-56"))
        assertEquals("00:1A:79:12:34:56", PortalForm.normalizeMac("001a79123456"))
        val f = PortalForm(type = PortalType.stalker, url = "http://p.de/c/", mac = "00:1A:79:")
        assertEquals(FieldError.MacFormat, f.validate()[PortalField.Mac])
        val p = f.copy(mac = "00:1a:79:aa:bb:cc").toPortal(newId = { "s" })
        assertEquals("00:1A:79:AA:BB:CC", p.username)
        assertNull(p.password)
    }

    @Test fun editKeepsIdExtrasAndMultiEpg() {
        val old = Portal("x1", "Alt", PortalType.xtream, "http://a.de", "u", "p", epgUrl = "http://e1\nhttp://e2",
            userAgent = "UA", altUrls = listOf("http://b.de"), epgOffsets = mapOf("portal" to 60))
        val f = PortalForm.from(old)
        assertEquals("", f.epg) // mehrere Quellen → Feld leer
        val p = f.copy(pass = "neu").toPortal(old)
        assertEquals("x1", p.id)
        assertEquals("http://e1\nhttp://e2", p.epgUrl)
        assertEquals("UA", p.userAgent)
        assertEquals(listOf("http://b.de"), p.altUrls)
        assertEquals(mapOf("portal" to 60), p.epgOffsets)
        assertEquals("neu", p.password)
    }

    @Test fun friendlyErrors() {
        assertEquals(CoreR.string.serverIsntResponding, FriendlyError.of(SocketTimeoutException()).res)
        assertEquals(CoreR.string.serverUnreachableCheck, FriendlyError.of(RuntimeException(UnknownHostException("x"))).res)
        val denied = FriendlyError.of(RepositoryException("Zugriff verweigert – Zugangsdaten prüfen (HTTP 401).", 401))
        assertEquals(CoreR.string.accessDeniedHttp, denied.res)
        assertEquals(listOf("401"), denied.args)
        assertEquals(R.string.tv_errLoginFailed, FriendlyError.of(RepositoryException("Login fehlgeschlagen – Benutzername oder Passwort prüfen.")).res)
        assertEquals(R.string.tv_errNoM3u, FriendlyError.of(RepositoryException("Das ist keine gültige M3U-Playlist.")).res)
        assertEquals(CoreR.string.serverHttpError, FriendlyError.of(RepositoryException("Server antwortet mit HTTP 500.", 500)).res)
        val raw = FriendlyError.of(IllegalArgumentException("etwas anderes"))
        assertNull(raw.res)
        assertEquals("etwas anderes", raw.raw)
    }

    @Test fun pairFormValidation() {
        assertEquals(PairError.UrlMissingXtream, PairForm().validate())
        assertEquals(PairError.UrlMissingM3u, PairForm(type = "m3u").validate())
        assertEquals(PairError.UrlScheme, PairForm(url = "x.de").validate())
        assertEquals(PairError.UserMissing, PairForm(url = "http://x.de").validate())
        assertEquals(PairError.MacFormat, PairForm.from(mapOf("type" to "stalker", "url" to "http://x.de/c/", "mac" to "00:1A")).validate())
        assertNull(PairForm.from(mapOf("type" to "stalker", "url" to "http://x.de/c/", "mac" to "00-1a-79-12-34-56")).validate())
        val r = PairForm(url = "http://host.de:80", username = "u", password = "p").toResult()
        assertEquals("host.de", r.name)
        assertEquals("", PairForm(url = "http://u:p@x.de").safeUrl)
    }

    @Test fun pickLanAddressPrefersPrivate() {
        val a = listOf("127.0.0.1", "100.70.1.2", "10.0.0.5", "192.168.1.20").map { InetAddress.getByName(it) }
        assertEquals("192.168.1.20", PairingSession.pickLanAddress(a)?.hostAddress)
        assertNull(PairingSession.pickLanAddress(listOf(InetAddress.getByName("127.0.0.1"))))
    }

    private fun http(url: String, method: String = "GET", body: String? = null, type: String = "application/x-www-form-urlencoded"): Pair<Int, String> {
        val c = URL(url).openConnection(java.net.Proxy.NO_PROXY) as HttpURLConnection
        c.requestMethod = method
        c.connectTimeout = 3000; c.readTimeout = 3000
        if (body != null) {
            c.doOutput = true
            c.setRequestProperty("Content-Type", type)
            c.outputStream.use { it.write(body.toByteArray()) }
        }
        val code = c.responseCode
        val text = (if (code < 400) c.inputStream else c.errorStream)?.use { String(it.readBytes()) }.orEmpty()
        c.disconnect()
        return code to text
    }

    @Test fun pairingServerRoundTrip() {
        val got = AtomicReference<Result<PairingResult>>()
        val latch = CountDownLatch(1)
        val s = PairingSession.start(PairingTexts(), InetAddress.getLoopbackAddress()) { got.set(it); latch.countDown() }
        try {
            assertTrue(s.url.contains("/p/"))
            val base = s.url.substringBefore("/p/")
            assertEquals(404, http("$base/p/wrong").first)
            assertEquals(404, http(s.url + "?x=1").first)
            val (code, page) = http(s.url)
            assertEquals(200, code)
            assertTrue(page.contains("<form"))
            // Ungültig → Formular mit Fehler, Sitzung läuft weiter.
            assertEquals(422, http(s.url, "POST", "type=xtream&url=http%3A%2F%2Fx.de").first)
            assertTrue(s.isActive)
            assertEquals(415, http(s.url, "POST", "{}", type = "application/json").first)
            val ok = http(s.url, "POST", "type=xtream&name=Mein+TV&url=http%3A%2F%2Fx.de%3A8080&username=u%C3%BC&password=p%26w")
            assertEquals(200, ok.first)
            assertTrue(latch.await(3, TimeUnit.SECONDS))
            val r = got.get().getOrThrow()
            assertEquals("Mein TV", r.name)
            assertEquals("http://x.de:8080", r.url)
            assertEquals("uü", r.username)
            assertEquals("p&w", r.password)
            assertFalse(s.isActive)
        } finally {
            s.cancel()
        }
    }

    @Test fun pairingExpiresAndCancels() {
        val got = AtomicReference<Result<PairingResult>>()
        val latch = CountDownLatch(1)
        PairingSession.start(PairingTexts(), InetAddress.getLoopbackAddress(), ttlMs = 50) { got.set(it); latch.countDown() }
        assertTrue(latch.await(3, TimeUnit.SECONDS))
        assertEquals(PairingException.Reason.Expired, (got.get().exceptionOrNull() as PairingException).reason)

        val got2 = AtomicReference<Result<PairingResult>>()
        val s = PairingSession.start(PairingTexts(), InetAddress.getLoopbackAddress()) { got2.set(it) }
        s.cancel()
        assertEquals(PairingException.Reason.Cancelled, (got2.get().exceptionOrNull() as PairingException).reason)
    }
}
