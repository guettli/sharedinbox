package de.sharedinbox.ui.navigation

sealed interface Screen {
    data object AccountList : Screen
    data object AddAccount : Screen
    data object Settings : Screen
    data class MailboxList(val accountId: String) : Screen
    data class EmailList(val accountId: String, val mailboxId: String) : Screen
    data class EmailDetail(val accountId: String, val emailId: String) : Screen
    data class Search(val accountId: String) : Screen
    data class SyncLog(val accountId: String) : Screen
    data class Compose(
        val accountId: String,
        val replyToEmailId: String? = null,
        val prefillTo: String = "",
        val prefillCc: String = "",
        val prefillSubject: String = "",
        val prefillBody: String = "",
    ) : Screen
}
