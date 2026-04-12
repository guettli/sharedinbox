package de.sharedinbox.core.account

/**
 * A locally-configured JMAP server connection.
 * Every DB table has an account_id FK referencing this.
 * [jmapAccountId] is the remote JMAP accountId returned by the session resource —
 * distinct from [id] which is our local UUID.
 */
data class Account(
    val id: String,
    val displayName: String,
    val baseUrl: String,         // e.g. "https://mail.example.com" or "http://localhost:8080"
    val username: String,
    val jmapAccountId: String,
    val apiUrl: String,
    val uploadUrl: String,
    val downloadUrl: String,
    val eventSourceUrl: String,
    val addedAt: Long,           // epoch millis
)
