package de.sharedinbox.data

import app.cash.sqldelight.driver.jdbc.sqlite.JdbcSqliteDriver
import de.sharedinbox.core.jmap.mail.EmailAddress
import de.sharedinbox.core.jmap.mail.EmailDraft
import de.sharedinbox.core.jmap.mail.EmailKeyword
import de.sharedinbox.core.jmap.mail.MailboxRole
import de.sharedinbox.data.db.SharedInboxDatabase
import de.sharedinbox.data.http.createHttpClient
import de.sharedinbox.data.jmap.JmapApiClient
import de.sharedinbox.data.network.JvmNetworkMonitor
import de.sharedinbox.data.repository.AccountRepositoryImpl
import de.sharedinbox.data.repository.EmailRepositoryImpl
import de.sharedinbox.data.repository.MailboxRepositoryImpl
import de.sharedinbox.data.repository.RecentAddressRepositoryImpl
import de.sharedinbox.data.repository.SessionRepositoryImpl
import de.sharedinbox.data.repository.SyncLogRepositoryImpl
import de.sharedinbox.data.repository.SyncSettingsRepositoryImpl
import de.sharedinbox.data.store.FileTokenStore
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlin.io.path.createTempFile
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * Integration tests for EmailRepositoryImpl (Phases 6, 7, 9).
 *
 * Requires a running Stalwart instance. Uses an in-memory SQLite DB.
 *
 * Env vars (exported by the Nix dev shell):
 *   STALWART_URL    — e.g. "http://localhost:53184"
 *   STALWART_USER_B — "alice"    STALWART_PASS_B — "secret"
 *   STALWART_USER_C — "bob"      STALWART_PASS_C — "secret"
 */
class EmailRepositoryIntegrationTest {
    private val baseUrl =
        System.getenv("STALWART_URL")
            ?: error("STALWART_URL not set — run inside nix develop with Stalwart running")
    private val userB = System.getenv("STALWART_USER_B") ?: error("STALWART_USER_B not set")
    private val passB = System.getenv("STALWART_PASS_B") ?: error("STALWART_PASS_B not set")
    private val userC = System.getenv("STALWART_USER_C") ?: error("STALWART_USER_C not set")
    private val passC = System.getenv("STALWART_PASS_C") ?: error("STALWART_PASS_C not set")

    private lateinit var db: SharedInboxDatabase
    private lateinit var tokenStore: FileTokenStore
    private lateinit var accountRepo: AccountRepositoryImpl
    private lateinit var mailboxRepo: MailboxRepositoryImpl
    private lateinit var emailRepo: EmailRepositoryImpl

    // Alice's account (primary test subject)
    private lateinit var aliceId: String
    private lateinit var aliceJmapId: String
    private lateinit var aliceApiUrl: String
    private lateinit var aliceInboxId: String
    private lateinit var aliceHttpClient: io.ktor.client.HttpClient
    private lateinit var aliceApiClient: JmapApiClient

    @BeforeTest
    fun setUp() =
        runBlocking {
            val driver = JdbcSqliteDriver(JdbcSqliteDriver.IN_MEMORY)
            SharedInboxDatabase.Schema.create(driver)
            driver.execute(null, "PRAGMA foreign_keys = ON", 0)
            db = SharedInboxDatabase(driver)
            tokenStore =
                FileTokenStore(
                    createTempFile(prefix = "sharedinbox-email-test-", suffix = ".json")
                        .also { it.toFile().deleteOnExit() },
                )
            val syncLogRepo = SyncLogRepositoryImpl(db)
            accountRepo = AccountRepositoryImpl(db, tokenStore, SessionRepositoryImpl())
            mailboxRepo = MailboxRepositoryImpl(db, tokenStore, syncLogRepo)
            emailRepo =
                EmailRepositoryImpl(
                    db = db,
                    tokenStore = tokenStore,
                    syncLog = syncLogRepo,
                    mailboxRepo = mailboxRepo,
                    recentAddresses = RecentAddressRepositoryImpl(db),
                    syncSettings = SyncSettingsRepositoryImpl(db),
                    networkMonitor = JvmNetworkMonitor(),
                )

            val aliceAccount = accountRepo.addAccount(baseUrl, userB, passB).getOrThrow()
            aliceId = aliceAccount.id
            aliceJmapId = aliceAccount.jmapAccountId
            aliceApiUrl = aliceAccount.apiUrl

            mailboxRepo.syncMailboxes(aliceId).getOrThrow()
            val mailboxes = mailboxRepo.observeMailboxes(aliceId).first()
            aliceInboxId = mailboxes.first { it.role == MailboxRole.INBOX }.id

            aliceHttpClient = createHttpClient(userB, passB)
            aliceApiClient = JmapApiClient(aliceApiUrl, aliceHttpClient)
        }

