package de.jasonstream.exoplayer

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RemoteLogicTest {
    @Test
    fun serviceName() {
        assertEquals("Wohnzimmer TV", RemoteLogic.serviceName("Wohnzimmer.TV"))
        assertEquals("Jason Stream Player", RemoteLogic.serviceName("  \n "))
        val long = "Ä".repeat(40) // 80 Bytes UTF-8
        val n = RemoteLogic.serviceName(long)
        assertTrue(n.toByteArray(Charsets.UTF_8).size <= 63)
        assertEquals("Ä".repeat(31), n) // nie mitten im Zeichen gekürzt
    }

    @Test
    fun attrs() {
        val a = RemoteLogic.attrs(
            mapOf(
                "id" to "abc123".toByteArray(),
                "v" to "1".toByteArray(),
                "evil" to "x".toByteArray(),
                "pw" to null,
            ),
        )
        assertEquals(mapOf("id" to "abc123", "v" to "1"), a)
        assertEquals(emptyMap<String, String>(), RemoteLogic.attrs(mapOf("id" to "a b".toByteArray())))
        assertEquals(emptyMap<String, String>(), RemoteLogic.attrs(mapOf("id" to ByteArray(100) { 65 })))
    }

    @Test
    fun type() {
        assertTrue(RemoteLogic.sameType("_jsp-remote._tcp."))
        assertTrue(RemoteLogic.sameType("_jsp-remote._tcp.local."))
        assertFalse(RemoteLogic.sameType("_googlecast._tcp."))
        assertFalse(RemoteLogic.sameType(null))
    }
}
