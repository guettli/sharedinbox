package de.sharedinbox.core.repository

import de.sharedinbox.core.jmap.mail.Mailbox
import kotlinx.coroutines.flow.Flow

interface MailboxRepository {
    /** Emits the mailbox list for [accountId] from the local DB, re-emits on sync. */
    fun observeMailboxes(accountId: String): Flow<List<Mailbox>>

    /** Runs Mailbox/get + Mailbox/changes against the server and writes results to DB. */
    suspend fun syncMailboxes(accountId: String): Result<Unit>

    /**
     * Creates a new mailbox on the server and stores it locally.
     *
     * Returns [Result.failure] with a descriptive message when the server rejects the
     * creation (e.g. due to insufficient permissions). The failure is also recorded in
     * the sync log so the user can review it.
     */
    suspend fun createMailbox(accountId: String, name: String, parentId: String? = null): Result<Mailbox>

    /**
     * Renames [mailboxId] to [newName] on the server and updates the local DB.
     *
     * Conflicts (server rejection) are logged and surfaced as [Result.failure].
     */
    suspend fun renameMailbox(accountId: String, mailboxId: String, newName: String): Result<Unit>

    /**
     * Deletes [mailboxId] on the server and removes it from the local DB.
     *
     * Conflicts (server rejection, e.g. non-empty mailbox) are logged and surfaced
     * as [Result.failure].
     */
    suspend fun deleteMailbox(accountId: String, mailboxId: String): Result<Unit>
}
