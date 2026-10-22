package de.jasonstream.data

import de.jasonstream.core.model.Channel
import de.jasonstream.core.model.EpgEntry
import de.jasonstream.data.epg.EpgMatcher
import de.jasonstream.data.epg.EpgWindow
import de.jasonstream.data.epg.XmltvLoader
import de.jasonstream.data.epg.XmltvScanner
import de.jasonstream.data.epg.epgOf
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.util.zip.GZIPOutputStream

/** Port von test/xmltv_test.dart, epg_matcher_test.dart, m3u_epg_pick_test.dart. */
class EpgTest {
    private val now = System.currentTimeMillis()
    private val fmt = DateTimeFormatter.ofPattern("yyyyMMddHHmm'00 +0000'").withZone(ZoneOffset.UTC)
    private fun t(ms: Long) = fmt.format(Instant.ofEpochMilli(ms))
    private val h = 3_600_000L
    private val a = now - h
    private val b = now + h
    private val old = now - 30 * 24 * h

    private val xml = """<?xml version="1.0" encoding="UTF-8"?>
<tv>
  <channel id="one.de"><display-name>Eins</display-name></channel>
  <programme start="${t(a)}" stop="${t(b)}" channel="one.de">
    <title lang="de">Tom &amp; Jerry – Folge 5</title>
    <title lang="en">Tom and Jerry</title>
    <desc lang="de"><![CDATA[Katze <jagt> Maus]]></desc>
    <category lang="de">Kinder</category>
  </programme>
  <programme start="${t(b)}" stop="${t(b + h)}" channel="one.de">
    <title>Nachrichten &#252;ber &#x263A;</title>
  </programme>
  <programme start="${t(old)}" stop="${t(old + h)}" channel="one.de">
    <title>Viel zu alt</title>
  </programme>
  <programme start="${t(a)}" stop="${t(b)}" channel="other.de"><title>Anderer Sender</title></programme>
</tv>"""

    @Test fun `Inhalte korrekt (Sonderzeichen, CDATA, erste Sprache, Genre)`() {
        val names = HashMap<String, String>()
        val epg = XmltvLoader.parse(xml.byteInputStream(), namesOut = names)
        val one = epg["one.de"]!!
        assertEquals(2, one.size)
        assertEquals("Tom & Jerry – Folge 5", one.first().title)
        assertEquals("Katze <jagt> Maus", one.first().description)
        assertEquals("Kinder", one.first().genre)
        assertEquals("Nachrichten über ☺", one.last().title)
        assertTrue(one.first().startMs < one.last().startMs)
        assertEquals("Eins", names["one.de"])
    }

    @Test fun `Zeitzonen und schnelle Zeitauswertung`() {
        val utc = { y: Int, mo: Int, d: Int, hh: Int, mi: Int, s: Int ->
            java.time.LocalDateTime.of(y, mo, d, hh, mi, s).toInstant(ZoneOffset.UTC).toEpochMilli()
        }
        assertEquals(utc(2026, 10, 19, 10, 0, 0), XmltvScanner.fastTime("20261019120000 +0200"))
        assertEquals(utc(2026, 10, 19, 17, 30, 0), XmltvScanner.fastTime("20261019120000 -0530"))
        assertEquals(utc(2026, 10, 19, 12, 0, 0), XmltvScanner.fastTime("20261019120000"))
        assertEquals(utc(2026, 12, 31, 22, 59, 59), XmltvScanner.fastTime("20261231235959 +0100"))
        assertEquals(utc(2024, 2, 29, 0, 0, 0), XmltvScanner.fastTime("20240229000000 +0000"))
        assertNull(XmltvScanner.fastTime("2026x019120000"))
        assertNull(XmltvScanner.fastTime("2026"))
    }

    @Test fun `Filter, gzip, Stueckgrenzen, Attribute`() {
        assertEquals(listOf("one.de"), XmltvLoader.parse(xml.byteInputStream(), channelIds = setOf("one.de")).keys.toList())
        val bos = ByteArrayOutputStream()
        GZIPOutputStream(bos).use { it.write(xml.toByteArray()) }
        assertEquals("Tom & Jerry – Folge 5", XmltvLoader.parse(bos.toByteArray().inputStream())["one.de"]!!.first().title)
        // In winzigen Stücken gefüttert (Grenzen mitten in Tags/Umlauten).
        val s = XmltvScanner()
        xml.chunked(7).forEach { s.write(it) }
        val r = s.finish()
        assertEquals(2, r["one.de"]!!.size)
        assertEquals("Tom & Jerry – Folge 5", r["one.de"]!!.first().title)
        val x = "<tv><programme channel='q.de'  start = \"${t(a)}\" stop='${t(b)}'><title>Q</title></programme></tv>"
        assertEquals("Q", XmltvLoader.parse(x)["q.de"]!!.single().title)
        // Zeitversatz der Quelle.
        val shifted = XmltvLoader.parse(xml, offsetMinutes = 60)["one.de"]!!.first()
        assertEquals(XmltvLoader.parse(xml)["one.de"]!!.first().startMs + h, shifted.startMs)
    }

