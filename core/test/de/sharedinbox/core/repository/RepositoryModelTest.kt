package de.sharedinbox.core.repository

import de.sharedinbox.core.network.NetworkType
import de.sharedinbox.core.sync.SyncDirection
import de.sharedinbox.core.sync.SyncLogEntry
import de.sharedinbox.core.sync.SyncStatus
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import kotlin.test.assertNull
import kotlin.time.Instant

class RepositoryModelTest {
    // --- NetworkType ---

    @Test
    fun networkType_values() {
        assertEquals(2, NetworkType.entries.size)
        assertEquals(NetworkType.MOBILE, NetworkType.entries[0])
        assertEquals(NetworkType.WIFI_OR_UNMETERED, NetworkType.entries[1])
    }

    @Test
    fun networkType_valueOf() {
        assertEquals(NetworkType.MOBILE, NetworkType.valueOf("MOBILE"))
        assertEquals(NetworkType.WIFI_OR_UNMETERED, NetworkType.valueOf("WIFI_OR_UNMETERED"))
    }

    // --- SyncSettings ---

    @Test
    fun syncSettings_defaults() {
        val settings = SyncSettings()
        assertEquals(60, settings.mobileDays)
        assertEquals(1, settings.mobileMbLimit)
        assertEquals(400, settings.wifiDays)
        assertEquals(10, settings.wifiMbLimit)
    }

    @Test
    fun syncSettings_customValues() {
        val settings = SyncSettings(mobileDays = 30, mobileMbLimit = 2, wifiDays = 365, wifiMbLimit = 50)
        assertEquals(30, settings.mobileDays)
        assertEquals(2, settings.mobileMbLimit)
        assertEquals(365, settings.wifiDays)
        assertEquals(50, settings.wifiMbLimit)
    }

    @Test
    fun syncSettings_equality() {
        val a = SyncSettings()
        val b = SyncSettings()
        assertEquals(a, b)
    }

    @Test
    fun syncSettings_copy() {
        val original = SyncSettings()
        val updated = original.copy(mobileDays = 7)
        assertEquals(7, updated.mobileDays)
        assertEquals(original.wifiDays, updated.wifiDays)
    }

    // --- RecentAddress ---

    @Test
    fun recentAddress_construction() {
        val addr =
            RecentAddress(
                email = "alice@example.com",
                name = "Alice",
                useCount = 5,
                lastUsedEpochMillis = 1_700_000_000_000L,
            )
        assertEquals("alice@example.com", addr.email)
        assertEquals("Alice", addr.name)
        assertEquals(5, addr.useCount)
        assertEquals(1_700_000_000_000L, addr.lastUsedEpochMillis)
    }

    @Test
    fun recentAddress_nullName() {
        val addr = RecentAddress(email = "bob@example.com", name = null, useCount = 1, lastUsedEpochMillis = 0L)
        assertNull(addr.name)
    }

    @Test
    fun recentAddress_equality() {
        val a = RecentAddress("x@x.com", "X", 1, 0L)
        val b = RecentAddress("x@x.com", "X", 1, 0L)
        assertEquals(a, b)
    }

    // --- Contact ---

    @Test
    fun contact_construction() {
        val contact = Contact(name = "Alice", email = "alice@example.com")
        assertEquals("Alice", contact.name)
        assertEquals("alice@example.com", contact.email)
    }

    @Test
    fun contact_nullName() {
        val contact = Contact(name = null, email = "noreply@example.com")
        assertNull(contact.name)
    }

    @Test
    fun contact_equality() {
        val a = Contact("Alice", "alice@example.com")
        val b = Contact("Alice", "alice@example.com")
        val c = Contact("Bob", "bob@example.com")
        assertEquals(a, b)
        assertNotEquals(a, c)
    }

    // --- SyncHealth ---

    @Test
    fun syncHealth_withValues() {
        val entry =
            SyncLogEntry(
                id = 1L,
                accountId = "acc1",
                occurredAt = Instant.parse("2024-06-01T00:00:00Z"),
                direction = SyncDirection.SERVER_TO_DB,
                operation = "sync",
                status = SyncStatus.ERROR,
                detail = "timeout",
            )
        val health =
            SyncHealth(
                lastSuccessAt = Instant.parse("2024-06-01T00:00:00Z"),
                lastError = entry,
            )
        assertEquals(Instant.parse("2024-06-01T00:00:00Z"), health.lastSuccessAt)
        assertEquals(entry, health.lastError)
    }

    @Test
    fun syncHealth_nullValues() {
        val health = SyncHealth(lastSuccessAt = null, lastError = null)
        assertNull(health.lastSuccessAt)
        assertNull(health.lastError)
    }

    @Test
    fun syncHealth_equality() {
        val a = SyncHealth(null, null)
        val b = SyncHealth(null, null)
        assertEquals(a, b)
    }
}
