package de.sharedinbox.core.jmap

import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlin.test.Test
import kotlin.test.assertEquals

class JmapSerializationTest {

    private val json = Json { ignoreUnknownKeys = true }

    // --- MethodCall ---

    @Test
    fun methodCall_encodesToArray() {
        val call = MethodCall(
            name = "Mailbox/get",
            arguments = buildJsonObject { put("accountId", "A13824") },
            clientId = "0",
        )
        val encoded = json.encodeToString(call)
        assertEquals("""["Mailbox/get",{"accountId":"A13824"},"0"]""", encoded)
    }

    @Test
    fun methodCall_decodesFromArray() {
        val raw = """["Email/query",{"accountId":"A1","filter":null},"r1"]"""
        val call = json.decodeFromString<MethodCall>(raw)
        assertEquals("Email/query", call.name)
        assertEquals("r1", call.clientId)
    }

    @Test
    fun methodCall_roundTrip() {
        val original = MethodCall(
            name = "Email/get",
            arguments = buildJsonObject {
                put("accountId", "A1")
                put("ids", buildJsonObject {})
            },
            clientId = "c1",
        )
        val decoded = json.decodeFromString<MethodCall>(json.encodeToString(original))
        assertEquals(original, decoded)
    }

    // --- MethodResponse ---

    @Test
    fun methodResponse_roundTrip() {
        val original = MethodResponse(
            name = "Mailbox/get",
            result = buildJsonObject { put("state", "abc123") },
            clientId = "0",
        )
        val decoded = json.decodeFromString<MethodResponse>(json.encodeToString(original))
        assertEquals(original, decoded)
    }

    // --- JmapRequest ---

    @Test
    fun jmapRequest_roundTrip() {
        val request = JmapRequest(
            using = listOf(JmapCapability.CORE, JmapCapability.MAIL),
            methodCalls = listOf(
                MethodCall("Mailbox/get", buildJsonObject { put("accountId", "A1") }, "0"),
                MethodCall("Email/query", buildJsonObject { put("accountId", "A1") }, "1"),
            ),
        )
        val decoded = json.decodeFromString<JmapRequest>(json.encodeToString(request))
        assertEquals(request, decoded)
    }

    // --- JmapSession ---

    @Test
    fun jmapSession_parsesFromWireJson() {
        val wireJson = """
        {
          "username": "alice@localhost",
          "apiUrl": "http://localhost:8080/jmap/",
          "downloadUrl": "http://localhost:8080/jmap/download/{accountId}/{blobId}/{name}",
          "uploadUrl": "http://localhost:8080/jmap/upload/{accountId}/",
          "eventSourceUrl": "http://localhost:8080/jmap/eventsource/",
          "state": "state1",
          "accounts": {
            "A1": {
              "name": "alice@localhost",
              "isPersonal": true,
              "isReadOnly": false,
              "accountCapabilities": {}
            }
          },
          "primaryAccounts": {
            "urn:ietf:params:jmap:mail": "A1"
          },
          "capabilities": {}
        }
        """.trimIndent()

        val session = json.decodeFromString<JmapSession>(wireJson)
        assertEquals("alice@localhost", session.username)
        assertEquals("A1", session.primaryAccounts[JmapCapability.MAIL])
        assertEquals(true, session.accounts["A1"]?.isPersonal)
    }
}
