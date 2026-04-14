package de.sharedinbox.data.repository

import app.cash.sqldelight.coroutines.asFlow
import app.cash.sqldelight.coroutines.mapToList
import de.sharedinbox.core.account.Account
import de.sharedinbox.core.jmap.JmapCapability
import de.sharedinbox.core.repository.AccountRepository
import de.sharedinbox.core.repository.SessionRepository
import de.sharedinbox.core.repository.TokenStore
import de.sharedinbox.data.db.SharedInboxDatabase
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map
import kotlin.time.Clock
import kotlin.uuid.ExperimentalUuidApi
import kotlin.uuid.Uuid

@OptIn(ExperimentalUuidApi::class)
class AccountRepositoryImpl(
    private val db: SharedInboxDatabase,
    private val tokenStore: TokenStore,
    private val sessionRepository: SessionRepository,
) : AccountRepository {
    override fun observeAccounts(): Flow<List<Account>> =
        db.accountQueries
            .selectAllAccounts()
            .asFlow()
            .mapToList(Dispatchers.IO)
            .map { rows -> rows.map { it.toDomain() } }

    override suspend fun addAccount(
        baseUrl: String,
        username: String,
        password: String,
    ): Result<Account> =
        runCatching {
            val session = sessionRepository.discover(baseUrl, username, password).getOrThrow()
            val jmapAccountId =
                session.primaryAccounts[JmapCapability.MAIL]
                    ?: error("Server at $baseUrl has no JMAP mail account")
            val displayName = session.accounts[jmapAccountId]?.name ?: username
            val accountId = Uuid.random().toString()
            val now = Clock.System.now().toEpochMilliseconds()

            db.accountQueries.insertAccount(
                id = accountId,
                display_name = displayName,
                base_url = baseUrl,
                username = username,
                jmap_account_id = jmapAccountId,
                api_url = session.apiUrl,
                upload_url = session.uploadUrl,
                download_url = session.downloadUrl,
                event_source_url = session.eventSourceUrl,
                added_at = now,
            )
            tokenStore.saveCredentials(accountId, username, password)

            Account(
                id = accountId,
                displayName = displayName,
                baseUrl = baseUrl,
                username = username,
                jmapAccountId = jmapAccountId,
                apiUrl = session.apiUrl,
                uploadUrl = session.uploadUrl,
                downloadUrl = session.downloadUrl,
                eventSourceUrl = session.eventSourceUrl,
                addedAt = now,
            )
        }

    override suspend fun removeAccount(accountId: String) {
        db.accountQueries.deleteAccount(accountId)
        tokenStore.clearCredentials(accountId)
    }

    override suspend fun getCapabilities(accountId: String): Set<String>? {
        val account = db.accountQueries.selectAccount(accountId).executeAsOneOrNull() ?: return null
        val credentials = tokenStore.loadCredentials(accountId) ?: return null
        return sessionRepository
            .discover(account.base_url, credentials.username, credentials.password)
            .getOrNull()
            ?.accounts
            ?.get(account.jmap_account_id)
            ?.accountCapabilities
            ?.keys
    }
}

private fun de.sharedinbox.data.db.Account.toDomain() =
    Account(
        id = id,
        displayName = display_name,
        baseUrl = base_url,
        username = username,
        jmapAccountId = jmap_account_id,
        apiUrl = api_url,
        uploadUrl = upload_url,
        downloadUrl = download_url,
        eventSourceUrl = event_source_url,
        addedAt = added_at,
    )
