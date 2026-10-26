package de.jasonstream.exoplayer

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

class AudioLogicTest {
    @Test
    fun speedIsAlwaysOne() {
        assertEquals(1.0f, PlaybackSpeed.NORMAL)
        assertEquals(1.0f, PlaybackSpeed.LIVE_MIN)
        assertEquals(1.0f, PlaybackSpeed.LIVE_MAX)
    }

    @Test
    fun bufferPlanIsSane() {
        assertTrue(AudioBufferPlan.MIN_PCM_US >= 250_000)
        assertTrue(AudioBufferPlan.MAX_PCM_US >= AudioBufferPlan.MIN_PCM_US)
        assertTrue(AudioBufferPlan.MAX_PCM_US <= 1_000_000)
        assertTrue(AudioBufferPlan.MULTIPLIER >= 4)
    }

    @Test
    fun matricesExistForOneToEightChannels() {
        for (ch in 1..8) {
            val m = Downmix.matrix(ch)
            assertEquals(2 * ch, m.size)
            for (row in 0..1) {
                var sum = 0f
                for (i in 0 until ch) {
                    val c = m[row * ch + i]
                    assertTrue("negativ ch=$ch", c >= 0f)
                    sum += c
                }
                // Zeilensumme 1 → abgemischtes Signal kann vor dem Ausgleich nie übersteuern.
                assertEquals("ch=$ch row=$row", 1f, sum, 1e-5f)
            }
        }
    }

    @Test(expected = IllegalArgumentException::class)
    fun nineChannelsRejected() {
        Downmix.matrix(9)
    }

    @Test
    fun fiveOneFollowsLoRo() {
        val m = Downmix.matrix(6) // FL FR FC LFE BL BR
        val l = m.copyOfRange(0, 6)
        val r = m.copyOfRange(6, 12)
        // Center und Surround −3 dB gegenüber Front, LFE weg, keine Übersprechung.
        assertEquals(Downmix.MINUS_3DB, l[2] / l[0], 1e-5f)
        assertEquals(Downmix.MINUS_3DB, l[4] / l[0], 1e-5f)
        assertEquals(0f, l[3])
        assertEquals(0f, r[3])
        assertEquals(0f, l[1])
        assertEquals(0f, l[5])
        assertEquals(0f, r[0])
        assertEquals(0f, r[4])
        assertEquals(l[2], r[2], 0f)
    }

    @Test
    fun sevenAndEightChannelLayouts() {
        val m7 = Downmix.matrix(7) // … BL BR BC
        assertEquals(m7[6], m7[7 + 6], 0f) // BC auf beide Seiten
        assertTrue(m7[4] > 0f && m7[5] == 0f)
        val m8 = Downmix.matrix(8) // … BL BR SL SR
        assertTrue(m8[6] > 0f && m8[7] == 0f)
        assertTrue(m8[8 + 7] > 0f && m8[8 + 6] == 0f)
    }

    @Test
    fun neededOnlyForMultichannelToStereoWithoutPassthrough() {
        assertTrue(Downmix.needed(false, 6, 2))
        assertTrue(Downmix.needed(false, 8, 2))
        assertTrue(Downmix.needed(false, 3, 1))
        assertFalse(Downmix.needed(false, 2, 2))
        assertFalse(Downmix.needed(false, 1, 2))
        assertFalse(Downmix.needed(true, 6, 2))
        assertFalse(Downmix.needed(false, 6, 6))
        assertFalse(Downmix.needed(false, 6, 8))
        assertFalse(Downmix.needed(false, 10, 2))
    }

