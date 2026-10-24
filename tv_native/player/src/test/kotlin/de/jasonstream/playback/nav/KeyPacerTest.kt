package de.jasonstream.playback.nav

import android.view.KeyEvent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Einstufung gehaltener Tasten (reine Logik, ohne Compose): false = nur zusammenfassen, nie verwerfen. */
class KeyPacerTest {
    private var now = 10_000L
    private val up = KeyEvent.KEYCODE_DPAD_UP

    @Test fun everyFreshPressPasses() {
        val p = KeyPacer(clock = { now })
        // 20 einzelne Drücke im selben Bild (gestaut): jeder zählt.
        repeat(20) { assertTrue(p.accept(up, 0, now)) }
    }

    @Test fun fastRepeatsRenderWhenFramesKeepUp() {
        val p = KeyPacer(clock = { now })
        var rendered = 0
        if (p.accept(up, 0, now)) rendered++
        // 1 s gehalten, Wiederholung alle 25 ms (schnelle Fernbedienung), je Wiederholung ein Bild fertig.
        var t = now + 400
        for (r in 1..40) {
            p.frameBusy = false // Bild gezeichnet
            now = t
            if (p.accept(up, r, t)) rendered++
            t += 25
        }
        // Kein Mindestabstand mehr: jede Wiederholung wird gezeichnet (und zählt sowieso).
        assertEquals(41, rendered)
    }

    @Test fun minIntervalOnlyCoalescesRendering() {
        val p = KeyPacer(minIntervalMs = 83, clock = { now })
        var rendered = 0
        if (p.accept(up, 0, now)) rendered++
        var t = now + 400
        for (r in 1..40) {
            p.frameBusy = false
            now = t
            if (p.accept(up, r, t)) rendered++
            t += 25
        }
        assertTrue("rendered=$rendered", rendered in 10..14)
    }

    @Test fun oneStepPerFrame() {
        val p = KeyPacer(clock = { now })
        p.accept(up, 0, now)
        p.frameBusy = false
        assertTrue(p.accept(up, 1, now + 400))
        // Kein Bild seitdem → weitere Wiederholung verworfen, auch wenn Zeit vergangen ist.
        assertFalse(p.accept(up, 2, now + 500))
        p.frameBusy = false
        assertTrue(p.accept(up, 3, now + 600))
    }

    @Test fun staleRepeatsAreCoalesced() {
        val p = KeyPacer(clock = { now })
        p.accept(up, 0, now - 2_000)
        p.frameBusy = false
        // Ereignisse, die 300 ms in der Warteschlange lagen (App beschäftigt) → zusammengefasst (zählen trotzdem).
        var passed = 0
        for (r in 1..10) if (p.accept(up, r, now - 300 + r)) passed++
        assertEquals(0, passed)
        // Frische Wiederholung danach geht wieder.
        assertTrue(p.accept(up, 11, now))
    }

    @Test fun otherKeyResets() {
        val p = KeyPacer(clock = { now })
        p.accept(up, 0, now)
        // Wechsel der Taste (auch als Wiederholung gemeldet) zählt als neuer Druck.
        assertTrue(p.accept(KeyEvent.KEYCODE_DPAD_DOWN, 3, now + 1))
    }
}
