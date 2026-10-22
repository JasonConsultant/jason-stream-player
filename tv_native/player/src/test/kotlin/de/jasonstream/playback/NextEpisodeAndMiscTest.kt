package de.jasonstream.playback

import de.jasonstream.core.model.Episode
import de.jasonstream.core.model.EpgEntry
import de.jasonstream.core.model.VodItem
import de.jasonstream.playback.api.PlayRequest
import de.jasonstream.playback.logic.AspectMode
import de.jasonstream.playback.logic.DisplayModeInfo
import de.jasonstream.playback.logic.FrameRateMatch
import de.jasonstream.playback.logic.NextEpisode
import de.jasonstream.playback.logic.NextUpState
import de.jasonstream.playback.logic.SubtitleStyle
import de.jasonstream.playback.logic.TimeshiftState
import de.jasonstream.playback.logic.TrackInfo
import de.jasonstream.playback.logic.TrackLanguage
import de.jasonstream.playback.logic.canSaveResume
import de.jasonstream.playback.logic.fmtBehind
import de.jasonstream.playback.logic.fmtClock
import de.jasonstream.playback.logic.pickTrack
import de.jasonstream.playback.logic.resumeTargetMs
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NextEpisodeAndMiscTest {
    private fun ep(id: String, s: Int, n: Int) = Episode(id, s, n, "T$id", "http://h/$id.mkv")
    private val seasons = mapOf(2 to listOf(ep("21", 2, 1)), 1 to listOf(ep("11", 1, 1), ep("12", 1, 2)))

    @Test fun nextEpisodeAcrossSeasons() {
        assertEquals("12", NextEpisode.after(seasons, ep("11", 1, 1))?.id)
        assertEquals("21", NextEpisode.after(seasons, ep("12", 1, 2))?.id)
        assertNull(NextEpisode.after(seasons, ep("21", 2, 1)))
        assertNull(NextEpisode.after(seasons, ep("99", 9, 9)))
    }

    @Test fun episodeRequestChainsNextUp() = runTest {
        val series = VodItem("s", "Serie", "c", "", isSeries = true)
        var finished = false
        val started = ArrayList<String>()
        val r = PlayRequest.episode("p", series, ep("12", 1, 2), seasons, onStart = { started += it.id }, onSeriesFinished = { finished = true })
        assertEquals("ep_12", r.resumeKey)
        assertEquals(PlayRequest.Kind.EPISODE, r.kind)
        val n = r.nextUp!!()!!
        assertEquals(2, n.season); assertEquals(1, n.number)
        assertEquals("ep_21", n.request.resumeKey)
        n.onStart!!()
        assertEquals(listOf("21"), started)
        assertNull(n.request.nextUp!!())
        assertTrue(finished)
    }

    @Test fun nextUpCardFlow() {
        var enabled = true
        val s = NextUpState { enabled }
        val len = 40 * 60_000L
        assertEquals(NextUpState.Action.None, s.onPosition(10_000, len))
        assertEquals(NextUpState.Action.Resolve, s.onPosition(len - 29_000, len))
        assertEquals(NextUpState.Action.None, s.onPosition(len - 28_000, len)) // nur einmal
        s.onResolved(true)
        assertTrue(s.showing)
        repeat(9) { assertEquals(NextUpState.Action.None, s.tick()) }
        assertEquals(1, s.secondsLeft)
        assertEquals(NextUpState.Action.Play, s.tick())
        assertFalse(s.showing)

        // Abbrechen: Folge läuft zu Ende, dann schließen.
        val c = NextUpState { enabled }
        c.onPosition(len - 1000, len); c.onResolved(true)
        assertEquals(NextUpState.Action.None, c.cancel())
        assertEquals(NextUpState.Action.Exit, c.onCompleted())

        // Kurze Videos: keine Karte vor dem Ende; am Ende auflösen.
        val t = NextUpState { enabled }
        assertEquals(NextUpState.Action.None, t.onPosition(60_000, 90_000))
        assertEquals(NextUpState.Action.Resolve, t.onCompleted())
        assertEquals(NextUpState.Action.Exit, t.onResolved(false))

        // Ausgeschaltet (set_autonext = false).
        enabled = false
        val off = NextUpState { enabled }
        assertEquals(NextUpState.Action.None, off.onPosition(len - 1000, len))
        assertEquals(NextUpState.Action.Exit, off.onCompleted())

        // OK während der Karte = sofort.
        enabled = true
        val okNow = NextUpState { enabled }
        okNow.onPosition(len - 1000, len); okNow.onResolved(true)
        assertEquals(NextUpState.Action.Play, okNow.commit())
    }

    @Test fun resumeRules() {
        assertFalse(canSaveResume(live = true, opening = false, posSec = 100, totalSec = 1000))
        assertFalse(canSaveResume(false, opening = true, posSec = 100, totalSec = 1000))
        assertFalse(canSaveResume(false, false, 4, 1000))
        assertFalse(canSaveResume(false, false, 100, 0))
        assertTrue(canSaveResume(false, false, 5, 1000))
        assertNull(resumeTargetMs(null))
        assertNull(resumeTargetMs(15 to 100))
        assertEquals(16_000L, resumeTargetMs(16 to 100))
        // Gleicher Schlüssel/Format wie Flutter: resume_<key> = "pos/total".
        val st = memStorage()
        st.setResume("movie_1", 120, 3600)
        assertEquals(120 to 3600, st.resume("movie_1"))
        st.setResume("movie_1", 3500, 3600) // > 95 % → gesehen
        assertNull(st.resume("movie_1"))
        assertTrue(st.isWatched("movie_1"))
    }

    @Test fun timeshift() {
        val t = TimeshiftState(10 * 60_000L, 0)
        assertFalse(t.isShifted(5_000))
        t.pause(10_000)
        assertTrue(t.isShifted(10_000))
        assertEquals(20_000, t.behind(30_000))
        t.resume(30_000)
        assertEquals(20_000, t.behind(40_000))
        assertEquals(10_000, t.seek(10_000, 40_000)) // vor
        assertEquals(10_000, t.behind(40_000))
        assertEquals(-5_000, t.seek(-5_000, 40_000)) // zurück
        assertEquals(15_000, t.behind(40_000))
        t.goLive()
        assertFalse(t.isShifted(41_000))
        val off = TimeshiftState(0, 0)
        off.pause(1)
        assertFalse(off.paused)
        val hold = TimeshiftState(60_000, 0)
        hold.pause(0)
        assertFalse(hold.overflowed(30_000))
        assertTrue(hold.overflowed(60_000))
        hold.seekable = true
        assertFalse(hold.overflowed(60_000))
        assertEquals("−1:05", fmtBehind(65_000))
        assertEquals("−1:02:03", fmtBehind(3_723_000))
        assertEquals("01:05", fmtClock(65_000))
        assertEquals("1:02:03", fmtClock(3_723_000))
    }

    @Test fun tracksAndLanguages() {
        val tracks = listOf(TrackInfo("1", "eng", null), TrackInfo("2", null, "Deutsch (AC3)"), TrackInfo("3", "tur", null))
        assertNull(pickTrack(tracks, "auto"))
        assertEquals(1, pickTrack(tracks, "de"))
        assertEquals(2, pickTrack(tracks, "tr"))
        assertNull(pickTrack(tracks, "fr"))
        assertEquals(-1, pickTrack(tracks, "fr", allowOff = true))
        assertEquals(-1, pickTrack(tracks, "off", allowOff = true))
        assertEquals("Deutsch", TrackLanguage.describe("ger", "German", "Spur 1"))
        assertEquals("English · Director", TrackLanguage.describe("en", "Director", "x"))
        assertEquals("Spur 4", TrackLanguage.describe(null, null, "Spur 4"))
        assertEquals("Stereo · xx", TrackLanguage.describe("xx", "Stereo", "x"))
    }

    @Test fun subtitleStyleAndAspect() {
        val opts = mapOf("sub_size" to "gross", "sub_color" to "gelb", "sub_bg" to "box", "sub_outline" to "off")
        val s = SubtitleStyle.fromOptions { k, f -> opts[k] ?: f }
        assertEquals(60, s.fontSize)
        assertEquals(0xFFFFFF00.toInt(), s.colorArgb)
        assertEquals(0x80000000.toInt(), s.backArgb)
        assertFalse(s.outline)
        val d = SubtitleStyle.fromOptions { _, f -> if (f == "normal") "riesig" else f }
        assertEquals("normal", d.size)
        assertEquals(48 * 2f / 3f / 540f, d.fraction, 1e-6f)
        assertEquals(AspectMode.original, AspectMode.fromId(null))
        assertEquals(AspectMode.original, AspectMode.fromId("contain"))
        assertEquals(AspectMode.stretch, AspectMode.fromId("fill"))
        assertEquals(AspectMode.fill, AspectMode.fromId("cover"))
        assertEquals(AspectMode.cinema, AspectMode.fromId("cinema"))
        assertEquals(AspectMode.original, AspectMode.zoom.next)
        val st = memStorage()
        st.setChannelAspectId("p", "c", "16x9")
        assertEquals("16x9", st.channelAspectId("p", "c"))
    }

    @Test fun frameRateMatching() {
        val cur = DisplayModeInfo(1, 3840, 2160, 60f)
        val modes = listOf(cur, DisplayModeInfo(2, 3840, 2160, 50f), DisplayModeInfo(3, 3840, 2160, 23.976f), DisplayModeInfo(4, 1920, 1080, 50f))
        assertEquals(2, FrameRateMatch.pick(cur, modes, 25.0)?.id)
        assertEquals(2, FrameRateMatch.pick(cur, modes, 50.0)?.id)
        assertEquals(3, FrameRateMatch.pick(cur, modes, 23.976)?.id)
        assertEquals(1, FrameRateMatch.pick(cur, modes, 30.0)?.id)
        assertNull(FrameRateMatch.pick(cur, listOf(cur), 23.976))
        assertNull(FrameRateMatch.pick(cur, modes, 0.0))
    }

    @Test fun requestFactories() {
        val c = ch("7", "Sender 7", catchup = 3)
        val e = EpgEntry("x", "Show", 1_000_000L, 2_000_000L)
        val r = PlayRequest.catchup("p", c, e, listOf(ch("1"), c))
        assertEquals("cu_7_1000000", r.resumeKey)
        assertEquals(1, r.index)
        assertEquals(c, r.channel)
        assertTrue(r.isReplay)
        val l = PlayRequest.live("p", listOf(ch("1"), c), 5)
        assertEquals(1, l.index)
        assertNotNull(l.channel)
        val m = PlayRequest.movie("p", VodItem("9", "Film", "c", "http://h/9.mp4", year = 2020, genre = "Drama"))
        assertEquals("movie_9", m.resumeKey)
        assertEquals("2020 · Drama", m.subtitle)
    }
}
