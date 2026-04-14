package de.sharedinbox.core

import de.sharedinbox.core.account.Account
import de.sharedinbox.core.jmap.JmapCapability
import de.sharedinbox.core.jmap.JmapResponse
import de.sharedinbox.core.jmap.MethodResponse
import de.sharedinbox.core.repository.StoredCredentials
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals

class AccountAndCredentialsTest {
    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun account_construction() {
        val account =
            Account(
                id = "local-1",
                displayName = "Alice",
                baseUrl = "https://mail.example.com",
                username = "alice@example.com",
                jmapAccountId = "A1",
                apiUrl = "https://mail.example.com/jmap/",
                uploadUrl = "https://mail.example.com/jmap/upload/{accountId}/",
                downloadUrl = "https://mail.example.com/jmap/download/{accountId}/{blobId}/{name}",
                eventSourceUrl = "https://mail.example.com/jmap/eventsource/",
                addedAt = 1_700_000_000_000L,
            )
        assertEquals("alice@example.com", account.username)
        assertEquals("A1", account.jmapAccountId)
        assertEquals("https://mail.example.com", account.baseUrl)
    }

    @Test
    fun account_equality() {
        val a = Account("id1", "Alice", "url", "user", "jmap1", "api", "up", "down", "sse", 0L)
        val b = Account("id1", "Alice", "url", "user", "jmap1", "api", "up", "down", "sse", 0L)
        val c = Account("id2", "Bob", "url", "user2", "jmap2", "api", "up", "down", "sse", 0L)
        assertEquals(a, b)
        assertNotEquals(a, c)
    }

    @Test
    fun jmapCapability_constants() {
        assertEquals("urn:ietf:params:jmap:core", JmapCapability.CORE)
        assertEquals("urn:ietf:params:jmap:mail", JmapCapability.MAIL)
        assertEquals("urn:ietf:params:jmap:submission", JmapCapability.SUBMISSION)
    }

    @Test
    fun jmapResponse_roundTrip() {
        val response =
            JmapResponse(
                methodResponses =
                    listOf(
                        MethodResponse(
                            name = "Mailbox/get",
                            result = buildJsonObject { put("state", "s1") },
                            clientId = "0",
                        ),
                    ),
                sessionState = "state-abc",
            )
        val decoded = json.decodeFromString<JmapResponse>(json.encodeToString(response))
        assertEquals(response, decoded)
        assertEquals("state-abc", decoded.sessionState)
        assertEquals(1, decoded.methodResponses.size)
    }

    @Test
    fun jmapResponse_multipleMethodResponses() {
        val response =
            JmapResponse(
                methodResponses =
                    listOf(
                        MethodResponse("Mailbox/get", buildJsonObject {}, "r0"),
                        MethodResponse("Email/query", buildJsonObject { put("ids", "[]") }, "r1"),
                    ),
                sessionState = "s1",
            )
        val decoded = json.decodeFromString<JmapResponse>(json.encodeToString(response))
        assertEquals(2, decoded.methodResponses.size)
        assertEquals("Email/query", decoded.methodResponses[1].name)
    }

    @Test
    fun storedCredentials_construction() {
        val creds =
            StoredCredentials(
                accountId = "acc1",
                username = "alice",
                password = "s3cr3t",
            )
        assertEquals("alice", creds.username)
        assertEquals("s3cr3t", creds.password)
    }

    @Test
    fun storedCredentials_equality() {
        val a = StoredCredentials("acc1", "alice", "secret")
        val b = StoredCredentials("acc1", "alice", "secret")
        val c = StoredCredentials("acc2", "bob", "other")
        assertEquals(a, b)
        assertNotEquals(a, c)
    }

    @Test
    fun storedCredentials_copy() {
        val original = StoredCredentials("acc1", "alice", "old-password")
        val updated = original.copy(password = "new-password")
        assertEquals("new-password", updated.password)
        assertEquals("acc1", updated.accountId)
    }
}
