package de.sharedinbox.core.jmap.mail

import kotlinx.serialization.Serializable

/** RFC 8621 §2 */
@Serializable
data class Mailbox(
    val id: String,
    val name: String,
    val parentId: String? = null,
    val role: String? = null, // "inbox", "sent", "trash", "drafts", "archive", …
    val sortOrder: Int = 0,
    val totalEmails: Int = 0,
    val unreadEmails: Int = 0,
    val totalThreads: Int = 0,
    val unreadThreads: Int = 0,
    val myRights: MailboxRights,
    val isSubscribed: Boolean = false,
)

@Serializable
data class MailboxRights(
    val mayReadItems: Boolean,
    val mayAddItems: Boolean,
    val mayRemoveItems: Boolean,
    val maySetSeen: Boolean,
    val maySetKeywords: Boolean,
    val mayCreateChild: Boolean,
    val mayRename: Boolean,
    val mayDelete: Boolean,
    val maySubmit: Boolean,
)

/** Well-known mailbox roles (RFC 8621 §2) */
object MailboxRole {
    const val INBOX = "inbox"
    const val SENT = "sent"
    const val TRASH = "trash"
    const val DRAFTS = "drafts"
    const val ARCHIVE = "archive"
    const val SPAM = "junk"
}
