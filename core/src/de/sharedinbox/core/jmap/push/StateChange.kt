package de.sharedinbox.core.jmap.push

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * RFC 8620 §7.3 — pushed over the EventSource connection when server state changes.
 * [changed] maps accountId → (typeName → newState), e.g.:
 *   { "A13824": { "Mailbox": "abc", "Email": "xyz" } }
 */
@Serializable
data class StateChange(
    @SerialName("@type") val type: String,
    val changed: Map<String, Map<String, String>>,
)
