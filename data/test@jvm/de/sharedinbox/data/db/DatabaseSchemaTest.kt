package de.sharedinbox.data.db

import app.cash.sqldelight.driver.jdbc.sqlite.JdbcSqliteDriver
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/**
 * Verifies the SQLDelight schema: DDL compiles, CRUD works, and ON DELETE CASCADE fires.
 *
 * Uses an in-memory SQLite driver — no Stalwart instance required.
 */
class DatabaseSchemaTest {

    private lateinit var db: SharedInboxDatabase

    @BeforeTest
    fun setUp() {
        val driver = JdbcSqliteDriver(JdbcSqliteDriver.IN_MEMORY)
        SharedInboxDatabase.Schema.create(driver)
        driver.execute(null, "PRAGMA foreign_keys = ON", 0)
        db = SharedInboxDatabase(driver)
    }

    @AfterTest
    fun tearDown() {
        db.accountQueries  // access forces lazy init; driver closed by GC for in-memory
    }

    // --- account ---

    @Test
    fun insertAndSelectAccount() {
        insertAccount("acc1")
        val rows = db.accountQueries.selectAllAccounts().executeAsList()
        assertEquals(1, rows.size)
        assertEquals("acc1", rows[0].id)
        assertEquals("alice@localhost", rows[0].username)
    }

    @Test
    fun selectAccount_unknownId_returnsNull() {
        val row = db.accountQueries.selectAccount("nope").executeAsOneOrNull()
        assertNull(row)
    }

    @Test
    fun deleteAccount_removesRow() {
        insertAccount("acc1")
        db.accountQueries.deleteAccount("acc1")
        assertNull(db.accountQueries.selectAccount("acc1").executeAsOneOrNull())
    }

    // --- CASCADE: mailbox ---

    @Test
    fun deleteAccount_cascadesToMailboxes() {
        insertAccount("acc1")
        db.mailboxQueries.upsertMailbox(
            id = "mbox1", account_id = "acc1", name = "INBOX",
            role = "inbox", parent_id = null, sort_order = 0, unread_emails = 3,
        )
        assertEquals(1, db.mailboxQueries.selectMailboxesByAccount("acc1").executeAsList().size)

        db.accountQueries.deleteAccount("acc1")

        assertEquals(0, db.mailboxQueries.selectMailboxesByAccount("acc1").executeAsList().size)
    }

    // --- CASCADE: email_header ---

    @Test
    fun deleteAccount_cascadesToEmailHeaders() {
        insertAccount("acc1")
        db.emailHeaderQueries.upsertEmailHeader(
            id = "e1", account_id = "acc1", thread_id = "t1", mailbox_id = "mbox1",
            subject = "Hello", from_address = "bob@localhost", received_at = 1000L,
            keywords = "", has_attachment = 0, preview = null,
        )
        assertEquals(1, db.emailHeaderQueries.selectEmailsByMailbox("acc1", "mbox1").executeAsList().size)

        db.accountQueries.deleteAccount("acc1")

        assertEquals(0, db.emailHeaderQueries.selectEmailsByMailbox("acc1", "mbox1").executeAsList().size)
    }

    // --- CASCADE: email_body ---

    @Test
    fun deleteAccount_cascadesToEmailBodies() {
        insertAccount("acc1")
        db.emailBodyQueries.upsertEmailBody(
            email_id = "e1", account_id = "acc1",
            text_body = "plain text", html_body = null,
        )
        assertEquals(1, db.emailBodyQueries.selectEmailBody("acc1", "e1").executeAsList().size)

        db.accountQueries.deleteAccount("acc1")

        assertEquals(0, db.emailBodyQueries.selectEmailBody("acc1", "e1").executeAsList().size)
    }

    // --- CASCADE: state_token ---

    @Test
    fun deleteAccount_cascadesToStateTokens() {
        insertAccount("acc1")
        db.stateTokenQueries.upsertStateToken(account_id = "acc1", type_name = "Mailbox", state = "s1")
        assertEquals("s1", db.stateTokenQueries.selectStateToken("acc1", "Mailbox").executeAsOneOrNull())

        db.accountQueries.deleteAccount("acc1")

        assertNull(db.stateTokenQueries.selectStateToken("acc1", "Mailbox").executeAsOneOrNull())
    }

    // --- multi-account isolation ---

    @Test
    fun twoAccounts_dataIsIsolated() {
        insertAccount("acc1")
        insertAccount("acc2")
        db.mailboxQueries.upsertMailbox("mbox1", "acc1", "INBOX", "inbox", null, 0, 0)
        db.mailboxQueries.upsertMailbox("mbox2", "acc2", "INBOX", "inbox", null, 0, 0)

        db.accountQueries.deleteAccount("acc1")

        assertEquals(0, db.mailboxQueries.selectMailboxesByAccount("acc1").executeAsList().size)
        assertEquals(1, db.mailboxQueries.selectMailboxesByAccount("acc2").executeAsList().size)
    }

    // --- helpers ---

    private fun insertAccount(id: String) {
        db.accountQueries.insertAccount(
            id = id,
            display_name = id,
            hostname = "http://localhost:8080",
            username = "alice@localhost",
            jmap_account_id = "jmap-$id",
            api_url = "http://localhost:8080/jmap/",
            event_source_url = "http://localhost:8080/jmap/eventsource/",
            added_at = 1000L,
        )
    }
}