    private fun ch(id: String, name: String, epg: String? = null) = Channel(id, name, "c", "http://x/$id.ts", epgId = epg)

    @Test fun `EpgMatcher - Namen normalisieren`() {
        assertEquals("zdf", EpgMatcher.nameKey("DE: ZDF HD"))
        assertEquals("daserste", EpgMatcher.nameKey("DE • Das Erste FHD"))
        assertEquals("rtl", EpgMatcher.nameKey("|DE| RTL (RAW)"))
        assertEquals(EpgMatcher.nameKey("ProSieben"), EpgMatcher.nameKey("ProSieben HD+"))
        assertEquals("zdf", EpgMatcher.idKey("ZDF.de"))
        assertEquals("daserste", EpgMatcher.idKey("DasErste.de"))
        assertEquals("trt1", EpgMatcher.idKey("TRT1.tr"))
    }

    @Test fun `EpgMatcher - Zuordnung Kennung, Gross-Klein, Name`() {
        val channels = listOf(
            ch("1", "DE: ZDF HD", "ZDF.de"), ch("2", "DE • ZDF RAW"), ch("3", "Das Erste FHD", "daserste.DE"),
            ch("4", "Unbekannt XY"), ch("5", "ZDF", ""),
        )
        val m = EpgMatcher(channels)
        assertTrue(m.wants("ZDF.de"))
        assertTrue(m.wants("DasErste.de"))
        assertFalse(m.wants("Sat1.de"))
        val x = """<tv>
<programme start="${t(b)}" stop="${t(b + h)}" channel="ZDF.de"><title>Heute</title></programme>
<programme start="${t(b)}" stop="${t(b + h)}" channel="DasErste.de"><title>Tagesschau</title></programme>
<programme start="${t(b)}" stop="${t(b + h)}" channel="Sat1.de"><title>X</title></programme>
</tv>"""
        val out = m.assign(XmltvLoader.parse(x))
        assertEquals("Heute", epgOf(out, channels[0]).single().title)
        assertEquals("Heute", epgOf(out, channels[1]).single().title)
        assertEquals("Tagesschau", epgOf(out, channels[2]).single().title)
        assertTrue(epgOf(out, channels[3]).isEmpty())
        assertTrue(epgOf(out, channels[4]).isEmpty()) // „Kein EPG“
    }

    @Test fun `Nur EPGs der Laender der Sender`() {
        val base = "https://epgshare01.online/epgshare01/epg_ripper_"
        val urls = listOf("AL1", "ALL_SOURCES1", "AT1", "DE1", "DELUXEMUSIC1", "IT1", "TR1", "UK1", "US2").map { "$base$it.xml.gz" }
        val channels = listOf(ch("1", "1", "ZDF.de"), ch("2", "2", "DasErste.de"), ch("3", "3", "TRT1.tr"), ch("4", "4", "BBCOne.uk"))
        assertEquals(listOf("${base}DE1.xml.gz", "${base}TR1.xml.gz", "${base}UK1.xml.gz"), XmltvLoader.pickEpgUrls(urls, channels))
    }

    @Test fun `EpgWindow - Grenzen und Versatz`() {
        val day = EpgWindow.DAY
        val list = (-10..10).map { d -> EpgEntry("a", "t$d", now + d * day, now + d * day + h) }
        val capped = EpgWindow.cap(mapOf("a" to list), now = now, window = true)
        assertEquals((-7..6).map { "t$it" }, capped["a"]!!.map { it.title })
        // Zu viele Sendungen: erst ferne Zukunft (bis 2 Tage), dann Vergangenheit (bis 1 Tag) kürzen.
        val small = EpgWindow.cap(mapOf("a" to list), now = now, total = 3)
        assertEquals(listOf("t-1", "t0", "t1"), small["a"]!!.map { it.title })
        assertEquals(-180, EpgWindow.clampOffset(-500))
        assertEquals(30, EpgWindow.clampOffset(20))
        assertEquals(-30, EpgWindow.clampOffset(-15)) // Dart round(): weg von 0
        assertEquals(0, EpgWindow.clampOffset(14))
    }
}
