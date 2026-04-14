package de.sharedinbox.core.repository

import de.sharedinbox.core.sync.SyncDirection
import de.sharedinbox.core.sync.SyncLogEntry
import de.sharedinbox.core.sync.SyncStatus
import kotlinx.coroutines.flow.Flow

interface SyncLogRepository {
    /** Emits the most recent 200 log entries for [accountId], newest first. */
    fun observeLogs(accountId: String): Flow<List<SyncLogEntry>>

    /** Appends one entry to the log. */
    suspend fun log(
        accountId: String,
        direction: SyncDirection,
        operation: String,
        status: SyncStatus,
        detail: String? = null,
    )

    /** Removes all log entries for [accountId]. */
    suspend fun clearLogs(accountId: String)
}
