package de.jasonstream.player.focus

import android.view.KeyEvent
import de.jasonstream.player.logic.ShellState
import de.jasonstream.player.logic.Tab
import de.jasonstream.player.logic.Zone
import de.jasonstream.player.ui.common.RecomposeProbe
import de.jasonstream.player.ui.live.GROUP_DEBOUNCE_MS
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * „Läuft nicht sauber“: keine Neukomposition ganzer Bildschirme je
 * Tastendruck. Zählt Kompositionen (RecomposeProbe) beim Blättern.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "de-w960dp-h540dp-land-television-xhdpi")
class RecomposeTest : FocusHarness() {

    @Before fun on() { RecomposeProbe.enabled = true }
    @After fun off() { RecomposeProbe.enabled = false; RecomposeProbe.reset() }

    private fun counts() = RecomposeProbe.counts.toSortedMap().toString()

    private fun taps(code: Int, n: Int) {
        realtime()
        RecomposeProbe.reset()
        repeat(n) { tap(code, holdFrames = 2, gapFrames = 3) }
    }

    @Test fun liveListStepsDoNotRecomposeOverlay() {
        huge = true
        launch(big = true) { it.setShell(ShellState(Tab.Live, Zone.Content)) }
        taps(KeyEvent.KEYCODE_DPAD_DOWN, 12)
        realtimeEnd()
        println("live list: ${counts()}")
        assertEquals("LiveOverlay recomposed on ▼: ${counts()}", 0, RecomposeProbe["LiveOverlay"])
        assertEquals("GroupColumn recomposed on ▼: ${counts()}", 0, RecomposeProbe["GroupColumn"])
        // Nur neu sichtbare Zeilen werden komponiert (Scrollen um eine Zeile je Schritt).
        assertTrue("ChannelRow compositions ${counts()}", RecomposeProbe["ChannelRow"] <= 12 * 3)
    }

    @Test fun groupStepsAreDebounced() {
        huge = true
        launch(big = true) { it.setShell(ShellState(Tab.Live, Zone.Content)) }
        press(KeyEvent.KEYCODE_DPAD_LEFT)
        assertEquals("live_groups", zone())
        repeat(12) { press(KeyEvent.KEYCODE_DPAD_UP) }
        rule.mainClock.advanceTimeBy(GROUP_DEBOUNCE_MS + 40); settle()
        assertEquals("still in groups: ${label(focused())}", "live_groups", zone())
        // 10 Schritte schneller als die Entprell-Zeit → Overlay (Senderliste) höchstens einmal neu.
        val before = label(focused())
        taps(KeyEvent.KEYCODE_DPAD_DOWN, 10)
        val during = RecomposeProbe["LiveOverlay"]
        println("groups: $before → ${label(focused())} zone=${zone()}")
        frames((GROUP_DEBOUNCE_MS / 16 + 4).toInt())
        realtimeEnd()
        println("groups: during=$during ${counts()}")
        assertEquals("overlay must not rebuild while moving: ${counts()}", 0, during)
        assertTrue("overlay rebuilt once after debounce: ${counts()}", RecomposeProbe["LiveOverlay"] in 1..2)
        assertTrue("group column per step: ${counts()}", RecomposeProbe["GroupColumn"] <= 10 * 2 + 2)
    }

    @Test fun settingsStepsDoNotRecomposeScreen() {
        launch { it.setShell(ShellState(Tab.Settings, Zone.Content)) }
        taps(KeyEvent.KEYCODE_DPAD_DOWN, 10)
        realtimeEnd()
        println("settings: ${counts()}")
        assertEquals(counts(), 0, RecomposeProbe["SettingsScreen"])
    }

    @Test fun startStepsDoNotRecomposeScreen() {
        launch { it.setShell(ShellState(Tab.Start, Zone.Content)) }
        press(KeyEvent.KEYCODE_DPAD_DOWN)
        taps(KeyEvent.KEYCODE_DPAD_RIGHT, 4)
        taps(KeyEvent.KEYCODE_DPAD_UP, 1)
        realtimeEnd()
        println("start: ${counts()}")
        assertEquals(counts(), 0, RecomposeProbe["StartScreen"])
    }

    @Test fun guideStepsRecomposeOnlyAffectedRows() {
        launch { it.setShell(ShellState(Tab.Guide, Zone.Content)) }
        taps(KeyEvent.KEYCODE_DPAD_DOWN, 8)
        realtimeEnd()
        println("guide: ${counts()}")
        // Je Schritt: Kopf/Info (GuideScreen) + alte und neue Zeile (+ neu sichtbare beim Scrollen).
        assertTrue(counts(), RecomposeProbe["GuideScreen"] <= 8 + 2)
        assertTrue(counts(), RecomposeProbe["GuideRow"] <= 8 * 4)
    }
}
