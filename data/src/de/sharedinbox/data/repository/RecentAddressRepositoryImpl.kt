package de.sharedinbox.data.repository

import de.sharedinbox.core.jmap.mail.EmailAddress
import de.sharedinbox.core.repository.RecentAddress
import de.sharedinbox.core.repository.RecentAddressRepository
import de.sharedinbox.data.db.SharedInboxDatabase
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlin.time.Clock

class RecentAddressRepositoryImpl(
    private val db: SharedInboxDatabase,
) : RecentAddressRepository {
    override suspend fun getRecentAddresses(accountId: String): List<RecentAddress> =
        withContext(Dispatchers.Default) {
            db.recentAddressQueries
                .selectRecentByAccount(accountId)
                .executeAsList()
                .map { it.toDomain() }
        }

    override suspend fun searchAddresses(
        accountId: String,
        query: String,
    ): List<RecentAddress> =
        withContext(Dispatchers.Default) {
            db.recentAddressQueries
                .searchByAccount(accountId, query, query)
                .executeAsList()
                .map { it.toDomain() }
        }

    override suspend fun recordUsage(
        accountId: String,
        address: EmailAddress,
    ) = withContext(Dispatchers.Default) {
        val now = Clock.System.now().toEpochMilliseconds()
        db.recentAddressQueries.transaction {
            db.recentAddressQueries.insertOrIgnoreAddress(
                email = address.email,
                name = address.name,
                account_id = accountId,
                last_used = now,
            )
            db.recentAddressQueries.updateAddressUsage(
                name = address.name,
                last_used = now,
                email = address.email,
                account_id = accountId,
            )
        }
    }
}

private fun de.sharedinbox.data.db.Recent_address.toDomain() =
    RecentAddress(
        email = email,
        name = name,
        useCount = use_count.toInt(),
        lastUsedEpochMillis = last_used,
    )
