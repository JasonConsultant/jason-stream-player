package de.jasonstream.player.logic

import de.jasonstream.core.model.Category
import de.jasonstream.core.model.Channel
import de.jasonstream.core.model.ChannelOverride
import de.jasonstream.core.model.MyGroup
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LiveModelTest {
    private fun ch(id: String, name: String, cat: String, n: Int = 0) = Channel(id, name, cat, "http://x/$id", number = n)

    private val raw = RawLive(
        listOf(Category("de", "DE | Vollprogramm"), Category("sp", "DE | Sport"), Category("tr", "TR | Ulusal"), Category("xx", "Leer")),
        listOf(
            ch("1", "Das Erste HD", "de", 1), ch("2", "ZDF HD", "de", 2), ch("3", "Sky Sport 1 HD", "sp", 3),
            ch("4", "Sky Sport 1 FHD", "sp", 4), ch("5", "TRT 1 HD", "tr", 5), ch("6", "RTL HD", "de", 6),
        ),
    )

    @Test fun groupOrderFixedThenMyThenProviderThenAll() {
        val s = LiveSnapshot.build(
            raw,
            LivePrefs(
                favorites = setOf("2"), recents = listOf("5", "1"), mergeVariants = false,
                myGroups = listOf(MyGroup("my_a", "Fußball", listOf("3"))),
                groupOrder = listOf("tr", "de"),
            ),
        )
        assertEquals(listOf("__fav", "__recent", "my_a", "tr", "de", "sp", "__all"), s.groups.map { it.id })
        assertEquals(1, s.groups.first { it.id == GroupIds.FAV }.count)
        assertEquals(listOf("5", "1"), s.channelsOf(GroupIds.RECENT).map { it.id })
        // Leere Gruppe fehlt.
        assertFalse(s.groups.any { it.id == "xx" })
    }

    @Test fun hiddenGroupsAndChannelsRespected() {
        val s = LiveSnapshot.build(raw, LivePrefs(hidden = setOf("2"), hiddenGroups = setOf("tr"), mergeVariants = false))
        assertFalse(s.groups.any { it.id == "tr" })
        assertEquals(listOf("1", "3", "4", "6"), s.channelsOf(GroupIds.ALL).map { it.id })
        assertEquals(listOf("1", "6"), s.channelsOf("de").map { it.id })
    }

    @Test fun guestHidesFavoritesAndRecents() {
        val s = LiveSnapshot.build(raw, LivePrefs(favorites = setOf("1"), recents = listOf("1"), guest = true))
        assertFalse(s.groups.any { it.kind == GroupKind.Favorites || it.kind == GroupKind.Recent })
        assertTrue(s.channelsOf(GroupIds.RECENT).isEmpty())
    }

    @Test fun kidsModeOnlyAllowedGroups() {
        val s = LiveSnapshot.build(
            raw,
            LivePrefs(
                kids = true, kidsGroups = setOf("tr", "my_k"), mergeVariants = false,
                myGroups = listOf(MyGroup("my_k", "Kinder", listOf("2")), MyGroup("my_x", "X", listOf("1"))),
            ),
        )
        assertEquals(setOf("5", "2"), s.channels.map { it.id }.toSet())
        assertEquals(listOf("__fav", "my_k", "tr", "__all"), s.groups.map { it.id })
    }

    @Test fun variantsCollapsedAndPlayOrder() {
        val s = LiveSnapshot.build(raw, LivePrefs())
        val sky = s.channelsOf("sp")
        assertEquals(1, sky.size)
        assertEquals(2, s.variantCount(sky[0]))
        assertEquals(2, s.playOrder(sky[0]).size)
        // Gewählte Variante zuerst.
        val g = s.variantGroup(sky[0])!!
        val other = g.members.first { it.id != g.best.id }
        val s2 = LiveSnapshot.build(raw, LivePrefs(variantChoice = mapOf(g.key to other.id)))
        assertEquals(other.id, s2.playOrder(s2.channelsOf("sp")[0]).first().id)
    }

    @Test fun overridesAndCustomChannelOrder() {
        val s = LiveSnapshot.build(
            raw,
            LivePrefs(
                overrides = mapOf("1" to ChannelOverride(name = "ARD")), mergeVariants = false,
                channelOrders = mapOf("de" to listOf("6", "2")),
            ),
        )
        assertEquals(listOf("6", "2", "1"), s.channelsOf("de").map { it.id })
        assertEquals("ARD", s.byId["1"]!!.name)
    }

    @Test fun countryFilter() {
        val s = LiveSnapshot.build(raw, LivePrefs(countries = setOf("TR"), mergeVariants = false))
        assertEquals(listOf("5"), s.channels.map { it.id })
    }

    @Test fun bigListsStayFast() {
        // 20 000 Sender in 400 Gruppen, Varianten an: Aufbau im Hintergrund, Zugriffe sofort.
        val cats = (0 until 400).map { Category("c$it", "DE | Gruppe $it") }
        val chans = (0 until 20_000).map { i -> ch("$i", "Sender ${i / 2} ${if (i % 2 == 0) "HD" else "FHD"}", "c${i % 400}", i + 1) }
        val t0 = System.nanoTime()
        val s = LiveSnapshot.build(RawLive(cats, chans), LivePrefs(favorites = setOf("10", "20")))
        val groups = s.groups
        val all = s.channelsOf(GroupIds.ALL)
        val ms = (System.nanoTime() - t0) / 1_000_000
        assertEquals(402, groups.size) // Favoriten + 400 + Alle
        assertTrue(all.size in 10_000..20_000)
        assertTrue("Aufbau dauerte $ms ms", ms < 8000)
        // Gemerkt: gleiche Liste ohne Neuberechnung.
        assertTrue(s.channelsOf("c7") === s.channelsOf("c7"))
    }

    @Test fun sortOrderKeepsUnknownAtEnd() {
        assertEquals(listOf("c", "a", "b", "d"), SortOrder.apply(listOf("a", "b", "c", "d"), listOf("c", "x", "a")) { it })
    }

    @Test fun sportDetector() {
        assertTrue(SportDetector.isSportText("UEFA Conference League: Monaco – Freiburg"))
        assertTrue(SportDetector.isSportText("Motorsport Magazin"))
        assertFalse(SportDetector.isSportText("Transport heute"))
        assertFalse(SportDetector.isSportText("Golf von Neapel"))
        assertTrue(SportDetector.isSportGroup("TR: Spor"))
        assertTrue(SportDetector.isSportText("Formel 1: Training"))
    }
}
