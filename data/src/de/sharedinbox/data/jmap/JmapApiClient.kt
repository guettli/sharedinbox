package de.sharedinbox.data.jmap

import de.sharedinbox.core.jmap.JmapCapability
import de.sharedinbox.core.jmap.JmapRequest
import de.sharedinbox.core.jmap.JmapResponse
import de.sharedinbox.core.jmap.MethodCall
import de.sharedinbox.core.jmap.mail.Email
import de.sharedinbox.core.jmap.mail.EmailBodyPart
import de.sharedinbox.core.jmap.mail.EmailBodyValue
import de.sharedinbox.core.jmap.mail.Mailbox
import io.ktor.client.*
import io.ktor.client.call.*
import io.ktor.client.request.*
import io.ktor.client.statement.*
import io.ktor.http.*
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.*

private val jmapUsing = listOf(JmapCapability.CORE, JmapCapability.MAIL)
private val jmapUsingWithSubmission =
    listOf(JmapCapability.CORE, JmapCapability.MAIL, JmapCapability.SUBMISSION)

private val HEADER_PROPERTIES = buildJsonArray {
    listOf(
        "id", "blobId", "threadId", "mailboxIds", "keywords",
        "subject", "from", "receivedAt", "preview", "hasAttachment",
    ).forEach { add(it) }
}

/**
 * Low-level JMAP API client for one account.
 *
 * Each method posts a single [MethodCall] to [apiUrl] and decodes the response.
 * HTTP auth and content-negotiation are handled by [httpClient] (see [createHttpClient]).
 */
