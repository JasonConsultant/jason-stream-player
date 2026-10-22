package de.jasonstream.core

import de.jasonstream.core.migration.FlutterMigration
import de.jasonstream.core.migration.FlutterPrefs
import de.jasonstream.core.model.HostFailover
import de.jasonstream.core.model.PortalType
import de.jasonstream.core.prefs.MemoryKeyValueStore
import de.jasonstream.core.security.AesGcmFormat
import de.jasonstream.core.security.SecretCipher
import de.jasonstream.core.storage.Storage
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey

/** Ersatz für den Android-Keystore: gleiches Format (k1:IV:CT), eigener AES-Schlüssel. */
class TestKeystoreCipher(val key: SecretKey = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()) :
    SecretCipher {
    override fun encrypt(plain: String) = AesGcmFormat.encrypt(key, plain)
    override fun decrypt(cipher: String) = AesGcmFormat.decrypt(key, cipher)
}

class MigrationTest {
    private val keystore = TestKeystoreCipher()

    @After fun tearDown() { HostFailover.reset(); HostFailover.persist = null }

    /** So schreibt die Flutter-App (Storage.dart) ihre Daten – mit deren Schlüsselnamen. */
    private fun flutterValues(cipher: SecretCipher = keystore): Map<String, Any> = linkedMapOf(
        "portals" to """[{"id":"p1","name":"Mein Xtream","type":"xtream"},{"id":"p2","name":"Liste","type":"m3u"},{"id":"p3","name":"MAG","type":"stalker"}]""",
        "active_portal" to "p2",
        "sec_portal_p1" to cipher.encrypt(
            """{"url":"http://srv.example:8080","username":"jason","password":"Geh€im&<1>","epgUrl":null,""" +
                """"x":{"ua":"VLC/3.0.20 LibVLC/3.0.20","alt":["http://backup.example:8080"],"autoRefresh":12,"epgOffsets":{"portal":-60}}}""",
        ),
        "sec_portal_p2" to cipher.encrypt("""{"url":"http://list.example/get.php?username=a&password=b","username":null,"password":null,"epgUrl":"http://epg.example/e.xml.gz"}"""),
        "sec_portal_p3" to cipher.encrypt("""{"url":"http://mag.example/c/","username":"00:1A:79:00:00:01","password":null,"epgUrl":null}"""),
        "sec_pin_salt" to cipher.encrypt("AAECAwQFBgcICQoLDA0ODw=="),
        "sec_pin_hash" to cipher.encrypt("WiHdQHK3oE68BC4tD2QawN/Hg+Qui9FbNWwWAKUgkMM="),
        "fav_p1" to listOf("101", "7", "55"),
        "hidden_p1" to listOf("9"),
        "locked_p1" to listOf("13"),
        "hidden_groups_p1" to listOf("cat_xxx", "cat_2"),
        "order_groups_p1" to listOf("3", "1", "2"),
        "order_ch_p1_3" to listOf("55", "101"),
        "recent_p1" to listOf("7", "101"),
        "last_p1" to "7",
        "chov_p1" to """{"101":{"name":"Mein ZDF","logo":"http://l/z.png"},"7":{"epg":""}}""",
        "set_mygroups_p1" to """[{"id":"my_ab12cd34","n":"Fußball","c":["101","7"]}]""",
        "set_vodfav_p1" to """["m:5","s:9"]""",
        "set_countries_p1" to listOf("DE", "TR"),
        "set_kidsgroups_p1" to listOf("kids1"),
        "set_hwdec" to false,
        "set_buffer" to "large",
        "set_adultlock" to true,
        "set_epghour" to 4L,
        "althost_p1" to 1L,
        "listrefresh_p1" to 1760000000000L,
        "resume_m:5" to "600/5400",
        "watched_e:77" to true,
        "set_uiscale_factor" to 1.25,
    )

