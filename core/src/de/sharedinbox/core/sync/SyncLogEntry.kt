package de.sharedinbox.core.sync

import kotlin.time.Instant

enum class SyncDirection(val value: String) {
    SERVER_TO_DB("server_to_db"),
    DB_TO_SERVER("db_to_server"),
}

enum class SyncStatus(val value: String) {
    SUCCESS("success"),
    CONFLICT("conflict"),
    ERROR("error"),
}

data class SyncLogEntry(
    val id: Long,
    val accountId: String,
    val occurredAt: Instant,
    val direction: SyncDirection,
    val operation: String,
    val status: SyncStatus,
    val detail: String?,
)
