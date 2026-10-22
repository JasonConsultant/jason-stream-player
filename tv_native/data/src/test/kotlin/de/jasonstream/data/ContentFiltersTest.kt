package de.jasonstream.data

import de.jasonstream.data.channels.AdultDetector
import de.jasonstream.data.channels.CountryDetector
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Port von test/content_filters_test.dart (reine Erkennung). */
class ContentFiltersTest {
    @Test fun `AdultDetector sperrt`() {
        for (n in listOf(
            "XXX", "xxx Movies", "VIP | XXX 18+", "Adult", "ADULTS ONLY", "For Adults", "adultos", "Canales Adultos",
            "18+", "+18 Kanäle", "DE: Erwachsene", "Erwachsenenkanäle", "TR: YETİŞKİN", "Yetişkin Kanallar", "yetiskin",
            "Porn", "Pornhub", "Hustler TV", "Playboy TV", "Brazzers", "Private", "|XXX| Private HD", "adult (Premium)",
            "Pornografie-Doku",
        )) assertTrue(n, AdultDetector.isAdult(n))
    }

    @Test fun `AdultDetector laesst harmlose Namen`() {
        for (n in listOf(
            "Essex TV", "Sexy Hits", "Middlesex", "Adult Swim", "Kinder", "Sport 18", "U18 Fußball", "118 Comedy",
            "Formel 1 +180", "Privatsender", "Playtime", "Boxen XXL",
        )) assertFalse(n, AdultDetector.isAdult(n))
    }

    @Test fun `Kuerzel am Anfang oder als Abschnitt`() {
        val cases = mapOf(
            "DE | Sport" to "DE", "DE: ZDF HD" to "DE", "[TR] TRT 1" to "TR", "|UK| BBC One" to "UK", "GB • ITV" to "UK",
            "EX-YU: RTS 1" to "EXYU", "RS - Pink" to "EXYU", "HR | Kroatien" to "EXYU", "AL: Top Channel" to "AL",
            "VIP | DE | Sky Sport" to "DE", "AR: MBC" to "AR", "US: CNN" to "US", "DE ZDF" to "DE",
        )
        for ((k, v) in cases) assertEquals(k, v, CountryDetector.fromPrefix(k))
        for (n in listOf(
            "HR Fernsehen", "AL JAZEERA", "Al Jazeera", "ARD", "ZDF", "IT Crowd", "US Open Tennis", "NO Limit", "Sport",
            "DEUTSCHLAND",
        )) assertNull(n, CountryDetector.fromPrefix(n))
    }

    @Test fun `Laendernamen in Gruppen`() {
        assertEquals("DE", CountryDetector.fromGroup("Deutschland HD"))
        assertEquals("TR", CountryDetector.fromGroup("TÜRKIYE ULUSAL"))
        assertEquals("TR", CountryDetector.fromGroup("Türkiye Ulusal"))
        assertEquals("DE", CountryDetector.fromGroup("Germany Sports"))
        assertEquals("EXYU", CountryDetector.fromGroup("Balkan Music"))
        assertEquals("AR", CountryDetector.fromGroup("Arabic News"))
        assertNull(CountryDetector.fromGroup("Nachrichten"))
    }

    @Test fun `Sender - eigenes Kuerzel vor Gruppe und Filter`() {
        assertEquals("TR", CountryDetector.forItem("TR: Show TV", "DE"))
        assertEquals("TR", CountryDetector.forItem("Show TV", "TR"))
        assertNull(CountryDetector.forItem("Show TV", null))
        assertTrue(CountryDetector.passes("DE", emptySet()))
        assertTrue(CountryDetector.passes(null, setOf(CountryDetector.NONE)))
        assertFalse(CountryDetector.passes("TR", setOf("DE")))
    }
}
