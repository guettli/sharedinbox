package de.sharedinbox.ui.screen

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import de.sharedinbox.core.sync.SyncDirection
import de.sharedinbox.core.sync.SyncLogEntry
import de.sharedinbox.core.sync.SyncStatus
import de.sharedinbox.ui.viewmodel.SyncLogViewModel
import kotlinx.datetime.TimeZone
import kotlinx.datetime.toLocalDateTime

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SyncLogScreen(
    accountId: String,
    onBack: () -> Unit,
    vm: SyncLogViewModel,
) {
    vm.init(accountId)
    val entries by vm.entries.collectAsState()

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Sync Log") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
                actions = {
                    IconButton(onClick = { vm.clearLog() }) {
                        Icon(Icons.Default.Delete, contentDescription = "Clear log")
                    }
                },
            )
        },
    ) { innerPadding ->
        if (entries.isEmpty()) {
            Box(
                modifier =
                    Modifier
                        .fillMaxSize()
                        .padding(innerPadding),
                contentAlignment = Alignment.Center,
            ) {
                Text("No sync activity recorded yet.", style = MaterialTheme.typography.bodyLarge)
            }
        } else {
            LazyColumn(
                modifier =
                    Modifier
                        .fillMaxSize()
                        .padding(innerPadding),
            ) {
                items(entries, key = { it.id }) { entry ->
                    SyncLogRow(entry)
                    HorizontalDivider()
                }
            }
        }
    }
}

@Composable
private fun SyncLogRow(entry: SyncLogEntry) {
    val statusColor =
        when (entry.status) {
            SyncStatus.SUCCESS -> Color(0xFF2E7D32) // dark green
            SyncStatus.CONFLICT -> Color(0xFFE65100) // deep orange
            SyncStatus.ERROR -> Color(0xFFC62828) // dark red
        }
    val directionLabel =
        when (entry.direction) {
            SyncDirection.SERVER_TO_DB -> "↓ server→db"
            SyncDirection.DB_TO_SERVER -> "↑ db→server"
        }

    ListItem(
        headlineContent = {
            Text(
                text = "${entry.operation}  [$directionLabel]",
                style = MaterialTheme.typography.bodyMedium,
            )
        },
        supportingContent = {
            Column {
                Text(
                    text = entry.occurredAt.formatLocal(),
                    style = MaterialTheme.typography.labelSmall,
                )
                if (!entry.detail.isNullOrBlank()) {
                    Text(
                        text = entry.detail!!,
                        style = MaterialTheme.typography.bodySmall,
                        modifier =
                            Modifier
                                .fillMaxWidth()
                                .padding(top = 2.dp),
                    )
                }
            }
        },
        trailingContent = {
            Text(
                text = entry.status.value,
                color = statusColor,
                style = MaterialTheme.typography.labelMedium,
            )
        },
    )
}

private fun kotlin.time.Instant.formatLocal(): String {
    // Convert kotlin.time.Instant → kotlinx.datetime via epoch millis
    val kxInstant = kotlinx.datetime.Instant.fromEpochMilliseconds(toEpochMilliseconds())
    val local = kxInstant.toLocalDateTime(TimeZone.currentSystemDefault())
    return format("%04d-%02d-%02d %02d:%02d:%02d",
        local.year,
        local.monthNumber,
        local.dayOfMonth,
        local.hour,
        local.minute,
        local.second,
    )
}
