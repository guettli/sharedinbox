package de.sharedinbox.ui.screen

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.Button
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
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import de.sharedinbox.ui.viewmodel.SieveFilterViewModel

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SieveFilterScreen(
    accountId: String,
    onBack: () -> Unit,
    vm: SieveFilterViewModel,
) {
    LaunchedEffect(accountId) { vm.init(accountId) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Sieve Filter") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
            )
        },
    ) { padding ->
        Box(Modifier.fillMaxSize().padding(padding)) {
            if (vm.isLoading) {
                CircularProgressIndicator(Modifier.align(Alignment.Center))
            } else {
                Column(Modifier.fillMaxSize().padding(16.dp)) {
                    if (vm.error != null) {
                        Text(
                            text = vm.error!!,
                            color = MaterialTheme.colorScheme.error,
                            style = MaterialTheme.typography.bodySmall,
                            modifier = Modifier.padding(bottom = 8.dp),
                        )
                    }
                    if (vm.saved) {
                        Text(
                            text = "Saved.",
                            color = MaterialTheme.colorScheme.primary,
                            style = MaterialTheme.typography.bodySmall,
                            modifier = Modifier.padding(bottom = 8.dp),
                        )
                    }
                    OutlinedTextField(
                        value = vm.content,
                        onValueChange = {
                            vm.content = it
                            vm.saved = false
                        },
                        label = { Text("Sieve script") },
                        modifier = Modifier.fillMaxWidth().weight(1f),
                        textStyle =
                            MaterialTheme.typography.bodySmall.copy(
                                fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace,
                            ),
                    )
                    Button(
                        onClick = { vm.save() },
                        modifier = Modifier.align(Alignment.End).padding(top = 12.dp),
                    ) {
                        Text("Save")
                    }
                }
            }
        }
    }
}