    private fun xml(legacyLists: Boolean = false) = FlutterPrefs.encodeXml(flutterValues(), legacyLists)

    @Test fun `XML wird typgerecht und ohne flutter-Praefix gelesen`() {
        for (legacy in listOf(false, true)) {
            val v = FlutterPrefs.read(xml(legacy).byteInputStream())
            assertEquals(listOf("101", "7", "55"), v["fav_p1"])
            assertEquals(listOf("55", "101"), v["order_ch_p1_3"])
            assertEquals(false, v["set_hwdec"])
            assertEquals(4L, v["set_epghour"])
            assertEquals(1.25, v["set_uiscale_factor"])
            assertEquals("p2", v["active_portal"])
            assertTrue((v["sec_portal_p1"] as String).startsWith("k1:"))
        }
    }

    @Test fun `fremde Schluessel ohne Praefix und Set-Eintraege`() {
        val xml = """<?xml version='1.0' encoding='utf-8' standalone='yes' ?>
<map>
    <string name="other">x</string>
    <set name="flutter.old_set"><string>a</string><string>b</string></set>
    <int name="flutter.n" value="5" />
    <string name="flutter.big">${FlutterPrefs.BIG_INTEGER_PREFIX}zz</string>
</map>"""
        val v = FlutterPrefs.read(xml.byteInputStream())
        assertFalse(v.containsKey("other"))
        assertEquals(listOf("a", "b"), v["old_set"])
        assertEquals(5L, v["n"])
        assertEquals(35L * 36 + 35, v["big"])
    }

