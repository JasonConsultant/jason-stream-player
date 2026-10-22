package de.jasonstream.player.logic

import de.jasonstream.core.model.Channel
import de.jasonstream.core.model.EpgEntry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.TimeZone

class EpgGuideSearchTest {
    private val m = 60_000L
    private val t0 = 1_760_000_000_000L - (1_760_000_000_000L % (30 * m)) // halbe Stunde
    private val c = Channel("c", "Kanal", "g", "u", epgId = "k", catchupDays = 3)
    private fun e(title: String, s: Int, d: Int) = EpgEntry("k", title, t0 + s * m, t0 + (s + d) * m)

    private val list = listOf(e("A", 0, 60), e("B", 60, 30), e("C", 120, 45)) // Lücke 90–120
    private val idx = EpgIndex(mapOf("k" to list))

    @Test fun nowNextAndRange() {
        val nn = idx.nowNext(c, t0 + 70 * m)
        assertEquals("B", nn.now!!.title)
        assertEquals("C", nn.next!!.title)
        val gap = idx.nowNext(c, t0 + 100 * m)
        assertNull(gap.now)
        assertEquals("C", gap.next!!.title)
        assertEquals(listOf("B", "C"), idx.range(c, t0 + 61 * m, t0 + 121 * m).map { it.title })
        assertTrue(idx.nowNext(c, t0 + 500 * m).isEmpty)
    }

    @Test fun unsortedInputIsSorted() {
        val i2 = EpgIndex(mapOf("k" to list.reversed()))
        assertEquals("A", i2.at(c, t0 + 5 * m)!!.title)
    }

    @Test fun guideRightLeftThroughGap() {
        val span = 120 * m
        val min = t0 - 600 * m
        val max = t0 + 6000 * m
        var cur = GuideCursor(0, t0 + 10 * m, t0)
        cur = GuideNav.right(idx, list, cur, span, min, max)
        assertEquals(t0 + 60 * m, cur.anchor) // B
        cur = GuideNav.right(idx, list, cur, span, min, max)
        val gap = GuideNav.cellAt(idx, list, cur.anchor)
        assertNull(gap.entry) // Lücke 90–120
        assertEquals(t0 + 90 * m, gap.start)
        assertEquals(t0 + 120 * m, gap.end)
        cur = GuideNav.right(idx, list, cur, span, min, max)
        assertEquals("C", GuideNav.cellAt(idx, list, cur.anchor).entry!!.title)
        // Fenster folgt (C beginnt bei 120 ≥ 0 + 120 − 30).
        assertTrue(cur.viewStart > t0)
        cur = GuideNav.left(idx, list, cur, span, min, max)
        assertNull(GuideNav.cellAt(idx, list, cur.anchor).entry)
        cur = GuideNav.left(idx, list, cur, span, min, max)
        assertEquals("B", GuideNav.cellAt(idx, list, cur.anchor).entry!!.title)
    }

    @Test fun guideVerticalKeepsTimeAndClamps() {
        val cur = GuideCursor(3, t0 + 75 * m, t0 + 60 * m)
        val down = GuideNav.vertical(cur, 1, 10)
        assertEquals(4, down.row)
        assertEquals(cur.anchor, down.anchor)
        assertEquals(9, GuideNav.vertical(cur.copy(row = 9), 1, 10).row)
        assertEquals(0, GuideNav.vertical(cur.copy(row = 0), -1, 10).row)
        // Anker vor dem Fenster → Fensteranfang.
        assertEquals(t0 + 60 * m, GuideNav.vertical(cur.copy(anchor = t0), 1, 10).anchor)
    }

    @Test fun guideActions() {
        val now = t0 + 70 * m
        assertEquals(GuideNav.Action.PlayLive, GuideNav.actionFor(GuideNav.cellAt(idx, list, now), now, 3))
        assertEquals(GuideNav.Action.PlayCatchup, GuideNav.actionFor(GuideNav.cellAt(idx, list, t0), now, 3))
        assertEquals(GuideNav.Action.None, GuideNav.actionFor(GuideNav.cellAt(idx, list, t0), now, 0))
        assertEquals(GuideNav.Action.Remind, GuideNav.actionFor(GuideNav.cellAt(idx, list, t0 + 130 * m), now, 3))
    }

