package de.sharedinbox.ui.viewmodel

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import de.sharedinbox.core.repository.EmailRepository
import de.sharedinbox.core.repository.SyncLogRepository
import de.sharedinbox.ui.viewmodel.MailboxListViewModel.SyncWarning
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

@OptIn(ExperimentalCoroutinesApi::class)
class EmailListViewModel(
    private val emailRepo: EmailRepository,
    private val syncLogRepo: SyncLogRepository,
) : ViewModel() {
    private data class Params(
        val accountId: String,
        val mailboxId: String,
    )

    private val _params = MutableStateFlow<Params?>(null)

    val emails =
        _params
            .filterNotNull()
            .flatMapLatest { (accountId, mailboxId) -> emailRepo.observeEmails(accountId, mailboxId) }
            .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())

    val syncWarning =
        _params
            .filterNotNull()
            .flatMapLatest { (accountId, _) ->
                combine(
                    syncLogRepo.observeSyncHealth(accountId),
                    tickerFlow(),
                ) { health, now -> toWarning(health, now) }
            }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), SyncWarning(false, null))

    var isLoading by mutableStateOf(false)
    var error by mutableStateOf<String?>(null)

    // ── Selection ─────────────────────────────────────────────────────────────

    var selectedIds by mutableStateOf(emptySet<String>())
        private set

    val inSelectionMode get() = selectedIds.isNotEmpty()

    fun toggleSelection(emailId: String) {
        selectedIds = if (emailId in selectedIds) selectedIds - emailId else selectedIds + emailId
    }

    fun clearSelection() {
        selectedIds = emptySet()
    }

    fun bulkArchive() = bulkAction { accountId, emailId -> emailRepo.archiveEmail(accountId, emailId) }

    fun bulkDelete() = bulkAction { accountId, emailId -> emailRepo.deleteEmail(accountId, emailId) }

    fun bulkMarkSpam() = bulkAction { accountId, emailId -> emailRepo.markAsSpam(accountId, emailId) }

    private fun bulkAction(action: suspend (accountId: String, emailId: String) -> Result<Unit>) {
        val p = _params.value ?: return
        val ids = selectedIds.toSet()
        clearSelection()
        viewModelScope.launch {
            isLoading = true
            ids.forEach { id -> action(p.accountId, id) }
            isLoading = false
        }
    }

    // ── Sync ──────────────────────────────────────────────────────────────────

    fun init(
        accountId: String,
        mailboxId: String,
    ) {
        val next = Params(accountId, mailboxId)
        if (_params.value == next) return
        _params.value = next
        sync()
    }

    fun refresh() {
        error = null
        sync()
    }

    private fun sync() =
        viewModelScope.launch {
            val p = _params.value ?: return@launch
            isLoading = true
            error = null
            emailRepo
                .syncEmails(p.accountId, p.mailboxId)
                .onFailure { error = it.message ?: "Sync failed" }
            isLoading = false
        }
}