    @Test fun `Migration uebernimmt alles und Storage liest Portale mit Keystore`() {
        val dir = createTempDir()
        try {
            val f = File(dir, "shared_prefs/FlutterSharedPreferences.xml").apply { parentFile!!.mkdirs(); writeText(xml()) }
            val before = f.readText()
            val native = MemoryKeyValueStore()
            val m = FlutterMigration(native, keystore) { 1234L }
            val r = m.runIfNeeded { FlutterPrefs.read(FlutterPrefs.file(dir)) }!!
            assertTrue(r.sourceFound)
            assertEquals(3, r.portals)
            assertEquals(5, r.secrets)
            assertEquals(0, r.unreadableSecrets)
            assertEquals("p2", r.activePortal)
            assertEquals(3, r.favorites)
            assertEquals(1, r.myGroups)
            assertEquals(1, r.overrides)
            assertEquals(before, f.readText()) // Flutter-Daten unverändert
            // Zweiter Start: nichts mehr tun.
            assertNull(m.runIfNeeded { error("darf nicht lesen") })
            assertEquals(r, FlutterMigration.report(native))

            val st = Storage.open(native, keystore)
            assertEquals(0, st.unreadableSecrets)
            val ps = st.portals()
            assertEquals(listOf("p1", "p2", "p3"), ps.map { it.id })
            val x = ps[0]
            assertEquals(PortalType.xtream, x.type)
            assertEquals("Mein Xtream", x.name)
            assertEquals("http://srv.example:8080", x.url)
            assertEquals("jason", x.username)
            assertEquals("Geh€im&<1>", x.password)
            assertEquals("VLC/3.0.20 LibVLC/3.0.20", x.userAgent)
            assertEquals(listOf("http://backup.example:8080"), x.altUrls)
            assertEquals(12, x.autoRefreshHours)
            assertEquals(mapOf("portal" to -60), x.epgOffsets)
            assertEquals(PortalType.stalker, ps[2].type)
            assertEquals("00:1A:79:00:00:01", ps[2].username)
            assertEquals(listOf("http://epg.example/e.xml.gz"), ps[1].epgSources)
            assertEquals("p2", st.activePortal()!!.id)
            // Ersatz-Adresse (althost_) wiederhergestellt.
            assertEquals("http://backup.example:8080", HostFailover.activeBase(x))

            assertEquals(setOf("101", "7", "55"), st.favorites("p1"))
            assertEquals(listOf("101", "7", "55"), st.favorites("p1").toList()) // Reihenfolge
            assertEquals(setOf("9"), st.hidden("p1"))
            assertEquals(setOf("13"), st.locked("p1"))
            assertEquals(setOf("cat_xxx", "cat_2"), st.hiddenGroups("p1"))
            assertEquals(listOf("3", "1", "2"), st.groupOrder("p1"))
            assertEquals(listOf("55", "101"), st.channelOrder("p1", "3"))
            assertEquals(listOf("7", "101"), st.recent("p1"))
            assertEquals("7", st.lastChannel("p1"))
            val ov = st.overrides("p1")
            assertEquals("Mein ZDF", ov["101"]!!.name)
            assertEquals("", ov["7"]!!.epgId) // „Kein EPG“
            val g = st.myGroups("p1").single()
            assertEquals("Fußball", g.name)
            assertEquals(listOf("101", "7"), g.channels)
            assertEquals(setOf("m:5", "s:9"), st.vodFavorites("p1"))
            assertEquals(setOf("DE", "TR"), st.countries("p1"))
            assertFalse(st.flag("hwdec", fallback = true))
            assertEquals("large", st.option("buffer", "normal"))
            assertEquals(600 to 5400, st.resume("m:5"))
            assertTrue(st.isWatched("e:77"))
            // PIN (Hash/Salz aus der Flutter-App, PBKDF2 wie PinHasher.dart).
            assertTrue(st.hasPin())
            assertEquals(Storage.PinResult.Ok, st.verifyPin("1234"))
            assertEquals(Storage.PinResult.Wrong(4), st.verifyPin("0000"))
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test fun `Frische Installation ohne Flutter-Daten`() {
        val native = MemoryKeyValueStore()
        val r = FlutterMigration(native, keystore).runIfNeeded { null }!!
        assertFalse(r.sourceFound)
        assertTrue(FlutterMigration(native, keystore).isDone())
        assertTrue(Storage.open(native, keystore).portals().isEmpty())
    }

    @Test fun `Anderer Keystore-Schluessel - Geheimnisse nicht lesbar, Rest bleibt`() {
        val other = TestKeystoreCipher()
        val native = MemoryKeyValueStore()
        val r = FlutterMigration(native, other).runIfNeeded { flutterValues(keystore) }!!
        assertEquals(5, r.unreadableSecrets)
        val st = Storage.open(native, other)
        assertEquals(5, st.unreadableSecrets)
        assertTrue(st.portals().isEmpty()) // neu anmelden nötig
        assertEquals(setOf("101", "7", "55"), st.favorites("p1")) // Favoriten bleiben
    }

    @Test fun `Lesefehler - bis zu drei Versuche`() {
        val native = MemoryKeyValueStore()
        val m = FlutterMigration(native, keystore)
        repeat(2) {
            assertTrue(m.runIfNeeded { throw java.io.IOException("x") }!!.error!!.startsWith("read"))
            assertFalse(m.isDone())
        }
        m.runIfNeeded { throw java.io.IOException("x") }
        assertTrue(m.isDone())
    }

    @Test fun `Uralte Klartext-Portale werden verschluesselt`() {
        val native = MemoryKeyValueStore(
            mapOf(
                "portals" to """[{"id":"a","name":"Alt","type":"xtream","url":"http://h:1","username":"u","password":"pw"}]""",
                "parental_pin" to "4321",
            ),
        )
        val st = Storage.open(native, keystore)
        assertEquals("pw", st.portals().single().password)
        assertFalse(native.getString("portals")!!.contains("pw"))
        assertTrue(native.getString("sec_portal_a")!!.startsWith("k1:"))
        assertNull(native.getString("parental_pin"))
        assertEquals(Storage.PinResult.Ok, st.verifyPin("4321"))
    }

    private fun createTempDir(): File = java.nio.file.Files.createTempDirectory("jsp").toFile()
}
