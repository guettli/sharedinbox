package de.sharedinbox.ui.viewmodel

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import de.sharedinbox.core.repository.MailboxRepository
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

@OptIn(ExperimentalCoroutinesApi::class)
class MailboxListViewModel(
    private val mailboxRepo: MailboxRepository,
) : ViewModel() {

    private val _accountId = MutableStateFlow("")

    val mailboxes = _accountId
        .filter { it.isNotBlank() }
        .flatMapLatest { mailboxRepo.observeMailboxes(it) }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())

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

    private fun sync() = viewModelScope.launch {
        if (_accountId.value.isBlank()) return@launch
        isLoading = true
        error = null
        mailboxRepo.syncMailboxes(_accountId.value)
            .onFailure { error = it.message ?: "Sync failed" }
        isLoading = false
    }
}
