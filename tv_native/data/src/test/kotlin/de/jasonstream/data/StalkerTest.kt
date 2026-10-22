package de.jasonstream.data

import de.jasonstream.core.model.Channel
import de.jasonstream.core.model.EpgEntry
import de.jasonstream.core.model.Portal
import de.jasonstream.core.model.PortalType
import de.jasonstream.core.model.RepositoryException
import de.jasonstream.data.net.JsonStream
import de.jasonstream.data.stalker.StalkerRepository
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.time.LocalDateTime
import java.time.ZoneId

/** Port von test/stalker_test.dart + ein Ablauf gegen einen Test-Server. */
class StalkerTest {
    private val zone = ZoneId.of("Europe/Berlin")
    private fun local(y: Int, mo: Int, d: Int, h: Int = 0, mi: Int = 0, s: Int = 0) =
        LocalDateTime.of(y, mo, d, h, mi, s).atZone(zone).toInstant().toEpochMilli()

    @Test fun `Endpunkte`() {
        assertEquals(
            listOf("http://srv.example:8080/server/load.php", "http://srv.example:8080/portal.php", "http://srv.example:8080/stalker_portal/server/load.php"),
            StalkerRepository.endpointCandidates("http://srv.example:8080/c/"),
        )
        assertEquals(
            listOf("http://srv.example:8080/stalker_portal/server/load.php", "http://srv.example:8080/portal.php"),
            StalkerRepository.endpointCandidates("http://srv.example:8080/stalker_portal/c/"),
        )
        assertEquals(
            listOf("http://srv.example:8080/server/load.php", "http://srv.example:8080/portal.php", "http://srv.example:8080/stalker_portal/server/load.php"),
            StalkerRepository.endpointCandidates("srv.example:8080"),
        )
        assertEquals(
            listOf("http://srv.example/server/load.php", "http://srv.example/portal.php", "http://srv.example/stalker_portal/server/load.php"),
            StalkerRepository.endpointCandidates("http://srv.example/"),
        )
        val c = StalkerRepository.endpointCandidates("https://srv.example/portal.php")
        assertEquals("https://srv.example/portal.php", c.first())
        assertTrue(c.contains("https://srv.example/stalker_portal/server/load.php"))
        assertEquals(c.size, c.toSet().size)
        assertEquals("http://srv.example/server/load.php", StalkerRepository.endpointCandidates("http://srv.example:80/c").first())
        assertEquals(
            "http://srv.example:88/stalker_portal/server/load.php",
            StalkerRepository.endpointCandidates("http://srv.example:88/stalker_portal/c/index.html").first(),
        )
        assertEquals("http://a.example:8080/", StalkerRepository.portalRoot("http://a.example:8080/c/"))
    }

    @Test fun `MAC-Adresse`() {
        assertEquals("00:1A:79:AB:CD:EF", StalkerRepository.normalizeMac(" 00:1a:79:ab:cd:ef "))
        assertEquals("00:1A:79:AB:CD:EF", StalkerRepository.normalizeMac("00-1A-79-AB-CD-EF"))
        for (bad in listOf(null, "", "00:1A:79:AB:CD", "001A79ABCDEF", "00:1A:79:AB:CD:EG", "00:1A:79:AB:CD:EF:00")) {
            try {
                StalkerRepository.normalizeMac(bad); fail("$bad")
            } catch (_: RepositoryException) {
            }
        }
    }

    @Test fun `cmd`() {
        assertEquals("http://x.example/ch/1", StalkerRepository.stripCmd("ffmpeg http://x.example/ch/1"))
        assertEquals("http://x.example/1", StalkerRepository.stripCmd("ffrt http://x.example/1"))
        assertEquals("http://x.example/1", StalkerRepository.stripCmd("auto  http://x.example/1 "))
        assertEquals("http://x.example/1", StalkerRepository.stripCmd("http://x.example/1"))
        assertEquals("", StalkerRepository.stripCmd(null))
    }

