package de.sharedinbox.ui.screen

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import de.sharedinbox.ui.viewmodel.ComposeViewModel

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ComposeScreen(
    accountId: String,
    fromEmail: String,
    replyToEmailId: String? = null,
    prefillTo: String = "",
    prefillCc: String = "",
    prefillSubject: String = "",
    prefillBody: String = "",
    onSuccess: () -> Unit,
    onCancel: () -> Unit,
    vm: ComposeViewModel,
) {
    vm.init(accountId, fromEmail, replyToEmailId, prefillTo, prefillCc, prefillSubject, prefillBody)

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("New Message") },
                navigationIcon = {
                    IconButton(onClick = onCancel) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Cancel")
                    }
                },
                actions = {
                    IconButton(
                        onClick = { vm.send(onSuccess) },
                        enabled = !vm.isLoading && vm.to.isNotBlank() && vm.subject.isNotBlank(),
                    ) {
                        if (vm.isLoading) {
                            CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                        } else {
                            Icon(Icons.AutoMirrored.Filled.Send, contentDescription = "Send")
                        }
                    }
                },
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(horizontal = 16.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            OutlinedTextField(
                value = vm.to,
                onValueChange = { vm.to = it },
                label = { Text("To") },
                placeholder = { Text("user@example.com, other@example.com") },
                modifier = Modifier.fillMaxWidth(),
                singleLine = true,
            )
            OutlinedTextField(
                value = vm.cc,
                onValueChange = { vm.cc = it },
                label = { Text("CC") },
                placeholder = { Text("user@example.com, other@example.com") },
                modifier = Modifier.fillMaxWidth(),
                singleLine = true,
            )
            OutlinedTextField(
                value = vm.subject,
                onValueChange = { vm.subject = it },
                label = { Text("Subject") },
                modifier = Modifier.fillMaxWidth(),
                singleLine = true,
            )
            vm.error?.let { err ->
                Text(err, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall)
            }
            OutlinedTextField(
                value = vm.body,
                onValueChange = { vm.body = it },
                label = { Text("Body") },
                modifier = Modifier.fillMaxWidth().weight(1f),
                minLines = 8,
            )
        }
    }
}
