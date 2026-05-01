package de.sharedinbox.ui.viewmodel

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import de.sharedinbox.core.repository.AccountRepository
import kotlinx.coroutines.launch

class AddImapSmtpAccountViewModel(
    private val accountRepo: AccountRepository,
) : ViewModel() {
    var displayName by mutableStateOf("")
    var username by mutableStateOf("")
    var password by mutableStateOf("")
    var imapHost by mutableStateOf("")
    var imapPort by mutableStateOf("993")
    var imapSecurity by mutableStateOf("TLS")
    var smtpHost by mutableStateOf("")
    var smtpPort by mutableStateOf("587")
    var smtpSecurity by mutableStateOf("STARTTLS")
    var isLoading by mutableStateOf(false)
    var error by mutableStateOf<String?>(null)
    var connectionOk by mutableStateOf(false)

    val isValid: Boolean
        get() =
            !isLoading &&
                username.isNotBlank() &&
                password.isNotBlank() &&
                imapHost.isNotBlank() &&
                imapPort.toIntOrNull() != null &&
                smtpHost.isNotBlank() &&
                smtpPort.toIntOrNull() != null

    fun checkConnection() =
        viewModelScope.launch {
            isLoading = true
            error = null
            connectionOk = false
            accountRepo
                .checkImapSmtpConnection(
                    username = username.trim(),
                    password = password,
                    imapHost = imapHost.trim(),
                    imapPort = imapPort.toIntOrNull() ?: 993,
                    imapSecurity = imapSecurity,
                    smtpHost = smtpHost.trim(),
                    smtpPort = smtpPort.toIntOrNull() ?: 587,
                    smtpSecurity = smtpSecurity,
                ).onSuccess {
                    connectionOk = true
                }.onFailure { e ->
                    val raw = e.message ?: "Unknown error"
                    error =
                        if (raw.contains("Not a byte value") || raw.contains("byte value")) {
                            "Password contains characters not supported by SMTP (e.g. €). Please use only ASCII characters."
                        } else {
                            raw
                        }
                }
            isLoading = false
        }

    fun addAccount(onSuccess: () -> Unit) =
        viewModelScope.launch {
            isLoading = true
            error = null
            connectionOk = false
            accountRepo
                .addImapSmtpAccount(
                    displayName = displayName.trim(),
                    username = username.trim(),
                    password = password,
                    imapHost = imapHost.trim(),
                    imapPort = imapPort.toIntOrNull() ?: 993,
                    imapSecurity = imapSecurity,
                    smtpHost = smtpHost.trim(),
                    smtpPort = smtpPort.toIntOrNull() ?: 587,
                    smtpSecurity = smtpSecurity,
                ).onSuccess { onSuccess() }
                .onFailure { error = it.message ?: "Unknown error" }
            isLoading = false
        }
}
