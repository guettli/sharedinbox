package de.sharedinbox.core.jmap.sieve

import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class SieveScriptTest {
    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun sieveScript_defaults() {
        val script = SieveScript()
        assertEquals("", script.id)
        assertNull(script.name)
        assertEquals("", script.blobId)
        assertEquals(false, script.isActive)
    }

    @Test
    fun sieveScript_roundTrip() {
        val script =
            SieveScript(
                id = "sieve1",
                name = "spam-filter",
                blobId = "blob-abc",
                isActive = true,
            )
        val decoded = json.decodeFromString<SieveScript>(json.encodeToString(script))
        assertEquals("sieve1", decoded.id)
        assertEquals("spam-filter", decoded.name)
        assertEquals("blob-abc", decoded.blobId)
        assertEquals(true, decoded.isActive)
    }

    @Test
    fun sieveScript_inactive_roundTrip() {
        val script = SieveScript(id = "s2", blobId = "b2", isActive = false)
        val decoded = json.decodeFromString<SieveScript>(json.encodeToString(script))
        assertEquals(false, decoded.isActive)
        assertNull(decoded.name)
    }
}
