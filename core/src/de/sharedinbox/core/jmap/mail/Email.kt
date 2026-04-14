package de.sharedinbox.core.jmap.mail

import kotlinx.serialization.Serializable
import kotlin.time.Instant

/** RFC 8621 §4 */
@Serializable
data class Email(
    val id: String,
    val blobId: String,
    val threadId: String,
    val mailboxIds: Map<String, Boolean>,
    val keywords: Map<String, Boolean> = emptyMap(),
    val subject: String? = null,
    val sentAt: Instant? = null,
    val receivedAt: Instant,
    val from: List<EmailAddress>? = null,
    val to: List<EmailAddress>? = null,
    val cc: List<EmailAddress>? = null,
    val replyTo: List<EmailAddress>? = null,
    val preview: String? = null,
    val hasAttachment: Boolean = false,
    // body — only present when explicitly requested via Email/get bodyProperties
    val bodyValues: Map<String, EmailBodyValue> = emptyMap(),
    val htmlBody: List<EmailBodyPart> = emptyList(),
    val textBody: List<EmailBodyPart> = emptyList(),
    val attachments: List<EmailBodyPart> = emptyList(),
)

@Serializable
data class EmailAddress(
    val name: String? = null,
    val email: String,
)

@Serializable
data class EmailBodyValue(
    val value: String,
    val isEncodingProblem: Boolean = false,
    val isTruncated: Boolean = false,
)

@Serializable
data class EmailBodyPart(
    val partId: String? = null,
    val blobId: String? = null,
    val type: String,
    val charset: String? = null,
    val name: String? = null,
    val size: Long? = null,
    val disposition: String? = null,
    /** RFC 8621 §4.1.5 — the Content-ID header value, used for CID-referenced inline images. */
    val cid: String? = null,
)

/** Outgoing email — used for send/reply (not a JMAP wire type, local only) */
data class EmailDraft(
    val from: EmailAddress,
    val to: List<EmailAddress>,
    val cc: List<EmailAddress> = emptyList(),
    val subject: String,
    val textBody: String,
    val inReplyToEmailId: String? = null,
)

/** Standard JMAP keywords (RFC 8621 §4.1.1) */
object EmailKeyword {
    const val SEEN = "\$seen"
    const val FLAGGED = "\$flagged"
    const val ANSWERED = "\$answered"
    const val DRAFT = "\$draft"
}
