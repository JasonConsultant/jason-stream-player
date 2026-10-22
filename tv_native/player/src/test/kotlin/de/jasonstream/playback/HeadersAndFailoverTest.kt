package de.jasonstream.playback

import de.jasonstream.core.model.HostFailover
import de.jasonstream.core.model.Portal
import de.jasonstream.core.model.PortalType
import de.jasonstream.playback.logic.HostCandidates
import de.jasonstream.playback.logic.PlayerHeaders
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class HeadersAndFailoverTest {
    private val portal = Portal(
        "p1", "P", PortalType.xtream, "http://main.tv:8080", "u", "pw",
        userAgent = "MyUA/1", referer = "http://ref/", altUrls = listOf("http://alt1.tv:8080", "http://alt2.tv"),
    )

    @Before fun reset() = HostFailover.reset()

    @Test fun defaultUserAgentWhenNoneSet() {
        val (url, h) = PlayerHeaders.forStream(null, null, "http://x/a.ts")
        assertEquals("http://x/a.ts", url)
        assertEquals(mapOf("User-Agent" to "JasonStreamPlayer/0.4"), h)
    }

    @Test fun portalThenChannelThenPipe() {
        val c = ch("1", headers = mapOf("referer" to "http://chref/", "X-Forwarded-For" to "1.2.3.4", "Cookie" to "a=b"))
        val (url, h) = PlayerHeaders.forStream(portal, c, "http://main.tv:8080/live/u/pw/1.ts|User-Agent=Pipe%20UA&Origin=http://o")
        assertEquals("http://main.tv:8080/live/u/pw/1.ts", url)
        assertEquals("Pipe UA", h["User-Agent"])
        assertEquals("http://chref/", h["Referer"])
        assertEquals("a=b", h["Cookie"])
        assertEquals("http://o", h["Origin"])
        assertFalse(h.keys.any { it.equals("X-Forwarded-For", true) })
    }

    @Test fun portalUserAgentSuppressesDefault() {
        val (_, h) = PlayerHeaders.forStream(portal, null, "http://main.tv:8080/x.m3u8")
        assertEquals("MyUA/1", h["User-Agent"])
        assertEquals("http://ref/", h["Referer"])
        assertNull(PlayerHeaders.headerValue(h, "cookie"))
        assertEquals("MyUA/1", PlayerHeaders.headerValue(h, "user-agent"))
    }

    @Test fun hostCandidatesFollowFailoverOrder() {
        val hc = HostCandidates(portal, "http://main.tv:8080/live/u/pw/1.ts")
        assertEquals(
            listOf("http://main.tv:8080/live/u/pw/1.ts", "http://alt1.tv:8080/live/u/pw/1.ts", "http://alt2.tv/live/u/pw/1.ts"),
            hc.urls,
        )
        assertEquals(2, hc.left)
        assertTrue(hc.next())
        assertEquals("http://alt1.tv:8080/live/u/pw/1.ts", hc.current)
        hc.markWorking()
        assertEquals(1, HostFailover.activeIndex(portal))
        // Nächster Sender startet direkt auf der funktionierenden Adresse.
        val next = HostCandidates(portal, "http://main.tv:8080/live/u/pw/2.ts")
        assertEquals("http://alt1.tv:8080/live/u/pw/2.ts", next.current)
        assertTrue(next.next())
        assertTrue(next.next())
        assertFalse(next.next())
    }

    @Test fun noPortalSingleCandidate() {
        val hc = HostCandidates(null, "http://x/1.ts")
        assertEquals(listOf("http://x/1.ts"), hc.urls)
        assertEquals(0, hc.left)
        assertFalse(hc.next())
        hc.markWorking() // kein Fehler
    }

    @Test fun foreignHostNotRewritten() {
        val hc = HostCandidates(portal, "http://cdn.other/x.ts")
        assertEquals(listOf("http://cdn.other/x.ts"), hc.urls)
    }
}
