package de.jasonstream.data

import de.jasonstream.core.model.Channel
import de.jasonstream.data.channels.VariantIndex
import de.jasonstream.data.channels.VariantQuality
import de.jasonstream.data.channels.analyzeVariantName
import de.jasonstream.data.channels.groupVariants
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/** Port von test/channel_variants_test.dart (alle kniffligen Fälle). */
class ChannelVariantsTest {
    private var n = 0
    private fun c(name: String, group: String = "g", id: String? = null, logo: String? = null, epg: String? = null) =
        Channel(id = id ?: "id${n++}", name = name, categoryId = group, streamUrl = "http://s/${n++}", logoUrl = logo, epgId = epg)

    private fun groups(list: List<Channel>) = groupVariants(list).map { g -> g.members.map { it.name } }
    private fun <T> assertUnordered(expected: List<T>, actual: List<T>) =
        assertEquals(expected.toSet(), actual.toSet()).also { assertEquals(expected.size, actual.size) }

    @Test fun `Laenderpraefixe in allen Schreibweisen`() {
        for (s in listOf("DE: ZDF", "DE | ZDF", "|DE| ZDF", "[DE] ZDF", "DE - ZDF", "DE| ZDF HD", "de: ZDF")) {
            val v = analyzeVariantName(s)
            assertEquals(s, "zdf", v.key)
            assertEquals(s, "DE", v.country)
        }
    }

    @Test fun `Qualitaetsangaben werden erkannt und entfernt`() {
        assertEquals(VariantQuality.hd, analyzeVariantName("ZDF HD").quality)
        assertEquals(VariantQuality.fhd, analyzeVariantName("ZDF FHD").quality)
        assertEquals(VariantQuality.fhd, analyzeVariantName("ZDF Full HD").quality)
        assertEquals(VariantQuality.fhd, analyzeVariantName("ZDF 1080p").quality)
        assertEquals(VariantQuality.uhd, analyzeVariantName("ZDF 4K").quality)
        assertEquals(VariantQuality.uhd, analyzeVariantName("ZDF UHD").quality)
        assertEquals(VariantQuality.raw, analyzeVariantName("ZDF RAW").quality)
        assertEquals(VariantQuality.sd, analyzeVariantName("ZDF SD").quality)
        assertEquals(VariantQuality.unknown, analyzeVariantName("ZDF").quality)
        assertEquals(VariantQuality.hd, analyzeVariantName("DE: ZDF ᴴᴰ").quality)
        assertEquals("zdf", analyzeVariantName("ZDFᴴᴰ").key)
        assertEquals(VariantQuality.uhd, analyzeVariantName("ZDF ᵁᴴᴰ").quality)
        assertEquals(VariantQuality.fhd, analyzeVariantName("ZDF ᶠᴴᴰ").quality)
        for (s in listOf(
            "ZDF HD", "ZDF FHD", "ZDF RAW", "DE: ZDF ᴴᴰ", "ZDF (Backup)", "ZDF 4K", "ZDF SD", "ZDF HEVC", "ZDF H265",
            "ZDF HD 50fps", "ZDF [HD]", "ZDF.HD", "zdf hd", "ZDF HD Backup 2", "ZDF Alt", "ZDF #2", "ZDF HD 50",
        )) assertEquals(s, "zdf", analyzeVariantName(s).key)
    }

    @Test fun `Backup-Angaben`() {
        assertTrue(analyzeVariantName("ZDF (Backup)").backup)
        assertTrue(analyzeVariantName("ZDF HD Alt").backup)
        assertTrue(analyzeVariantName("ZDF Backup1").backup)
        assertTrue(analyzeVariantName("ZDF #2").backup)
        assertFalse(analyzeVariantName("ZDF HD").backup)
    }

    @Test fun `Ziffern im Namen bleiben erhalten`() {
        assertEquals("trt 1", analyzeVariantName("TR: TRT 1 HD").key)
        assertEquals("sky sport 1", analyzeVariantName("Sky Sport 1 HD").key)
        assertEquals("sky sport 2", analyzeVariantName("Sky Sport 2").key)
        assertEquals("sport1+", analyzeVariantName("Sport1+").key)
        assertEquals("kanal 50", analyzeVariantName("Kanal 50").key)
    }

    @Test fun `Tuerkische Buchstaben`() {
        assertEquals("atv", analyzeVariantName("TR | ATV FHD").key)
        assertEquals("TR", analyzeVariantName("TR | ATV FHD").country)
        assertEquals(analyzeVariantName("TRT Belgesel").key, analyzeVariantName("TRT BELGESEL HD").key)
        assertEquals(analyzeVariantName("Show Türk HD").key, analyzeVariantName("TR: SHOW TÜRK").key)
        assertEquals("kanal d i", analyzeVariantName("KANAL D İ").key)
    }

