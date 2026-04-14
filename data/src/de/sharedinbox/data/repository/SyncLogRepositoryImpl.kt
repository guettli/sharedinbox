package de.sharedinbox.data.repository

import app.cash.sqldelight.coroutines.asFlow
import app.cash.sqldelight.coroutines.mapToList
import app.cash.sqldelight.coroutines.mapToOneOrNull
import de.sharedinbox.core.repository.SyncHealth
import de.sharedinbox.core.repository.SyncLogRepository
import de.sharedinbox.core.sync.SyncDirection
import de.sharedinbox.core.sync.SyncLogEntry
import de.sharedinbox.core.sync.SyncStatus
import de.sharedinbox.data.db.SharedInboxDatabase
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.withContext
import kotlin.time.Clock
import kotlin.time.Instant

class SyncLogRepositoryImpl(
    private val db: SharedInboxDatabase,
) : SyncLogRepository {
    override fun observeLogs(accountId: String): Flow<List<SyncLogEntry>> =
        db.syncLogQueries
            .selectLogsByAccount(accountId)
            .asFlow()
            .mapToList(Dispatchers.Default)
            .map { rows -> rows.map { it.toDomain() } }

    override suspend fun log(
        accountId: String,
        direction: SyncDirection,
        operation: String,
        status: SyncStatus,
        detail: String?,
    ): Unit =
        withContext(Dispatchers.Default) {
            db.syncLogQueries.insertSyncLog(
                account_id = accountId,
                occurred_at = Clock.System.now().toEpochMilliseconds(),
                direction = direction.value,
                operation = operation,
                status = status.value,
                detail = detail,
            )
        }

    override suspend fun clearLogs(accountId: String): Unit =
        withContext(Dispatchers.Default) {
            db.syncLogQueries.deleteLogsByAccount(accountId)
        }

    override fun observeSyncHealth(accountId: String): Flow<SyncHealth> {
        val lastSuccessFlow =
            db.syncLogQueries
                .lastSuccessfulSync(accountId)
                .asFlow()
                .mapToOneOrNull(Dispatchers.Default)
                .map { row -> row?.MAX?.let { Instant.fromEpochMilliseconds(it) } }
        val lastErrorFlow =
            db.syncLogQueries
                .lastErrorEntry(accountId)
                .asFlow()
                .mapToOneOrNull(Dispatchers.Default)
                .map { row -> row?.toDomain() }
        return combine(lastSuccessFlow, lastErrorFlow) { lastSuccess, lastError ->
            SyncHealth(lastSuccessAt = lastSuccess, lastError = lastError)
        }
    }
}

private fun de.sharedinbox.data.db.Sync_log.toDomain() =
    SyncLogEntry(
        id = id,
        accountId = account_id,
        occurredAt = Instant.fromEpochMilliseconds(occurred_at),
        direction = SyncDirection.entries.first { it.value == direction },
        operation = operation,
        status = SyncStatus.entries.first { it.value == status },
        detail = detail,
    )
