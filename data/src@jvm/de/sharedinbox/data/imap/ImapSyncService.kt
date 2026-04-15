package de.sharedinbox.data.imap

import de.sharedinbox.core.jmap.mail.EmailDraft
import de.sharedinbox.core.repository.SyncLogRepository
import de.sharedinbox.core.repository.TokenStore
import de.sharedinbox.core.sync.SyncDirection
import de.sharedinbox.core.sync.SyncStatus
import de.sharedinbox.data.db.SharedInboxDatabase
import io.github.kmpmail.imap.ImapClient
import io.github.kmpmail.imap.ImapSecurity
import io.github.kmpmail.imap.ImapValue
import io.github.kmpmail.mime.MimeMessage
import io.github.kmpmail.mime.buildMime
import io.github.kmpmail.smtp.SmtpClient
import io.github.kmpmail.smtp.SmtpSecurity
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.text.SimpleDateFormat
import java.util.Locale

/**
 * Syncs mailboxes and emails between an IMAP server and the local SQLite DB.
 * Also sends outgoing email via SMTP.
 *
 * Connection parameters are read from the `imap_config` table (populated by
 * an account-setup flow). Credentials are read from [TokenStore].
 *
 * All sync operations are idempotent: re-running them produces the same DB state.
 */
class ImapSyncService(
    private val db: SharedInboxDatabase,
    private val tokenStore: TokenStore,
    private val syncLog: SyncLogRepository,
) {
    private val json = Json { ignoreUnknownKeys = true }

    // ─────────────────────────────────────────────────────────────────────────
    // Mailbox sync
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * LISTs all mailboxes from the IMAP server and upserts them into the DB.
     * Mailboxes present in the DB but absent from IMAP are removed.
     */
    suspend fun syncMailboxes(accountId: String): Result<Unit> =
        runCatching {
            withImapClient(accountId) { client ->
                val remoteMailboxes = client.listMailboxes()
                db.mailboxQueries.transaction {
                    db.mailboxQueries.deleteMailboxesByAccount(accountId)
                    remoteMailboxes.forEachIndexed { index, entry ->
                        db.mailboxQueries.upsertMailbox(
                            id = entry.name,
                            account_id = accountId,
                            name = entry.name,
                            role = roleFromAttributes(entry.attributes, entry.name),
                            parent_id = null,
                            sort_order = index.toLong(),
                            unread_emails = 0,
                        )
                    }
                }
            }
            syncLog.log(
                accountId = accountId,
                direction = SyncDirection.SERVER_TO_DB,
                operation = "imap_sync_mailboxes",
                status = SyncStatus.SUCCESS,
            )
        }.onFailure { e ->
            syncLog.log(
                accountId = accountId,
                direction = SyncDirection.SERVER_TO_DB,
                operation = "imap_sync_mailboxes",
                status = SyncStatus.ERROR,
                detail = e.message,
            )
        }

    // ─────────────────────────────────────────────────────────────────────────
    // Email sync
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Fetches new messages in [mailboxName] from the IMAP server and writes them
     * to the DB. Uses UIDVALIDITY + UIDNEXT state tokens for incremental syncs.
     * Also syncs flag changes (\\Seen, \\Flagged, etc.) for all messages in DB.
     */
    suspend fun syncEmails(
        accountId: String,
        mailboxName: String,
    ): Result<Unit> =
        runCatching {
            withImapClient(accountId) { client ->
                val info = client.select(mailboxName)
                val uidValidity = info.uidValidity ?: 0L

                // Full resync when UIDVALIDITY changed (server was rebuilt).
                val storedValidity =
                    db.stateTokenQueries
                        .selectStateToken(accountId, uidValidityKey(mailboxName))
                        .executeAsOneOrNull()
                if (storedValidity != null && storedValidity != uidValidity.toString()) {
                    db.emailHeaderQueries.deleteEmailHeadersByAccount(accountId)
                }

                // Fetch messages since last synced UIDNEXT.
                val lastUidNext =
                    db.stateTokenQueries
                        .selectStateToken(accountId, uidNextKey(mailboxName))
                        .executeAsOneOrNull()
                        ?.toLongOrNull() ?: 1L

                if (info.exists > 0) {
                    val searchedUids = client.search("UID $lastUidNext:*")
                    val newUids = searchedUids.filter { it >= lastUidNext }
                    if (newUids.isNotEmpty()) {
                        val uidSet = newUids.joinToString(",")
                        val messages = client.fetchMessages(uidSet)
                        db.emailHeaderQueries.transaction {
                            for (msg in messages) {
                                val emailId = emailId(accountId, uidValidity, msg.uid)
                                val mime = msg.message
                                db.emailHeaderQueries.upsertEmailHeader(
                                    id = emailId,
                                    account_id = accountId,
                                    thread_id = mime.messageId ?: emailId,
                                    mailbox_id = mailboxName,
                                    subject = mime.subject,
                                    from_address = mime.from?.let { parseFromHeader(it) },
                                    received_at = parseDateMillis(mime.date),
                                    keywords = json.encodeToString(msg.flags),
                                    has_attachment = if (mime.hasNonTextParts()) 1L else 0L,
                                    preview = mime.textBody?.take(200),
                                    blob_id = "",
                                )
                                db.emailBodyQueries.upsertEmailBody(
                                    email_id = emailId,
                                    account_id = accountId,
                                    text_body = mime.textBody,
                                    html_body = mime.htmlBody,
                                )
                            }
                        }
                    }

                    // Sync flag changes for messages already in DB.
                    syncFlagsInMailbox(accountId, mailboxName, uidValidity, client)
                }

                // Persist state tokens.
                val newUidNext = info.uidNext ?: (lastUidNext + info.exists)
                db.stateTokenQueries.upsertStateToken(
                    accountId,
                    uidValidityKey(mailboxName),
                    uidValidity.toString(),
                )
                db.stateTokenQueries.upsertStateToken(
                    accountId,
                    uidNextKey(mailboxName),
                    newUidNext.toString(),
                )
            }
            syncLog.log(
                accountId = accountId,
                direction = SyncDirection.SERVER_TO_DB,
                operation = "imap_sync_emails:$mailboxName",
                status = SyncStatus.SUCCESS,
            )
        }.onFailure { e ->
            syncLog.log(
                accountId = accountId,
                direction = SyncDirection.SERVER_TO_DB,
                operation = "imap_sync_emails:$mailboxName",
                status = SyncStatus.ERROR,
                detail = e.message,
            )
        }

    // ─────────────────────────────────────────────────────────────────────────
    // Flag sync
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Fetches current FLAGS for all messages in [mailboxName] from the IMAP server
     * and updates the DB for any that differ.
     */
    suspend fun syncFlags(
        accountId: String,
        mailboxName: String,
    ): Result<Unit> =
        runCatching {
            withImapClient(accountId) { client ->
                client.select(mailboxName)
                val uidValidity =
                    db.stateTokenQueries
                        .selectStateToken(accountId, uidValidityKey(mailboxName))
                        .executeAsOneOrNull()
                        ?.toLongOrNull() ?: return@withImapClient
                syncFlagsInMailbox(accountId, mailboxName, uidValidity, client)
            }
        }

    private suspend fun syncFlagsInMailbox(
        accountId: String,
        mailboxName: String,
        uidValidity: Long,
        client: ImapClient,
    ) {
        val flagResponses = client.uidFetch("1:*", "(UID FLAGS)")
        for (r in flagResponses) {
            val attrList = r.values.firstOrNull()?.asList() ?: continue
            val attrs = extractAttrsMap(attrList)
            val uid = (attrs["UID"] as? ImapValue.Num)?.value ?: continue
            val flags =
                (attrs["FLAGS"] as? ImapValue.Lst)
                    ?.items
                    ?.mapNotNull { it.asString() } ?: continue
            val emailId = emailId(accountId, uidValidity, uid)
            db.emailHeaderQueries.updateEmailKeywords(
                keywords = json.encodeToString(flags),
                account_id = accountId,
                id = emailId,
            )
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Send email
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Builds a MIME message from [draft] and delivers it via the SMTP server
     * configured for [accountId].
     */
    suspend fun sendEmail(
        accountId: String,
        draft: EmailDraft,
    ): Result<Unit> =
        runCatching {
            val config =
                db.imapConfigQueries.selectImapConfig(accountId).executeAsOneOrNull()
                    ?: error("No IMAP config for account $accountId")
            val credentials =
                tokenStore.loadCredentials(accountId)
                    ?: error("No credentials for account $accountId")

            val rawMessage =
                buildMime {
                    from(draft.from.toMimeAddress())
                    draft.to.forEach { to(it.toMimeAddress()) }
                    draft.cc.forEach { cc(it.toMimeAddress()) }
                    subject(draft.subject)
                    textBody(draft.textBody)
                }

            val smtpClient =
                SmtpClient {
                    host = config.smtp_host
                    port = config.smtp_port.toInt()
                    security = SmtpSecurity.valueOf(config.smtp_security)
                    credentials(credentials.username, credentials.password)
                }
            smtpClient.connect()
            try {
                smtpClient.send(
                    rawMessage = rawMessage,
                    from = credentials.username,
                    to = (draft.to + draft.cc).map { it.email },
                )
            } finally {
                smtpClient.disconnect()
            }
            syncLog.log(
                accountId = accountId,
                direction = SyncDirection.DB_TO_SERVER,
                operation = "imap_send_email",
                status = SyncStatus.SUCCESS,
            )
        }.onFailure { e ->
            syncLog.log(
                accountId = accountId,
                direction = SyncDirection.DB_TO_SERVER,
                operation = "imap_send_email",
                status = SyncStatus.ERROR,
                detail = e.message,
            )
        }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal helpers
    // ─────────────────────────────────────────────────────────────────────────

    private suspend fun withImapClient(
        accountId: String,
        block: suspend (ImapClient) -> Unit,
    ) {
        val config =
            db.imapConfigQueries.selectImapConfig(accountId).executeAsOneOrNull()
                ?: error("No IMAP config for account $accountId")
        val credentials =
            tokenStore.loadCredentials(accountId)
                ?: error("No credentials for account $accountId")

        val client =
            ImapClient {
                host = config.imap_host
                port = config.imap_port.toInt()
                security = ImapSecurity.valueOf(config.imap_security)
                username = credentials.username
                password = credentials.password
            }
        client.connect()
        try {
            block(client)
        } finally {
            client.disconnect()
        }
    }

    private fun emailId(
        accountId: String,
        uidValidity: Long,
        uid: Long,
    ) = "$accountId:$uidValidity:$uid"

    private fun uidValidityKey(mailboxName: String) = "IMAP_${mailboxName}_UIDVALIDITY"

    private fun uidNextKey(mailboxName: String) = "IMAP_${mailboxName}_UIDNEXT"

    /** Derives a JMAP-style mailbox role from RFC 6154 special-use flags or well-known names. */
    private fun roleFromAttributes(
        attrs: List<String>,
        name: String,
    ): String? {
        val specialUse = attrs.firstOrNull { it.startsWith("\\") && it.length > 1 }
        return when (specialUse?.lowercase()) {
            "\\inbox" -> "inbox"
            "\\sent" -> "sent"
            "\\drafts" -> "drafts"
            "\\trash" -> "trash"
            "\\junk" -> "junk"
            "\\archive" -> "archive"
            else ->
                when (name.lowercase()) {
                    "inbox" -> "inbox"
                    "sent", "sent items", "sent messages" -> "sent"
                    "drafts" -> "drafts"
                    "trash", "deleted", "deleted items" -> "trash"
                    "junk", "spam" -> "junk"
                    "archive" -> "archive"
                    else -> null
                }
        }
    }

    /**
     * Parses an RFC 2822 Date header to epoch millis.
     * Returns the current time if parsing fails.
     */
    private fun parseDateMillis(raw: String?): Long {
        raw ?: return System.currentTimeMillis()
        val formats =
            listOf(
                "EEE, dd MMM yyyy HH:mm:ss Z",
                "dd MMM yyyy HH:mm:ss Z",
                "EEE, dd MMM yyyy HH:mm:ss z",
            )
        for (fmt in formats) {
            runCatching {
                SimpleDateFormat(fmt, Locale.ENGLISH).parse(raw)?.time
            }.getOrNull()?.let { return it }
        }
        return System.currentTimeMillis()
    }

    /**
     * Encodes a raw RFC 5322 From header value as a JSON array for the DB.
     * e.g. "Alice <alice@example.com>" → `[{"name":"Alice","email":"alice@example.com"}]`
     */
    private fun parseFromHeader(raw: String): String {
        val angleStart = raw.indexOf('<')
        val angleEnd = raw.indexOf('>')
        return if (angleStart >= 0 && angleEnd > angleStart) {
            val email = raw.substring(angleStart + 1, angleEnd).trim()
            val name = raw.substring(0, angleStart).trim().removeSurrounding("\"")
            if (name.isNotEmpty()) {
                """[{"name":${json.encodeToString(name)},"email":${json.encodeToString(email)}}]"""
            } else {
                """[{"email":${json.encodeToString(email)}}]"""
            }
        } else {
            """[{"email":${json.encodeToString(raw.trim())}}]"""
        }
    }

    private fun MimeMessage.hasNonTextParts(): Boolean =
        allParts.any { part ->
            val ct = part.headers.contentType
            ct != null && !(ct.type == "text" && ct.subtype in listOf("plain", "html"))
        }

    /** Extracts a flat attr-name → value map from a FETCH response attr list. */
    private fun extractAttrsMap(items: List<ImapValue>): Map<String, ImapValue> {
        val result = mutableMapOf<String, ImapValue>()
        var i = 0
        while (i < items.size - 1) {
            val item = items[i]
            if (item is ImapValue.Atom) {
                val name = item.value.uppercase()
                val next = items.getOrNull(i + 1)
                if (next != null) {
                    result[name] = next
                    i += 2
                    continue
                }
            }
            i++
        }
        return result
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Extension helpers
// ─────────────────────────────────────────────────────────────────────────────

private fun de.sharedinbox.core.jmap.mail.EmailAddress.toMimeAddress(): String = if (name != null) "$name <$email>" else email
