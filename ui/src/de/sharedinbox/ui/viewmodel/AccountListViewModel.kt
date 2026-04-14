package de.sharedinbox.ui.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import de.sharedinbox.core.repository.AccountRepository
import de.sharedinbox.data.sync.AccountSyncManager
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

class AccountListViewModel(
    private val accountRepo: AccountRepository,
    private val syncManager: AccountSyncManager,
) : ViewModel() {
    val accounts =
        accountRepo
            .observeAccounts()
            .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())

    /**
     * Capabilities per account, keyed by accountId.
     * null = not yet loaded; empty set = loaded but none returned.
     */
    private val _capabilities = MutableStateFlow<Map<String, Set<String>>>(emptyMap())
    val capabilities: StateFlow<Map<String, Set<String>>> = _capabilities.asStateFlow()

    /** Fetches and caches the server capabilities for [accountId]. */
    fun loadCapabilities(accountId: String) {
        if (accountId in _capabilities.value) return
        viewModelScope.launch {
            val caps = accountRepo.getCapabilities(accountId) ?: emptySet()
            _capabilities.value = _capabilities.value + (accountId to caps)
        }
    }

    init {
        // Track account additions/removals and start/stop SSE accordingly.
        viewModelScope.launch {
            var previousIds = emptySet<String>()
            accountRepo.observeAccounts().collect { list ->
                val currentIds = list.map { it.id }.toSet()
                (previousIds - currentIds).forEach { syncManager.stopAccount(it) }
                (currentIds - previousIds).forEach { syncManager.startAccount(it) }
                previousIds = currentIds
            }
        }
    }

    fun removeAccount(accountId: String) =
        viewModelScope.launch {
            syncManager.stopAccount(accountId)
            accountRepo.removeAccount(accountId)
        }

    override fun onCleared() {
        syncManager.stopAll()
    }
}
