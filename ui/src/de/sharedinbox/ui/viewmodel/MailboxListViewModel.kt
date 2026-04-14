package de.sharedinbox.ui.viewmodel

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import de.sharedinbox.core.repository.MailboxRepository
import de.sharedinbox.core.repository.SyncHealth
import de.sharedinbox.core.repository.SyncLogRepository
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlin.time.Clock
import kotlin.time.Duration.Companion.minutes
import kotlin.time.Instant

/** Ticks every [intervalMs] milliseconds so time-based UI stays fresh. */
internal fun tickerFlow(intervalMs: Long = 60_000L): Flow<Instant> =
    flow {
        while (true) {
            emit(Clock.System.now())
            delay(intervalMs)
        }
    }

@OptIn(ExperimentalCoroutinesApi::class)
class MailboxListViewModel(
    private val mailboxRepo: MailboxRepository,
    private val syncLogRepo: SyncLogRepository,
) : ViewModel() {
    private val _accountId = MutableStateFlow("")

    val mailboxes =
        _accountId
            .filter { it.isNotBlank() }
            .flatMapLatest { mailboxRepo.observeMailboxes(it) }
            .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())

    /**
     * Combines DB-backed sync health with a 1-minute clock tick so the "stale"
     * warning appears even when no new log entries arrive.
     *
     * [syncStale] — true when the last successful sync is older than 1 hour.
     * [syncError] — description of the most recent error entry, or null.
     */
    data class SyncWarning(
        val syncStale: Boolean,
        val syncError: String?,
    )

    val syncWarning =
        _accountId
            .filter { it.isNotBlank() }
            .flatMapLatest { accountId ->
                combine(
                    syncLogRepo.observeSyncHealth(accountId),
                    tickerFlow(),
                ) { health, now ->
                    toWarning(health, now)
                }
            }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), SyncWarning(false, null))

    var isLoading by mutableStateOf(false)
    var error by mutableStateOf<String?>(null)

    fun init(accountId: String) {
        if (_accountId.value == accountId) return
        _accountId.value = accountId
        sync()
    }

    fun refresh() {
        error = null
        sync()
    }

    private fun sync() =
        viewModelScope.launch {
            if (_accountId.value.isBlank()) return@launch
            isLoading = true
            error = null
            mailboxRepo
                .syncMailboxes(_accountId.value)
                .onFailure { error = it.message ?: "Sync failed" }
            isLoading = false
        }
}

private fun toWarning(
    health: SyncHealth,
    now: Instant,
): MailboxListViewModel.SyncWarning {
    val stale = health.lastSuccessAt == null || (now - health.lastSuccessAt) > 60.minutes
    val errorMsg =
        health.lastError?.let { err ->
            buildString {
                append(err.operation.replace('_', ' '))
                if (err.detail != null) append(": ${err.detail}")
            }
        }
    return MailboxListViewModel.SyncWarning(syncStale = stale, syncError = errorMsg)
}
