package de.sharedinbox.ui.viewmodel

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import de.sharedinbox.core.jmap.mail.EmailAddress
import de.sharedinbox.core.jmap.mail.EmailDraft
import de.sharedinbox.core.repository.ContactBookRepository
import de.sharedinbox.core.repository.EmailRepository
import de.sharedinbox.core.repository.RecentAddressRepository
import de.sharedinbox.data.repository.JmapContactBookRepository
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

class ComposeViewModel(
    private val emailRepo: EmailRepository,
    private val recentAddresses: RecentAddressRepository,
    private val contactBook: ContactBookRepository,
    private val jmapContacts: JmapContactBookRepository,
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

    /** Current autocomplete suggestions for the field that last triggered search. */
    var suggestions by mutableStateOf<List<EmailAddress>>(emptyList())

    /** Which field owns the current suggestions list. */
    var suggestionsField by mutableStateOf<AddressField?>(null)

    private var suggestJob: Job? = null

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

    /**
     * Called when the To or Cc field changes. Extracts the last token (text after
     * the last comma) and searches both the contact book and recent-address history.
     * Clears suggestions when the token is blank.
     */
    fun onAddressInput(
        field: AddressField,
        value: String,
    ) {
        when (field) {
            AddressField.TO -> to = value
            AddressField.CC -> cc = value
        }
        val token = value.substringAfterLast(",").trim()
        suggestJob?.cancel()
        if (token.length < 2) {
            suggestions = emptyList()
            suggestionsField = null
            return
        }
        suggestJob =
            viewModelScope.launch {
                val platformContacts =
                    contactBook
                        .searchContacts(token)
                        .map { EmailAddress(name = it.name, email = it.email) }
                val serverContacts =
                    jmapContacts
                        .searchContacts(accountId, token)
                        .map { EmailAddress(name = it.name, email = it.email) }
                val recent =
                    recentAddresses
                        .searchAddresses(accountId, token)
                        .map { EmailAddress(name = it.name, email = it.email) }
                // Merge: platform contacts first, then JMAP contacts, then recent
                val seenEmails = mutableSetOf<String>()
                suggestions =
                    (platformContacts + serverContacts + recent)
                        .filter { seenEmails.add(it.email) }
                        .take(10)
                suggestionsField = field
            }
    }

    /** Appends [suggestion] to [field], replacing the current incomplete token. */
    fun acceptSuggestion(
        field: AddressField,
        suggestion: EmailAddress,
    ) {
        val display = if (suggestion.name != null) "${suggestion.name} <${suggestion.email}>" else suggestion.email

        fun replaceToken(current: String): String {
            val prefix = current.substringBeforeLast(",", "")
            return if (prefix.isBlank()) display else "$prefix, $display"
        }
        when (field) {
            AddressField.TO -> to = replaceToken(to)
            AddressField.CC -> cc = replaceToken(cc)
        }
        suggestions = emptyList()
    }

    /** Clears the current suggestion list (e.g. when the field loses focus). */
    fun clearSuggestions() {
        suggestions = emptyList()
        suggestionsField = null
    }

    enum class AddressField { TO, CC }

    fun send(onSuccess: () -> Unit) =
        viewModelScope.launch {
            isLoading = true
            error = null
            val draft =
                EmailDraft(
                    from = EmailAddress(email = fromEmail.ifBlank { "me" }),
                    to =
                        to
                            .split(",")
                            .map { it.trim() }
                            .filter { it.isNotBlank() }
                            .map { EmailAddress(email = it) },
                    cc =
                        cc
                            .split(",")
                            .map { it.trim() }
                            .filter { it.isNotBlank() }
                            .map { EmailAddress(email = it) },
                    subject = subject,
                    textBody = body,
                    inReplyToEmailId = replyToEmailId,
                )
            emailRepo
                .sendEmail(accountId, draft)
                .onSuccess {
                    sent = true
                    onSuccess()
                }.onFailure { error = it.message ?: "Failed to send" }
            isLoading = false
        }
}
