package de.sharedinbox.data

import app.cash.sqldelight.driver.jdbc.sqlite.JdbcSqliteDriver
import de.sharedinbox.data.db.SharedInboxDatabase
import de.sharedinbox.data.http.createHttpClient
import de.sharedinbox.data.jmap.JmapApiClient
import de.sharedinbox.data.repository.AccountRepositoryImpl
import de.sharedinbox.data.repository.SessionRepositoryImpl
import de.sharedinbox.data.repository.SieveRepositoryImpl
import de.sharedinbox.data.store.FileTokenStore
import kotlinx.coroutines.runBlocking
import kotlin.io.path.createTempFile
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Integration tests for SieveRepositoryImpl.
 *
 * Requires a running Stalwart instance with JMAP Sieve support.
 * Uses an in-memory SQLite DB and a fresh account per test run.
 *
 * Env vars (exported by the Nix dev shell):
 *   STALWART_URL    — e.g. "http://localhost:53184"
 *   STALWART_USER_B — "alice@example.com"   STALWART_PASS_B — "secret"
 */
class SieveRepositoryIntegrationTest {
    private val baseUrl =
        System.getenv("STALWART_URL")
            ?: error("STALWART_URL not set — run inside nix develop with Stalwart running")
    private val userB = System.getenv("STALWART_USER_B") ?: error("STALWART_USER_B not set")
    private val passB = System.getenv("STALWART_PASS_B") ?: error("STALWART_PASS_B not set")

    private lateinit var accountRepo: AccountRepositoryImpl
    private lateinit var sieveRepo: SieveRepositoryImpl
    private lateinit var accountId: String
    private lateinit var apiClient: JmapApiClient
    private lateinit var jmapAccountId: String

    @BeforeTest
    fun setUp() =
        runBlocking {
            val driver = JdbcSqliteDriver(JdbcSqliteDriver.IN_MEMORY)
            SharedInboxDatabase.Schema.create(driver)
            driver.execute(null, "PRAGMA foreign_keys = ON", 0)
            val db = SharedInboxDatabase(driver)
            val tokenStore =
                FileTokenStore(
                    createTempFile(prefix = "sharedinbox-test-sieve-", suffix = ".json").also {
                        it.toFile().deleteOnExit()
                    },
                )
            accountRepo = AccountRepositoryImpl(db, tokenStore, SessionRepositoryImpl())
            sieveRepo = SieveRepositoryImpl(db, tokenStore)
            val account = accountRepo.addAccount(baseUrl, userB, passB).getOrThrow()
            accountId = account.id
            jmapAccountId = account.jmapAccountId

            // Delete any scripts left over from previous test runs so each test starts clean.
            val httpClient = createHttpClient(userB, passB)
            apiClient = JmapApiClient(account.apiUrl, httpClient)
            apiClient.getSieveScripts(jmapAccountId).forEach { script ->
                apiClient.destroySieveScript(jmapAccountId, script.id)
            }
        }

    @Test
    fun loadScript_doesNotThrow(): Unit =
        runBlocking {
            // loadScript must return without throwing, regardless of server state.
            // If no scripts exist it returns "", if scripts exist it returns the content.
            sieveRepo.loadScript(accountId)
        }

    @Test
    fun saveScript_succeeds_forValidSieve() =
        runBlocking {
            val script =
                """
                require ["fileinto"];
                if header :contains "Subject" "[SPAM]" {
                    fileinto "Spam";
                }
                """.trimIndent()
            val error = sieveRepo.saveScript(accountId, script)
            assertNull(error, "Expected no error for valid Sieve script, got: $error")

            // Reload and verify content round-trips.
            val loaded = sieveRepo.loadScript(accountId)
            assertTrue(loaded.contains("fileinto"), "Loaded script should contain the saved rule")
        }

    @Test
    fun saveScript_returnsError_forInvalidSieve() =
        runBlocking {
            val badScript = "this is not valid sieve syntax !!!!"
            val error = sieveRepo.saveScript(accountId, badScript)
            assertNotNull(error, "Expected a server error for invalid Sieve syntax, but got null")
            assertTrue(error.isNotBlank(), "Error message should not be blank")
        }
}
