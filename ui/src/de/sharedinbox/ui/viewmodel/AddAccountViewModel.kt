package de.sharedinbox.ui.viewmodel

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import de.sharedinbox.core.repository.AccountRepository
import kotlinx.coroutines.launch

class AddAccountViewModel(
    private val accountRepo: AccountRepository,
) : ViewModel() {
    var baseUrl by mutableStateOf("")
    var username by mutableStateOf("")
    var password by mutableStateOf("")
    var isLoading by mutableStateOf(false)
    var error by mutableStateOf<String?>(null)

    fun addAccount(onSuccess: () -> Unit) =
        viewModelScope.launch {
            isLoading = true
            error = null
            accountRepo
                .addAccount(baseUrl.trim(), username.trim(), password)
                .onSuccess { onSuccess() }
                .onFailure { error = it.message ?: "Unknown error" }
            isLoading = false
        }
}
