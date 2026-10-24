package de.jasonstream.player.focus

import android.view.KeyEvent
import de.jasonstream.core.R
import de.jasonstream.player.logic.ShellState
import de.jasonstream.player.logic.Tab
import de.jasonstream.player.logic.Zone
import de.jasonstream.player.state.Overlay
import de.jasonstream.playback.stats.PlaybackStats
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * Einstellungen → Wiedergabe-Statistik: Seite per D-Pad bedienbar (jede Zeile
 * ein Schritt), „Zurücksetzen“ leert die Zähler, 3× OK auf die Überschrift
 * schaltet den Dauertest frei, Zurück schließt die Seite.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "de-w960dp-h540dp-land-television-xhdpi")
class StatsScreenTest : FocusHarness() {
    private fun s(id: Int, vararg a: Any) = rule.activity.getString(id, *a)
    private fun hasTag(t: String) = t in (topFocused()?.let { tags(it) } ?: emptyList())

    @Test fun statsPageDpadResetAndSoakUnlock() {
        val rec = PlaybackStats.session
        rec.reset()
        // Ein paar Werte, damit die Ampel etwas zeigt und „Zurücksetzen“ sichtbar wirkt.
        rec.onZapStart(0); rec.onOpen(zap = true, reconnect = false); rec.onFirstFrame()
        rec.onStall()
        launch { it.setShell(ShellState(Tab.Settings, Zone.Content)) }
        assertEquals(1, rec.data.zapCount)

        // Zum Eintrag „Wiedergabe-Statistik“ und öffnen.
        var n = 0
        while (!hasTag("settings_stats") && n++ < 30) down()
        assertTrue("stats entry reachable: ${label(topFocused())}", hasTag("settings_stats"))
        ok()
        settle(6)
        assertTrue("stats page open", vm.overlays.value.lastOrNull() == Overlay.Stats)
        assertTrue("title focused first: ${label(topFocused())}", hasTag("stats_title"))
        assertTrue(s(R.string.statFocusReaction) in textsUnder("stats_list"))

        // ▼: jede Zeile genau ein Schritt bis „Zurücksetzen“ (Titel, 6 Ziele, Zaps, Reset = 8 Schritte).
        val seen = arrayListOf(label(topFocused()))
        repeat(8) { down(); seen += label(topFocused()) }
        assertEquals("each ▼ a new row: $seen", 9, seen.toSet().size)
        assertTrue("reset reached: ${label(topFocused())}", hasTag("stats_reset"))
        down()
        assertTrue("end of list stays on reset", hasTag("stats_reset"))
        ok()
        settle(3)
        assertEquals(0, rec.data.zapCount)
        assertEquals(0, rec.data.stalls)
        assertTrue("toast shown", s(R.string.statResetDone) in textsUnder("main"))

        // Zurück zur Überschrift, 3× OK → Dauertest-Einträge erscheinen und bekommen den Fokus.
        repeat(10) { up() }
        assertTrue(hasTag("stats_title"))
        repeat(2) { ok() }
        assertTrue("not unlocked after 2×OK", textsUnder("stats_list").none { it == s(R.string.soakStartN, "20") })
        ok()
        settle(4)
        assertTrue("soak rows", textsUnder("stats_list").any { it == s(R.string.soakStartN, "20") })
        assertTrue("focus on first soak row: ${label(topFocused())}", hasTag("soak_20"))
        down(); assertTrue(hasTag("soak_100"))
        down(); assertTrue(hasTag("soak_300"))
        // Ohne Engine (Tests): Hinweis statt Start, Seite bleibt bedienbar.
        ok()
        settle(3)
        assertTrue(hasTag("soak_300"))

        back()
        settle(4)
        assertTrue("back closes stats page", vm.overlays.value.isEmpty())
        assertTrue("focus back in settings: ${label(topFocused())}", hasTag("settings_list"))
    }
}
