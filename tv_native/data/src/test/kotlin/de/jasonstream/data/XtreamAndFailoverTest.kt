package de.jasonstream.data

import de.jasonstream.core.model.Channel
import de.jasonstream.core.model.EpgEntry
import de.jasonstream.core.model.HostFailover
import de.jasonstream.core.model.Portal
import de.jasonstream.core.model.PortalType
import de.jasonstream.core.model.RepositoryException
import de.jasonstream.data.m3u.M3uRepository
import de.jasonstream.data.net.Net
import de.jasonstream.data.xtream.XtreamRepository
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import java.io.IOException
import java.net.ServerSocket
import java.time.ZoneOffset
import java.util.Base64

/**
 * Xtream-API gegen einen Test-Server + Port von test/host_failover_test.dart
 * (Hauptserver tot → Ersatz-Adressen, gemerkt, Header, 403 ohne Wechsel).
 */
class XtreamAndFailoverTest {
    private val servers = mutableListOf<MockWebServer>()
    private val requests = mutableListOf<RecordedRequest>()
    private val persisted = HashMap<String, Int>()

    @Before fun setUp() {
        HostFailover.reset()
        HostFailover.persist = { id, i -> persisted[id] = i }
        Net.client = Net.defaultClient()
    }

    @After fun tearDown() {
        servers.forEach { runCatching { it.shutdown() } }
        HostFailover.persist = null
        HostFailover.reset()
    }

