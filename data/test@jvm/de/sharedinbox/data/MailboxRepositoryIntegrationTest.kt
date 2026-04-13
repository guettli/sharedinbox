package de.sharedinbox.data

import app.cash.sqldelight.driver.jdbc.sqlite.JdbcSqliteDriver
import de.sharedinbox.core.jmap.mail.MailboxRole
import de.sharedinbox.data.db.SharedInboxDatabase
import de.sharedinbox.data.repository.AccountRepositoryImpl
import de.sharedinbox.data.repository.MailboxRepositoryImpl
import de.sharedinbox.data.repository.SessionRepositoryImpl
import de.sharedinbox.data.store.FileTokenStore
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlin.io.path.createTempFile
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * Integration tests for MailboxRepositoryImpl.
 *
 * Requires a running Stalwart instance. Uses an in-memory SQLite DB so each test
 * starts with a clean slate.
 *
 * Env vars (exported by the Nix dev shell):
 *   STALWART_URL    — e.g. "http://localhost:53184"
 *   STALWART_USER_A — "admin"    STALWART_PASS_A — "admin"
 *   STALWART_USER_B — "alice"    STALWART_PASS_B — "secret"
 */
class MailboxRepositoryIntegrationTest {

    private val baseUrl = System.getenv("STALWART_URL")
        ?: error("STALWART_URL not set — run inside nix develop with Stalwart running")
    private val userA = System.getenv("STALWART_USER_A") ?: error("STALWART_USER_A not set")
    private val passA = System.getenv("STALWART_PASS_A") ?: error("STALWART_PASS_A not set")
    private val userB = System.getenv("STALWART_USER_B") ?: error("STALWART_USER_B not set")
    private val passB = System.getenv("STALWART_PASS_B") ?: error("STALWART_PASS_B not set")

    private lateinit var db: SharedInboxDatabase
    private lateinit var tokenStore: FileTokenStore
    private lateinit var accountRepo: AccountRepositoryImpl
    private lateinit var mailboxRepo: MailboxRepositoryImpl

    @BeforeTest
    fun setUp() {
        val driver = JdbcSqliteDriver(JdbcSqliteDriver.IN_MEMORY)
        SharedInboxDatabase.Schema.create(driver)
        driver.execute(null, "PRAGMA foreign_keys = ON", 0)
        db = SharedInboxDatabase(driver)
        tokenStore = FileTokenStore(
            createTempFile(prefix = "sharedinbox-test-creds-", suffix = ".json")
                .also { it.toFile().deleteOnExit() }
        )
        accountRepo = AccountRepositoryImpl(db, tokenStore, SessionRepositoryImpl())
        mailboxRepo = MailboxRepositoryImpl(db, tokenStore)
    }

    @Test
    fun syncMailboxes_populatesDb() = runBlocking {
        val account = accountRepo.addAccount(baseUrl, userA, passA).getOrThrow()
        mailboxRepo.syncMailboxes(account.id).getOrThrow()

        val mailboxes = mailboxRepo.observeMailboxes(account.id).first()
        assertTrue(mailboxes.isNotEmpty(), "Expected at least one mailbox after sync")
    }

    @Test
    fun syncMailboxes_inboxPresent() = runBlocking {
        val account = accountRepo.addAccount(baseUrl, userA, passA).getOrThrow()
        mailboxRepo.syncMailboxes(account.id).getOrThrow()

        val mailboxes = mailboxRepo.observeMailboxes(account.id).first()
        val inbox = mailboxes.firstOrNull { it.role == MailboxRole.INBOX }
        assertNotNull(inbox, "Expected an Inbox mailbox")
        assertEquals("Inbox", inbox.name)
    }

    @Test
    fun syncMailboxes_twoAccountsAreIndependent() = runBlocking {
        val accountA = accountRepo.addAccount(baseUrl, userA, passA).getOrThrow()
        val accountB = accountRepo.addAccount(baseUrl, userB, passB).getOrThrow()

        mailboxRepo.syncMailboxes(accountA.id).getOrThrow()
        mailboxRepo.syncMailboxes(accountB.id).getOrThrow()

        val mailboxesA = mailboxRepo.observeMailboxes(accountA.id).first()
        val mailboxesB = mailboxRepo.observeMailboxes(accountB.id).first()

        // Both accounts have their own mailboxes in the DB.
        // (The server may assign the same IDs to different accounts — independence is enforced
        // by the local account_id FK, not by JMAP ID uniqueness.)
        assertTrue(mailboxesA.isNotEmpty(), "Account A should have mailboxes")
        assertTrue(mailboxesB.isNotEmpty(), "Account B should have mailboxes")

        // Removing A's mailboxes (by removing A) must not touch B
        accountRepo.removeAccount(accountA.id)
        val mailboxesAfterRemoveA = mailboxRepo.observeMailboxes(accountB.id).first()
        assertEquals(mailboxesB.size, mailboxesAfterRemoveA.size,
            "Account B mailboxes should be unaffected by removing account A")
    }

    @Test
    fun syncMailboxes_stateTokenSaved() = runBlocking {
        val account = accountRepo.addAccount(baseUrl, userA, passA).getOrThrow()
        mailboxRepo.syncMailboxes(account.id).getOrThrow()

        val state = db.stateTokenQueries
            .selectStateToken(account.id, "Mailbox")
            .executeAsOneOrNull()
        assertNotNull(state, "Expected Mailbox state token to be saved after sync")
        assertTrue(state.isNotBlank())
    }

    @Test
    fun syncMailboxes_incrementalSyncIdempotent() = runBlocking {
        val account = accountRepo.addAccount(baseUrl, userA, passA).getOrThrow()

        // First sync (full)
        mailboxRepo.syncMailboxes(account.id).getOrThrow()
        val afterFirst = mailboxRepo.observeMailboxes(account.id).first()

        // Second sync (incremental — no changes expected)
        mailboxRepo.syncMailboxes(account.id).getOrThrow()
        val afterSecond = mailboxRepo.observeMailboxes(account.id).first()

        assertEquals(afterFirst.size, afterSecond.size)
        assertEquals(afterFirst.map { it.id }.toSet(), afterSecond.map { it.id }.toSet())
    }

    @Test
    fun removeAccount_cascadesMailboxes() = runBlocking {
        val account = accountRepo.addAccount(baseUrl, userA, passA).getOrThrow()
        mailboxRepo.syncMailboxes(account.id).getOrThrow()

        val beforeRemove = mailboxRepo.observeMailboxes(account.id).first()
        assertTrue(beforeRemove.isNotEmpty())

        accountRepo.removeAccount(account.id)

        val afterRemove = mailboxRepo.observeMailboxes(account.id).first()
        assertTrue(afterRemove.isEmpty(), "Mailboxes should be cascade-deleted with account")
    }
}
