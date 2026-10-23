package de.jasonstream.player.focus

import android.view.KeyEvent
import de.jasonstream.core.R
import de.jasonstream.player.logic.ShellState
import de.jasonstream.player.logic.Tab
import de.jasonstream.player.logic.Zone
import de.jasonstream.player.state.Overlay
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * „Springt mehrere Schritte“ – für jede Liste, in der man mit Pfeiltasten
 * blättert: Einstellungen, Startseite (Reihen + Karten), TV-Guide (Chips +
 * Raster), Suche (Ergebnisse + Senderreihe), Portale, Auswahl-Dialog.
 *
 * Je Liste: Grundwahrheit aus einzelnen, voll abgewarteten Drücken (jeder
 * Schritt ein neues Element, zurück wieder am Anfang), dann dieselben
 * Schritte im Gerätetakt (KeyDown/KeyUp, wenige Bilder), gestaut (alle
 * Drücke ohne Bild dazwischen) und gehalten (Wiederholungen alle 48 ms:
 * gedrosselt, kein Nachlaufen nach dem Loslassen). Läuft mit leanback
 * (TV-Scrollverhalten wie auf der Box).
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "de-w960dp-h540dp-land-television-xhdpi")
class ListStepTest : FocusHarness() {

    private val trace = StringBuilder()
    private fun cur(): String = label(topFocused())
    private fun s(id: Int) = rule.activity.getString(id)

    private val UP = KeyEvent.KEYCODE_DPAD_UP
    private val DOWN = KeyEvent.KEYCODE_DPAD_DOWN
    private val LEFT = KeyEvent.KEYCODE_DPAD_LEFT
    private val RIGHT = KeyEvent.KEYCODE_DPAD_RIGHT

    /**
     * Prüft [steps] Schritte mit [next]/[prev] ab der aktuellen Position.
     * [read] liefert die Kennung der Position (Standard: Text des Fokus),
     * [expected] (optional) Texte, die die Positionen 0..steps enthalten müssen.
     */
    private fun checkList(
        name: String,
        next: Int,
        prev: Int,
        steps: Int,
        expected: List<String>? = null,
        read: () -> String = ::cur,
    ) {
        // 1) Grundwahrheit: einzelne Drücke, voll abgewartet.
        val seq = arrayListOf(read())
        repeat(steps) { press(next); seq += read() }
        trace.append("$name: ${seq.joinToString(" → ") { it.take(28) }}\n")
        assertEquals("$name: every press reaches a new element\n$trace", steps + 1, seq.toSet().size)
        expected?.forEachIndexed { i, e -> assertTrue("$name #$i: '${seq[i]}' should contain '$e'\n$trace", e in seq[i]) }
        repeat(steps) { press(prev) }
        assertEquals("$name: back at start\n$trace", seq[0], read())

        realtime()
        // 2) Gerätetakt: jeder Druck genau ein Schritt.
        for (i in 1..steps) {
            tap(next, holdFrames = 2, gapFrames = 3)
            assertEquals("$name: realtime ${keyName(next)} #$i\n$trace", seq[i], read())
        }
        for (i in steps - 1 downTo 0) {
            tap(prev, holdFrames = 2, gapFrames = 3)
            assertEquals("$name: realtime ${keyName(prev)} → #$i\n$trace", seq[i], read())
        }
        // 3) Gestaut: n Drücke im selben Bild → genau n Schritte.
        burst(next, steps)
        frames(12)
        assertEquals("$name: $steps queued presses\n$trace", seq[steps], read())
        burst(prev, steps)
        frames(12)
        assertEquals("$name: $steps queued presses back\n$trace", seq[0], read())
        // 4) Gehalten: 2·(steps−1) Wiederholungen à 48 ms → höchstens ~12/s, kein Nachlaufen.
        if (steps >= 3) {
            hold(next, repeats = 2 * (steps - 1))
            val afterRelease = read()
            frames(20)
            assertEquals("$name: no movement after release\n$trace", afterRelease, read())
            val j = seq.indexOf(afterRelease)
            assertTrue("$name: hold moved to #$j (2..$steps expected)\n$trace", j in 2..steps)
            realtimeEnd()
            repeat(j) { press(prev) }
        } else realtimeEnd()
        assertEquals("$name: back at start after hold\n$trace", seq[0], read())
    }

    private fun keyName(k: Int) = when (k) { UP -> "▲"; DOWN -> "▼"; LEFT -> "◀"; RIGHT -> "▶"; else -> "$k" }

    @Test fun settingsList() {
        launch { it.setShell(ShellState(Tab.Settings, Zone.Content)) }
        val exp = listOf(
            R.string.portals, R.string.epgSources, R.string.reloadChannelsEpg, R.string.appLanguage, R.string.showOnOpen,
            R.string.accentColor, R.string.preferredAudioLanguage, R.string.subtitles, R.string.subStyle,
        ).map(::s)
        checkList("settings", DOWN, UP, 8, exp)
        // Ende der Liste: ▼ bleibt am letzten Eintrag.
        repeat(30) { press(DOWN) }
        val last = cur()
        press(DOWN)
        assertEquals("settings end", last, cur())
        assertTrue("last entry visible", isVisible(topFocused()!!))
    }

