package de.sharedinbox.data

import app.cash.sqldelight.driver.jdbc.sqlite.JdbcSqliteDriver
import de.sharedinbox.core.sync.SyncDirection
import de.sharedinbox.core.sync.SyncStatus
import de.sharedinbox.data.db.SharedInboxDatabase
import de.sharedinbox.data.repository.SyncLogRepositoryImpl
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Unit tests for [SyncLogRepositoryImpl].
 *
 * Uses an in-memory SQLite driver — no Stalwart instance required.
 */
class SyncLogRepositoryTest {

    private lateinit var db: SharedInboxDatabase
    private lateinit var repo: SyncLogRepositoryImpl

    @BeforeTest
    fun setUp() {
        val driver = JdbcSqliteDriver(JdbcSqliteDriver.IN_MEMORY)
        SharedInboxDatabase.Schema.create(driver)
        driver.execute(null, "PRAGMA foreign_keys = ON", 0)
        db = SharedInboxDatabase(driver)
        repo = SyncLogRepositoryImpl(db)

        // Seed a minimal account row (FK required by sync_log)
        db.accountQueries.insertAccount(
            id = "acc1",
            display_name = "Test",
            base_url = "http://localhost",
            username = "user@localhost",
            jmap_account_id = "jmap-acc1",
            api_url = "http://localhost/jmap/",
            upload_url = "http://localhost/upload/",
            download_url = "http://localhost/download/",
            event_source_url = "http://localhost/events/",
            added_at = 0L,
        )
    }

    @Test
    fun log_insertsEntry() = runBlocking {
        repo.log(
            accountId = "acc1",
            direction = SyncDirection.SERVER_TO_DB,
            operation = "sync_mailboxes",
            status = SyncStatus.SUCCESS,
        )

        val entries = repo.observeLogs("acc1").first()
        assertEquals(1, entries.size)
        assertEquals("sync_mailboxes", entries[0].operation)
        assertEquals(SyncDirection.SERVER_TO_DB, entries[0].direction)
        assertEquals(SyncStatus.SUCCESS, entries[0].status)
    }

    @Test
    fun log_withDetail_preservesDetail() = runBlocking {
        repo.log(
            accountId = "acc1",
            direction = SyncDirection.DB_TO_SERVER,
            operation = "create_mailbox",
            status = SyncStatus.CONFLICT,
            detail = "notAllowed: insufficient permissions",
        )

        val entry = repo.observeLogs("acc1").first().first()
        assertEquals(SyncStatus.CONFLICT, entry.status)
        assertEquals("notAllowed: insufficient permissions", entry.detail)
    }

    @Test
    fun observeLogs_returnsNewestFirst() = runBlocking {
        repo.log("acc1", SyncDirection.SERVER_TO_DB, "sync_mailboxes", SyncStatus.SUCCESS)
        repo.log("acc1", SyncDirection.DB_TO_SERVER, "move_email", SyncStatus.SUCCESS)
        repo.log("acc1", SyncDirection.DB_TO_SERVER, "delete_email", SyncStatus.CONFLICT)

        val entries = repo.observeLogs("acc1").first()
        assertEquals(3, entries.size)
        // Newest (highest id) comes first
        assertEquals("delete_email", entries[0].operation)
        assertEquals("sync_mailboxes", entries[2].operation)
    }

    @Test
    fun clearLogs_removesAllForAccount() = runBlocking {
        repo.log("acc1", SyncDirection.SERVER_TO_DB, "sync_mailboxes", SyncStatus.SUCCESS)
        repo.log("acc1", SyncDirection.SERVER_TO_DB, "sync_emails", SyncStatus.SUCCESS)

        repo.clearLogs("acc1")

        val entries = repo.observeLogs("acc1").first()
        assertTrue(entries.isEmpty(), "Expected no entries after clearLogs")
    }

    @Test
    fun clearLogs_doesNotAffectOtherAccounts() = runBlocking {
        db.accountQueries.insertAccount(
            id = "acc2",
            display_name = "Other",
            base_url = "http://other",
            username = "other@localhost",
            jmap_account_id = "jmap-acc2",
            api_url = "http://other/jmap/",
            upload_url = "http://other/upload/",
            download_url = "http://other/download/",
            event_source_url = "http://other/events/",
            added_at = 0L,
        )

        repo.log("acc1", SyncDirection.SERVER_TO_DB, "sync_mailboxes", SyncStatus.SUCCESS)
        repo.log("acc2", SyncDirection.SERVER_TO_DB, "sync_mailboxes", SyncStatus.SUCCESS)

        repo.clearLogs("acc1")

        assertEquals(0, repo.observeLogs("acc1").first().size)
        assertEquals(1, repo.observeLogs("acc2").first().size)
    }

    @Test
    fun log_allStatuses_roundTrip() = runBlocking {
        repo.log("acc1", SyncDirection.SERVER_TO_DB, "op", SyncStatus.SUCCESS)
        repo.log("acc1", SyncDirection.SERVER_TO_DB, "op", SyncStatus.CONFLICT)
        repo.log("acc1", SyncDirection.SERVER_TO_DB, "op", SyncStatus.ERROR)

        val entries = repo.observeLogs("acc1").first()
        val statuses = entries.map { it.status }.toSet()
        assertEquals(setOf(SyncStatus.SUCCESS, SyncStatus.CONFLICT, SyncStatus.ERROR), statuses)
    }

    @Test
    fun log_allDirections_roundTrip() = runBlocking {
        repo.log("acc1", SyncDirection.SERVER_TO_DB, "op", SyncStatus.SUCCESS)
        repo.log("acc1", SyncDirection.DB_TO_SERVER, "op", SyncStatus.SUCCESS)

        val entries = repo.observeLogs("acc1").first()
        val directions = entries.map { it.direction }.toSet()
        assertEquals(setOf(SyncDirection.SERVER_TO_DB, SyncDirection.DB_TO_SERVER), directions)
    }
}
