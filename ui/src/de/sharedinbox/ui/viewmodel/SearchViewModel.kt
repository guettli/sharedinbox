package de.sharedinbox.ui.viewmodel

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import de.sharedinbox.core.jmap.mail.Email
import de.sharedinbox.core.repository.EmailRepository
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

class SearchViewModel(
    private val emailRepo: EmailRepository,
) : ViewModel() {

    var query by mutableStateOf("")
        private set
    var results by mutableStateOf(emptyList<Email>())
        private set
    var isSearching by mutableStateOf(false)
        private set
    var error by mutableStateOf<String?>(null)
        private set

    // ── Selection ─────────────────────────────────────────────────────────────

    var selectedIds by mutableStateOf(emptySet<String>())
        private set

    val inSelectionMode get() = selectedIds.isNotEmpty()

    fun toggleSelection(emailId: String) {
        selectedIds = if (emailId in selectedIds) selectedIds - emailId else selectedIds + emailId
    }

    fun clearSelection() { selectedIds = emptySet() }

    fun bulkArchive() = bulkAction { id -> emailRepo.archiveEmail(accountId, id) }
    fun bulkDelete() = bulkAction { id -> emailRepo.deleteEmail(accountId, id) }
    fun bulkMarkSpam() = bulkAction { id -> emailRepo.markAsSpam(accountId, id) }

    private fun bulkAction(action: suspend (emailId: String) -> Result<Unit>) {
        val ids = selectedIds.toSet()
        clearSelection()
        viewModelScope.launch {
            ids.forEach { action(it) }
            // Re-run search so deleted/archived items disappear from results
            runSearch()
        }
    }

    // ── Query ─────────────────────────────────────────────────────────────────

    private var accountId = ""
    private var searchJob: Job? = null

    fun init(accountId: String) {
        if (this.accountId == accountId) return
        this.accountId = accountId
        results = emptyList()
        query = ""
    }

    fun onQueryChange(newQuery: String) {
        query = newQuery
        error = null
        searchJob?.cancel()
        if (newQuery.isBlank()) {
            results = emptyList()
            return
        }
        searchJob = viewModelScope.launch {
            delay(200)   // debounce — avoid hitting the DB on every keystroke
            runSearch()
        }
    }

    private suspend fun runSearch() {
        if (query.isBlank()) return
        isSearching = true
        emailRepo.searchEmails(accountId, query)
            .onSuccess { results = it }
            .onFailure { error = it.message }
        isSearching = false
    }
}
