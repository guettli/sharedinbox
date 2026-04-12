package de.sharedinbox.core.repository

import de.sharedinbox.core.jmap.mail.Mailbox
import kotlinx.coroutines.flow.Flow

interface MailboxRepository {
    /** Emits the mailbox list for [accountId] from the local DB, re-emits on sync. */
    fun observeMailboxes(accountId: String): Flow<List<Mailbox>>

    /** Runs Mailbox/get + Mailbox/changes against the server and writes results to DB. */
    suspend fun syncMailboxes(accountId: String): Result<Unit>
}