    @Test fun `Kurze und leere Namen`() {
        assertEquals("", analyzeVariantName("HD").key)
        assertEquals("", analyzeVariantName("DE: 4K").key)
    }

    @Test fun `ZDF-Varianten werden eine Gruppe, FHD zuerst`() {
        val list = listOf(c("ZDF SD"), c("ZDF HD"), c("ZDF (Backup)"), c("ZDF 4K"), c("ZDF FHD"), c("ZDF RAW"), c("ARD HD"))
        assertEquals(listOf(listOf("ZDF FHD", "ZDF HD", "ZDF 4K", "ZDF RAW", "ZDF SD", "ZDF (Backup)")), groups(list))
    }

    @Test fun `Ohne Qualitaetsangabe zwischen HD und 4K`() {
        assertEquals(listOf(listOf("ZDF HD", "ZDF", "ZDF 4K")), groups(listOf(c("ZDF 4K"), c("ZDF"), c("ZDF HD"))))
    }

    @Test fun `gleiche Qualitaet - urspruengliche Reihenfolge`() {
        val g = groupVariants(listOf(c("ZDF HD", id = "a"), c("ZDF ᴴᴰ", id = "b"))).single()
        assertEquals(listOf("a", "b"), g.members.map { it.id })
    }

    @Test fun `Gruppen und Laender`() {
        assertEquals(
            listOf(listOf("DE | ZDF FHD", "DE: ZDF HD")),
            groups(listOf(c("DE: ZDF HD", group = "de_hd"), c("DE | ZDF FHD", group = "de_fhd"))),
        )
        assertTrue(groups(listOf(c("ZDF HD", group = "a"), c("ZDF FHD", group = "b"))).isEmpty())
        assertTrue(groups(listOf(c("DE: Eurosport 1", group = "eu"), c("UK: Eurosport 1", group = "eu"))).isEmpty())
        assertEquals(
            listOf(listOf("DE: Eurosport 1 HD", "Eurosport 1")),
            groups(listOf(c("DE: Eurosport 1 HD", group = "eu"), c("Eurosport 1", group = "eu"), c("UK: Eurosport 1", group = "eu"))),
        )
    }

    @Test fun `Tuerkische Sender`() {
        val g = groups(
            listOf(
                c("TR: TRT 1 HD", group = "tr"), c("TR: TRT 1 FHD", group = "tr"), c("TR: TRT 2", group = "tr"),
                c("TR | ATV FHD", group = "tr"), c("TR | ATV HD", group = "tr"), c("ATV Avrupa", group = "tr"),
                c("ATV Avrupa HD", group = "tr"),
            ),
        )
        assertUnordered(
            listOf(listOf("TR: TRT 1 FHD", "TR: TRT 1 HD"), listOf("TR | ATV FHD", "TR | ATV HD"), listOf("ATV Avrupa HD", "ATV Avrupa")),
            g,
        )
    }

    @Test fun `Keine Fehl-Zusammenlegungen`() {
        val list = listOf(
            "ATV", "ATV Avrupa", "Sky Sport 1", "Sky Sport 2", "Sky Sport 1 HD", "ProSieben", "ProSieben Maxx",
            "ProSieben Maxx HD", "RTL", "RTL II", "RTLup", "Sport1", "Sport1+", "Kabel Eins", "Kabel Eins Doku", "TRT 1",
            "TRT 2", "ZDF", "ZDFneo", "ZDF info",
        ).map { c(it) }
        assertUnordered(listOf(listOf("Sky Sport 1 HD", "Sky Sport 1"), listOf("ProSieben Maxx HD", "ProSieben Maxx")), groups(list))
    }

    @Test fun `Vorgaben - Fehl- und Pflicht-Zusammenlegungen`() {
        assertTrue(groups(listOf(c("ATV"), c("ATV Avrupa"))).isEmpty())
        assertTrue(groups(listOf(c("Sky Sport 1"), c("Sky Sport 2"))).isEmpty())
        assertTrue(groups(listOf(c("ProSieben"), c("ProSieben Maxx"))).isEmpty())
        assertEquals(listOf(listOf("TRT 1 HD", "TRT 1")), groups(listOf(c("TRT 1"), c("TRT 1 HD"))))
        assertEquals(listOf(listOf("ZDF FHD", "DE: ZDF HD")), groups(listOf(c("DE: ZDF HD"), c("ZDF FHD"))))
    }

