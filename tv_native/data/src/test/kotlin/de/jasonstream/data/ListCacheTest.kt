package de.jasonstream.data

import de.jasonstream.core.model.Category
import de.jasonstream.core.model.Channel
import de.jasonstream.core.model.Portal
import de.jasonstream.core.model.PortalType
import de.jasonstream.core.model.VodItem
import de.jasonstream.data.cache.ListCache
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files

class ListCacheTest {
    private val dir: File = Files.createTempDirectory("lc").toFile()
    @After fun tearDown() { dir.deleteRecursively() }

    private val portal = Portal("p/1", "P", PortalType.xtream, "http://h:8080", username = "jason", password = "S3cr€t pw")

    private fun live(n: Int = 3) = LiveList(
        listOf(Category("1", "DE"), Category("2", "Sport")),
        (0 until n).map {
            Channel(
                id = "$it", name = "Sender $it ü", categoryId = if (it % 2 == 0) "1" else "2",
                streamUrl = "http://h:8080/live/jason/S3cr%E2%82%ACt%20pw/$it.ts",
                logoUrl = if (it == 0) null else "http://l/$it.png", epgId = "e$it.de", catchupDays = it, number = it + 1,
                catchupMode = if (it == 1) "shift" else null, catchupSource = null,
                headers = if (it == 2) mapOf("User-Agent" to "UA", "Referer" to "jason") else null, epgShift = -it * 30,
            )
        },
    )

    @Test fun `Senderliste speichern und laden, ohne Zugangsdaten in der Datei`() {
        val c = ListCache(dir)
        val l = live()
        val st = c.storeLive(portal, l, savedMs = 42)
        assertFalse(st.unchanged)
        val f = File(dir, "live_p_1.bin")
        assertTrue(f.exists())
        val raw = String(f.readBytes(), Charsets.ISO_8859_1)
        assertFalse(raw.contains("jason"))
        assertFalse(raw.contains("S3cr"))
        val back = c.loadLive(portal)!!
        assertEquals(l.channels, back.items)
        assertEquals(l.categories, back.categories)
        assertEquals(42L, back.savedMs)
        assertEquals(st.hash, back.hash)
        // Unverändert → nichts schreiben.
        assertTrue(c.storeLive(portal, l, prevHash = st.hash).unchanged)
        assertFalse(c.storeLive(portal, live(4), prevHash = st.hash).unchanged)
    }

    @Test fun `Andere Zugangsdaten - Speicher ungueltig, kaputte Datei geloescht`() {
        val c = ListCache(dir)
        c.storeLive(portal, live())
        assertNull(c.loadLive(portal.copy(password = "neu")))
        File(dir, "live_p_1.bin").writeBytes(ByteArray(100) { 7 })
        assertNull(c.loadLive(portal))
        assertFalse(File(dir, "live_p_1.bin").exists())
    }

    @Test fun `Filme speichern und laden`() {
        val c = ListCache(dir)
        val v = VodList(
            listOf(Category("10", "Filme")),
            listOf(
                VodItem("5", "Film", "10", "http://h:8080/movie/jason/x/5.mkv", "http://p", null, 8.4, 2020, "Plot", "Drama", "A", "B", 5400, 1_700_000_000_000, "yt", false),
                VodItem("9", "Serie", "10", "", isSeries = true),
            ),
        )
        c.storeVod(ListCache.KIND_MOVIES, portal, v)
        assertEquals(v.items, c.loadVod(ListCache.KIND_MOVIES, portal)!!.items)
    }

    @Test fun `Flutter-Zwischenspeicher wird uebernommen`() {
        // So schreibt list_cache.dart: Kopf + maskierter JSON-Inhalt (Platzhalter \u0000S<i>\u0000).
        val secrets = ListCache.secrets(portal)
        assertEquals(listOf("S3cr%E2%82%ACt%20pw", "S3cr€t pw", "jason"), secrets)
        val fp = ListCache.fingerprint(secrets)
        val body = """"cats":[["1","DE"],["2","Sport"]],"ch":[""" +
            """["11","ZDF HD","http://l/z.png","1","http://h:8080/live/jason/S3cr%E2%82%ACt%20pw/11.ts","ZDF.de",7,1,null,null,null,0],""" +
            """["12","Arte",null,"2","http://h:8080/live/jason/S3cr%E2%82%ACt%20pw/12.ts",null,0,2,"shift","x",{"User-Agent":"UA"},-60],""" +
            """["kaputt"],""" +
            """["13","Alt",null,"2","http://x/13.ts",null,0,3,null,null]]}"""
        var masked = body
        secrets.forEachIndexed { i, s -> masked = masked.replace(s, "\u0000S$i\u0000") }
        val file = """{"v":1,"saved":1760000000000,"fp":"$fp","h":"abc",""" + masked
        val flutterDir = Files.createTempDirectory("ff").toFile()
        try {
            File(flutterDir, "live_p_1.json").writeText(file)
            val c = ListCache(dir)
            val r = c.importFlutterLive(flutterDir, portal)!!
            assertEquals(1_760_000_000_000L, r.savedMs)
            assertEquals(listOf("1", "2"), r.categories.map { it.id })
            assertEquals(listOf("11", "12", "13"), r.items.map { it.id })
            assertEquals("http://h:8080/live/jason/S3cr%E2%82%ACt%20pw/11.ts", r.items[0].streamUrl)
            assertEquals(7, r.items[0].catchupDays)
            assertEquals(mapOf("User-Agent" to "UA"), r.items[1].headers)
            assertEquals(-60, r.items[1].epgShift)
            assertEquals(0, r.items[2].epgShift)
            // Andere Zugangsdaten → nicht übernehmen.
            assertNull(c.importFlutterLive(flutterDir, portal.copy(password = "x")))
        } finally {
            flutterDir.deleteRecursively()
        }
    }

    @Test fun `50 000 Sender - schnell und kompakt`() {
        val c = ListCache(dir)
        val big = live(50_000)
        val t0 = System.currentTimeMillis()
        c.storeLive(portal, big)
        val back = c.loadLive(portal)!!
        assertEquals(50_000, back.items.size)
        assertTrue("zu langsam", System.currentTimeMillis() - t0 < 10_000)
        assertTrue(File(dir, "live_p_1.bin").length() < 12L * 1024 * 1024)
    }
}
