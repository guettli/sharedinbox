package de.sharedinbox.ui.viewmodel

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import de.sharedinbox.core.jmap.mail.Email
import de.sharedinbox.core.jmap.mail.EmailBodyPart
import de.sharedinbox.core.jmap.mail.EmailKeyword
import de.sharedinbox.core.platform.AttachmentOpener
import de.sharedinbox.core.repository.EmailRepository
import kotlinx.coroutines.launch

class EmailDetailViewModel(
    private val emailRepo: EmailRepository,
    private val attachmentOpener: AttachmentOpener,
) : ViewModel() {

    var email by mutableStateOf<Email?>(null)
    var isLoading by mutableStateOf(false)
    var error by mutableStateOf<String?>(null)
    var attachments by mutableStateOf<List<EmailBodyPart>>(emptyList())
    var downloadingBlobId by mutableStateOf<String?>(null)
    var downloadError by mutableStateOf<String?>(null)
    var mutationInProgress by mutableStateOf(false)

    private var accountId = ""
    private var emailId = ""

    fun init(accountId: String, emailId: String) {
        if (this.accountId == accountId && this.emailId == emailId) return
        this.accountId = accountId
        this.emailId = emailId
        loadEmail()
    }

    private fun loadEmail() = viewModelScope.launch {
        isLoading = true
        error = null
        email = null
        attachments = emptyList()
        emailRepo.getEmail(accountId, emailId)
            .onSuccess { e ->
                email = e
                emailRepo.setKeyword(accountId, emailId, EmailKeyword.SEEN, true)
                if (e.hasAttachment) loadAttachments()
            }
            .onFailure { error = it.message }
        isLoading = false
    }

    private fun loadAttachments() = viewModelScope.launch {
        emailRepo.getAttachments(accountId, emailId)
            .onSuccess { attachments = it }
    }

    fun archive(onDone: () -> Unit) = viewModelScope.launch {
        mutationInProgress = true
        emailRepo.archiveEmail(accountId, emailId)
            .onSuccess { onDone() }
            .onFailure { error = it.message }
        mutationInProgress = false
    }

    fun delete(onDone: () -> Unit) = viewModelScope.launch {
        mutationInProgress = true
        emailRepo.deleteEmail(accountId, emailId)
            .onSuccess { onDone() }
            .onFailure { error = it.message }
        mutationInProgress = false
    }

    fun markAsSpam(onDone: () -> Unit) = viewModelScope.launch {
        mutationInProgress = true
        emailRepo.markAsSpam(accountId, emailId)
            .onSuccess { onDone() }
            .onFailure { error = it.message }
        mutationInProgress = false
    }

    fun downloadAttachment(part: EmailBodyPart) {
        val blobId = part.blobId ?: return
        viewModelScope.launch {
            downloadingBlobId = blobId
            downloadError = null
            emailRepo.downloadBlob(accountId, blobId, part.type)
                .onSuccess { bytes ->
                    attachmentOpener.open(bytes, part.name ?: "attachment", part.type)
                }
                .onFailure { downloadError = it.message }
            downloadingBlobId = null
        }
    }
}
