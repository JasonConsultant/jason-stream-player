package de.jasonstream.player.logic

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ShellAndUpdateTest {
    @Test fun backStackContentMenuStartExit() {
        var s = ShellState(Tab.Guide, Zone.Content)
        var r = ShellNav.back(s, 1000)
        assertEquals(ShellState(Tab.Guide, Zone.Menu), r.state)
        r = ShellNav.back(r.state, 1100)
        assertEquals(Tab.Start, r.state.tab)
        assertEquals(Zone.Menu, r.state.zone)
        r = ShellNav.back(r.state, 1200)
        assertEquals(ShellNav.Effect.ShowExitHint, r.effect)
        // Nach mehr als 2 s erneut nur der Hinweis.
        val late = ShellNav.back(r.state, 1200 + ShellNav.EXIT_WINDOW_MS + 1)
        assertEquals(ShellNav.Effect.ShowExitHint, late.effect)
        // Innerhalb von 2 s → Beenden.
        assertEquals(ShellNav.Effect.Exit, ShellNav.back(late.state, 1200 + ShellNav.EXIT_WINDOW_MS + 500).effect)
        // Jede andere Aktion setzt das Beenden zurück.
        s = ShellNav.enterContent(r.state)
        assertNull(s.exitArmedAt)
        assertEquals(ShellState(Tab.Live, Zone.Content), ShellNav.open(ShellState(), Tab.Live))
        assertEquals(Zone.Menu, ShellNav.toMenu(s).zone)
    }

    @Test fun versionCompare() {
        assertEquals(1, UpdateLogic.compareVersions("0.9.10", "0.9.4"))
        assertEquals(0, UpdateLogic.compareVersions("v1.2", "1.2.0"))
        assertEquals(1, UpdateLogic.compareVersions("2.0.0", "2.0.0-alpha1"))
        assertEquals(-1, UpdateLogic.compareVersions("2.0.0-alpha1", "2.0.0-alpha2"))
        assertEquals(1, UpdateLogic.compareVersions("2.0.0-beta1", "2.0.0-alpha3"))
        assertEquals(1, UpdateLogic.compareVersions("2.0.0-alpha1", "1.5.3"))
        assertEquals(0, UpdateLogic.compareVersions("1.4.0+12", "1.4.0"))
    }

    @Test fun assetNameAndParse() {
        assertEquals("JasonStreamPlayer_TV_2.0.1.apk", UpdateLogic.assetFor("de.jasonstream.player", "2.0.1"))
        assertEquals("JasonStreamPlayer_TR_TV_2.0.1.apk", UpdateLogic.assetFor("de.jasonstream.player.tr", "2.0.1"))
        val json = """{"tag_name":"v2.0.1","body":" Neu ","assets":[
            {"name":"JasonStreamPlayer_2.0.1_arm64.apk","browser_download_url":"https://x/a.apk","size":1},
            {"name":"JasonStreamPlayer_TV_2.0.1.apk","browser_download_url":"https://x/tv.apk","size":42}]}"""
        val u = UpdateLogic.parseLatest(json, "2.0.0-alpha1", "de.jasonstream.player")!!
        assertEquals("2.0.1", u.version)
        assertEquals("https://x/tv.apk", u.apkUrl)
        assertEquals(42L, u.size)
        assertEquals("Neu", u.notes)
        assertNull(UpdateLogic.parseLatest(json, "2.0.1", "de.jasonstream.player"))
        assertNull(UpdateLogic.parseLatest(json, "2.0.0", "de.jasonstream.player.tr")) // keine TR-Datei
        val http = json.replace("https://x/tv.apk", "http://x/tv.apk")
        assertNull(UpdateLogic.parseLatest(http, "2.0.0", "de.jasonstream.player"))
        assertTrue(UpdateLogic.LATEST_URL.contains("JasonConsultant/jason-stream-player"))
    }
}
