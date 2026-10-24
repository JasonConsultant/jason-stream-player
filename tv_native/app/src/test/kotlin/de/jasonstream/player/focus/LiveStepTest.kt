package de.jasonstream.player.focus

import android.view.KeyEvent
import de.jasonstream.player.logic.GroupKind
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
 * Gerätemeldung alpha2: „Wenn ich in den Gruppen nach oben drücke, springt es
 * mehrere Schritte.“ – Live-Overlay mit Gerätetakt (Bilder nur bei laufender
 * Uhr), TV-Scrollverhalten (leanback) und 40 Gruppen / 2 000 Sendern.
 * Jeder Druck = genau ein Schritt; gehaltene Taste = ein Schritt je Wiederholung, ohne Nachlaufen.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "de-w960dp-h540dp-land-television-xhdpi")
class LiveStepTest : FocusHarness() {

    private val up = KeyEvent.KEYCODE_DPAD_UP
    private val down = KeyEvent.KEYCODE_DPAD_DOWN

    private fun groupName(i: Int): String {
        val g = vm.live.value.groups[i]
        val ctx = rule.activity
        return when (g.kind) {
            GroupKind.Favorites -> ctx.getString(de.jasonstream.core.R.string.favouritesStarred)
            GroupKind.Recent -> ctx.getString(de.jasonstream.core.R.string.recentlyWatched)
            GroupKind.All -> ctx.getString(de.jasonstream.core.R.string.allChannels)
            else -> g.name
        }
    }

    /** Index der fokussierten Gruppe (-1 = Fokus nicht in den Gruppen). */
    private fun groupIndex(): Int {
        val f = focused() ?: return -1
        if (zone(f) != "live_groups") return -1
        val l = label(f)
        return vm.live.value.groups.indices.firstOrNull { l.startsWith("${groupName(it)} |") } ?: -1
    }

    /** Index des fokussierten Senders in der Liste der gewählten Gruppe. */
    private fun channelIndex(groupId: String): Int {
        val f = focused() ?: return -1
        if (zone(f) != "live_list") return -1
        val t = texts(f)
        return vm.live.value.channelsOf(groupId).indexOfFirst { it.name in t }
    }

    private fun openGroups(huge: Boolean = true) {
        this.huge = huge
        launch(big = true) { it.setShell(ShellState(Tab.Live, Zone.Content)) }
        left()
        assertEquals("live_groups", zone())
    }

    /** Gruppe in die Mitte bringen, damit nach oben und unten Platz ist. */
    private fun toGroup(target: Int) {
        var n = 0
        while (groupIndex() != target && n++ < 60) if (groupIndex() < target) down() else up()
        assertEquals(target, groupIndex())
    }

    @Test fun groupsOneStepPerPressDeviceTiming() {
        openGroups()
        toGroup(30)
        realtime()
        val trace = StringBuilder()
        for (k in 1..12) {
            val before = groupIndex()
            tap(up, holdFrames = 3, gapFrames = 4)
            val after = groupIndex()
            trace.append("▲#$k $before→$after\n")
            assertEquals("▲ press #$k must move exactly one group\n$trace", before - 1, after)
        }
        for (k in 1..8) {
            val before = groupIndex()
            tap(down, holdFrames = 2, gapFrames = 3)
            assertEquals("▼ press #$k\n$trace", before + 1, groupIndex())
        }
        realtimeEnd()
    }

    @Test fun groupsQueuedPressesWhileBusy() {
        openGroups()
        toGroup(30)
        realtime()
        // 5 Drücke stauen sich, während die Liste neu aufbaut → genau 5 Schritte.
        burst(up, 5)
        frames(12)
        assertEquals(25, groupIndex())
        burst(down, 3)
        frames(12)
        assertEquals(28, groupIndex())
        realtimeEnd()
        // Nach dem Entprellen zeigt die Liste die neue Gruppe.
        val g = vm.live.value.groups[28]
        assertTrue(vm.live.value.channelsOf(g.id).first().name in textsUnder("live_list"))
    }

    @Test fun groupsHoldCountsEveryRepeat() {
        openGroups()
        toGroup(35)
        realtime()
        val before = groupIndex()
        // 20 Wiederholungen alle 48 ms (≈ 1 s gehalten) → 1 + 20 Schritte, zählgenau, kein Nachlaufen.
        hold(up, repeats = 20, everyFrames = 3)
        frames(2)
        val afterRelease = groupIndex()
        frames(30)
        val later = groupIndex()
        assertEquals("hold: 1 + 20 repeats = 21 steps", 21, before - afterRelease)
        assertEquals("no extra steps after release", afterRelease, later)
        realtimeEnd()
    }

    @Test fun groupsFastRepeatsCountExactly() {
        openGroups()
        toGroup(35)
        realtime()
        val before = groupIndex()
        // Fernbedienung mit 32 ms Wiederholrate (2 Bilder): 12 Wiederholungen → 13 Schritte.
        hold(up, repeats = 12, everyFrames = 2)
        frames(3)
        assertEquals("fast repeats", 13, before - groupIndex())
        realtimeEnd()
    }

    @Test fun groupsQueuedRepeatsAllCount() {
        openGroups()
        toGroup(30)
        realtime()
        val t0 = android.os.SystemClock.uptimeMillis()
        send(up, KeyEvent.ACTION_DOWN, 0, t0)
        frames(2)
        // 10 Wiederholungen kommen gleichzeitig (gestaut) an → zählen alle, gezeichnet wird das Ziel.
        rule.runOnUiThread {
            for (r in 1..10) rule.activity.dispatchKeyEvent(KeyEvent(t0, t0 + 400 + r * 50L, KeyEvent.ACTION_DOWN, up, r))
        }
        frames(2)
        send(up, KeyEvent.ACTION_UP, 0, t0 + 1000)
        frames(4)
        assertEquals("queued repeats count: 1 + 10", 11, 30 - groupIndex())
        realtimeEnd()
    }

    @Test fun channelListOneStepPerPress() {
        this.huge = true
        launch(big = true) { it.setShell(ShellState(Tab.Live, Zone.Content)) }
        assertEquals("live_list", zone())
        val gid = vm.lastLiveGroup ?: "__all"
        // gewählte Gruppe aus der Liste ermitteln
        val group = vm.live.value.groups.first { g -> vm.live.value.channelsOf(g.id).any { it.name in texts(focused()!!) } && g.kind == GroupKind.All }
        realtime()
        for (k in 1..15) {
            val before = channelIndex(group.id)
            tap(down, holdFrames = 2, gapFrames = 3)
            assertEquals("▼ #$k (group $gid)", before + 1, channelIndex(group.id))
        }
        for (k in 1..15) {
            val before = channelIndex(group.id)
            tap(up, holdFrames = 2, gapFrames = 3)
            assertEquals("▲ #$k", before - 1, channelIndex(group.id))
        }
        burst(down, 6)
        frames(10)
        val b = channelIndex(group.id)
        burst(down, 4)
        frames(10)
        assertEquals("queued presses in list", b + 4, channelIndex(group.id))
        realtimeEnd()
    }
}
