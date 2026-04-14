package de.sharedinbox.ui.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import de.sharedinbox.core.repository.SyncLogRepository
import de.sharedinbox.core.sync.SyncLogEntry
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

@OptIn(ExperimentalCoroutinesApi::class)
class SyncLogViewModel(
    private val syncLogRepo: SyncLogRepository,
) : ViewModel() {

    private val _accountId = MutableStateFlow<String?>(null)

    val entries = _accountId
        .filterNotNull()
        .flatMapLatest { syncLogRepo.observeLogs(it) }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList<SyncLogEntry>())

    fun init(accountId: String) {
        if (_accountId.value == accountId) return
        _accountId.value = accountId
    }

    fun clearLog() {
        val id = _accountId.value ?: return
        viewModelScope.launch { syncLogRepo.clearLogs(id) }
    }
}