    @AfterTest
    fun tearDown() {
        aliceHttpClient.close()
    }

    // ── Phase 6: email header sync ───────────────────────────────────────────

    @Test
    fun syncEmails_populatesDb() =
        runBlocking {
            createTestEmail("Subject A")
            createTestEmail("Subject B")

            emailRepo.syncEmails(aliceId, aliceInboxId).getOrThrow()

            val emails = emailRepo.observeEmails(aliceId, aliceInboxId).first()
            assertTrue(emails.size >= 2, "Expected at least 2 emails, got ${emails.size}")
            val subjects = emails.map { it.subject }
            assertTrue(subjects.contains("Subject A"))
            assertTrue(subjects.contains("Subject B"))
        }

    @Test
    fun observeEmails_emitsFlow() =
        runBlocking {
            createTestEmail("Flow test")
            emailRepo.syncEmails(aliceId, aliceInboxId).getOrThrow()

            val emails = emailRepo.observeEmails(aliceId, aliceInboxId).first()
            assertTrue(emails.isNotEmpty())
        }

    @Test
    fun syncEmails_stateTokenSaved() =
        runBlocking {
            emailRepo.syncEmails(aliceId, aliceInboxId).getOrThrow()

            val state =
                db.stateTokenQueries
                    .selectStateToken(aliceId, "Email")
                    .executeAsOneOrNull()
            assertNotNull(state)
            assertTrue(state.isNotBlank())
        }

    @Test
    fun syncEmails_incrementalSync_idempotent() =
        runBlocking {
            createTestEmail("Incremental test")
            emailRepo.syncEmails(aliceId, aliceInboxId).getOrThrow()
            val countAfterFirst = emailRepo.observeEmails(aliceId, aliceInboxId).first().size

            // Second sync (incremental — no new emails)
            emailRepo.syncEmails(aliceId, aliceInboxId).getOrThrow()
            val countAfterSecond = emailRepo.observeEmails(aliceId, aliceInboxId).first().size

            assertEquals(countAfterFirst, countAfterSecond)
        }

    @Test
    fun syncEmails_twoAccounts_independent() =
        runBlocking {
            val bobAccount = accountRepo.addAccount(baseUrl, userC, passC).getOrThrow()
            mailboxRepo.syncMailboxes(bobAccount.id).getOrThrow()
            val bobMailboxes = mailboxRepo.observeMailboxes(bobAccount.id).first()
            val bobInboxId = bobMailboxes.first { it.role == MailboxRole.INBOX }.id

            createTestEmail("For alice only")
            emailRepo.syncEmails(aliceId, aliceInboxId).getOrThrow()
            emailRepo.syncEmails(bobAccount.id, bobInboxId).getOrThrow()

            val aliceEmails = emailRepo.observeEmails(aliceId, aliceInboxId).first()
            val bobEmails = emailRepo.observeEmails(bobAccount.id, bobInboxId).first()

            // Alice has emails; bob has none (no emails sent to bob in this test)
            assertTrue(aliceEmails.isNotEmpty(), "Alice should have emails")
            // Removing alice's account must not affect bob's emails
            accountRepo.removeAccount(aliceId)
            val bobEmailsAfter = emailRepo.observeEmails(bobAccount.id, bobInboxId).first()
            assertEquals(bobEmails.size, bobEmailsAfter.size)
        }

