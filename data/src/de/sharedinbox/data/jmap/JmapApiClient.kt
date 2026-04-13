package de.sharedinbox.data.jmap

import de.sharedinbox.core.jmap.JmapCapability
import de.sharedinbox.core.jmap.JmapRequest
import de.sharedinbox.core.jmap.JmapResponse
import de.sharedinbox.core.jmap.MethodCall
import de.sharedinbox.core.jmap.mail.Mailbox
import io.ktor.client.*
import io.ktor.client.call.*
import io.ktor.client.request.*
import io.ktor.http.*
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.*

private val jmapUsing = listOf(JmapCapability.CORE, JmapCapability.MAIL)

/**
 * Low-level JMAP API client for one account.
 *
 * Each method posts a single [MethodCall] to [apiUrl] and decodes the response.
 * HTTP auth and content-negotiation are handled by [httpClient] (see [createHttpClient]).
 */
class JmapApiClient(
    private val apiUrl: String,
    private val httpClient: HttpClient,
    private val json: Json = Json { ignoreUnknownKeys = true },
) {

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

    private suspend inline fun <reified T> call(
        methodName: String,
        arguments: JsonObject,
    ): T {
        val request = JmapRequest(
            using = jmapUsing,
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
