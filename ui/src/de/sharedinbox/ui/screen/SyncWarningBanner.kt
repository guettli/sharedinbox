package de.sharedinbox.ui.screen

import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import de.sharedinbox.ui.viewmodel.MailboxListViewModel.SyncWarning

/**
 * Shows a coloured banner when the last sync is stale (> 1 hour) or the most
 * recent sync operation failed. Both conditions can be shown at once.
 *
 * Renders nothing when [warning] reports no problems.
 */
@Composable
fun SyncWarningBanner(warning: SyncWarning) {
    if (!warning.syncStale && warning.syncError == null) return

    Surface(
        modifier = Modifier.fillMaxWidth(),
        color = MaterialTheme.colorScheme.errorContainer,
    ) {
        val lines =
            buildList {
                if (warning.syncStale) add("Last sync was more than one hour ago.")
                if (warning.syncError != null) add("Sync error: ${warning.syncError}")
            }
        Text(
            text = lines.joinToString("\n"),
            color = MaterialTheme.colorScheme.onErrorContainer,
            style = MaterialTheme.typography.bodySmall,
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp),
        )
    }
}
