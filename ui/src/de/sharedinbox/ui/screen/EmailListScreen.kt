package de.sharedinbox.ui.screen

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Create
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import de.sharedinbox.core.jmap.mail.Email
import de.sharedinbox.core.jmap.mail.EmailKeyword
import de.sharedinbox.ui.viewmodel.EmailListViewModel

@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
fun EmailListScreen(
    accountId: String,
    mailboxId: String,
    onNavigateToDetail: (emailId: String) -> Unit,
    onNavigateToCompose: () -> Unit,
    onBack: () -> Unit,
    fromEmail: String,
    vm: EmailListViewModel,
) {
    vm.init(accountId, mailboxId)
    val emails by vm.emails.collectAsState()
    val inSelection = vm.inSelectionMode

    Scaffold(
        topBar = {
            if (inSelection) {
                TopAppBar(
                    title = { Text("${vm.selectedIds.size} selected") },
                    navigationIcon = {
                        IconButton(onClick = { vm.clearSelection() }) {
                            Icon(Icons.Default.Close, contentDescription = "Cancel selection")
                        }
                    },
                    actions = {
                        TextButton(onClick = { vm.bulkArchive() }) { Text("Archive") }
                        TextButton(onClick = { vm.bulkDelete() }) { Text("Delete") }
                        TextButton(onClick = { vm.bulkMarkSpam() }) { Text("Spam") }
                    },
                )
            } else {
                TopAppBar(
                    title = { Text("Emails") },
                    navigationIcon = {
                        IconButton(onClick = onBack) {
                            Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                        }
                    },
                    actions = {
                        IconButton(onClick = { vm.refresh() }, enabled = !vm.isLoading) {
                            Icon(Icons.Default.Refresh, contentDescription = "Refresh emails")
                        }
                    },
                )
            }
        },
        floatingActionButton = {
            if (!inSelection) {
                FloatingActionButton(onClick = onNavigateToCompose) {
                    Icon(Icons.Default.Create, contentDescription = "Compose new email")
                }
            }
        },
    ) { padding ->
        Box(Modifier.fillMaxSize().padding(padding)) {
            when {
                vm.isLoading && emails.isEmpty() -> CircularProgressIndicator(
                    Modifier.align(Alignment.Center)
                        .semantics { contentDescription = "Loading emails" }
                )

                vm.error != null && emails.isEmpty() -> ErrorContent(
                    message = vm.error!!,
                    onRetry = { vm.refresh() },
                    modifier = Modifier.align(Alignment.Center),
                )

                emails.isEmpty() -> Text(
                    text = "No emails in this mailbox.",
                    modifier = Modifier.align(Alignment.Center),
                    style = MaterialTheme.typography.bodyLarge,
                )

                else -> LazyColumn(Modifier.fillMaxSize()) {
                    items(emails, key = { it.id }) { email ->
                        val selected = email.id in vm.selectedIds
                        EmailRow(
                            email = email,
                            selected = selected,
                            inSelectionMode = inSelection,
                            onClick = {
                                if (inSelection) vm.toggleSelection(email.id)
                                else onNavigateToDetail(email.id)
                            },
                            onLongClick = { vm.toggleSelection(email.id) },
                        )
                        HorizontalDivider()
                    }
                }
            }
            // Error banner overlay when list is populated but sync failed
            vm.error?.let { err ->
                if (emails.isNotEmpty()) {
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

@Composable
private fun EmailRow(
    email: Email,
    selected: Boolean,
    inSelectionMode: Boolean,
    onClick: () -> Unit,
    onLongClick: () -> Unit,
) {
    val isUnread = !email.keywords.containsKey(EmailKeyword.SEEN)
    val from = email.from?.firstOrNull()?.let { it.name ?: it.email } ?: "Unknown"
    ListItem(
        headlineContent = {
            Text(
                text = email.subject ?: "(no subject)",
                fontWeight = if (isUnread) FontWeight.Bold else FontWeight.Normal,
            )
        },
        supportingContent = { Text("$from · ${email.preview ?: ""}") },
        leadingContent = if (inSelectionMode) {
            { Checkbox(checked = selected, onCheckedChange = null) }
        } else null,
        modifier = Modifier.combinedClickable(onClick = onClick, onLongClick = onLongClick)
            .semantics {
                contentDescription = buildString {
                    if (isUnread) append("Unread. ")
                    append(email.subject ?: "No subject")
                    append(". From $from")
                }
            },
    )
}
