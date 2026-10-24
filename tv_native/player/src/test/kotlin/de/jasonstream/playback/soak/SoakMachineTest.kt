package de.jasonstream.playback.soak

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Dauertest-Zustandsmaschine: Zyklus, Verweilzeit, Fehler, Hänger, Abbruch. */
class SoakMachineTest {
    @Test fun cyclesThroughListAndFinishes() {
        val m = SoakMachine(count = 5, dwellMs = 1000, listSize = 3, startIndex = 1)
        var t = 0L
        var a = m.start(t)
        val visited = ArrayList<Int>()
        while (a is SoakAction.Zap) {
            visited += a.index
            t += 300
            m.onFirstFrame(t)
            assertTrue(m.state is SoakState.Dwelling)
            assertNull(m.tick(t + 500))
            t += 1000
            a = m.tick(t) ?: error("expected next action")
        }
        assertEquals(SoakAction.Finish, a)
        assertEquals(listOf(2, 0, 1, 2, 0), visited)
        val r = m.result!!
        assertTrue(r.completed)
        assertEquals(5, r.ok)
        assertEquals(0, r.failed)
        assertEquals(300L, r.p50Ms)
        assertEquals(300L, r.p90Ms)
        assertTrue("summary: ${r.summaryLine()}", "5/5 ok=5 fail=0" in r.summaryLine())
    }

    @Test fun errorsContinueAndStallAborts() {
        val m = SoakMachine(count = 3, dwellMs = 4000, listSize = 10)
        m.start(0)
        assertNull(m.onError(100, "http 403")) // weiter nach kurzer Pause
        assertEquals(1, m.failedCount)
        val next = m.tick(100 + 1500)
        assertTrue(next is SoakAction.Zap && next.step == 2)
        // Hänger: 15 s ohne Bild → Abbruch.
        assertNull(m.tick(1600 + 14_000))
        val fin = m.tick(1600 + 15_000)
        assertEquals(SoakAction.Finish, fin)
        val r = m.result!!
        assertEquals(SoakAbort.stall, r.abort)
        assertEquals(2, r.failed)
        assertTrue(!r.completed)
    }

    @Test fun cancelFromBack() {
        val m = SoakMachine(count = 100, listSize = 5)
        m.start(0)
        m.onFirstFrame(800)
        assertEquals(SoakAction.Finish, m.cancel(900))
        assertNull(m.cancel(1000))
        val r = m.result!!
        assertEquals(SoakAbort.cancelled, r.abort)
        assertEquals(1, r.zaps)
        assertEquals(1, r.ok)
        assertEquals(800L, r.maxMs)
    }
}
