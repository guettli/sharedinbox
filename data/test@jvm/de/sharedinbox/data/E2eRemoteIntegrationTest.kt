package de.sharedinbox.data

import de.sharedinbox.data.repository.SessionRepositoryImpl
import kotlinx.coroutines.runBlocking
import kotlin.test.Test
import kotlin.test.assertTrue

/**
 * Integration tests against the shared remote Stalwart instance used for E2E CI.
 *
 * Required env vars (set in .env and exported before running):
 *   E2E_URL      — e.g. "https://mail.example.com"
 *   E2E_USER     — login name
 *   E2E_PASSWORD — password
 */
class E2eRemoteIntegrationTest {
    private val baseUrl =
        System.getenv("E2E_URL")
            ?: error("E2E_URL is not set")
    private val username =
        System.getenv("E2E_USER")
            ?: error("E2E_USER is not set")
    private val password =
        System.getenv("E2E_PASSWORD")
            ?: error("E2E_PASSWORD is not set")

    @Test
    fun discover_succeeds() {
        val result = runBlocking { SessionRepositoryImpl().discover(baseUrl, username, password) }
        assertTrue(result.isSuccess, "JMAP session discovery failed: ${result.exceptionOrNull()}")
    }
}
