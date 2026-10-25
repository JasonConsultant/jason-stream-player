package de.jasonstream.exoplayer

import androidx.media3.common.PlaybackException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LogicTest {
    @Test
    fun errorCategories() {
        assertEquals(ErrorCategory.NETWORK, ErrorCategory.of(PlaybackException.ERROR_CODE_IO_BAD_HTTP_STATUS))
        assertEquals(ErrorCategory.NETWORK, ErrorCategory.of(PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_FAILED))
        assertEquals(ErrorCategory.NETWORK, ErrorCategory.of(PlaybackException.ERROR_CODE_TIMEOUT))
        assertEquals(ErrorCategory.CONTAINER, ErrorCategory.of(PlaybackException.ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED))
        assertEquals(ErrorCategory.CONTAINER, ErrorCategory.of(PlaybackException.ERROR_CODE_PARSING_CONTAINER_MALFORMED))
        assertEquals(ErrorCategory.FORMAT, ErrorCategory.of(PlaybackException.ERROR_CODE_DECODING_FORMAT_UNSUPPORTED))
        assertEquals(ErrorCategory.FORMAT, ErrorCategory.of(PlaybackException.ERROR_CODE_PARSING_MANIFEST_MALFORMED))
        assertEquals(ErrorCategory.DECODER, ErrorCategory.of(PlaybackException.ERROR_CODE_DECODER_INIT_FAILED))
        assertEquals(ErrorCategory.DECODER, ErrorCategory.of(PlaybackException.ERROR_CODE_DECODING_FAILED))
        assertEquals(ErrorCategory.DECODER, ErrorCategory.of(PlaybackException.ERROR_CODE_AUDIO_TRACK_INIT_FAILED))
        assertEquals(ErrorCategory.DRM, ErrorCategory.of(PlaybackException.ERROR_CODE_DRM_LICENSE_ACQUISITION_FAILED))
        assertEquals(ErrorCategory.OTHER, ErrorCategory.of(PlaybackException.ERROR_CODE_UNSPECIFIED))
    }

    @Test
    fun compatOnlyForDecoderFormatContainer() {
        assertTrue(ErrorCategory.DECODER.wantsCompat)
        assertTrue(ErrorCategory.FORMAT.wantsCompat)
        assertTrue(ErrorCategory.CONTAINER.wantsCompat)
        assertFalse(ErrorCategory.NETWORK.wantsCompat)
        assertFalse(ErrorCategory.DRM.wantsCompat)
        assertFalse(ErrorCategory.OTHER.wantsCompat)
    }

    @Test
    fun headersAreSanitized() {
        val h = StreamHeaders.sanitize(
            linkedMapOf(
                "user-agent" to "VLC/3.0\r\nX-Evil: 1",
                "Referrer" to "http://portal/",
                "Host" to "evil",
                "Content-Length" to "5",
                "Bad Name" to "x",
                "Cookie" to "",
                "X-Emby-Token" to "abc",
                "USER-AGENT" to "Second",
            ),
        )
        assertEquals("Second", h["User-Agent"])
        assertEquals("http://portal/", h["Referer"])
        assertEquals("abc", h["X-Emby-Token"])
        assertFalse(h.containsKey("Host"))
        assertFalse(h.containsKey("Content-Length"))
        assertFalse(h.containsKey("Bad Name"))
        assertFalse(h.containsKey("Cookie"))
        assertEquals(3, h.size)
    }

    @Test
    fun headerValueHasNoControlChars() {
        val h = StreamHeaders.sanitize(mapOf("User-Agent" to "A\nB"))
        assertEquals("AB", h["User-Agent"])
    }

    @Test
    fun decoderOrder() {
        data class D(val name: String, val sw: Boolean)
        val list = listOf(D("hw1", false), D("sw1", true), D("hw2", false), D("sw2", true))
        assertEquals(list, DecoderOrder.order(list, false) { it.sw })
        assertEquals(listOf("sw1", "sw2", "hw1", "hw2"), DecoderOrder.order(list, true) { it.sw }.map { it.name })
        assertTrue(DecoderOrder.looksSoftware("c2.android.avc.decoder"))
        assertTrue(DecoderOrder.looksSoftware("OMX.google.h264.decoder"))
        assertTrue(DecoderOrder.looksSoftware("ffmpegAudio"))
        assertFalse(DecoderOrder.looksSoftware("c2.amlogic.avc.decoder"))
        assertFalse(DecoderOrder.looksSoftware("OMX.MTK.VIDEO.DECODER.AVC"))
        assertFalse(DecoderOrder.looksSoftware(null))
    }

    @Test
    fun bufferPlan() {
        val normal = BufferPlan.of(48 shl 20, 0)
        assertEquals(1_000, normal.playbackMs)
        assertEquals(2_000, normal.rebufferMs)
        assertEquals(0, normal.backBufferMs)
        assertEquals(48 shl 20, normal.targetBytes)
        assertTrue(normal.playbackMs <= normal.minBufferMs && normal.minBufferMs <= normal.maxBufferMs)
        // Live-Pause: Rückpuffer aus Bytes (≈ 4 Mbit/s), Vorpuffer mindestens 50 s.
        val ts = BufferPlan.of(48 shl 20, 300_000_000, 400_000_000)
        assertEquals(600_000, ts.backBufferMs)
        assertEquals(800_000, ts.maxBufferMs)
        assertEquals(400_000_000, ts.targetBytes)
        // Obergrenze 512 MB.
        assertEquals(512 shl 20, BufferPlan.of(48 shl 20, 0, 900_000_000).targetBytes)
        // Untergrenze für kleine Puffer.
        assertEquals(8 shl 20, BufferPlan.of(1 shl 20, 0).targetBytes)
        // Vorsichtiger Start: mehr Vorpuffer vor dem Bild und nach Hängern.
        val careful = BufferPlan.of(48 shl 20, 0, careful = true)
        assertEquals(3_000, careful.playbackMs)
        assertEquals(6_000, careful.rebufferMs)
        assertTrue(careful.playbackMs <= careful.minBufferMs && careful.minBufferMs <= careful.maxBufferMs)
        assertTrue(careful != normal)
    }

    @Test
    fun redactRemovesUrlsAndCredentials() {
        val s = Redact.text("Unable to connect to http://host:8080/live/user1/pass1/123.ts?token=abc and username=bob")
        assertFalse(s.contains("user1"))
        assertFalse(s.contains("pass1"))
        assertFalse(s.contains("host:8080"))
        assertFalse(s.contains("bob"))
        assertTrue(s.contains("http://•••"))
        assertEquals("", Redact.text(null))
        assertEquals(300, Redact.text("x".repeat(500)).length)
    }

    @Test
    fun mediaKind() {
        assertTrue(MediaKind.isHls("http://a/b/index.m3u8?x=1"))
        assertTrue(MediaKind.isHls("http://a/play?type=m3u8"))
        assertFalse(MediaKind.isHls("http://a/live/u/p/1.ts"))
        assertTrue(MediaKind.isDash("https://a/manifest.mpd"))
        assertEquals("application/x-subrip", MediaKind.subtitleMime("http://e/Videos/1/Subtitles/2/Stream.srt?api_key=x", null))
        assertEquals("text/x-ssa", MediaKind.subtitleMime("http://e/s.ass", null))
        assertEquals("text/vtt", MediaKind.subtitleMime("http://e/s", "webvtt"))
        assertEquals("application/x-subrip", MediaKind.subtitleMime("http://e/s.vtt", "subrip"))
    }

    @Test
    fun videoLimit() {
        val off = VideoLimit.of(0, 0)
        assertFalse(off.active)
        assertEquals(Int.MAX_VALUE, off.bitrateOrMax)
        assertEquals(Int.MAX_VALUE, off.maxWidth)
        val saver = VideoLimit.of(1_500_000, 720)
        assertTrue(saver.active)
        assertEquals(1_500_000, saver.bitrateOrMax)
        assertEquals(720, saver.heightOrMax)
        assertEquals(1280, saver.maxWidth)
        assertEquals(VideoLimit.NONE, VideoLimit.of(-5, -1))
    }

    @Test
    fun netState() {
        assertTrue(NetState.of(notMetered = false, cellular = true).metered)
        assertFalse(NetState.of(notMetered = true, cellular = false).metered)
        assertTrue(NetState.of(notMetered = true, cellular = true).cellular)
        assertFalse(NetState.NONE.connected)
    }

    @Test
    fun castMime() {
        assertTrue(CastMime.isHls("application/x-mpegURL"))
        assertTrue(CastMime.isHls("application/vnd.apple.mpegurl"))
        assertFalse(CastMime.isHls("video/mp2t"))
    }
}
