package de.jasonstream.player.focus

import de.jasonstream.player.logic.ShellState
import de.jasonstream.player.logic.Tab
import de.jasonstream.player.logic.Zone
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** Feste Abläufe mit der Fernbedienung (Menü, Zurück, Live-Overlay ↔ Player). */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "de-w960dp-h540dp-land-television-xhdpi")
class ScriptedNavTest : FocusHarness() {

    private val trace = StringBuilder()
    private fun where(): String {
        val f = focused()
        val t = f?.let { tags(it) } ?: emptyList()
        return when {
            f == null -> "<none>"
            "menu" in t -> "menu"
            else -> t.firstOrNull { it != "main" } ?: "content"
        }
    }
    private fun expect(z: String, step: String) {
        val w = where()
        trace.append("$step → [$w] ${label(focused()).take(80)} shell=${vm.shell.value}\n")
        assertEquals("$step\n$trace", z, w)
    }

    @Test fun startBackTwiceExits() {
        launch { it.setShell(ShellState(Tab.Start, Zone.Content)) }
        expect("content", "start")
        up(); expect("menu", "▲ from first row → menu")
        down(); expect("content", "▼ from menu → content")
        back(); expect("menu", "Back → menu")
        assertEquals(0, exits)
        back(); assertEquals("first Back on Start menu only arms exit", 0, exits)
        back(); assertEquals("second Back exits", 1, exits)
    }

    @Test fun everyTabTopRowReachesMenu() {
        for (tab in listOf(Tab.Guide, Tab.Search, Tab.Settings, Tab.Movies)) {
            launchOnce(tab)
            // Bis ganz nach oben, dann muss ▲ ins Menü führen.
            var n = 0
            while (where() != "menu" && n++ < 12) up()
            expect("menu", "$tab ▲ reaches menu (after $n)")
            // Guide: Raster beginnt beim laufenden Sender (Zeile 4) → Zeilen + Chips + Menü.
            assertTrue("$tab: menu within a few presses\n$trace", n <= if (tab == Tab.Guide) 8 else 3)
            down(); expect("content", "$tab ▼ back into content")
            back(); expect("menu", "$tab Back → menu")
            back(); assertEquals("$tab Back from menu → Start", Tab.Start, vm.shell.value.tab)
            expect("menu", "$tab now Start menu")
            assertEquals(0, exits)
        }
    }

    private var launched = false
    private fun launchOnce(tab: Tab) {
        if (!launched) { launch { it.setShell(ShellState(tab, Zone.Content)) }; launched = true }
        else { rule.runOnUiThread { vm.openTab(tab) }; settle(4) }
    }

    @Test fun guideChipsAndGrid() {
        launch { it.setShell(ShellState(Tab.Guide, Zone.Content)) }
        expect("content", "guide grid")
        val grid = focused()!!.id
        repeat(30) { if (focused()?.id == grid) up() }
        expect("content", "▲ to chips row")
        assertTrue("left the grid", focused()!!.id != grid)
        right(); right(); expect("content", "▶ along chips (last chip: edge, not menu)")
        repeat(3) { left() }; expect("content", "◀ along chips")
        down(); expect("content", "▼ back into grid")
        assertEquals(grid, focused()!!.id)
        repeat(5) { down() }; right(); left(); left()
        expect("content", "moving inside grid")
        back(); expect("menu", "Back → menu")
    }

    @Test fun liveOverlayPlayerAndMenu() {
        launch { it.setShell(ShellState(Tab.Live, Zone.Content)) }
        expect("live_list", "open")
        back(); expect("player", "Back hides overlay → player")
        left(); expect("live_list", "◀ on player → list again")
        assertTrue("playing channel focused", vm.current.value!!.name in texts(focused()!!))
        left(); expect("live_groups", "◀ → groups")
        // ▲ in den Gruppen bis zur Suche, dann ins Menü.
        repeat(15) { if (where() == "live_groups") up() }
        expect("live_search", "search")
        rule.runOnUiThread { fake.grab() }; settle()
        expect("live_search", "player grab while in search")
        up(); expect("menu", "▲ from search → menu")
        assertEquals(Zone.Menu, vm.shell.value.zone)
        down(); expect("live_list", "▼ from menu → overlay list")
        back(); back(); expect("menu", "Back, Back → menu")
        back(); assertEquals(Tab.Start, vm.shell.value.tab)
        assertEquals(0, exits)
    }

    @Test fun livePlayOtherGroupThenBack() {
        launch { it.setShell(ShellState(Tab.Live, Zone.Content)) }
        left(); down(); down(); down()
        expect("live_groups", "browse groups")
        right(); expect("live_list", "into list")
        down(); val name = texts(focused()!!)
        ok(); expect("live_list", "OK plays, focus stays in list")
        assertNotNull(vm.request.value)
        assertTrue("now playing $name", vm.current.value!!.name in name)
        back(); expect("player", "Back → player")
        left(); expect("live_list", "◀ → list at playing channel")
        assertTrue(vm.current.value!!.name in texts(focused()!!))
        left(); expect("live_groups", "◀ → group of the playing channel")
    }
}
