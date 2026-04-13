package de.sharedinbox.data.repository

import app.cash.sqldelight.coroutines.asFlow
import app.cash.sqldelight.coroutines.mapToList
import de.sharedinbox.core.jmap.mail.Mailbox
import de.sharedinbox.core.jmap.mail.MailboxRights
import de.sharedinbox.core.repository.MailboxRepository
import de.sharedinbox.core.repository.TokenStore
import de.sharedinbox.data.db.SharedInboxDatabase
import de.sharedinbox.data.http.createHttpClient
import de.sharedinbox.data.jmap.JmapApiClient
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map

class MailboxRepositoryImpl(
    private val db: SharedInboxDatabase,
    private val tokenStore: TokenStore,
) : MailboxRepository {

    override fun observeMailboxes(accountId: String): Flow<List<Mailbox>> =
        db.mailboxQueries.selectMailboxesByAccount(accountId)
            .asFlow()
            .mapToList(Dispatchers.IO)
            .map { rows -> rows.map { it.toDomain() } }

    override suspend fun syncMailboxes(accountId: String): Result<Unit> = runCatching {
        val account = db.accountQueries.selectAccount(accountId).executeAsOneOrNull()
            ?: error("Account $accountId not found")
        val credentials = tokenStore.loadCredentials(accountId)
            ?: error("No credentials for account $accountId")
        val httpClient = createHttpClient(credentials.username, credentials.password)
        try {
            val apiClient = JmapApiClient(account.api_url, httpClient)
            val sinceState = db.stateTokenQueries
                .selectStateToken(accountId, "Mailbox")
                .executeAsOneOrNull()
            if (sinceState == null) {
                fullSync(accountId, account.jmap_account_id, apiClient)
            } else {
                incrementalSync(accountId, account.jmap_account_id, apiClient, sinceState)
            }
        } finally {
            httpClient.close()
        }
    }

    private suspend fun fullSync(
        accountId: String,
        jmapAccountId: String,
        apiClient: JmapApiClient,
    ) {
        val result = apiClient.getMailboxes(jmapAccountId)
        db.mailboxQueries.transaction {
            db.mailboxQueries.deleteMailboxesByAccount(accountId)
            result.list.forEach { upsertMailbox(accountId, it) }
            db.stateTokenQueries.upsertStateToken(accountId, "Mailbox", result.state)
        }
    }

    private suspend fun incrementalSync(
        accountId: String,
        jmapAccountId: String,
        apiClient: JmapApiClient,
        sinceState: String,
    ) {
        val changes = apiClient.getMailboxChanges(jmapAccountId, sinceState)
        val toFetch = (changes.created + changes.updated).distinct()

        // Fetch updated/created mailboxes before opening the transaction (suspend not allowed inside).
        val fetched = if (toFetch.isNotEmpty()) {
            apiClient.getMailboxes(jmapAccountId, toFetch).list
        } else {
            emptyList()
        }

        db.mailboxQueries.transaction {
            fetched.forEach { upsertMailbox(accountId, it) }
            changes.destroyed.forEach { db.mailboxQueries.deleteMailbox(accountId, it) }
            db.stateTokenQueries.upsertStateToken(accountId, "Mailbox", changes.newState)
        }

        if (changes.hasMoreChanges) {
            incrementalSync(accountId, jmapAccountId, apiClient, changes.newState)
        }
    }

    private fun upsertMailbox(accountId: String, mailbox: Mailbox) {
        db.mailboxQueries.upsertMailbox(
            id = mailbox.id,
            account_id = accountId,
            name = mailbox.name,
            role = mailbox.role,
            parent_id = mailbox.parentId,
            sort_order = mailbox.sortOrder.toLong(),
            unread_emails = mailbox.unreadEmails.toLong(),
        )
    }
}

private val defaultRights = MailboxRights(
    mayReadItems = true,
    mayAddItems = true,
    mayRemoveItems = true,
    maySetSeen = true,
    maySetKeywords = true,
    mayCreateChild = true,
    mayRename = true,
    mayDelete = true,
    maySubmit = true,
)

private fun de.sharedinbox.data.db.Mailbox.toDomain() = Mailbox(
    id = id,
    name = name,
    parentId = parent_id,
    role = role,
    sortOrder = sort_order.toInt(),
    unreadEmails = unread_emails.toInt(),
    myRights = defaultRights,
)