    @Test fun `Markennamen mit Trenner sind kein Laenderpraefix`() {
        assertNull(analyzeVariantName("HBO: Family").country)
        assertEquals("hbo family", analyzeVariantName("HBO: Family").key)
        assertTrue(groups(listOf(c("HBO: Family"), c("Family HD"))).isEmpty())
        assertTrue(groups(listOf(c("ATV - Avrupa"), c("Kanal 7 Avrupa"))).isEmpty())
        assertEquals("DE", analyzeVariantName("GER: ZDF").country)
        assertEquals("UK", analyzeVariantName("[UK] BBC One HD").country)
        assertEquals("vip zdf", analyzeVariantName("[VIP] ZDF").key)
    }

    @Test fun `zu kurze Namen nie zusammenlegen`() {
        assertTrue(groups(listOf(c("HD"), c("FHD"), c("4K"))).isEmpty())
        assertTrue(groups(listOf(c("X HD"), c("X FHD"))).isEmpty())
        assertEquals(listOf(listOf("N1 FHD", "N1 HD")), groups(listOf(c("N1 HD"), c("N1 FHD"))))
    }

    @Test fun `playOrder - Wahl des Nutzers zuerst`() {
        val g = groupVariants(listOf(c("ZDF SD", id = "sd"), c("ZDF FHD", id = "fhd"), c("ZDF HD", id = "hd"))).single()
        assertEquals(listOf("fhd", "hd", "sd"), g.playOrder(null).map { it.id })
        assertEquals(listOf("sd", "fhd", "hd"), g.playOrder("sd").map { it.id })
        assertEquals(listOf("fhd", "hd", "sd"), g.playOrder("unknown").map { it.id })
        assertEquals("SD", g.labelOf(g.members.last()))
    }

    private val list = listOf(
        c("ARD", id = "ard"), c("ZDF SD", id = "sd", logo = "http://logo"), c("ZDF FHD", id = "fhd"),
        c("ZDF HD", id = "hd", epg = "zdf.de"), c("RTL", id = "rtl"),
    )

    @Test fun `VariantIndex collapse`() {
        val idx = VariantIndex.of(groupVariants(list))
        val out = idx.collapse(list)
        assertEquals(listOf("ard", "fhd", "rtl"), out.map { it.id })
        assertEquals("http://logo", out[1].logoUrl)
        assertEquals("zdf.de", out[1].epgId)
        assertEquals(3, idx.countOf("fhd"))
        assertEquals(3, idx.countOf("sd"))
        assertEquals(1, idx.countOf("ard"))
        assertEquals("fhd", idx.representativeOf("sd"))
        assertEquals("ard", idx.representativeOf("ard"))
    }

    @Test fun `VariantIndex Favorit, Sperre, ausgeblendet`() {
        val fav = VariantIndex.of(groupVariants(list), favorites = setOf("sd"))
        assertEquals(listOf("ard", "sd", "rtl"), fav.collapse(list).map { it.id })
        assertEquals("sd", fav.representativeOf("hd"))
        val lk = VariantIndex.of(groupVariants(list), locked = setOf("sd"))
        assertEquals(listOf("ard", "sd", "rtl"), lk.collapse(list).map { it.id })
        assertEquals("sd", VariantIndex.of(groupVariants(list), locked = setOf("sd"), favorites = setOf("hd")).representativeOf("fhd"))
        assertEquals("fhd", VariantIndex.of(groupVariants(list), locked = setOf("sd"), hidden = setOf("sd")).representativeOf("sd"))
        assertEquals(listOf("ard", "hd", "rtl"), VariantIndex.of(groupVariants(list), hidden = setOf("fhd")).collapse(list).map { it.id })
        assertEquals("fhd", VariantIndex.of(groupVariants(list), hidden = setOf("fhd", "hd", "sd")).representativeOf("sd"))
    }

    @Test fun `VariantIndex resolve und leer`() {
        val idx = VariantIndex.of(groupVariants(list))
        val byId = idx.collapse(list).associateBy { it.id }
        assertEquals(listOf("fhd", "rtl", "ard"), idx.resolve(listOf("sd", "rtl", "fhd", "hd", "gone", "ard"), byId).map { it.id })
        assertSame(list, VariantIndex.empty.collapse(list))
    }

    @Test fun `grosse Liste in vertretbarer Zeit`() {
        val q = listOf("HD", "FHD", "SD")
        val big = (0 until 20000).map { i -> c("DE: Sender ${i / 3} ${q[i % 3]}", group = "g${i / 300}") }
        val t = System.currentTimeMillis()
        val g = groupVariants(big)
        assertTrue(System.currentTimeMillis() - t < 3000)
        assertTrue(g.size > 6000)
    }
}