    @Test fun `Sender - Felder als String oder Zahl, relatives Logo`() {
        val js = JsonStream.parse(
            """{"js":{"total_items":3,"data":[
            {"id":"101","name":"Das Erste HD","number":"1","cmd":"ffmpeg http://localhost/ch/101","logo":"/stalker_portal/misc/logos/320/101.png","tv_genre_id":"5","tv_archive":"1","tv_archive_duration":"72"},
            {"id":102,"name":"ZDF","number":2,"cmd":"ffrt http://localhost/ch/102","logo":"https://cdn.example/zdf.png","tv_genre_id":5,"tv_archive":1,"tv_archive_duration":0},
            {"id":"103","name":"Arte","cmd":"http://cdn.example/arte.m3u8","logo":"","tv_archive":0},
            {"id":"104","name":"ohne cmd"}]}}""",
        )
        val ch = StalkerRepository.parseChannels(js, "http://p.example:8080/")
        assertEquals(3, ch.size)
        assertEquals("101", ch[0].id)
        assertEquals("101", ch[0].epgId)
        assertEquals(1, ch[0].number)
        assertEquals("5", ch[0].categoryId)
        assertEquals("ffmpeg http://localhost/ch/101", ch[0].streamUrl)
        assertEquals("http://p.example:8080/stalker_portal/misc/logos/320/101.png", ch[0].logoUrl)
        assertEquals(0, ch[0].catchupDays)
        assertEquals("102", ch[1].id)
        assertEquals(2, ch[1].number)
        assertEquals("5", ch[1].categoryId)
        assertEquals("https://cdn.example/zdf.png", ch[1].logoUrl)
        assertNull(ch[2].logoUrl)
        assertEquals(0, ch[2].number)
        val bad = StalkerRepository.parseChannels(JsonStream.parse("""[{"id":"1","name":"x","cmd":"c","logo":"file:///etc/passwd"}]"""), "http://p.example:8080/")
        assertNull(bad.single().logoUrl)
        val g = StalkerRepository.parseGenres(JsonStream.parse("""{"js":[{"id":"*","title":"All"},{"id":5,"title":"Deutschland"}]}"""))
        assertEquals(listOf("5"), g.map { it.id })
        assertEquals("Deutschland", g.single().name)
    }

    private val epgJs = JsonStream.parse(
        """{"js":{"data":{
        "101":[{"name":"Tagesschau","descr":"Nachrichten","start_timestamp":"1700003600","stop_timestamp":1700004500},
               {"name":"Morgenmagazin","start_timestamp":1700000000,"stop_timestamp":"1700003600"}],
        "102":[{"name":"heute","time":"2024-01-01 19:00:00","time_to":"2024-01-01 19:20:00"},{"name":"kaputt","start_timestamp":0}]}}}""",
    )

    @Test fun `EPG mappt, sortiert, filtert`() {
        val epg = StalkerRepository.parseEpg(epgJs, zone = zone)
        assertEquals(setOf("101", "102"), epg.keys)
        assertEquals(listOf("Morgenmagazin", "Tagesschau"), epg["101"]!!.map { it.title })
        assertEquals("Nachrichten", epg["101"]!![1].description)
        assertEquals(15 * 60_000L, epg["101"]!![1].durationMs)
        assertEquals("101", epg["101"]!!.first().channelEpgId)
        assertEquals(20 * 60_000L, epg["102"]!!.single().durationMs)
        assertEquals(local(2024, 1, 1, 19), epg["102"]!!.single().startMs)
        assertEquals(listOf("102"), StalkerRepository.parseEpg(epgJs, setOf("102"), zone).keys.toList())
        assertTrue(StalkerRepository.parseEpg(null).isEmpty())
        assertTrue(StalkerRepository.parseEpg(JsonStream.parse("""{"js":[]}""")).isEmpty())
    }

