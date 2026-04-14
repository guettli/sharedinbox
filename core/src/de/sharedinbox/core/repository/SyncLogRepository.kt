package de.sharedinbox.core.repository

import de.sharedinbox.core.sync.SyncDirection
import de.sharedinbox.core.sync.SyncLogEntry
import de.sharedinbox.core.sync.SyncStatus
import kotlinx.coroutines.flow.Flow
import kotlin.time.Instant

/**
 * A snapshot of the recent sync health for one account.
 *
 * [lastSuccessAt] — the timestamp of the most recent successful sync operation,
 * or null if none has been recorded yet.
 *
 * [lastError] — the most recent log entry with status ERROR, or null when the
 * last known sync was clean.
 */
data class SyncHealth(
    val lastSuccessAt: Instant?,
    val lastError: SyncLogEntry?,
)

interface SyncLogRepository {
    /** Emits the most recent 200 log entries for [accountId], newest first. */
    fun observeLogs(accountId: String): Flow<List<SyncLogEntry>>

    /**
     * Emits the current sync health for [accountId] and re-emits whenever the
     * sync log changes (e.g. after a background sync completes or fails).
     */
    fun observeSyncHealth(accountId: String): Flow<SyncHealth>

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