class JmapApiClient(
    private val apiUrl: String,
    val httpClient: HttpClient,
    val json: Json = Json { ignoreUnknownKeys = true },
) {

    // ── Mailbox ──────────────────────────────────────────────────────────────

    @Serializable
    data class MailboxGetResult(
        val accountId: String,
        val state: String,
        val list: List<Mailbox>,
        val notFound: List<String> = emptyList(),
    )

    @Serializable
    data class MailboxChangesResult(
        val accountId: String,
        val oldState: String,
        val newState: String,
        val hasMoreChanges: Boolean,
        val created: List<String>,
        val updated: List<String>,
        val destroyed: List<String>,
    )

    /** Fetches all mailboxes ([ids] = null) or a specific subset. */
    suspend fun getMailboxes(
        jmapAccountId: String,
        ids: List<String>? = null,
    ): MailboxGetResult {
        val arguments = buildJsonObject {
            put("accountId", jmapAccountId)
            put("ids", if (ids == null) JsonNull else buildJsonArray { ids.forEach { add(it) } })
        }
        return call("Mailbox/get", arguments)
    }

    // ── Mailbox/set ──────────────────────────────────────────────────────────

    @Serializable
    data class MailboxSetResult(
        val accountId: String,
        val newState: String,
        val created: Map<String, JsonObject> = emptyMap(),
        val updated: Map<String, JsonObject?> = emptyMap(),
        val destroyed: List<String> = emptyList(),
        val notCreated: Map<String, SetError> = emptyMap(),
        val notUpdated: Map<String, SetError> = emptyMap(),
        val notDestroyed: Map<String, SetError> = emptyMap(),
    )

    /**
     * Generic [Mailbox/set](https://www.rfc-editor.org/rfc/rfc8621#section-2.5).
     *
     * [arguments] must NOT include `accountId` — it is injected automatically.
     */
    suspend fun mailboxSet(
        jmapAccountId: String,
        arguments: JsonObject,
    ): MailboxSetResult {
        val fullArgs = buildJsonObject {
            put("accountId", jmapAccountId)
            arguments.forEach { (k, v) -> put(k, v) }
        }
        return call("Mailbox/set", fullArgs)
    }

    /** Returns the delta since [sinceState] (RFC 8621 §2.5). */
    suspend fun getMailboxChanges(
        jmapAccountId: String,
        sinceState: String,
    ): MailboxChangesResult {
        val arguments = buildJsonObject {
            put("accountId", jmapAccountId)
            put("sinceState", sinceState)
        }
        return call("Mailbox/changes", arguments)
    }

    // ── Email/query ──────────────────────────────────────────────────────────

    @Serializable
    data class EmailQueryResult(
        val accountId: String,
        val queryState: String,
        val canCalculateChanges: Boolean = false,
        val ids: List<String>,
        val position: Int = 0,
        val total: Int = 0,
    )

    /** Lists email IDs in [mailboxId], sorted by receivedAt descending. */
    suspend fun queryEmails(
        jmapAccountId: String,
        mailboxId: String,
        limit: Int = 500,
    ): EmailQueryResult {
        val arguments = buildJsonObject {
            put("accountId", jmapAccountId)
            put("filter", buildJsonObject { put("inMailbox", mailboxId) })
            put("sort", buildJsonArray {
                add(buildJsonObject {
                    put("property", "receivedAt")
                    put("isAscending", false)
                })
            })
            put("position", 0)
            put("limit", limit)
        }
        return call("Email/query", arguments)
    }

    // ── Email/get ────────────────────────────────────────────────────────────

    @Serializable
    data class EmailGetResult(
        val accountId: String,
        val state: String,
        val list: List<Email>,
        val notFound: List<String> = emptyList(),
    )

    /** Fetches email headers (no body) for the given IDs. */
    suspend fun getEmailHeaders(
        jmapAccountId: String,
        ids: List<String>,
    ): EmailGetResult {
        val arguments = buildJsonObject {
            put("accountId", jmapAccountId)
            put("ids", buildJsonArray { ids.forEach { add(it) } })
            put("properties", HEADER_PROPERTIES)
        }
        return call("Email/get", arguments)
    }

    /**
     * Body-only projection of an email — only fields requested in [getEmailBody].
     * Using a separate type avoids [kotlinx.serialization.MissingFieldException] from
     * required non-body fields (blobId, threadId, mailboxIds, receivedAt) in [Email].
     */
    @Serializable
    data class EmailBodyOnly(
        val id: String,
        val bodyValues: Map<String, EmailBodyValue> = emptyMap(),
        val htmlBody: List<EmailBodyPart> = emptyList(),
        val textBody: List<EmailBodyPart> = emptyList(),
    )

    @Serializable
    data class EmailBodyOnlyResult(
        val accountId: String,
        val state: String,
        val list: List<EmailBodyOnly>,
        val notFound: List<String> = emptyList(),
    )

    /** Fetches body content (text + HTML) for a single email. */
    suspend fun getEmailBody(
        jmapAccountId: String,
        emailId: String,
    ): EmailBodyOnly {
        val arguments = buildJsonObject {
            put("accountId", jmapAccountId)
            put("ids", buildJsonArray { add(emailId) })
            put("properties", buildJsonArray {
                listOf("id", "bodyValues", "htmlBody", "textBody").forEach { add(it) }
            })
            put("fetchHTMLBodyValues", true)
            put("fetchTextBodyValues", true)
            put("maxBodyValueBytes", 1048576)
        }
        val result: EmailBodyOnlyResult = call("Email/get", arguments)
        return result.list.firstOrNull() ?: error("Email $emailId not found on server")
    }

    // ── Email/changes ────────────────────────────────────────────────────────

    @Serializable
    data class EmailChangesResult(
        val accountId: String,
        val oldState: String,
        val newState: String,
        val hasMoreChanges: Boolean,
        val created: List<String>,
        val updated: List<String>,
        val destroyed: List<String>,
    )

    suspend fun getEmailChanges(
        jmapAccountId: String,
        sinceState: String,
    ): EmailChangesResult {
        val arguments = buildJsonObject {
            put("accountId", jmapAccountId)
            put("sinceState", sinceState)
        }
        return call("Email/changes", arguments)
    }

    // ── Email/set ────────────────────────────────────────────────────────────

    @Serializable
    data class SetError(
        val type: String,
        val description: String? = null,
    )

    @Serializable
    data class EmailSetResult(
        val accountId: String,
        val newState: String,
        val created: Map<String, JsonObject> = emptyMap(),
        val updated: Map<String, JsonObject?> = emptyMap(),
        val destroyed: List<String> = emptyList(),
        val notCreated: Map<String, SetError> = emptyMap(),
        val notUpdated: Map<String, SetError> = emptyMap(),
        val notDestroyed: Map<String, SetError> = emptyMap(),
    )

    /**
     * Generic [Email/set](https://www.rfc-editor.org/rfc/rfc8621#section-4.2).
     *
     * [arguments] must NOT include `accountId` — it is injected automatically.
     */
    suspend fun emailSet(
        jmapAccountId: String,
        arguments: JsonObject,
    ): EmailSetResult {
        val fullArgs = buildJsonObject {
            put("accountId", jmapAccountId)
            arguments.forEach { (k, v) -> put(k, v) }
        }
        return call("Email/set", fullArgs)
    }

    // ── Identity/get ─────────────────────────────────────────────────────────

    @Serializable
    data class Identity(
        val id: String,
        val name: String? = null,
        val email: String? = null,
    )

    @Serializable
    data class IdentityGetResult(
        val accountId: String,
        val state: String,
        val list: List<Identity>,
        val notFound: List<String> = emptyList(),
    )

    suspend fun getIdentities(jmapAccountId: String): IdentityGetResult {
        val arguments = buildJsonObject {
            put("accountId", jmapAccountId)
            put("ids", JsonNull)
        }
        return call("Identity/get", arguments, jmapUsingWithSubmission)
    }

    // ── EmailSubmission/set ───────────────────────────────────────────────────

    @Serializable
    data class EmailSubmissionSetResult(
        val accountId: String,
        val newState: String,
        val created: Map<String, JsonObject> = emptyMap(),
        val notCreated: Map<String, SetError> = emptyMap(),
    )

    suspend fun emailSubmissionSet(
        jmapAccountId: String,
        identityId: String,
        emailId: String,
    ): EmailSubmissionSetResult {
        val arguments = buildJsonObject {
            put("accountId", jmapAccountId)
            put("create", buildJsonObject {
                put("sub1", buildJsonObject {
                    put("identityId", identityId)
                    put("emailId", emailId)
                })
            })
        }
        return call("EmailSubmission/set", arguments, jmapUsingWithSubmission)
    }

    // ── Attachments ───────────────────────────────────────────────────────────

    @Serializable
    data class EmailAttachmentsOnly(
        val id: String,
        val attachments: List<EmailBodyPart> = emptyList(),
    )

    @Serializable
    data class EmailAttachmentsResult(
        val accountId: String,
        val state: String,
        val list: List<EmailAttachmentsOnly>,
        val notFound: List<String> = emptyList(),
    )

    /** Fetches the attachment list for a single email (no body content). */
    suspend fun getEmailAttachments(
        jmapAccountId: String,
        emailId: String,
    ): List<EmailBodyPart> {
        val arguments = buildJsonObject {
            put("accountId", jmapAccountId)
            put("ids", buildJsonArray { add(emailId) })
            put("properties", buildJsonArray {
                listOf("id", "attachments").forEach { add(it) }
            })
        }
        val result: EmailAttachmentsResult = call("Email/get", arguments)
        return result.list.firstOrNull()?.attachments ?: emptyList()
    }

    /**
     * Downloads a blob (attachment) using the JMAP download URL template.
     *
     * [downloadUrlTemplate] is the RFC 8620 §6.2 URI template from the session.
     * Simple `{var}` substitution covers the vast majority of JMAP servers.
     */
    suspend fun downloadBlob(
        downloadUrlTemplate: String,
        jmapAccountId: String,
        blobId: String,
        mimeType: String,
    ): ByteArray {
        val url = downloadUrlTemplate
            .replace("{accountId}", jmapAccountId)
            .replace("{blobId}", blobId)
            .replace("{type}", mimeType)
            .replace("{name}", "attachment")
        return httpClient.get(url).readRawBytes()
    }

    // ── internal ─────────────────────────────────────────────────────────────

    private suspend inline fun <reified T> call(
        methodName: String,
        arguments: JsonObject,
        using: List<String> = jmapUsing,
    ): T {
        val request = JmapRequest(
            using = using,
            methodCalls = listOf(MethodCall(methodName, arguments, "c0")),
        )
        val response: JmapResponse = httpClient.post(apiUrl) {
            contentType(ContentType.Application.Json)
            setBody(request)
        }.body()
        val methodResponse = response.methodResponses.firstOrNull { it.clientId == "c0" }
            ?: error("No response for $methodName")
        if (methodResponse.name == "error") {
            val type = methodResponse.result["type"]?.jsonPrimitive?.content ?: "unknown"
            error("JMAP error for $methodName: $type")
        }
        return json.decodeFromJsonElement(methodResponse.result)
    }
}
