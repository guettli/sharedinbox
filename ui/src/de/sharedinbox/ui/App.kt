package de.sharedinbox.ui

import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import de.sharedinbox.ui.di.dataModule
import de.sharedinbox.ui.di.platformModule
import de.sharedinbox.ui.di.uiModule
import de.sharedinbox.ui.navigation.Screen
import de.sharedinbox.ui.screen.AccountListScreen
import de.sharedinbox.ui.screen.AddAccountScreen
import de.sharedinbox.ui.screen.AddImapSmtpAccountScreen
import de.sharedinbox.ui.screen.ComposeScreen
import de.sharedinbox.ui.screen.EmailDetailScreen
import de.sharedinbox.ui.screen.EmailListScreen
import de.sharedinbox.ui.screen.MailboxListScreen
import de.sharedinbox.ui.screen.SearchScreen
import de.sharedinbox.ui.screen.SettingsScreen
import de.sharedinbox.ui.screen.SieveFilterScreen
import de.sharedinbox.ui.screen.SyncLogScreen
import de.sharedinbox.ui.viewmodel.AccountListViewModel
import de.sharedinbox.ui.viewmodel.AddAccountViewModel
import de.sharedinbox.ui.viewmodel.AddImapSmtpAccountViewModel
import de.sharedinbox.ui.viewmodel.ComposeViewModel
import de.sharedinbox.ui.viewmodel.EmailDetailViewModel
import de.sharedinbox.ui.viewmodel.EmailListViewModel
import de.sharedinbox.ui.viewmodel.MailboxListViewModel
import de.sharedinbox.ui.viewmodel.SearchViewModel
import de.sharedinbox.ui.viewmodel.SieveFilterViewModel
import de.sharedinbox.ui.viewmodel.SyncLogViewModel
import de.sharedinbox.ui.viewmodel.SyncSettingsViewModel
import org.koin.compose.KoinApplication
import org.koin.compose.viewmodel.koinViewModel

/**
 * Root composable for all platforms.
 *
 * [context] is passed to the platform-specific [platformModule] factory.
 * On JVM/iOS pass `Unit` (default); on Android pass `applicationContext`.
 *
 * Navigation uses a plain back-stack (List<Screen>). Navigation3 will be adopted
 * in Phase 12 when its alpha API has stabilised.
 */
@Composable
fun App(context: Any = Unit) {
    KoinApplication(application = {
        modules(dataModule, uiModule, platformModule(context))
    }) {
        MaterialTheme {
            AppNavigation()
        }
    }
}

@Composable
private fun AppNavigation() {
    var backStack by remember { mutableStateOf(listOf<Screen>(Screen.AccountList)) }

    fun push(screen: Screen) {
        backStack = backStack + screen
    }

    fun pop() {
        if (backStack.size > 1) backStack = backStack.dropLast(1)
    }

    // Shared AccountListViewModel — reused by both AccountListScreen and SettingsScreen
    val accountListVm = koinViewModel<AccountListViewModel>()

    when (val current = backStack.last()) {
        Screen.AccountList ->
            AccountListScreen(
                onNavigateToAdd = { push(Screen.AddAccount) },
                onNavigateToAddImap = { push(Screen.AddImapSmtpAccount) },
                onNavigateToMailboxes = { accountId -> push(Screen.MailboxList(accountId)) },
                onNavigateToSettings = { push(Screen.Settings) },
                vm = accountListVm,
            )
        Screen.AddAccount ->
            AddAccountScreen(
                onSuccess = { pop() },
                onCancel = { pop() },
                vm = koinViewModel<AddAccountViewModel>(),
            )
        Screen.AddImapSmtpAccount ->
            AddImapSmtpAccountScreen(
                onSuccess = { pop() },
                onCancel = { pop() },
                vm = koinViewModel<AddImapSmtpAccountViewModel>(),
            )
        Screen.Settings ->
            SettingsScreen(
                onBack = { pop() },
                onNavigateToSieveFilter = { accountId -> push(Screen.SieveFilter(accountId)) },
                vm = accountListVm,
                syncSettingsVm = koinViewModel<SyncSettingsViewModel>(),
            )
        is Screen.MailboxList ->
            MailboxListScreen(
                accountId = current.accountId,
                onNavigateToEmails = { mailboxId -> push(Screen.EmailList(current.accountId, mailboxId)) },
                onNavigateToSearch = { push(Screen.Search(current.accountId)) },
                onNavigateToSyncLog = { push(Screen.SyncLog(current.accountId)) },
                onBack = { pop() },
                vm = koinViewModel<MailboxListViewModel>(),
            )
        is Screen.SyncLog ->
            SyncLogScreen(
                accountId = current.accountId,
                onBack = { pop() },
                vm = koinViewModel<SyncLogViewModel>(),
            )
        is Screen.Search ->
            SearchScreen(
                accountId = current.accountId,
                onNavigateToDetail = { emailId -> push(Screen.EmailDetail(current.accountId, emailId)) },
                onBack = { pop() },
                vm = koinViewModel<SearchViewModel>(),
            )
        is Screen.EmailList -> {
            val accounts by accountListVm.accounts.collectAsState()
            val fromEmail = accounts.firstOrNull { it.id == current.accountId }?.username ?: ""
            EmailListScreen(
                accountId = current.accountId,
                mailboxId = current.mailboxId,
                onNavigateToDetail = { emailId -> push(Screen.EmailDetail(current.accountId, emailId)) },
                onNavigateToCompose = { push(Screen.Compose(current.accountId)) },
                onBack = { pop() },
                fromEmail = fromEmail,
                vm = koinViewModel<EmailListViewModel>(),
            )
        }
        is Screen.EmailDetail ->
            EmailDetailScreen(
                accountId = current.accountId,
                emailId = current.emailId,
                onBack = { pop() },
                onNavigateToCompose = { push(it) },
                vm = koinViewModel<EmailDetailViewModel>(),
            )
        is Screen.Compose -> {
            val accounts by accountListVm.accounts.collectAsState()
            val fromEmail = accounts.firstOrNull { it.id == current.accountId }?.username ?: ""
            ComposeScreen(
                accountId = current.accountId,
                fromEmail = fromEmail,
                replyToEmailId = current.replyToEmailId,
                prefillTo = current.prefillTo,
                prefillCc = current.prefillCc,
                prefillSubject = current.prefillSubject,
                prefillBody = current.prefillBody,
                onSuccess = { pop() },
                onCancel = { pop() },
                vm = koinViewModel<ComposeViewModel>(),
            )
        }
        is Screen.SieveFilter ->
            SieveFilterScreen(
                accountId = current.accountId,
                onBack = { pop() },
                vm = koinViewModel<SieveFilterViewModel>(),
            )
    }
}
