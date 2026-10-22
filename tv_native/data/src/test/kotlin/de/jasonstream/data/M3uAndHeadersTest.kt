package de.jasonstream.data

import de.jasonstream.core.model.Channel
import de.jasonstream.core.model.EpgEntry
import de.jasonstream.core.model.Portal
import de.jasonstream.core.model.PortalType
import de.jasonstream.data.m3u.M3uParser
import de.jasonstream.data.m3u.M3uRepository
import de.jasonstream.data.net.StreamHeaders
import okio.Buffer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.ZoneOffset

/** Port von test/stream_headers_test.dart, M3U-Teil aus security_test.dart + Catch-up-Vorlagen. */
class M3uAndHeadersTest {
    @Test fun `EXTVLCOPT user-agent, referrer, origin`() {
        assertEquals(mapOf("User-Agent" to "Mozilla/5.0 (X11)"), StreamHeaders.parseM3uOptionLine("#EXTVLCOPT:http-user-agent=Mozilla/5.0 (X11)"))
        assertEquals(mapOf("Referer" to "https://site.tv/"), StreamHeaders.parseM3uOptionLine("#EXTVLCOPT:http-referrer=https://site.tv/"))
        assertEquals(mapOf("Origin" to "https://site.tv"), StreamHeaders.parseM3uOptionLine("#EXTVLCOPT:http-origin=https://site.tv"))
        assertTrue(StreamHeaders.parseM3uOptionLine("#EXTVLCOPT:network-caching=1000").isEmpty())
    }

    @Test fun `KODIPROP nur Header, keine DRM-Zeilen`() {
        assertEquals(
            mapOf("User-Agent" to "Kodi/20", "Referer" to "https://a.tv/"),
            StreamHeaders.parseM3uOptionLine("#KODIPROP:inputstream.adaptive.stream_headers=User-Agent=Kodi%2F20&Referer=https%3A%2F%2Fa.tv%2F&X-Foo=bar"),
        )
        assertEquals(mapOf("Cookie" to "sid=1"), StreamHeaders.parseM3uOptionLine("#KODIPROP:inputstream.adaptive.manifest_headers=Cookie=sid%3D1"))
        for (drm in listOf(
            "#KODIPROP:inputstream.adaptive.license_type=clearkey",
            "#KODIPROP:inputstream.adaptive.license_key=https://lic/|User-Agent=X|R{SSM}|",
            "#KODIPROP:inputstream.adaptive.license_headers=User-Agent=X",
            "#KODIPROP:inputstreamaddon=inputstream.adaptive",
        )) assertTrue(drm, StreamHeaders.parseM3uOptionLine(drm).isEmpty())
    }

    @Test fun `EXTHTTP JSON und Pipe-Header`() {
        assertEquals(
            mapOf("User-Agent" to "UA1", "Cookie" to "a=b"),
            StreamHeaders.parseM3uOptionLine("""#EXTHTTP:{"User-Agent":"UA1","cookie":"a=b","Authorization":"x"}"""),
        )
        assertTrue(StreamHeaders.parseM3uOptionLine("#EXTHTTP:{kaputt").isEmpty())
        val (url, h) = StreamHeaders.splitPipeHeaders("http://cdn.tv/live/1.m3u8|User-Agent=VLC%2F3.0&Referer=http://r.tv/&Origin=http://o.tv")
        assertEquals("http://cdn.tv/live/1.m3u8", url)
        assertEquals(mapOf("User-Agent" to "VLC/3.0", "Referer" to "http://r.tv/", "Origin" to "http://o.tv"), h)
        assertEquals("http://a/b.ts" to emptyMap<String, String>(), StreamHeaders.splitPipeHeaders("http://a/b.ts"))
        val inj = StreamHeaders.parseHeaderQuery("User-Agent=a%0D%0AX-Evil:%201")
        assertEquals("aX-Evil: 1", inj["User-Agent"])
        assertEquals(setOf("User-Agent"), inj.keys)
    }

