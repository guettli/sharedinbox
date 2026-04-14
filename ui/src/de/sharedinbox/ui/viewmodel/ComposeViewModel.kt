package de.sharedinbox.ui.viewmodel

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import de.sharedinbox.core.jmap.mail.EmailAddress
import de.sharedinbox.core.jmap.mail.EmailDraft
import de.sharedinbox.core.repository.EmailRepository
import kotlinx.coroutines.launch

class ComposeViewModel(
    private val emailRepo: EmailRepository,
) : ViewModel() {

    var accountId by mutableStateOf("")
    var to by mutableStateOf("")
    var cc by mutableStateOf("")
    var subject by mutableStateOf("")
    var body by mutableStateOf("")
    var fromEmail by mutableStateOf("")
    var replyToEmailId by mutableStateOf<String?>(null)
    var isLoading by mutableStateOf(false)
    var error by mutableStateOf<String?>(null)
    var sent by mutableStateOf(false)

    fun init(
        accountId: String,
        fromEmail: String,
        replyToEmailId: String? = null,
        prefillTo: String = "",
        prefillCc: String = "",
        prefillSubject: String = "",
        prefillBody: String = "",
    ) {
        if (this.accountId == accountId && this.replyToEmailId == replyToEmailId) return
        this.accountId = accountId
        this.fromEmail = fromEmail
        this.replyToEmailId = replyToEmailId
        this.to = prefillTo
        this.cc = prefillCc
        this.subject = prefillSubject
        this.body = prefillBody
    }

    fun send(onSuccess: () -> Unit) = viewModelScope.launch {
        isLoading = true
        error = null
        val draft = EmailDraft(
            from = EmailAddress(email = fromEmail.ifBlank { "me" }),
            to = to.split(",").map { it.trim() }.filter { it.isNotBlank() }
                .map { EmailAddress(email = it) },
            cc = cc.split(",").map { it.trim() }.filter { it.isNotBlank() }
                .map { EmailAddress(email = it) },
            subject = subject,
            textBody = body,
            inReplyToEmailId = replyToEmailId,
        )
        emailRepo.sendEmail(accountId, draft)
            .onSuccess { sent = true; onSuccess() }
            .onFailure { error = it.message ?: "Failed to send" }
        isLoading = false
    }
}