    // ── Phase 7: email body sync ─────────────────────────────────────────────

    @Test
    fun getEmail_fetchesAndCachesBody() =
        runBlocking {
            createTestEmail("Body fetch test", body = "Hello, this is the body.")
            emailRepo.syncEmails(aliceId, aliceInboxId).getOrThrow()

            val header =
                emailRepo
                    .observeEmails(aliceId, aliceInboxId)
                    .first()
                    .first { it.subject == "Body fetch test" }

            val fullEmail = emailRepo.getEmail(aliceId, header.id).getOrThrow()

            // Body should be present
            val bodyText =
                fullEmail.textBody
                    .firstOrNull()
                    ?.partId
                    ?.let { fullEmail.bodyValues[it]?.value }
            assertNotNull(bodyText, "Expected text body to be present")
            assertTrue(bodyText.contains("Hello"), "Expected body to contain 'Hello'")
        }

    @Test
    fun getEmail_usesLocalCache() =
        runBlocking {
            createTestEmail("Cache test", body = "Cached body.")
            emailRepo.syncEmails(aliceId, aliceInboxId).getOrThrow()

            val header =
                emailRepo
                    .observeEmails(aliceId, aliceInboxId)
                    .first()
                    .first { it.subject == "Cache test" }

            // First call fetches from server
            emailRepo.getEmail(aliceId, header.id).getOrThrow()

            // Second call should use local DB (no server call needed)
            val bodyInDb = db.emailBodyQueries.selectEmailBody(aliceId, header.id).executeAsOneOrNull()
            assertNotNull(bodyInDb, "Body should be cached in DB after first getEmail()")

            val secondCall = emailRepo.getEmail(aliceId, header.id).getOrThrow()
            val bodyText =
                secondCall.textBody
                    .firstOrNull()
                    ?.partId
                    ?.let { secondCall.bodyValues[it]?.value }
            assertTrue(bodyText != null, "Cached body should be non-null")
        }

    // ── Phase 9: mutations ───────────────────────────────────────────────────

    @Test
    fun setKeyword_marksEmailAsSeen() =
        runBlocking {
            createTestEmail("Keyword test")
            emailRepo.syncEmails(aliceId, aliceInboxId).getOrThrow()

            val emailId =
                emailRepo
                    .observeEmails(aliceId, aliceInboxId)
                    .first()
                    .first { it.subject == "Keyword test" }
                    .id

            emailRepo.setKeyword(aliceId, emailId, EmailKeyword.SEEN, true).getOrThrow()

            val updated = db.emailHeaderQueries.selectEmailById(aliceId, emailId).executeAsOneOrNull()
            assertNotNull(updated)
            assertTrue(
                updated.keywords.contains(EmailKeyword.SEEN),
                "Expected \$seen in keywords, got: ${updated.keywords}",
            )
        }

    @Test
    fun setKeyword_removesKeyword() =
        runBlocking {
            createTestEmail("Unflag test")
            emailRepo.syncEmails(aliceId, aliceInboxId).getOrThrow()
            val emailId =
                emailRepo
                    .observeEmails(aliceId, aliceInboxId)
                    .first()
                    .first { it.subject == "Unflag test" }
                    .id

            // Set then clear
            emailRepo.setKeyword(aliceId, emailId, EmailKeyword.FLAGGED, true).getOrThrow()
            emailRepo.setKeyword(aliceId, emailId, EmailKeyword.FLAGGED, false).getOrThrow()

            val updated = db.emailHeaderQueries.selectEmailById(aliceId, emailId).executeAsOneOrNull()
            assertNotNull(updated)
            assertTrue(
                !updated.keywords.contains(EmailKeyword.FLAGGED),
                "Expected \$flagged to be removed, got: ${updated.keywords}",
            )
        }