    @Test fun guideDays() {
        val tz = TimeZone.getTimeZone("Europe/Berlin")
        val now = t0
        val day = 86_400_000L
        assertEquals(listOf(-1, 0, 1, 2), GuideDays.offsets(now - day to now + 2 * day + 3600_000, now, tz))
        assertEquals(listOf(0), GuideDays.offsets(null, now, tz))
        assertEquals(listOf(-7, -6, -5, -4, -3, -2, -1, 0), GuideDays.offsets(now - 30 * day to now, now, tz))
        val j = GuideDays.jumpTarget(1, now, tz)
        assertEquals(0L, j % (30 * m))
    }

    @Test fun searchRankingAndShows() {
        val chans = listOf(
            Channel("1", "Sky Sport News", "g", "u", epgId = "a"),
            Channel("2", "Sport1", "g", "u", epgId = "b", catchupDays = 0),
            Channel("3", "Eurosport", "g", "u", epgId = "c", catchupDays = 7),
            Channel("4", "sport", "g", "u"),
        )
        val now = t0
        val epg = mapOf(
            "a" to listOf(EpgEntry("a", "Sport live", now - 10 * m, now + 20 * m)),
            "b" to listOf(EpgEntry("b", "Sportschau", now - 200 * m, now - 100 * m)), // vergangen, kein Archiv
            "c" to listOf(
                EpgEntry("c", "Sportschau", now - 300 * m, now - 250 * m),
                EpgEntry("c", "Sportschau", now + 60 * m, now + 90 * m),
            ),
        )
        val se = SearchEngine(chans, epg)
        val r = se.search("  Sport ", now)
        assertEquals(listOf("4", "2", "1", "3"), r.channels.map { it.id })
        assertEquals(listOf("Sport live", "Sportschau", "Sportschau"), r.shows.map { it.entry.title })
        assertEquals(now + 60 * m, r.shows[1].entry.startMs) // demnächst vor vergangen
        // Verlängerter Begriff sucht in alten Treffern.
        assertEquals(listOf("2"), se.search("sport1", now).channels.map { it.id })
        assertTrue(se.search("s", now).isEmpty)
    }

    @Test fun recentSearches() {
        var l = emptyList<String>()
        for (q in listOf("tatort", "Sport", "x", "TATORT")) l = RecentSearches.add(l, q)
        assertEquals(listOf("TATORT", "Sport"), l)
        for (i in 0..10) l = RecentSearches.add(l, "q$i")
        assertEquals(8, l.size)
    }

    @Test fun demoDataEpgCoversNow() {
        val now = System.currentTimeMillis()
        val epg = EpgIndex(DemoData.epg(now))
        for (ch in DemoData.channels) assertTrue(epg.nowNext(ch, now).now != null)
    }
}

class GuideWindowingTest {
    @Test fun windowOverManyChannelsIsSmall() {
        val m = 60_000L
        val t0 = 1_760_000_000_000L
        val chans = (0 until 2500).map { Channel("c$it", "Kanal $it", "g", "u", epgId = "k$it") }
        // 7 Tage à 30 Min. je Sender = 336 Sendungen × 2 500 = 840 000 Einträge.
        val epg = chans.associate { c ->
            c.epgId!! to (0 until 336).map { i -> EpgEntry(c.epgId!!, "S$i", t0 + i * 30 * m, t0 + (i + 1) * 30 * m) }
        }
        val idx = EpgIndex(epg)
        val view = t0 + 100 * 30 * m
        val start = System.nanoTime()
        var cells = 0
        for (c in chans) cells += idx.range(c, view, view + 127 * m).size
        val ms = (System.nanoTime() - start) / 1_000_000
        assertEquals(2500 * 5, cells) // 127 Min. berühren 5 Halbstunden-Zellen
        assertTrue("Fenster für alle Sender: $ms ms", ms < 2000)
    }
}
