package de.sharedinbox.ui.screen

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import de.sharedinbox.core.jmap.mail.Mailbox
import de.sharedinbox.ui.viewmodel.MailboxListViewModel

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MailboxListScreen(
    accountId: String,
    onNavigateToEmails: (mailboxId: String) -> Unit,
    onNavigateToSearch: () -> Unit,
    onNavigateToSyncLog: () -> Unit,
    onBack: () -> Unit,
    vm: MailboxListViewModel,
) {
    vm.init(accountId)
    val mailboxes by vm.mailboxes.collectAsState()
    val syncWarning by vm.syncWarning.collectAsState()

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Mailboxes") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
                actions = {
                    IconButton(onClick = onNavigateToSearch) {
                        Icon(Icons.Default.Search, contentDescription = "Search emails")
                    }
                    IconButton(onClick = onNavigateToSyncLog) {
                        Icon(Icons.Default.History, contentDescription = "Sync log")
                    }
                    IconButton(onClick = { vm.refresh() }, enabled = !vm.isLoading) {
                        Icon(Icons.Default.Refresh, contentDescription = "Refresh mailboxes")
                    }
                },
            )
        },
    ) { padding ->
        Column(Modifier.fillMaxSize().padding(padding)) {
            SyncWarningBanner(syncWarning)
            Box(Modifier.weight(1f)) {
                when {
                    vm.isLoading && mailboxes.isEmpty() ->
                        CircularProgressIndicator(
                            Modifier
                                .align(Alignment.Center)
                                .semantics { contentDescription = "Loading mailboxes" },
                        )

                    vm.error != null && mailboxes.isEmpty() ->
                        ErrorContent(
                            message = vm.error!!,
                            onRetry = { vm.refresh() },
                            modifier = Modifier.align(Alignment.Center),
                        )

                    mailboxes.isEmpty() ->
                        Text(
                            text = "No mailboxes found.",
                            modifier = Modifier.align(Alignment.Center),
                            style = MaterialTheme.typography.bodyLarge,
                        )

                    else ->
                        LazyColumn(Modifier.fillMaxSize()) {
                            items(mailboxes, key = { it.id }) { mailbox ->
                                MailboxRow(mailbox = mailbox, onClick = { onNavigateToEmails(mailbox.id) })
                                HorizontalDivider()
                            }
                        }
                }
                // Error banner overlay when list is populated but a refresh failed
                vm.error?.let { err ->
                    if (mailboxes.isNotEmpty()) {
                        Text(
                            text = "Sync failed: $err",
                            color = MaterialTheme.colorScheme.error,
                            style = MaterialTheme.typography.bodySmall,
                            modifier = Modifier.align(Alignment.TopCenter).padding(horizontal = 8.dp, vertical = 4.dp),
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun MailboxRow(
    mailbox: Mailbox,
    onClick: () -> Unit,
) {
    ListItem(
        headlineContent = { Text(mailbox.name) },
        supportingContent =
            if (mailbox.unreadEmails > 0) {
                { Text("${mailbox.unreadEmails} unread") }
            } else {
                null
            },
        modifier =
            Modifier
                .clickable(onClick = onClick)
                .semantics { contentDescription = "${mailbox.name}, ${mailbox.unreadEmails} unread" },
    )
}
