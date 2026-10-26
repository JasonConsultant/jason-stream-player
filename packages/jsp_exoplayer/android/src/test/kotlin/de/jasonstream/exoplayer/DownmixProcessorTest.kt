package de.jasonstream.exoplayer

import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder

class DownmixProcessorTest {
    private fun pcm16(vararg samples: Int): ByteBuffer {
        val b = ByteBuffer.allocateDirect(samples.size * 2).order(ByteOrder.nativeOrder())
        for (s in samples) b.putShort(s.toShort())
        b.flip()
        return b
    }

    @Test
    fun allChannelCountsConfigureWithoutException() {
        for (enc in listOf(C.ENCODING_PCM_16BIT, C.ENCODING_PCM_FLOAT)) {
            for (ch in 1..8) {
                val p = DownmixAudioProcessor(passthrough = false) { 2 }
                val out = p.configure(AudioProcessor.AudioFormat(48_000, ch, enc))
                p.flush()
                if (ch <= 2) {
                    assertFalse(p.isActive)
                } else {
                    assertTrue(p.isActive)
                    assertEquals(2, out.channelCount)
                    assertEquals(enc, out.encoding)
                    assertEquals(48_000, out.sampleRate)
                }
            }
        }
    }

    @Test
    fun inactiveWithPassthroughOrMultichannelOutput() {
        val a = DownmixAudioProcessor(passthrough = true) { 2 }
        a.configure(AudioProcessor.AudioFormat(48_000, 6, C.ENCODING_PCM_16BIT))
        assertFalse(a.isActive)
        val b = DownmixAudioProcessor(passthrough = false) { 8 }
        b.configure(AudioProcessor.AudioFormat(48_000, 6, C.ENCODING_PCM_16BIT))
        assertFalse(b.isActive)
        // Unbekannte Formate (24 bit) bleiben unangetastet.
        val c = DownmixAudioProcessor(passthrough = false) { 2 }
        c.configure(AudioProcessor.AudioFormat(48_000, 6, C.ENCODING_PCM_24BIT))
        assertFalse(c.isActive)
    }

    @Test
    fun fiveOneSixteenBitMixesWithoutClipping() {
        val p = DownmixAudioProcessor(passthrough = false) { 2 }
        p.configure(AudioProcessor.AudioFormat(48_000, 6, C.ENCODING_PCM_16BIT))
        p.flush()
        // Frame 1: alles Vollaussteuerung; Frame 2: nur Center (Dialog).
        p.queueInput(pcm16(32767, 32767, 32767, 32767, 32767, 32767, 0, 0, 16384, 0, 0, 0))
        val out = p.output.order(ByteOrder.nativeOrder())
        assertEquals(8, out.remaining())
        val l1 = out.short.toInt()
        val r1 = out.short.toInt()
        val l2 = out.short.toInt()
        val r2 = out.short.toInt()
        assertTrue(l1 in 20_000..32_766 && r1 == l1)
        assertTrue(l2 > 4_000 && l2 == r2)
    }

    @Test
    fun floatInputIsMixed() {
        val p = DownmixAudioProcessor(passthrough = false) { 2 }
        p.configure(AudioProcessor.AudioFormat(44_100, 8, C.ENCODING_PCM_FLOAT))
        p.flush()
        val b = ByteBuffer.allocateDirect(8 * 4 * 2).order(ByteOrder.nativeOrder())
        repeat(8) { b.putFloat(1f) }
        repeat(8) { b.putFloat(-1f) }
        b.flip()
        p.queueInput(b)
        assertEquals(0, b.remaining())
        val out = p.output.order(ByteOrder.nativeOrder())
        assertEquals(16, out.remaining())
        val l = out.float
        val r = out.float
        assertTrue(l < 1f && l > 0.75f && r == l)
        assertTrue(out.float > -1f)
    }
}
