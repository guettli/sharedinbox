package de.sharedinbox.core.sync

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.time.Instant

class SyncModelTest {
    @Test
    fun syncDirection_serverToDb_value() {
        assertEquals("server_to_db", SyncDirection.SERVER_TO_DB.value)
    }

    @Test
    fun syncDirection_dbToServer_value() {
        assertEquals("db_to_server", SyncDirection.DB_TO_SERVER.value)
    }

    @Test
    fun syncDirection_allEntries() {
        assertEquals(2, SyncDirection.entries.size)
        assertEquals(SyncDirection.SERVER_TO_DB, SyncDirection.entries[0])
        assertEquals(SyncDirection.DB_TO_SERVER, SyncDirection.entries[1])
    }

    @Test
    fun syncDirection_lookupByValue() {
        val found = SyncDirection.entries.first { it.value == "server_to_db" }
        assertEquals(SyncDirection.SERVER_TO_DB, found)
    }

    @Test
    fun syncStatus_values() {
        assertEquals("success", SyncStatus.SUCCESS.value)
        assertEquals("conflict", SyncStatus.CONFLICT.value)
        assertEquals("error", SyncStatus.ERROR.value)
    }

    @Test
    fun syncStatus_allEntries() {
        assertEquals(3, SyncStatus.entries.size)
    }

    @Test
    fun syncStatus_lookupByValue() {
        val found = SyncStatus.entries.first { it.value == "error" }
        assertEquals(SyncStatus.ERROR, found)
    }

    @Test
    fun syncLogEntry_success() {
        val entry =
            SyncLogEntry(
                id = 1L,
                accountId = "acc1",
                occurredAt = Instant.parse("2024-06-01T00:00:00Z"),
                direction = SyncDirection.SERVER_TO_DB,
                operation = "sync_mailboxes",
                status = SyncStatus.SUCCESS,
                detail = null,
            )
        assertEquals("acc1", entry.accountId)
        assertEquals(SyncDirection.SERVER_TO_DB, entry.direction)
        assertEquals(SyncStatus.SUCCESS, entry.status)
        assertNull(entry.detail)
    }

    @Test
    fun syncLogEntry_error_withDetail() {
        val entry =
            SyncLogEntry(
                id = 2L,
                accountId = "acc1",
                occurredAt = Instant.parse("2024-06-01T00:00:01Z"),
                direction = SyncDirection.DB_TO_SERVER,
                operation = "create_mailbox",
                status = SyncStatus.ERROR,
                detail = "Network timeout",
            )
        assertEquals("Network timeout", entry.detail)
        assertEquals(SyncStatus.ERROR, entry.status)
        assertEquals(SyncDirection.DB_TO_SERVER, entry.direction)
    }

    @Test
    fun syncLogEntry_conflict() {
        val entry =
            SyncLogEntry(
                id = 3L,
                accountId = "acc2",
                occurredAt = Instant.parse("2024-06-01T00:00:02Z"),
                direction = SyncDirection.DB_TO_SERVER,
                operation = "move_email",
                status = SyncStatus.CONFLICT,
                detail = "Server rejected: notFound",
            )
        assertEquals(SyncStatus.CONFLICT, entry.status)
    }
}
