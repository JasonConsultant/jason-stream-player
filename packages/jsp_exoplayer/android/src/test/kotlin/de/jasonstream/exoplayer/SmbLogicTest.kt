package de.jasonstream.exoplayer

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SmbLogicTest {
    @Test
    fun hostPort() {
        assertEquals("nas" to 445, SmbLogic.hostPort("nas"))
        assertEquals("nas" to 4455, SmbLogic.hostPort("nas:4455"))
        assertEquals("192.168.1.5" to 445, SmbLogic.hostPort("smb://192.168.1.5/filme"))
        assertEquals("nas.local" to 445, SmbLogic.hostPort("\\\\nas.local\\share"))
        assertEquals("fe80::1" to 445, SmbLogic.hostPort("[fe80::1]"))
        assertEquals("fe80::1" to 1445, SmbLogic.hostPort("[fe80::1]:1445"))
        assertNull(SmbLogic.hostPort(""))
        assertNull(SmbLogic.hostPort("nas:99999"))
        assertNull(SmbLogic.hostPort("user@nas"))
    }

    @Test
    fun paths() {
        assertEquals("Filme\\IPTV", SmbLogic.cleanPath("/Filme//IPTV/"))
        assertEquals("", SmbLogic.cleanPath(""))
        assertNull(SmbLogic.cleanPath("a/../../etc"))
        assertNull(SmbLogic.cleanPath("bad:name"))
        assertEquals("IPTV\\Downloads\\x.mkv", SmbLogic.join("IPTV", "Downloads/x.mkv"))
        assertEquals("x.mkv", SmbLogic.join("", "x.mkv"))
        assertEquals("IPTV\\Downloads", SmbLogic.parent("IPTV\\Downloads\\x.mkv"))
        assertEquals("video", SmbLogic.cleanShare("\\video\\"))
    }

    @Test
    fun target() {
        val t = SmbTarget.from(mapOf("server" to "nas", "share" to "media", "path" to "IPTV",
            "user" to "jason", "password" to "pw", "domain" to ""))!!
        assertEquals("IPTV\\Aufnahmen\\a.ts", t.path("Aufnahmen/a.ts"))
        assertTrue(!t.key.contains("pw"))
        assertNull(SmbTarget.from(mapOf("server" to "", "share" to "media")))
        assertNull(SmbTarget.from(mapOf("server" to "nas", "share" to "media", "path" to "../x")))
    }

    @Test
    fun classify() {
        assertEquals("auth", SmbLogic.classify("SMBApiException", "x", "STATUS_LOGON_FAILURE"))
        assertEquals("share", SmbLogic.classify("SMBApiException", "x", "STATUS_BAD_NETWORK_NAME"))
        assertEquals("path", SmbLogic.classify("SMBApiException", "x", "STATUS_OBJECT_PATH_NOT_FOUND"))
        assertEquals("denied", SmbLogic.classify("SMBApiException", "x", "STATUS_ACCESS_DENIED"))
        assertEquals("full", SmbLogic.classify("SMBApiException", "x", "STATUS_DISK_FULL"))
        assertEquals("host", SmbLogic.classify("java.net.UnknownHostException", "nas", null))
        assertEquals("host", SmbLogic.classify("java.net.ConnectException", "Connection refused", null))
        assertEquals("timeout", SmbLogic.classify("java.net.SocketTimeoutException", "Read timed out", null))
        assertEquals("smb1", SmbLogic.classify("TransportException", "Dialect not supported by server", null))
        assertEquals("io", SmbLogic.classify("IOException", "broken pipe", null))
    }

    @Test
    fun range() {
        assertEquals(0L to 999L, SmbLogic.range("bytes=0-", 1000))
        assertEquals(100L to 199L, SmbLogic.range("bytes=100-199", 1000))
        assertEquals(500L to 999L, SmbLogic.range("bytes=-500", 1000))
        assertEquals(900L to 999L, SmbLogic.range("bytes=900-5000", 1000))
        assertNull(SmbLogic.range("bytes=1000-", 1000))
        assertNull(SmbLogic.range(null, 1000))
        assertNull(SmbLogic.range("items=0-1", 1000))
    }
}
