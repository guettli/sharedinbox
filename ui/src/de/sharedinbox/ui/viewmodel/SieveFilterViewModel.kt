package de.sharedinbox.ui.viewmodel

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import de.sharedinbox.core.repository.SieveRepository
import kotlinx.coroutines.launch

class SieveFilterViewModel(
    private val sieveRepo: SieveRepository,
) : ViewModel() {
    var accountId by mutableStateOf("")
        private set

    var content by mutableStateOf("")

    var isLoading by mutableStateOf(false)
        private set

    var error by mutableStateOf<String?>(null)

    var saved by mutableStateOf(false)

    fun init(accountId: String) {
        if (this.accountId == accountId) return
        this.accountId = accountId
        load()
    }

    private fun load() {
        viewModelScope.launch {
            isLoading = true
            error = null
            runCatching { sieveRepo.loadScript(accountId) }
                .onSuccess { content = it }
                .onFailure { error = it.message ?: "Failed to load script" }
            isLoading = false
        }
    }

    fun save() {
        viewModelScope.launch {
            isLoading = true
            error = null
            saved = false
            runCatching { sieveRepo.saveScript(accountId, content) }
                .onSuccess { serverError ->
                    if (serverError == null) {
                        saved = true
                    } else {
                        error = serverError
                    }
                }.onFailure { error = it.message ?: "Failed to save script" }
            isLoading = false
        }
    }
}