    private val playlist = """
#EXTM3U url-tvg="http://epg.tv/e.xml"
#EXTINF:-1 tvg-id="ard.de" tvg-shift="-1.5" group-title="DE",Das Erste
#EXTVLCOPT:http-user-agent=Mozilla/5.0 Test
#EXTVLCOPT:http-referrer=https://ref.tv/
http://s.tv/ard.m3u8
#EXTINF:-1 group-title="DE",ZDF
http://s.tv/zdf.m3u8|User-Agent=Pipe%20UA&Cookie=k%3Dv
#KODIPROP:inputstream.adaptive.license_type=clearkey
#KODIPROP:inputstream.adaptive.license_key=0123:4567
#EXTINF:-1 group-title="DE" catchup="shift" catchup-days="3",Arte
http://s.tv/arte.m3u8
"""

    @Test fun `M3U - Header pro Sender, tvg-shift, Catch-up`() {
        for (r in listOf(M3uParser.parse(playlist), M3uParser.parse(Buffer().writeUtf8(playlist))!!)) {
            assertEquals(3, r.channels.size)
            val (ard, zdf, arte) = r.channels
            assertEquals("http://s.tv/ard.m3u8", ard.streamUrl)
            assertEquals(mapOf("User-Agent" to "Mozilla/5.0 Test", "Referer" to "https://ref.tv/"), ard.headers)
            assertEquals(-90, ard.epgShift)
            assertEquals("http://s.tv/zdf.m3u8", zdf.streamUrl)
            assertEquals(mapOf("User-Agent" to "Pipe UA", "Cookie" to "k=v"), zdf.headers)
            assertNull(arte.headers)
            assertEquals("shift", arte.catchupMode)
            assertEquals(3, arte.catchupDays)
            assertEquals("http://epg.tv/e.xml", r.epgUrl)
            assertEquals(listOf("DE"), r.categories.map { it.id })
            assertEquals(listOf("m3u_1", "m3u_2", "m3u_3"), r.channels.map { it.id })
        }
    }

    @Test fun `M3U - EXTVLCOPT vor EXTINF, globaler tvg-shift, BOM, EXTGRP, tvg-chno`() {
        val r = M3uParser.parse(
            "﻿#EXTM3U tvg-shift=\"+1\"\r\n#EXTVLCOPT:http-user-agent=Box/1.0\r\n#EXTINF:-1 tvg-id=\"a\",A\r\n" +
                "http://h/a.ts|Referer=http%3A%2F%2Fr.example%2F\r\n#EXTINF:-1 tvg-id=\"b\" tvg-shift=\"-2\",B\r\n" +
                "#KODIPROP:inputstream.adaptive.license_key=https://lic.example/x\r\nhttp://h/b.ts\r\n" +
                "#EXTINF:-1 tvg-chno=\"42\" tvg-name=\"CN\" tvg-logo=\"http://l/c.png\",C, mit Komma\r\n#EXTGRP:Sport\r\nhttp://h/c.ts\r\n",
        )
        val (a, b, c) = r.channels
        assertEquals("http://h/a.ts", a.streamUrl)
        assertEquals(mapOf("User-Agent" to "Box/1.0", "Referer" to "http://r.example/"), a.headers)
        assertEquals(60, a.epgShift)
        assertNull(b.headers)
        assertEquals(-120, b.epgShift)
        assertEquals(42, c.number)
        assertEquals("C, mit Komma", c.name)
        assertEquals("CN", c.epgId)
        assertEquals("Sport", c.categoryId)
        assertEquals("http://l/c.png", c.logoUrl)
        assertEquals(listOf("Allgemein", "Sport"), r.categories.map { it.name })
    }

    @Test fun `M3U - unsichere Eintraege werden verworfen`() {
        val r = M3uParser.parse(
            """#EXTM3U x-tvg-url="file:///etc/epg.xml"
#EXTINF:-1 tvg-logo="file:///sdcard/x.png" group-title="A",Gut
http://srv.example/live/1.ts
#EXTINF:-1 group-title="A",Böse
file:///data/data/de.jasonstream.player/shared_prefs/x.xml
#EXTINF:-1 group-title="A",Auch böse
content://com.android.contacts/contacts
""",
        )
        assertEquals(listOf("Gut"), r.channels.map { it.name })
        assertNull(r.channels.first().logoUrl)
        assertNull(r.epgUrl)
        assertNull(M3uParser.parse(Buffer().writeUtf8("<html>kein m3u</html>")))
    }

