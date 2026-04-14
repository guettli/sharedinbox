package de.sharedinbox.core.repository

import de.sharedinbox.core.jmap.mail.Email
import de.sharedinbox.core.jmap.mail.EmailBodyPart
import de.sharedinbox.core.jmap.mail.EmailDraft
import kotlinx.coroutines.flow.Flow

interface EmailRepository {
    /** Emits email headers in [mailboxId] for [accountId] from the local DB. */
    fun observeEmails(
        accountId: String,
        mailboxId: String,
    ): Flow<List<Email>>

    /** Syncs email headers for [mailboxId] via Email/query + Email/get. */
    suspend fun syncEmails(
        accountId: String,
        mailboxId: String,
    ): Result<Unit>

    /**
     * Returns a full [Email] including body, fetching from server on first access
     * and caching in the local DB thereafter.
     */
    suspend fun getEmail(
        accountId: String,
        emailId: String,
    ): Result<Email>

    /** Sets or clears [keyword] (e.g. [EmailKeyword.SEEN]) on [emailId]. */
    suspend fun setKeyword(
        accountId: String,
        emailId: String,
        keyword: String,
        set: Boolean,
    ): Result<Unit>

    /** Moves [emailId] to [toMailboxId]. */
    suspend fun moveEmail(
        accountId: String,
        emailId: String,
        toMailboxId: String,
    ): Result<Unit>

    /** Sends [draft] via Email/set create + blob upload + EmailSubmission/set. */
    suspend fun sendEmail(
        accountId: String,
        draft: EmailDraft,
    ): Result<Unit>

    /** Moves [emailId] to the account's trash mailbox, or permanently deletes if already there. */
    suspend fun deleteEmail(
        accountId: String,
        emailId: String,
    ): Result<Unit>

    /** Moves [emailId] to the archive mailbox. No-op if no archive mailbox exists. */
    suspend fun archiveEmail(
        accountId: String,
        emailId: String,
    ): Result<Unit>

    /** Moves [emailId] to the junk/spam mailbox. No-op if no junk mailbox exists. */
    suspend fun markAsSpam(
        accountId: String,
        emailId: String,
    ): Result<Unit>

    /** Returns the list of attachment parts for [emailId] (always fetched from server). */
    suspend fun getAttachments(
        accountId: String,
        emailId: String,
    ): Result<List<EmailBodyPart>>

    /** Downloads the raw bytes of a blob (attachment). */
    suspend fun downloadBlob(
        accountId: String,
        blobId: String,
        mimeType: String,
    ): Result<ByteArray>

    /**
     * Searches email headers in the local DB for [accountId] matching [query].
     *
     * Matches against subject, sender address, and preview text (case-insensitive substring).
     * Returns at most 200 results, newest first. Never hits the network.
     */
    suspend fun searchEmails(
        accountId: String,
        query: String,
    ): Result<List<Email>>
}