    private fun server(handler: (RecordedRequest) -> MockResponse): MockWebServer = MockWebServer().also { s ->
        s.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                synchronized(requests) { requests.add(request) }
                return handler(request)
            }
        }
        s.start()
        servers.add(s)
    }

    /** Port, auf dem niemand lauscht (Verbindung abgelehnt = Host-Fehler). */
    private fun deadUrl(): String = ServerSocket(0).use { "http://127.0.0.1:${it.localPort}" }

    private fun base(s: MockWebServer) = s.url("/").toString().trimEnd('/')

    private val b64 = { s: String -> Base64.getEncoder().encodeToString(s.toByteArray()) }

    private fun xtreamServer(): MockWebServer = server { r ->
        val u = r.requestUrl!!
        if (u.encodedPath != "/player_api.php") return@server MockResponse().setResponseCode(404)
        if (u.queryParameter("username") != "u s" || u.queryParameter("password") != "p&w") {
            return@server MockResponse().setBody("""{"user_info":{"auth":0}}""")
        }
        val body = when (u.queryParameter("action")) {
            null -> """{"user_info":{"auth":1,"status":"Active","exp_date":"1798761600","max_connections":"2","active_cons":"1"},"server_info":{}}"""
            "get_live_categories" -> """[{"category_id":"1","category_name":" DE | Allgemein "},{"category_id":2,"category_name":"Sport"},{"x":1},"kaputt"]"""
            "get_live_streams" -> """[
                {"num":1,"name":" ZDF HD ","stream_id":11,"stream_icon":"http://logo/zdf.png","epg_channel_id":"ZDF.de","category_id":"1","tv_archive":1,"tv_archive_duration":"7"},
                {"num":"2","name":"Sport1","stream_id":"12","stream_icon":"file:///x.png","epg_channel_id":"","category_id":2,"tv_archive":0},
                {"num":3,"name":"kaputt","stream_id":{"x":1}},
                "nicht-objekt",
                {"num":1.0,"name":null,"stream_id":13,"category_id":null,"extra":{"deep":[1,2,{"a":[]}]}}
            ]"""
            "get_vod_categories" -> """[{"category_id":"10","category_name":"Filme"}]"""
            "get_vod_streams" -> """[{"stream_id":5,"name":"Film","stream_icon":"http://p/5.jpg","category_id":"10","rating":"84","year":"2020","added":"1700000000","container_extension":"mkv"},{"stream_id":6,"name":"Ohne Ext","category_id":"10","rating":0,"added":"0"}]"""
            "get_series_categories" -> """[{"category_id":"20","category_name":"Serien"}]"""
            "get_series" -> """[{"series_id":9,"name":"Serie","cover":"http://p/9.jpg","category_id":"20","rating":"7.5","releaseDate":"2019-05-01","backdrop_path":["http://b/9.jpg"],"last_modified":"1700000000","episode_run_time":"45"}]"""
            "get_series_info" -> """{"info":{"plot":"Handlung","cast":"A, B","backdrop_path":[]},"episodes":{"2":[{"id":"202","episode_num":2,"title":"Zwei","container_extension":"mp4","info":{"duration_secs":"1500","movie_image":"http://i/202.jpg"}},{"id":"201","episode_num":"1","title":"Eins"}],"1":[{"id":"101","episode_num":1,"title":"Pilot","container_extension":"mkv"}]}}"""
            "get_vod_info" -> """{"info":{"plot":"P","genre":"Drama","releasedate":"2020-03-04","duration_secs":"5400","backdrop_path":["http://b/5.jpg"],"rating":"6.2"}}"""
            "get_short_epg" -> """{"epg_listings":[{"title":"${b64("Später")}","description":"${b64("Text")}","start_timestamp":"1700003600","stop_timestamp":"1700007200"},{"title":"${b64("Jetzt")}","start_timestamp":"1700000000","stop_timestamp":"1700003600"},{"title":"kein b64 ü","start_timestamp":"5","stop_timestamp":"5"}]}"""
            else -> "[]"
        }
        MockResponse().setBody(body)
    }

    private fun portal(url: String, alt: List<String> = emptyList()) =
        Portal("x1", "X", PortalType.xtream, url, username = "u s", password = "p&w", altUrls = alt, userAgent = "MyUA", referer = "https://ref.tv/")

    @Test fun `Login, Live, VOD, Serien, Kurz-EPG, Catch-up`() {
        val s = xtreamServer()
        val repo = XtreamRepository(portal(base(s) + "/"), ZoneOffset.UTC)
        val acc = repo.login()
        assertEquals("Active", acc.status)
        assertEquals(1_798_761_600_000L, acc.expiresMs)
        assertEquals(2, acc.maxConnections)
        assertEquals(1, acc.activeConnections)

        val live = repo.live()
        assertEquals(listOf("1" to "DE | Allgemein", "2" to "Sport"), live.categories.map { it.id to it.name })
        assertEquals(listOf("11", "12", "13"), live.channels.map { it.id })
        val zdf = live.channels[0]
        assertEquals("ZDF HD", zdf.name)
        assertEquals("http://logo/zdf.png", zdf.logoUrl)
        assertEquals("ZDF.de", zdf.epgId)
        assertEquals(7, zdf.catchupDays)
        assertEquals(1, zdf.number)
        assertEquals("${base(s)}/live/u%20s/p%26w/11.ts", zdf.streamUrl)
        assertNull(live.channels[1].logoUrl) // file: blockiert
        assertNull(live.channels[1].epgId)
        assertEquals("2", live.channels[1].categoryId)
        assertEquals("", live.channels[2].name)
        assertEquals("null", live.channels[2].categoryId) // wie Dart '${null}'
        assertEquals(0, live.channels[2].number) // „1.0“ ist keine Ganzzahl

        val movies = repo.movies()
        assertEquals("${base(s)}/movie/u%20s/p%26w/5.mkv", movies.items[0].streamUrl)
        assertEquals(8.4, movies.items[0].rating!!, 1e-9)
        assertEquals(2020, movies.items[0].year)
        assertEquals(1_700_000_000_000L, movies.items[0].addedMs)
        assertEquals("${base(s)}/movie/u%20s/p%26w/6.mp4", movies.items[1].streamUrl)
        assertNull(movies.items[1].rating)
        assertNull(movies.items[1].addedMs)
        val det = repo.movieDetails(movies.items[0])
        assertEquals("P", det.plot)
        assertEquals(5400L, det.durationSec)
        assertEquals("http://b/5.jpg", det.backdropUrl)

        val series = repo.series()
        val sr = series.items.single()
        assertTrue(sr.isSeries)
        assertEquals(2019, sr.year)
        assertEquals(45 * 60L, sr.durationSec)
        assertEquals("http://b/9.jpg", sr.backdropUrl)
        val info = repo.seriesDetails(sr)
        assertEquals(listOf(1, 2), info.seasons.keys.toList())
        assertEquals(listOf("201", "202"), info.seasons[2]!!.map { it.id })
        assertEquals("${base(s)}/series/u%20s/p%26w/202.mp4", info.seasons[2]!![1].streamUrl)
        assertEquals("${base(s)}/series/u%20s/p%26w/101.mkv", info.seasons[1]!![0].streamUrl)
        assertEquals("Handlung", info.series.plot)

        val epg = repo.shortEpg(zdf)
        assertEquals(listOf("Jetzt", "Später"), epg.map { it.title })
        assertEquals("Text", epg[1].description)
        assertEquals("ZDF.de", epg[0].channelEpgId)

        // 2023-11-14 22:13:20 UTC, 60 Minuten.
        val e = EpgEntry("ZDF.de", "x", 1_700_000_000_000L, 1_700_003_600_000L)
        assertEquals("${base(s)}/timeshift/u%20s/p%26w/60/2023-11-14:22-13/11.ts", repo.catchupUrl(zdf, e))
        assertNull(repo.catchupUrl(live.channels[1], e))
        assertEquals("${base(s)}/xmltv.php?username=u%20s&password=p%26w", repo.providerEpgUrl())

        // Portal-Header gehen mit.
        assertTrue(requests.all { it.getHeader("User-Agent") == "MyUA" && it.getHeader("Referer") == "https://ref.tv/" })
    }

    @Test fun `Falsche Zugangsdaten - Login-Fehler`() {
        val s = xtreamServer()
        val repo = XtreamRepository(portal(base(s)).copy(password = "falsch"))
        try { repo.login(); fail() } catch (e: RepositoryException) { assertTrue(e.message!!.contains("Login fehlgeschlagen")) }
    }

    @Test fun `Hauptserver tot - Ersatz 1 502 - Ersatz 2 klappt, gemerkt`() {
        val bad = server { MockResponse().setResponseCode(502).setBody("kaputt") }
        val good = xtreamServer()
        val p = portal(deadUrl(), listOf(base(bad), base(good)))
        val repo = XtreamRepository(p)
        assertEquals("Active", repo.login().status)
        assertEquals(base(good), HostFailover.activeBase(p))
        assertEquals(2, persisted["x1"])
        requests.clear()
        repo.login()
        assertEquals(listOf(good.port), requests.map { it.requestUrl!!.port })
        // Live-Liste: Stream-Adressen auf dem funktionierenden Server.
        assertTrue(repo.live().channels.first().streamUrl.startsWith(base(good) + "/live/"))
    }

    @Test fun `Streams werden umgeschrieben, fremde Server bleiben`() {
        val p = Portal("x1", "X", PortalType.xtream, "http://main.tv:8080", "u", "p", altUrls = listOf("http://backup1.tv:8080", "http://backup2.tv"))
        HostFailover.restore("x1", 1)
        val c = Channel("7", "A", "1", "http://main.tv:8080/live/u/p/7.ts")
        assertEquals("http://backup1.tv:8080/live/u/p/7.ts", XtreamRepository(p).resolveStreamUrl(c))
        assertEquals(
            listOf("http://backup1.tv:8080/live/u/p/7.ts", "http://main.tv:8080/live/u/p/7.ts", "http://backup2.tv/live/u/p/7.ts"),
            HostFailover.streamCandidates(p, c.streamUrl),
        )
        assertEquals("http://cdn.other/x.ts", HostFailover.rewrite(p, "http://cdn.other/x.ts"))
    }

    @Test fun `403 - kein Wechsel auf Ersatz-Adressen`() {
        val forbidden = server { MockResponse().setResponseCode(403) }
        val other = xtreamServer()
        val p = portal(base(forbidden), listOf(base(other)))
        try { XtreamRepository(p).login(); fail() } catch (e: RepositoryException) { assertEquals(403, e.statusCode) }
        assertEquals(1, requests.size)
        assertEquals(0, HostFailover.activeIndex(p))
    }

    @Test fun `Alle Adressen tot - erster Fehler`() {
        val p = portal(deadUrl(), listOf(deadUrl(), deadUrl()))
        try { XtreamRepository(p).login(); fail() } catch (_: IOException) { }
    }

    @Test fun `M3U - Spiegel-Playlist, Streams auf gleichem Server umgeschrieben`() {
        val down = server { MockResponse().setResponseCode(503) }
        lateinit var mirrorBase: String
        val mirror = server {
            MockResponse().setBody("#EXTM3U\n#EXTINF:-1,Eins\n${base(down)}/live/1.ts\n#EXTINF:-1,Zwei\nhttp://cdn.other/2.ts\n")
        }
        mirrorBase = base(mirror)
        val p = Portal("m1", "M", PortalType.m3u, "${base(down)}/get.php?u=1", altUrls = listOf("$mirrorBase/get.php?u=1"))
        val repo = M3uRepository(p)
        val chans = repo.live().channels
        assertEquals(2, chans.size)
        assertEquals(1, HostFailover.activeIndex(p))
        assertEquals("$mirrorBase/live/1.ts", repo.resolveStreamUrl(chans[0]))
        assertEquals("http://cdn.other/2.ts", repo.resolveStreamUrl(chans[1]))
    }

    @Test fun `Fehlerarten`() {
        assertTrue(HostFailover.isHostFailure(java.net.SocketTimeoutException("x")))
        assertTrue(HostFailover.isHostFailure(RepositoryException("x", 500)))
        assertTrue(HostFailover.isHostFailure(RepositoryException("x", 404)))
        assertTrue(!HostFailover.isHostFailure(RepositoryException("x", 401)))
        assertTrue(!HostFailover.isHostFailure(RepositoryException("x")))
        assertTrue(!HostFailover.isHostFailure(IllegalStateException("json")))
        assertTrue(!HostFailover.isHostFailure(Net.TooLarge()))
    }

    @Test fun `Weiterleitung, Groessenlimit, unsichere Adresse`() {
        val s = server { MockResponse().setBody("x".repeat(2000)) }
        try { Net.get(base(s) + "/a", maxBytes = 1000); fail() } catch (_: RepositoryException) { }
        try { Net.get("file:///etc/passwd"); fail() } catch (e: RepositoryException) { assertTrue(e.message!!.contains("Unsichere")) }
        val redir = server { r ->
            if (r.requestUrl!!.encodedPath == "/start") MockResponse().setResponseCode(302).setHeader("Location", "/ziel")
            else MockResponse().setBody("ok")
        }
        assertEquals("ok", String(Net.get(base(redir) + "/start")))
    }
}