    @Test fun `Profil und Konto`() {
        assertNull(StalkerRepository.profileError(JsonStream.parse("""{"js":{"id":"12","status":0}}""")))
        assertNull(StalkerRepository.profileError(JsonStream.parse("""{"id":12}""")))
        assertNotNull(StalkerRepository.profileError(JsonStream.parse("""{"js":{"id":"12","status":"1"}}""")))
        assertNotNull(StalkerRepository.profileError(JsonStream.parse("""{"js":{"id":null}}""")))
        assertNotNull(StalkerRepository.profileError(JsonStream.parse("""{"js":[]}""")))
        assertEquals(local(2025, 12, 31, 23, 59), StalkerRepository.parseExpiry("December 31, 2025, 11:59 pm", zone))
        assertEquals(local(2025, 12, 31, 23, 59, 59), StalkerRepository.parseExpiry("2025-12-31 23:59:59", zone))
        assertEquals(local(2025, 12, 31, 23, 59), StalkerRepository.parseExpiry("31.12.2025", zone))
        assertNull(StalkerRepository.parseExpiry("unbegrenzt", zone))
        val a = StalkerRepository.parseAccount(JsonStream.parse("""{"js":{"phone":"March 3, 2026","mac":"00:1A:79:00:00:01"}}"""), zone)!!
        assertEquals(local(2026, 3, 3, 23, 59), a.expiresMs)
        assertEquals("Active", a.status)
    }

    @Test fun `Catch-up und VOD vorerst nicht`() {
        val r = StalkerRepository(Portal("s", "S", PortalType.stalker, "http://p.example/c/", username = "00:1A:79:00:00:01"))
        assertEquals(false, r.supportsVod)
        assertNull(r.catchupUrl(Channel("1", "x", "", "c", catchupDays = 3), EpgEntry("1", "t", 0, 3_600_000)))
    }

    @Test fun `Ablauf - handshake, profile, Genres, Sender, create_link`() {
        val server = MockWebServer()
        val seen = mutableListOf<RecordedRequest>()
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                seen.add(request)
                val u = request.requestUrl!!
                if (u.encodedPath != "/stalker_portal/server/load.php") return MockResponse().setResponseCode(404)
                val body = when (u.queryParameter("action")) {
                    "handshake" -> """{"js":{"token":"TOK123"}}"""
                    "get_profile" -> """{"js":{"id":"77","status":0}}"""
                    "get_main_info" -> """{"js":{"phone":"31.12.2030"}}"""
                    "get_genres" -> """{"js":[{"id":"*","title":"All"},{"id":"5","title":"News"}]}"""
                    "get_all_channels" -> """{"js":{"data":[{"id":"1","name":"Eins","cmd":"ffmpeg http://localhost/ch/1","tv_genre_id":"5"}]}}"""
                    "create_link" -> """{"js":{"cmd":"ffmpeg http://cdn.example/live/1.ts?tok=abc"}}"""
                    else -> "{}"
                }
                return MockResponse().setBody(body)
            }
        }
        server.start()
        try {
            val base = server.url("/stalker_portal/c/").toString()
            val repo = StalkerRepository(Portal("s", "S", PortalType.stalker, base, username = "00:1a:79:00:00:01"), zone)
            val acc = repo.login()
            assertEquals("Active", acc.status)
            val live = repo.live()
            assertEquals(listOf("5"), live.categories.map { it.id })
            assertEquals("Eins", live.channels.single().name)
            assertEquals("http://cdn.example/live/1.ts?tok=abc", repo.resolveStreamUrl(live.channels.single()))
            val hs = seen.first { it.requestUrl!!.queryParameter("action") == "handshake" }
            assertTrue(hs.getHeader("Cookie")!!.contains("mac=00%3A1A%3A79%3A00%3A00%3A01"))
            assertEquals("1-xml", hs.requestUrl!!.queryParameter("JsHttpRequest"))
            val later = seen.last()
            assertEquals("Bearer TOK123", later.getHeader("Authorization"))
            assertTrue(later.getHeader("User-Agent")!!.contains("MAG200"))
        } finally {
            server.shutdown()
        }
    }
}