    @Test
    fun moveEmail_updatesMailboxId() =
        runBlocking {
            createTestEmail("Move test")
            emailRepo.syncEmails(aliceId, aliceInboxId).getOrThrow()

            val emailId =
                emailRepo
                    .observeEmails(aliceId, aliceInboxId)
                    .first()
                    .first { it.subject == "Move test" }
                    .id

            val mailboxes = mailboxRepo.observeMailboxes(aliceId).first()
            val sentMailbox =
                mailboxes.firstOrNull { it.role == MailboxRole.SENT }
                    ?: mailboxes.first { it.id != aliceInboxId }

            emailRepo.moveEmail(aliceId, emailId, sentMailbox.id).getOrThrow()

            val updated = db.emailHeaderQueries.selectEmailById(aliceId, emailId).executeAsOneOrNull()
            assertNotNull(updated)
            assertEquals(sentMailbox.id, updated.mailbox_id)
        }

    @Test
    fun deleteEmail_movesToTrash() =
        runBlocking {
            createTestEmail("Delete test")
            emailRepo.syncEmails(aliceId, aliceInboxId).getOrThrow()

            val emailId =
                emailRepo
                    .observeEmails(aliceId, aliceInboxId)
                    .first()
                    .first { it.subject == "Delete test" }
                    .id

            emailRepo.deleteEmail(aliceId, emailId).getOrThrow()

            val inTrash = db.emailHeaderQueries.selectEmailById(aliceId, emailId).executeAsOneOrNull()
            assertNotNull(inTrash, "Email should still exist (moved to trash, not deleted)")
            val trashMailbox = db.mailboxQueries.selectMailbox(aliceId, inTrash.mailbox_id).executeAsOneOrNull()
            assertNotNull(trashMailbox, "Email's mailbox should exist")
            assertEquals(MailboxRole.TRASH, trashMailbox.role, "Email should be in trash mailbox")
        }

    @Test
    fun sendEmail_succeeds() =
        runBlocking {
            val draft =
                EmailDraft(
                    from = EmailAddress(name = "Alice", email = "alice@localhost"),
                    to = listOf(EmailAddress(name = "Bob", email = "bob@localhost")),
                    subject = "Hello from integration test",
                    textBody = "This is a test email sent via JMAP.",
                )
            val result = emailRepo.sendEmail(aliceId, draft)
            assertTrue(result.isSuccess, "sendEmail should succeed, got: ${result.exceptionOrNull()}")
        }

    // ── helper ───────────────────────────────────────────────────────────────

    private suspend fun createTestEmail(
        subject: String,
        body: String = "Test body for: $subject",
    ) {
        val result =
            aliceApiClient.emailSet(
                aliceJmapId,
                buildJsonObject {
                    put(
                        "create",
                        buildJsonObject {
                            put(
                                "new1",
                                buildJsonObject {
                                    put("mailboxIds", buildJsonObject { put(aliceInboxId, true) })
                                    put("subject", subject)
                                    put(
                                        "from",
                                        buildJsonArray {
                                            add(buildJsonObject { put("email", "alice@localhost") })
                                        },
                                    )
                                    put(
                                        "to",
                                        buildJsonArray {
                                            add(buildJsonObject { put("email", "bob@localhost") })
                                        },
                                    )
                                    put(
                                        "bodyValues",
                                        buildJsonObject {
                                            put("body1", buildJsonObject { put("value", body) })
                                        },
                                    )
                                    put(
                                        "textBody",
                                        buildJsonArray {
                                            add(
                                                buildJsonObject {
                                                    put("partId", "body1")
                                                    put("type", "text/plain")
                                                },
                                            )
                                        },
                                    )
                                },
                            )
                        },
                    )
                },
            )
        check(result.notCreated.isEmpty()) { "createTestEmail failed: ${result.notCreated}" }
    }
}
