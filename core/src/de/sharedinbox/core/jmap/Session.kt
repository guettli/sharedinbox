package de.sharedinbox.core.jmap

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonObject

/** RFC 8620 §2 — Session resource returned by GET /.well-known/jmap */
@Serializable
data class JmapSession(
    val username: String,
    val apiUrl: String,
    val downloadUrl: String,
    val uploadUrl: String,
    val eventSourceUrl: String,
    val state: String,
    val accounts: Map<String, JmapAccount>,
    val primaryAccounts: Map<String, String>,
    val capabilities: Map<String, JsonObject>,
)

@Serializable
data class JmapAccount(
    val name: String,
    val isPersonal: Boolean,
    val isReadOnly: Boolean,
    val accountCapabilities: Map<String, JsonObject>,
)

/** JMAP capability URNs (RFC 8620 / RFC 8621 / RFC 9610) */
object JmapCapability {
    const val CORE = "urn:ietf:params:jmap:core"
    const val MAIL = "urn:ietf:params:jmap:mail"
    const val SUBMISSION = "urn:ietf:params:jmap:submission"

    /** RFC 9610 — JMAP for Contacts (CardDAV replacement) */
    const val CONTACTS = "urn:ietf:params:jmap:contacts"

    /** JMAP Sieve — server-side mail filtering scripts */
    const val SIEVE = "urn:ietf:params:jmap:sieve"
}
