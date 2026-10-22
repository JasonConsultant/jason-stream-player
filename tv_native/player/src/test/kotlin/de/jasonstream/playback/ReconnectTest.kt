package de.jasonstream.playback

import de.jasonstream.playback.logic.FailureKind
import de.jasonstream.playback.logic.ReconnectPolicy
import de.jasonstream.playback.logic.RecoveryKind
import de.jasonstream.playback.logic.RecoveryStep
import de.jasonstream.playback.logic.StallDetector
import de.jasonstream.playback.logic.StreamError
import de.jasonstream.playback.logic.StreamErrorKind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ReconnectTest {
    @Test fun backoffThenVariantThenGiveUp() {
        val r = ReconnectPolicy()
        assertEquals(RecoveryStep(RecoveryKind.retry, 1000), r.onFailure(FailureKind.stall, null, live = true, variantsLeft = 1))
        assertEquals(RecoveryStep(RecoveryKind.retry, 2000), r.onFailure(FailureKind.stall, null, live = true, variantsLeft = 1))
        assertEquals(RecoveryStep(RecoveryKind.retry, 4000), r.onFailure(FailureKind.stall, null, live = true, variantsLeft = 1))
        assertEquals(RecoveryKind.nextVariant, r.onFailure(FailureKind.stall, null, live = true, variantsLeft = 1).kind)
        // Weitere Variante: nur noch 1 Wiederholung.
        assertEquals(RecoveryStep(RecoveryKind.retry, 1000), r.onFailure(FailureKind.stall, null, live = true, variantsLeft = 0))
        assertEquals(RecoveryKind.giveUp, r.onFailure(FailureKind.stall, null, live = true, variantsLeft = 0).kind)
    }

    @Test fun hopelessErrorsSkipRetries() {
        val r = ReconnectPolicy()
        assertEquals(RecoveryKind.nextVariant, r.onFailure(FailureKind.error, "HTTP error 403 Forbidden", true, 2).kind)
        val v = ReconnectPolicy()
        assertEquals(RecoveryKind.giveUp, v.onFailure(FailureKind.error, "HTTP error 451", false).kind)
    }

    @Test fun hostFailoverBeforeVariants() {
        val r = ReconnectPolicy()
        repeat(3) { assertEquals(RecoveryKind.retry, r.onFailure(FailureKind.error, "HTTP error 503", true, 1, hostsLeft = 1).kind) }
        assertEquals(RecoveryKind.nextHost, r.onFailure(FailureKind.error, "HTTP error 503", true, 1, hostsLeft = 1).kind)
        assertEquals(RecoveryKind.retry, r.onFailure(FailureKind.error, "HTTP error 503", true, 1, hostsLeft = 0).kind)
        assertEquals(RecoveryKind.nextVariant, r.onFailure(FailureKind.error, "HTTP error 503", true, 1, hostsLeft = 0).kind)
    }

    @Test fun notFoundGoesStraightToOtherHost() {
        val r = ReconnectPolicy()
        assertEquals(RecoveryKind.nextHost, r.onFailure(FailureKind.error, "HTTP error 404", false, 0, hostsLeft = 2).kind)
        // 403 hilft eine andere Adresse nicht.
        val f = ReconnectPolicy()
        assertEquals(RecoveryKind.giveUp, f.onFailure(FailureKind.error, "HTTP error 403", false, 0, hostsLeft = 2).kind)
    }

    @Test fun decoderErrorTriesSoftwareOnce() {
        val r = ReconnectPolicy()
        val m = "Decoder error (ERROR_CODE_DECODER_INIT_FAILED): MediaCodec"
        repeat(3) { r.onFailure(FailureKind.error, m, false) }
        assertEquals(RecoveryKind.softwareDecode, r.onFailure(FailureKind.error, m, false).kind)
        assertTrue(r.triedSoftware)
        repeat(3) { r.onFailure(FailureKind.error, m, false) }
        assertEquals(RecoveryKind.giveUp, r.onFailure(FailureKind.error, m, false).kind)
    }

    @Test fun healthyPlaybackResetsCounters() {
        val r = ReconnectPolicy()
        r.onFailure(FailureKind.stall, null, true)
        assertTrue(r.recovering)
        r.markGood(0)
        r.markGood(59_000)
        assertTrue(r.recovering)
        r.markGood(60_000)
        assertFalse(r.recovering)
        assertEquals(RecoveryStep(RecoveryKind.retry, 1000), r.onFailure(FailureKind.stall, null, true))
    }

    @Test fun stallDetector() {
        val s = StallDetector(limitMs = 12_000, startupLimitMs = 25_000)
        assertFalse(s.sample(0, 0, true))
        assertFalse(s.sample(0, 20_000, true)) // Start: mehr Geduld
        assertTrue(s.sample(0, 25_000, true))
        s.reset()
        assertFalse(s.sample(0, 0, true))
        assertFalse(s.sample(1000, 1000, true)) // läuft
        assertFalse(s.sample(1000, 12_000, true))
        assertTrue(s.sample(1000, 13_000, true))
        s.reset()
        assertFalse(s.sample(5, 0, false))
        assertFalse(s.sample(5, 100_000, false)) // pausiert: nie
    }

    @Test fun classify() {
        assertEquals(StreamErrorKind.geoBlocked, StreamError.classify("HTTP error 451"))
        assertEquals(StreamErrorKind.forbidden, StreamError.classify("HTTP error 403 Forbidden"))
        assertEquals(StreamErrorKind.unauthorized, StreamError.classify("status: 401"))
        assertEquals(StreamErrorKind.notFound, StreamError.classify("Server returned 404"))
        assertEquals(StreamErrorKind.unreachable, StreamError.classify("Connection timed out"))
        assertEquals(StreamErrorKind.unreachable, StreamError.classify("Failed to open: connection failed"))
        assertEquals(StreamErrorKind.blockedByApp, StreamError.classify("Diese Stream-Adresse wurde aus Sicherheitsgründen blockiert."))
        // Zahlen in Adressen zählen nicht.
        assertEquals(StreamErrorKind.other, StreamError.classify("ERROR_CODE_PARSING_CONTAINER_MALFORMED: /live/403/x.ts"))
        assertTrue(StreamError.isLocationRelated("HTTP error 403"))
    }
}
