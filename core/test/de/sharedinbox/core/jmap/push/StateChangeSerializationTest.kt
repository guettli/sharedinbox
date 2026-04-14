package de.sharedinbox.core.jmap.push

import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlin.test.Test
import kotlin.test.assertEquals

class StateChangeSerializationTest {
    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun stateChange_parsesFromWireJson() {
        val wireJson =
            """
            {
              "@type": "StateChange",
              "changed": {
                "A13824": {
                  "Mailbox": "state1",
                  "Email": "state2"
                }
              }
            }
            """.trimIndent()
        val sc = json.decodeFromString<StateChange>(wireJson)
        assertEquals("StateChange", sc.type)
        assertEquals("state1", sc.changed["A13824"]?.get("Mailbox"))
        assertEquals("state2", sc.changed["A13824"]?.get("Email"))
    }

    @Test
    fun stateChange_roundTrip() {
        val sc =
            StateChange(
                type = "StateChange",
                changed = mapOf("A1" to mapOf("Mailbox" to "abc", "Email" to "xyz")),
            )
        val decoded = json.decodeFromString<StateChange>(json.encodeToString(sc))
        assertEquals(sc, decoded)
    }

    @Test
    fun stateChange_multipleAccounts() {
        val sc =
            StateChange(
                type = "StateChange",
                changed =
                    mapOf(
                        "A1" to mapOf("Mailbox" to "s1"),
                        "A2" to mapOf("Email" to "s2"),
                    ),
            )
        assertEquals(2, sc.changed.size)
        assertEquals("s1", sc.changed["A1"]?.get("Mailbox"))
        assertEquals("s2", sc.changed["A2"]?.get("Email"))
    }

    @Test
    fun stateChange_emptyChanged() {
        val sc = StateChange(type = "StateChange", changed = emptyMap())
        val decoded = json.decodeFromString<StateChange>(json.encodeToString(sc))
        assertEquals(0, decoded.changed.size)
    }
}
