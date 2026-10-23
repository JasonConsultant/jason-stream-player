package de.jasonstream.player.focus

import de.jasonstream.player.logic.ShellState
import de.jasonstream.player.logic.Tab
import de.jasonstream.player.logic.Zone
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * Gerätemeldung alpha1: „In der Gruppe kann ich nicht wechseln.“ – Live-TV-
 * Senderliste mit echten Tastendrücken: ◀ in die Gruppen, ▲▼ wechseln die
 * Gruppe (Liste rechts folgt), ▶/OK zurück in die Liste, ▲ zur Suche.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "de-w960dp-h540dp-land-television-xhdpi")
class LiveGroupFocusTest : FocusHarness() {

    private val trace = StringBuilder()
    private fun log(step: String) {
        val f = focused()
        trace.append("$step → [${zone(f)}] ${label(f)}\n")
    }

    private fun groupIds() = vm.live.value.groups.map { it.id }

    /** Index der fokussierten Gruppe (über den angezeigten Namen). */
    private fun selectedGroupIndex(): Int {
        val l = label(focused())
        val ctx = rule.activity
        return vm.live.value.groups.indexOfFirst { g ->
            val name = when (g.kind) {
                de.jasonstream.player.logic.GroupKind.Favorites -> ctx.getString(de.jasonstream.core.R.string.favouritesStarred)
                de.jasonstream.player.logic.GroupKind.Recent -> ctx.getString(de.jasonstream.core.R.string.recentlyWatched)
                de.jasonstream.player.logic.GroupKind.All -> ctx.getString(de.jasonstream.core.R.string.allChannels)
                else -> g.name
            }
            l.startsWith("$name |")
        }
    }

    private fun assertZone(z: String, step: String) {
        log(step)
        assertEquals("$step\n$trace", z, zone())
    }

    private fun assertListShows(groupId: String, step: String) {
        // Senderliste folgt der Gruppe entprellt (GROUP_DEBOUNCE_MS nach dem letzten Schritt).
        rule.mainClock.advanceTimeBy(de.jasonstream.player.ui.live.GROUP_DEBOUNCE_MS + 40); settle()
        val expected = vm.live.value.channelsOf(groupId).first().name
        val shown = textsUnder("live_list")
        assertTrue("$step: list should show $groupId ($expected) but shows ${shown.take(6)}\n$trace", expected in shown)
    }

    private fun openLive(big: Boolean) {
        launch(big = big) { it.setShell(ShellState(Tab.Live, Zone.Content)) }
        log("open")
        assertZone("live_list", "open")
    }

    private fun groupScenario(big: Boolean) {
        openLive(big)
        left(); assertZone("live_groups", "◀ from list")
        val ids = groupIds()
        var idx = selectedGroupIndex()
        assertTrue("selected group from label ${label(focused())}", idx >= 0)
        val dir = if (idx > ids.size / 2) -1 else 1
        repeat(minOf(6, ids.size - 1)) {
            if (dir > 0) down() else up(); idx += dir
            assertZone("live_groups", "${if (dir > 0) "▼" else "▲"} in groups #$it")
            assertEquals(idx, selectedGroupIndex())
            assertListShows(ids[idx], "move in groups #$it")
        }
        if (dir > 0) up() else down(); idx -= dir
        assertZone("live_groups", "reverse in groups"); assertListShows(ids[idx], "reverse in groups")
        right(); assertZone("live_list", "▶ from group")
        val first = vm.live.value.channelsOf(ids[idx]).first().name
        assertTrue("▶ lands on first channel\n$trace", first in texts(focused()!!))
        left(); assertZone("live_groups", "◀ back to groups")
        assertTrue("◀ lands on selected group\n$trace", textsUnder("live_list").contains(first))
        // OK auf der Gruppe → Liste.
        if (idx == ids.lastIndex) { up(); idx-- } else { down(); idx++ }
        ok(); assertZone("live_list", "OK on group")
        assertTrue(vm.live.value.channelsOf(ids[idx]).first().name in texts(focused()!!))
        // Player holt sich den Fokus (Umschalten/Ausblend-Zeitgeber) während man in den Gruppen ist.
        left(); assertZone("live_groups", "◀ again")
        rule.runOnUiThread { fake.grab() }; settle()
        assertZone("live_groups", "player grabFocus while in groups")
        // Zur Suche hoch und zurück.
        repeat(ids.size + 2) { if (zone() == "live_groups") up() }
        assertZone("live_search", "▲ to search")
        // Der Weg nach oben hat die Gruppen durchgeblättert → oberste Gruppe gewählt.
        idx = 0
        down(); assertZone("live_groups", "▼ from search")
        assertEquals("▼ from search lands on selected group\n$trace", 0, selectedGroupIndex())
        while (vm.live.value.channelsOf(ids[idx]).isEmpty()) { down(); idx++ }
        assertListShows(ids[idx], "▼ to first non-empty group")
        // Umschalten mit OK in der Liste: Fokus bleibt in der Liste.
        right(); ok(); assertZone("live_list", "OK plays, focus stays")
        assertTrue("request changed", vm.request.value != null)
        back(); log("Back hides overlay")
        assertEquals("Back hides overlay → player\n$trace", null, zone())
        assertTrue("player focused after hide\n$trace", focused() != null)
        assertEquals(0, exits)
        println(trace)
    }

    @Test fun groupsDemo() = groupScenario(big = false)

    @Test fun groupsBig() = groupScenario(big = true)
}
