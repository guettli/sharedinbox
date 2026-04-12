package de.sharedinbox.data

import de.sharedinbox.core.jmap.JmapCapability
import de.sharedinbox.data.repository.SessionRepositoryImpl
import de.sharedinbox.data.store.FileTokenStore
import kotlinx.coroutines.runBlocking
import kotlin.io.path.createTempFile
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * Integration tests for session discovery and credential persistence.
 *
 * Requires a running Stalwart instance. Set the following env vars (provided by the
 * Nix dev shell when Stalwart is running):
 *
 *   STALWART_URL    — e.g. "http://localhost:8080"
 *   STALWART_USER_A — login name (currently "admin")
 *   STALWART_PASS_A — password (currently "admin")
 *
 * Note: Stalwart 0.14.x internal-directory users require PHC-hashed passwords via
 * the admin API. Phase 2 uses the fallback admin (plaintext auth).
 */
class SessionRepositoryIntegrationTest {

    private val baseUrl = System.getenv("STALWART_URL")
        ?: error("STALWART_URL not set — start Stalwart: stalwart --config stalwart-dev/config.toml")
    private val username = System.getenv("STALWART_USER_A")
        ?: error("STALWART_USER_A not set")
    private val password = System.getenv("STALWART_PASS_A")
        ?: error("STALWART_PASS_A not set")

    // --- Session discovery ---

    @Test
    fun discover_returnsSuccess() {
        val repo = SessionRepositoryImpl()
        val result = runBlocking { repo.discover(baseUrl, username, password) }

        assertTrue(result.isSuccess, "discover() failed: ${result.exceptionOrNull()}")
    }

    @Test
    fun discover_sessionUsernameIsNonBlank() {
        val repo = SessionRepositoryImpl()
        val session = runBlocking { repo.discover(baseUrl, username, password).getOrThrow() }

        assertTrue(session.username.isNotBlank(), "Expected session.username to be non-blank")
    }

    @Test
    fun discover_sessionHasMailCapabilityAndPrimaryAccount() {
        val repo = SessionRepositoryImpl()
        val session = runBlocking { repo.discover(baseUrl, username, password).getOrThrow() }

        assertNotNull(
            session.primaryAccounts[JmapCapability.MAIL],
            "Expected primaryAccounts to contain urn:ietf:params:jmap:mail"
        )
        assertTrue(session.accounts.isNotEmpty(), "Expected at least one account in session")
    }

    @Test
    fun discover_sessionApiUrlIsNonEmpty() {
        val repo = SessionRepositoryImpl()
        val session = runBlocking { repo.discover(baseUrl, username, password).getOrThrow() }

        assertTrue(session.apiUrl.isNotBlank(), "apiUrl should not be blank")
        assertTrue(session.uploadUrl.isNotBlank(), "uploadUrl should not be blank")
        assertTrue(session.downloadUrl.isNotBlank(), "downloadUrl should not be blank")
        assertTrue(session.eventSourceUrl.isNotBlank(), "eventSourceUrl should not be blank")
    }

    @Test
    fun discover_followsWellKnownRedirect() {
        // Stalwart redirects /.well-known/jmap → /jmap/session (307 Temporary Redirect).
        // This test confirms the Ktor client follows the redirect and returns a valid session.
        val repo = SessionRepositoryImpl()
        val session = runBlocking { repo.discover(baseUrl, username, password).getOrThrow() }

        // If the redirect was NOT followed, we'd get a redirect response body rather than a
        // parsed JmapSession, and parsing would fail. Getting here means the redirect was followed.
        assertTrue(session.accounts.isNotEmpty())
    }

    @Test
    fun discover_badCredentials_returnsFailure() {
        val repo = SessionRepositoryImpl()
        val result = runBlocking { repo.discover(baseUrl, username, "wrong-password-xyz") }

        assertTrue(result.isFailure, "Expected failure with wrong password, got: ${result.getOrNull()}")
    }

    // --- TokenStore (FileTokenStore on JVM) ---

    @Test
    fun fileTokenStore_saveAndLoad_roundTrip() = runBlocking {
        val tmp = createTempFile(prefix = "sharedinbox-test-", suffix = ".json")
        tmp.toFile().deleteOnExit()
        val store = FileTokenStore(storePath = tmp)

        store.saveCredentials("acc1", "alice@localhost", "secret")
        val loaded = store.loadCredentials("acc1")

        assertNotNull(loaded)
        assertEquals("acc1", loaded.accountId)
        assertEquals("alice@localhost", loaded.username)
        assertEquals("secret", loaded.password)
    }

    @Test
    fun fileTokenStore_clear_removesEntry() = runBlocking {
        val tmp = createTempFile(prefix = "sharedinbox-test-", suffix = ".json")
        tmp.toFile().deleteOnExit()
        val store = FileTokenStore(storePath = tmp)

        store.saveCredentials("acc1", "alice@localhost", "secret")
        store.clearCredentials("acc1")

        val loaded = store.loadCredentials("acc1")
        assertTrue(loaded == null, "Expected null after clear, got $loaded")
    }

    @Test
    fun fileTokenStore_multipleAccounts_isolatedEntries() = runBlocking {
        val tmp = createTempFile(prefix = "sharedinbox-test-", suffix = ".json")
        tmp.toFile().deleteOnExit()
        val store = FileTokenStore(storePath = tmp)

        store.saveCredentials("acc1", "alice@localhost", "passA")
        store.saveCredentials("acc2", "bob@localhost", "passB")

        assertEquals("passA", store.loadCredentials("acc1")?.password)
        assertEquals("passB", store.loadCredentials("acc2")?.password)

        store.clearCredentials("acc1")
        assertTrue(store.loadCredentials("acc1") == null)
        assertEquals("passB", store.loadCredentials("acc2")?.password)
    }
}