    @Test
    fun softClipIsLinearBelowKneeAndNeverReachesOne() {
        assertEquals(0.5f, Downmix.softClip(0.5f), 0f)
        assertEquals(-0.7f, Downmix.softClip(-0.7f), 0f)
        // Größter möglicher Wert nach Abmischung: Zeilensumme 1 × Ausgleich.
        for (x in listOf(0.8f, 1f, 1.2f, Downmix.MAKEUP_GAIN)) {
            val y = Downmix.softClip(x)
            assertTrue("x=$x y=$y", y < 1f && y > Downmix.KNEE)
            assertEquals(-y, Downmix.softClip(-x), 0f)
        }
        for (x in listOf(3f, 100f)) {
            val y = Downmix.softClip(x)
            assertTrue("x=$x y=$y", y <= 1f && y > Downmix.KNEE)
            assertEquals(-y, Downmix.softClip(-x), 0f)
        }
        // stetig und monoton
        var prev = -1f
        var x = -2f
        while (x <= 2f) {
            val y = Downmix.softClip(x)
            assertTrue(y >= prev)
            prev = y
            x += 0.01f
        }
        assertTrue(abs(Downmix.softClip(Downmix.KNEE + 1e-4f) - Downmix.KNEE) < 1e-3f)
    }

    @Test
    fun fullScaleAllChannelsDoesNotClip() {
        for (ch in 1..8) {
            val m = Downmix.matrix(ch)
            val out = FloatArray(2)
            Downmix.mixFrame(FloatArray(ch) { 1f }, ch, m, out)
            assertTrue(out[0] < 1f && out[1] < 1f)
            Downmix.mixFrame(FloatArray(ch) { -1f }, ch, m, out)
            assertTrue(out[0] > -1f && out[1] > -1f)
        }
    }

    @Test
    fun dialogInCenterIsAudibleOnBothSides() {
        val m = Downmix.matrix(6)
        val out = FloatArray(2)
        Downmix.mixFrame(floatArrayOf(0f, 0f, 0.5f, 0f, 0f, 0f), 6, m, out)
        assertTrue(out[0] > 0.15f)
        assertEquals(out[0], out[1], 0f)
    }

    @Test
    fun routePhoneIsStereo() {
        val spk = AudioRoute.Device(2, intArrayOf())
        assertEquals(2, AudioRoute.maxChannels(null, listOf(spk), tv = false, hdmiPlugMax = null))
        // Handy mit HDMI-Liste aber ohne Routing-Info → Stereo
        val hdmi = AudioRoute.Device(AudioRoute.TYPE_HDMI, intArrayOf(2, 6, 8))
        assertEquals(2, AudioRoute.maxChannels(null, listOf(spk, hdmi), tv = false, hdmiPlugMax = null))
    }

    @Test
    fun routeTvUsesHdmiCapabilities() {
        val tvStereo = AudioRoute.Device(AudioRoute.TYPE_HDMI, intArrayOf(2))
        val avr = AudioRoute.Device(AudioRoute.TYPE_HDMI_ARC, intArrayOf(2, 6, 8))
        val unknown = AudioRoute.Device(AudioRoute.TYPE_HDMI, intArrayOf())
        assertEquals(2, AudioRoute.maxChannels(null, listOf(tvStereo), tv = true, hdmiPlugMax = null))
        assertEquals(8, AudioRoute.maxChannels(null, listOf(avr), tv = true, hdmiPlugMax = null))
        assertEquals(2, AudioRoute.maxChannels(null, listOf(unknown), tv = true, hdmiPlugMax = null))
        assertEquals(6, AudioRoute.maxChannels(null, listOf(unknown), tv = true, hdmiPlugMax = 6))
        assertEquals(2, AudioRoute.maxChannels(null, emptyList(), tv = true, hdmiPlugMax = null))
        // API 33+: tatsächliches Ziel (Bluetooth-Kopfhörer am TV) zählt.
        val bt = AudioRoute.Device(8, intArrayOf())
        assertEquals(2, AudioRoute.maxChannels(listOf(bt), listOf(avr, bt), tv = true, hdmiPlugMax = 8))
        assertEquals(8, AudioRoute.maxChannels(listOf(avr), listOf(avr), tv = true, hdmiPlugMax = null))
    }
}
