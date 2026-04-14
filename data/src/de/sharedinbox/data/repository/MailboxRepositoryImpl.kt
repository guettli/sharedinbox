package de.sharedinbox.data.repository

import app.cash.sqldelight.coroutines.asFlow
import app.cash.sqldelight.coroutines.mapToList
import de.sharedinbox.core.jmap.mail.Mailbox
import de.sharedinbox.core.jmap.mail.MailboxRights
import de.sharedinbox.core.repository.MailboxRepository
import de.sharedinbox.core.repository.SyncLogRepository
import de.sharedinbox.core.repository.TokenStore
import de.sharedinbox.core.sync.SyncDirection
import de.sharedinbox.core.sync.SyncStatus
import de.sharedinbox.data.db.SharedInboxDatabase
import de.sharedinbox.data.http.createHttpClient
import de.sharedinbox.data.jmap.JmapApiClient
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

class MailboxRepositoryImpl(
    private val db: SharedInboxDatabase,
    private val tokenStore: TokenStore,
    private val syncLog: SyncLogRepository,
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
            syncLog.log(
                accountId = accountId,
                direction = SyncDirection.SERVER_TO_DB,
                operation = "sync_mailboxes",
                status = SyncStatus.SUCCESS,
            )
        } catch (e: Exception) {
            syncLog.log(
                accountId = accountId,
                direction = SyncDirection.SERVER_TO_DB,
                operation = "sync_mailboxes",
                status = SyncStatus.ERROR,
                detail = e.message,
            )
            throw e
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

    // ── Mutations (DB → Server) ───────────────────────────────────────────────

    override suspend fun createMailbox(
        accountId: String,
        name: String,
        parentId: String?,
    ): Result<Mailbox> = runCatching {
        withApiClient(accountId) { apiClient, account ->
            val result = apiClient.mailboxSet(account.jmap_account_id, buildJsonObject {
                put("create", buildJsonObject {
                    put("new1", buildJsonObject {
                        put("name", name)
                        if (parentId != null) put("parentId", parentId)
                    })
                })
            })

            if (result.notCreated.isNotEmpty()) {
                val detail = result.notCreated.entries.joinToString { (_, e) ->
                    "${e.type}: ${e.description ?: "no description"}"
                }
                syncLog.log(
                    accountId = accountId,
                    direction = SyncDirection.DB_TO_SERVER,
                    operation = "create_mailbox",
                    status = SyncStatus.CONFLICT,
                    detail = "name=$name — $detail",
                )
                error("Server rejected mailbox creation '$name': $detail")
            }

            // Parse the server-assigned id from the created response
            val createdObj = result.created["new1"]
                ?: error("Server returned no created mailbox for 'new1'")
            val serverId = (createdObj["id"] as? JsonPrimitive)?.content
                ?: error("Server did not return an id for the new mailbox")

            // Fetch the canonical mailbox object (server may set sortOrder, role, etc.)
            val fetched = apiClient.getMailboxes(account.jmap_account_id, listOf(serverId))
            val mailbox = fetched.list.firstOrNull()
                ?: Mailbox(
                    id = serverId,
                    name = name,
                    parentId = parentId,
                    role = null,
                    sortOrder = 0,
                    unreadEmails = 0,
                    myRights = defaultRights,
                )

            upsertMailbox(accountId, mailbox)
            syncLog.log(
                accountId = accountId,
                direction = SyncDirection.DB_TO_SERVER,
                operation = "create_mailbox",
                status = SyncStatus.SUCCESS,
                detail = "name=$name id=$serverId",
            )
            mailbox
        }
    }

    override suspend fun renameMailbox(
        accountId: String,
        mailboxId: String,
        newName: String,
    ): Result<Unit> = runCatching {
        withApiClient(accountId) { apiClient, account ->
            val result = apiClient.mailboxSet(account.jmap_account_id, buildJsonObject {
                put("update", buildJsonObject {
                    put(mailboxId, buildJsonObject { put("name", newName) })
                })
            })

            if (result.notUpdated.isNotEmpty()) {
                val detail = result.notUpdated.entries.joinToString { (_, e) ->
                    "${e.type}: ${e.description ?: "no description"}"
                }
                syncLog.log(
                    accountId = accountId,
                    direction = SyncDirection.DB_TO_SERVER,
                    operation = "rename_mailbox",
                    status = SyncStatus.CONFLICT,
                    detail = "mailboxId=$mailboxId newName=$newName — $detail",
                )
                error("Server rejected rename of '$mailboxId' to '$newName': $detail")
            }

            db.mailboxQueries.selectMailbox(accountId, mailboxId).executeAsOneOrNull()?.let {
                db.mailboxQueries.upsertMailbox(
                    id = it.id,
                    account_id = accountId,
                    name = newName,
                    role = it.role,
                    parent_id = it.parent_id,
                    sort_order = it.sort_order,
                    unread_emails = it.unread_emails,
                )
            }
            syncLog.log(
                accountId = accountId,
                direction = SyncDirection.DB_TO_SERVER,
                operation = "rename_mailbox",
                status = SyncStatus.SUCCESS,
                detail = "mailboxId=$mailboxId newName=$newName",
            )
        }
    }

    override suspend fun deleteMailbox(
        accountId: String,
        mailboxId: String,
    ): Result<Unit> = runCatching {
        withApiClient(accountId) { apiClient, account ->
            val result = apiClient.mailboxSet(account.jmap_account_id, buildJsonObject {
                put("destroy", kotlinx.serialization.json.buildJsonArray { add(mailboxId) })
            })

            if (result.notDestroyed.isNotEmpty()) {
                val detail = result.notDestroyed.entries.joinToString { (_, e) ->
                    "${e.type}: ${e.description ?: "no description"}"
                }
                syncLog.log(
                    accountId = accountId,
                    direction = SyncDirection.DB_TO_SERVER,
                    operation = "delete_mailbox",
                    status = SyncStatus.CONFLICT,
                    detail = "mailboxId=$mailboxId — $detail",
                )
                error("Server rejected deletion of '$mailboxId': $detail")
            }

            db.mailboxQueries.deleteMailbox(accountId, mailboxId)
            syncLog.log(
                accountId = accountId,
                direction = SyncDirection.DB_TO_SERVER,
                operation = "delete_mailbox",
                status = SyncStatus.SUCCESS,
                detail = "mailboxId=$mailboxId",
            )
        }
    }

    // ── helpers ───────────────────────────────────────────────────────────────

    private suspend fun <T> withApiClient(
        accountId: String,
        block: suspend (JmapApiClient, de.sharedinbox.data.db.Account) -> T,
    ): T {
        val account = db.accountQueries.selectAccount(accountId).executeAsOneOrNull()
            ?: error("Account $accountId not found")
        val credentials = tokenStore.loadCredentials(accountId)
            ?: error("No credentials for account $accountId")
        val httpClient = createHttpClient(credentials.username, credentials.password)
        return try {
            block(JmapApiClient(account.api_url, httpClient), account)
        } finally {
            httpClient.close()
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
