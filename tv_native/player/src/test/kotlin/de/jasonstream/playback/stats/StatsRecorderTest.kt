package de.jasonstream.playback.stats

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Wiedergabe-Statistik: Zähler, Perzentile, Ampel, Persistenz (reine Logik). */
class StatsRecorderTest {
    private var now = 100_000L
    private var wall = 1_700_000_000_000L
    private val saved = ArrayList<String>()
    private val store = object : StatsStore {
        var json: String? = null
        override fun load() = json
        override fun save(json: String) { this.json = json; saved += json }
    }

    private fun rec() = StatsRecorder(clock = { now }, wallClock = { wall })

    @Test fun zapTimeFromKeyPressToFirstFrame() {
        val r = rec()
        r.onZapStart(now)
        now += 120 // PIN/Adresse
        r.onOpen(zap = true, reconnect = false)
        now += 880
        r.onFirstFrame()
        r.onFirstFrame() // zweites Bild zählt nicht
        assertEquals(1, r.data.zapCount)
        assertEquals(listOf(1000L), r.data.zapMs)
        assertEquals(1000L, r.data.zapP90)
        // Öffnen ohne vorherigen Tastendruck (Auswahl in der Liste): Zeit ab Öffnen.
        r.onOpen(zap = true, reconnect = false)
        now += 500
        r.onFirstFrame()
        assertEquals(listOf(1000L, 500L), r.data.zapMs)
        assertEquals(2, r.data.zapCount)
    }

    @Test fun reconnectIsNotAZapAndErrorsCountFailedZaps() {
        val r = rec()
        r.onZapStart(now); r.onOpen(zap = true, reconnect = false)
        now += 200
        r.onError("http 403")
        assertEquals(1, r.data.zapFailed)
        assertTrue(r.data.zapMs.isEmpty())
        r.onOpen(zap = true, reconnect = true)
        now += 300
        r.onFirstFrame()
        assertEquals(1, r.data.reconnects)
        assertEquals(1, r.data.zapCount)
        assertTrue("first frame after reconnect is no zap", r.data.zapMs.isEmpty())
    }

    @Test fun stallsOnlyAfterReady() {
        val r = rec()
        r.onOpen(zap = true, reconnect = false)
        r.onPlaybackState(2) // erstes Puffern: kein Stall
        r.onPlaybackState(3)
        r.onPlaybackState(2) // Nachpuffern
        r.onPlaybackState(2)
        r.onPlaybackState(3)
        r.onPlaybackState(2)
        assertEquals(2, r.data.stalls)
        r.onStall()
        assertEquals(3, r.data.stalls)
    }

    @Test fun watchTimeAndStallGrade() {
        val r = rec()
        r.onIsPlaying(true)
        now += 3_600_000
        r.tick()
        now += 3_600_000
        r.onIsPlaying(false)
        assertEquals(7_200_000L, r.data.watchMs)
        assertEquals(Grade.green, r.data.grade(Metric.stalls))
        r.onStall()
        assertEquals(Grade.green, r.data.grade(Metric.stalls)) // 1 je 2 h erlaubt
        r.onStall(); r.onStall()
        assertEquals(Grade.yellow, r.data.grade(Metric.stalls))
        r.onStall()
        assertEquals(Grade.red, r.data.grade(Metric.stalls))
    }

    @Test fun focusReactionP95AndGrades() {
        val r = rec()
        for (i in 1..20) {
            r.onNavKeyDown(now)
            r.onNavKeyDown(now) // zweites Tasten-Tor: zählt nicht doppelt
            now += 40
            r.onFocusGained()
            r.onFocusGained() // Fokus ohne Taste: keine Messung
            now += 500
        }
        assertEquals(20, r.data.focusMs.size)
        assertEquals(40L, r.data.focusP95)
        assertEquals(Grade.green, r.data.grade(Metric.focus))
        repeat(2) { r.onNavKeyDown(now); now += 190; r.onFocusGained(); now += 500 }
        assertEquals(190L, r.data.focusP95)
        assertEquals(Grade.yellow, r.data.grade(Metric.focus))
        // Zu späte Reaktion (> 2 s) ist keine Antwort auf die Taste.
        r.onNavKeyDown(now); now += 5000; r.onFocusGained()
        assertEquals(22, r.data.focusMs.size)
    }

    @Test fun percentilesAndOverall() {
        assertNull(StatsData.percentile(emptyList(), 90))
        assertEquals(5L, StatsData.percentile((1L..10L).toList(), 50))
        assertEquals(9L, StatsData.percentile((1L..10L).toList(), 90))
        assertEquals(10L, StatsData.percentile((1L..10L).toList(), 95))
        val d = StatsData(zapMs = listOf(500, 800, 4000), focusMs = listOf(50), appStartMs = listOf(2500))
        assertEquals(Grade.yellow, d.grade(Metric.zap)) // P90 = 4000 ≤ 4500
        assertEquals(Grade.green, d.grade(Metric.appStart))
        assertEquals(Grade.yellow, d.overall)
        assertEquals(Grade.red, d.copy(crashes = 3).overall)
        assertEquals(Grade.green, StatsData().grade(Metric.crashes))
        assertEquals(Grade.none, StatsData().grade(Metric.zap))
        assertEquals(Grade.green, StatsData().overall)
    }

    @Test fun persistsAndMergesEventsBeforeStore() {
        val r = rec()
        r.onCrashMarker() // vor dem Laden (Application.onCreate)
        r.onAppStart(1800)
        store.json = StatsData(zapCount = 3, zapMs = listOf(700, 900, 1100), stalls = 1, since = 42).toJson()
        r.store = store
        assertEquals(1, r.data.crashes)
        assertEquals(3, r.data.zapCount)
        assertEquals(listOf(1800L), r.data.appStartMs)
        assertEquals(42L, r.data.since)
        // Gespeichert → neu geladen identisch.
        val again = StatsData.fromJson(store.json)
        assertEquals(r.data, again)
        // Zurücksetzen leert alles und schreibt sofort.
        r.reset()
        assertEquals(0, StatsData.fromJson(store.json).zapCount)
        assertEquals(0, r.data.crashes)
        assertEquals(wall, r.data.since)
    }

    @Test fun listsAreBounded() {
        var d = StatsData()
        for (i in 1..600) d = d + StatsData(zapMs = listOf(i.toLong()))
        assertEquals(StatsData.MAX_ZAPS, d.zapMs.size)
        assertEquals(600L, d.zapMs.last())
        assertEquals(20, d.zapLast20.size)
    }

    @Test fun jsonRoundTripIgnoresGarbage() {
        assertEquals(StatsData(), StatsData.fromJson("not json"))
        assertEquals(StatsData(), StatsData.fromJson(null))
        val d = StatsData(2, 1, listOf(5, 6), 3, 4, 1, 2, listOf(10), listOf(2000), 99, "20/20 ok=20", 7)
        assertEquals(d, StatsData.fromJson(d.toJson()))
    }
}
