package de.sharedinbox.ui.screen

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import de.sharedinbox.core.account.Account
import de.sharedinbox.core.jmap.JmapCapability
import de.sharedinbox.core.repository.SyncSettings
import de.sharedinbox.ui.viewmodel.AccountListViewModel
import de.sharedinbox.ui.viewmodel.SyncSettingsViewModel

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    onBack: () -> Unit,
    onNavigateToSieveFilter: (accountId: String) -> Unit,
    vm: AccountListViewModel,
    syncSettingsVm: SyncSettingsViewModel,
) {
    val accounts by vm.accounts.collectAsState()
    val capabilities by vm.capabilities.collectAsState()
    val syncSettings by syncSettingsVm.settings.collectAsState()

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Settings") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
            )
        },
    ) { padding ->
        LazyColumn(Modifier.fillMaxSize().padding(padding)) {
            if (accounts.isEmpty()) {
                item {
                    Box(
                        modifier = Modifier.fillMaxWidth().padding(16.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text("No accounts configured.", style = MaterialTheme.typography.bodyLarge)
                    }
                }
            } else {
                item {
                    ListItem(headlineContent = {
                        Text(
                            "Accounts",
                            style = MaterialTheme.typography.labelMedium,
                            color = MaterialTheme.colorScheme.primary,
                        )
                    })
                }
                items(accounts, key = { it.id }) { account ->
                    val accountCaps = capabilities[account.id]
                    AccountSettingsRow(
                        account = account,
                        capabilities = accountCaps,
                        onDelete = { vm.removeAccount(account.id) },
                        onLoadCapabilities = { vm.loadCapabilities(account.id) },
                        onNavigateToSieveFilter = { onNavigateToSieveFilter(account.id) },
                    )
                    HorizontalDivider()
                }
            }
            item {
                SyncSettingsSection(
                    settings = syncSettings,
                    onSave = { syncSettingsVm.save(it) },
                )
            }
        }
    }
}

@Composable
private fun SyncSettingsSection(
    settings: SyncSettings,
    onSave: (SyncSettings) -> Unit,
) {
    var mobileDays by remember(settings) { mutableStateOf(settings.mobileDays.toString()) }
    var mobileMb by remember(settings) { mutableStateOf(settings.mobileMbLimit.toString()) }
    var wifiDays by remember(settings) { mutableStateOf(settings.wifiDays.toString()) }
    var wifiMb by remember(settings) { mutableStateOf(settings.wifiMbLimit.toString()) }

    fun commit() {
        val md = mobileDays.toIntOrNull() ?: return
        val mm = mobileMb.toIntOrNull() ?: return
        val wd = wifiDays.toIntOrNull() ?: return
        val wm = wifiMb.toIntOrNull() ?: return
        onSave(SyncSettings(mobileDays = md, mobileMbLimit = mm, wifiDays = wd, wifiMbLimit = wm))
    }

    Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) {
        Text(
            "Sync",
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.primary,
            modifier = Modifier.padding(bottom = 8.dp),
        )
        Text(
            "Mobile data",
            style = MaterialTheme.typography.titleSmall,
            modifier = Modifier.padding(bottom = 4.dp),
        )
        Row(Modifier.fillMaxWidth()) {
            OutlinedTextField(
                value = mobileDays,
                onValueChange = {
                    mobileDays = it
                    commit()
                },
                label = { Text("Days to sync") },
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                modifier = Modifier.weight(1f).padding(end = 8.dp),
                singleLine = true,
            )
            OutlinedTextField(
                value = mobileMb,
                onValueChange = {
                    mobileMb = it
                    commit()
                },
                label = { Text("Max attachment MB") },
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                modifier = Modifier.weight(1f),
                singleLine = true,
            )
        }
        Text(
            "WiFi / unmetered",
            style = MaterialTheme.typography.titleSmall,
            modifier = Modifier.padding(top = 12.dp, bottom = 4.dp),
        )
        Row(Modifier.fillMaxWidth()) {
            OutlinedTextField(
                value = wifiDays,
                onValueChange = {
                    wifiDays = it
                    commit()
                },
                label = { Text("Days to sync") },
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                modifier = Modifier.weight(1f).padding(end = 8.dp),
                singleLine = true,
            )
            OutlinedTextField(
                value = wifiMb,
                onValueChange = {
                    wifiMb = it
                    commit()
                },
                label = { Text("Max attachment MB") },
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                modifier = Modifier.weight(1f),
                singleLine = true,
            )
        }
    }
}

@Composable
private fun AccountSettingsRow(
    account: Account,
    capabilities: Set<String>?,
    onDelete: () -> Unit,
    onLoadCapabilities: () -> Unit,
    onNavigateToSieveFilter: () -> Unit,
) {
    var showConfirm by remember { mutableStateOf(false) }

    LaunchedEffect(account.id) { onLoadCapabilities() }

    ListItem(
        headlineContent = { Text(account.displayName) },
        supportingContent = {
            Column {
                Text(account.username)
                if (capabilities == null) {
                    Text(
                        "Checking server features…",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.secondary,
                    )
                } else {
                    val hasContacts = JmapCapability.CONTACTS in capabilities
                    val hasSubmission = JmapCapability.SUBMISSION in capabilities
                    val hasSieve = JmapCapability.SIEVE in capabilities
                    Text(
                        buildString {
                            append("Contacts: ${if (hasContacts) "yes" else "no"}")
                            append("  •  ")
                            append("Submission: ${if (hasSubmission) "yes" else "no"}")
                            append("  •  ")
                            append("Sieve: ${if (hasSieve) "yes" else "no"}")
                        },
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.secondary,
                    )
                    if (hasSieve) {
                        FilledTonalButton(
                            onClick = onNavigateToSieveFilter,
                            modifier = Modifier.padding(top = 4.dp),
                        ) {
                            Text("Edit Sieve Filter")
                        }
                    }
                }
            }
        },
        trailingContent = {
            IconButton(onClick = { showConfirm = true }) {
                Icon(Icons.Default.Delete, contentDescription = "Remove account")
            }
        },
    )

    if (showConfirm) {
        AlertDialog(
            onDismissRequest = { showConfirm = false },
            title = { Text("Remove account?") },
            text = { Text("This will remove ${account.displayName} and all its local data.") },
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