    @Test fun optionsDialog() {
        launch { it.setShell(ShellState(Tab.Settings, Zone.Content)) }
        // Einstellungen → Untertitel (Slot 7) → Auswahl mit 14 Sprachen.
        repeat(7) { press(DOWN) }
        assertTrue(s(R.string.subtitles) in cur())
        press(KeyEvent.KEYCODE_DPAD_CENTER)
        assertTrue("dialog open", openDialog() != null)
        checkList("options dialog", DOWN, UP, 8)
        repeat(20) { press(DOWN) }
        assertTrue("last option visible", isVisible(topFocused()!!))
        press(KeyEvent.KEYCODE_BACK)
    }

    @Test fun portalsList() {
        launch { it.setShell(ShellState(Tab.Settings, Zone.Content)) }
        rule.runOnUiThread { vm.pushOverlay(Overlay.Portals) }
        settle(6)
        checkList("portals", DOWN, UP, 2, listOf("", s(R.string.addPortal), s(R.string.setUpPhone)))
    }

    @Test fun startRowsAndCards() {
        launch { it.setShell(ShellState(Tab.Start, Zone.Content)) }
        val snap = vm.live.value
        val rows = 1 + listOf(snap.recentChannels, snap.favoriteChannels).count { it.isNotEmpty() }
        if (rows > 1) checkList("start rows", DOWN, UP, rows - 1)
        // In die erste Kartenreihe, dann ◀▶.
        press(DOWN)
        val cards = snap.recentChannels.ifEmpty { snap.favoriteChannels }
        val n = minOf(5, cards.size - 1)
        if (n >= 1) checkList("start cards", RIGHT, LEFT, n, cards.take(n + 1).map { it.name })
    }

    @Test fun guideChipsAndGrid() {
        launch { it.setShell(ShellState(Tab.Guide, Zone.Content)) }
        // Raster: ▼ genau ein Sender je Druck (Info oben zeigt den Sender).
        val info = { textsUnder("guide_info").firstOrNull() ?: "" }
        checkList("guide grid", DOWN, UP, 6, read = info)
        // Hoch zu den Chips, ganz nach links, dann ◀▶.
        var n = 0
        while ("guide_chips" !in (topFocused()?.let { tags(it) } ?: emptyList()) && n++ < 40) press(UP)
        repeat(20) { press(LEFT) }
        checkList("guide chips", RIGHT, LEFT, 6)
    }

    @Test fun searchResults() {
        launch {
            it.pendingSearch = "Sport"
            it.setShell(ShellState(Tab.Search, Zone.Content))
        }
        rule.waitUntil(10_000) { settle(); textsUnder("search_results").isNotEmpty() }
        // Suchfeld → ▼ (über die Chips der letzten Suchen) in die Ergebnisse (Senderreihe).
        var k = 0
        while ("search_results" !in tags(topFocused()!!) && k++ < 3) press(DOWN)
        assertTrue("in results: ${tags(topFocused()!!)}", "search_results" in tags(topFocused()!!))
        val chans = textsUnder("search_results")
        assertTrue("Arena Sport 1 HD" in chans)
        checkList("search cards", RIGHT, LEFT, 1)
        checkList("search results", DOWN, UP, 5)
    }

    @Test fun keyLogDiagnostic() {
        launch { it.setShell(ShellState(Tab.Settings, Zone.Content)) }
        val keyLog = de.jasonstream.player.ui.common.KeyLog
        try {
            assertTrue("off by default", !keyLog.enabled)
            var n = 0
            while ("settings_version" !in tags(topFocused()!!) && n++ < 30) press(DOWN)
            assertTrue("version focusable: ${label(topFocused())}", "settings_version" in tags(topFocused()!!))
            repeat(4) { press(KeyEvent.KEYCODE_DPAD_CENTER) }
            assertTrue("not yet after 4×OK", !keyLog.enabled)
            press(KeyEvent.KEYCODE_DPAD_CENTER)
            assertTrue("on after 5×OK", keyLog.enabled)
            press(UP); press(DOWN)
            settle(3)
            val shown = textsUnder("keylog")
            println("keylog: $shown")
            assertTrue("shows DPAD_UP down/up: $shown", shown.any { "DPAD_UP" in it && "↓" in it } && shown.any { "DPAD_UP" in it && "↑" in it })
            assertTrue("shows focused element tag: $shown", shown.any { it.startsWith("Fokus:") && "settings_list" in it })
            assertTrue("at most 8 events", keyLog.entries.size <= 8)
            // Wiederholungen, die das Tasten-Tor zusammenfasst, sind markiert (×).
            realtime()
            hold(UP, repeats = 6)
            realtimeEnd()
            assertTrue("dropped repeats marked: ${keyLog.entries}", keyLog.entries.any { it.dropped && it.repeat > 0 })
            // Wieder aus: 5×OK auf der Version.
            n = 0
            while ("settings_version" !in tags(topFocused()!!) && n++ < 30) press(DOWN)
            repeat(5) { press(KeyEvent.KEYCODE_DPAD_CENTER) }
            assertTrue("off again", !keyLog.enabled)
            assertTrue(textsUnder("keylog").isEmpty())
        } finally {
            if (keyLog.enabled) keyLog.toggle()
        }
    }
}
