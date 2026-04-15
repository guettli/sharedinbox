package de.sharedinbox.ui.screen

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.AlertDialog
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
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import de.sharedinbox.core.account.Account
import de.sharedinbox.ui.viewmodel.AccountListViewModel

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AccountListScreen(
    onNavigateToAdd: () -> Unit,
    onNavigateToAddImap: () -> Unit,
    onNavigateToMailboxes: (accountId: String) -> Unit,
    onNavigateToSettings: () -> Unit,
    vm: AccountListViewModel,
) {
    val accounts by vm.accounts.collectAsState()
    var showAddDialog by remember { mutableStateOf(false) }

    if (showAddDialog) {
        AlertDialog(
            onDismissRequest = { showAddDialog = false },
            title = { Text("Add Account") },
            text = { Text("Choose the protocol for the new account.") },
            confirmButton = {
                TextButton(onClick = {
                    showAddDialog = false
                    onNavigateToAdd()
                }) { Text("JMAP") }
            },
            dismissButton = {
                TextButton(onClick = {
                    showAddDialog = false
                    onNavigateToAddImap()
                }) { Text("IMAP + SMTP") }
            },
        )
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("SharedInbox") },
                actions = {
                    IconButton(onClick = onNavigateToSettings) {
                        Icon(Icons.Default.Settings, contentDescription = "Settings")
                    }
                },
            )
        },
        floatingActionButton = {
            FloatingActionButton(onClick = { showAddDialog = true }) {
                Icon(Icons.Default.Add, contentDescription = "Add account")
            }
        },
    ) { padding ->
        if (accounts.isEmpty()) {
            Box(
                modifier = Modifier.fillMaxSize().padding(padding),
                contentAlignment = Alignment.Center,
            ) {
                Text("No accounts yet. Tap + to add one.", style = MaterialTheme.typography.bodyLarge)
            }
        } else {
            LazyColumn(Modifier.fillMaxSize().padding(padding)) {
                items(accounts, key = { it.id }) { account ->
                    AccountRow(
                        account = account,
                        onClick = { onNavigateToMailboxes(account.id) },
                        onDelete = { vm.removeAccount(account.id) },
                    )
                    HorizontalDivider()
                }
            }
        }
    }
}

@Composable
private fun AccountRow(
    account: Account,
    onClick: () -> Unit,
    onDelete: () -> Unit,
) {
    var showConfirm by remember { mutableStateOf(false) }

    ListItem(
        headlineContent = { Text(account.displayName) },
        supportingContent = { Text(account.baseUrl) },
        trailingContent = {
            IconButton(onClick = { showConfirm = true }) {
                Icon(Icons.Default.Delete, contentDescription = "Remove account")
            }
        },
        modifier = Modifier.clickable(onClick = onClick),
    )

    if (showConfirm) {
        AlertDialog(
            onDismissRequest = { showConfirm = false },
            title = { Text("Remove account?") },
            text = { Text("This will remove ${account.displayName} and all its data.") },
            confirmButton = {
                TextButton(onClick = {
                    onDelete()
                    showConfirm = false
                }) { Text("Remove") }
            },
            dismissButton = {
                TextButton(onClick = { showConfirm = false }) { Text("Cancel") }
            },
        )
    }
}