    @Test fun `streamHeadersFor und Vorlagen`() {
        val portal = Portal("p", "P", PortalType.m3u, "http://s.tv/list.m3u", userAgent = "PortalUA", referer = "https://portal.tv/")
        assertEquals(mapOf("User-Agent" to "PortalUA", "Referer" to "https://portal.tv/"), StreamHeaders.streamHeadersFor(portal, null))
        val c = Channel("1", "X", "g", "http://s.tv/x", headers = mapOf("user-agent" to "ChannelUA", "Cookie" to "a=1"))
        assertEquals(
            mapOf("User-Agent" to "ChannelUA", "Referer" to "https://portal.tv/", "Cookie" to "a=1"),
            StreamHeaders.streamHeadersFor(portal, c),
        )
        assertTrue(StreamHeaders.streamHeadersFor(Portal("q", "Q", PortalType.xtream, "http://h:1"), null).isEmpty())
        assertEquals("app", StreamHeaders.presetIdOf(null))
        assertEquals("vlc", StreamHeaders.presetIdOf(StreamHeaders.UA_VLC))
        assertEquals("browser", StreamHeaders.presetIdOf(StreamHeaders.UA_BROWSER))
        assertEquals("custom", StreamHeaders.presetIdOf("Mein UA"))
    }

    @Test fun `tvg-shift einmal je Kennung`() {
        val t = 1_790_000_000_000L
        fun e(id: String) = EpgEntry(id, "x", t, t + 3_600_000)
        val epg = mutableMapOf("a.de" to listOf(e("a.de")), "b.de" to listOf(e("b.de")))
        val chans = listOf(
            Channel("1", "A", "g", "http://s/1", epgId = "a.de", epgShift = -90),
            Channel("2", "A HD", "g", "http://s/2", epgId = "a.de", epgShift = -90),
            Channel("3", "B", "g", "http://s/3", epgId = "b.de"),
        )
        val out = M3uRepository.applyTvgShift(epg, chans)
        assertEquals(t - 90 * 60_000, out["a.de"]!!.single().startMs)
        assertEquals(t, out["b.de"]!!.single().startMs)
    }

    @Test fun `Catch-up-Adressen (shift, flussonic, append, default)`() {
        val utc = ZoneOffset.UTC
        val repo = M3uRepository(Portal("m", "M", PortalType.m3u, "http://h/l.m3u"), utc)
        val start = 1_767_225_600_000L // 2026-01-01T00:00:00Z
        val e = EpgEntry("x", "t", start, start + 3_600_000)
        val now = start + 7_200_000
        fun ch(url: String, mode: String?, src: String? = null) = Channel("1", "c", "g", url, catchupDays = 3, catchupMode = mode, catchupSource = src)
        assertEquals("http://s/live.m3u8?utc=1767225600&lutc=1767232800", repo.catchupUrl(ch("http://s/live.m3u8", "shift"), e, now))
        assertEquals("http://s/a?x=1&utc=1767225600&lutc=1767232800", repo.catchupUrl(ch("http://s/a?x=1", "shift"), e, now))
        assertEquals("http://fs/ch/index-1767225600-3600.m3u8?token=1", repo.catchupUrl(ch("http://fs/ch/index.m3u8?token=1", "flussonic"), e, now))
        assertEquals("http://fs/ch/video-1767225600-3600.m3u8", repo.catchupUrl(ch("http://fs/ch/video", "fs"), e, now))
        assertEquals(
            "http://s/live.ts?start=1767225600&end=1767228000".replace("1767228000", "1767229200"),
            repo.catchupUrl(ch("http://s/live.ts", "append", "?start={utc}&end={utcend}"), e, now),
        )
        assertEquals(
            "http://arch/2026/01/01/00-00?d=60&off=7200&x={unknown}",
            repo.catchupUrl(ch("http://s/live.ts", null, "http://arch/{Y}/{m}/{d}/{H}-{M}?d={duration:60}&off=\${offset}&x={unknown}"), e, now),
        )
        assertNull(repo.catchupUrl(ch("http://s/live.ts", "default", null), e, now))
        assertNull(repo.catchupUrl(Channel("1", "c", "g", "http://s"), e, now))
    }
}
