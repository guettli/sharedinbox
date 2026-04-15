package de.sharedinbox.ui.screen

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuAnchorType
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import de.sharedinbox.ui.viewmodel.AddImapSmtpAccountViewModel

private val SECURITY_OPTIONS = listOf("TLS", "STARTTLS", "NONE")

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AddImapSmtpAccountScreen(
    onSuccess: () -> Unit,
    onCancel: () -> Unit,
    vm: AddImapSmtpAccountViewModel,
) {
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Add IMAP + SMTP Account") },
                navigationIcon = {
                    IconButton(onClick = onCancel) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
            )
        },
    ) { padding ->
        Column(
            modifier =
                Modifier
                    .fillMaxWidth()
                    .padding(padding)
                    .padding(horizontal = 16.dp, vertical = 8.dp)
                    .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            OutlinedTextField(
                value = vm.displayName,
                onValueChange = { vm.displayName = it },
                label = { Text("Display Name (optional)") },
                placeholder = { Text("My Email Account") },
                modifier = Modifier.fillMaxWidth(),
                singleLine = true,
            )
            OutlinedTextField(
                value = vm.username,
                onValueChange = { vm.username = it },
                label = { Text("Email / Username") },
                modifier = Modifier.fillMaxWidth(),
                singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email),
            )
            OutlinedTextField(
                value = vm.password,
                onValueChange = { vm.password = it },
                label = { Text("Password") },
                modifier = Modifier.fillMaxWidth(),
                singleLine = true,
                visualTransformation = PasswordVisualTransformation(),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
            )

            HorizontalDivider(modifier = Modifier.padding(vertical = 4.dp))
            Text("IMAP (Incoming Mail)", style = MaterialTheme.typography.titleSmall)

            OutlinedTextField(
                value = vm.imapHost,
                onValueChange = { vm.imapHost = it },
                label = { Text("IMAP Host") },
                placeholder = { Text("imap.example.com") },
                modifier = Modifier.fillMaxWidth(),
                singleLine = true,
            )
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                OutlinedTextField(
                    value = vm.imapPort,
                    onValueChange = { vm.imapPort = it },
                    label = { Text("Port") },
                    modifier = Modifier.weight(1f),
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                )
                SecurityDropdown(
                    label = "Security",
                    selected = vm.imapSecurity,
                    onSelected = { vm.imapSecurity = it },
                    modifier = Modifier.weight(1f),
                )
            }

            HorizontalDivider(modifier = Modifier.padding(vertical = 4.dp))
            Text("SMTP (Outgoing Mail)", style = MaterialTheme.typography.titleSmall)

            OutlinedTextField(
                value = vm.smtpHost,
                onValueChange = { vm.smtpHost = it },
                label = { Text("SMTP Host") },
                placeholder = { Text("smtp.example.com") },
                modifier = Modifier.fillMaxWidth(),
                singleLine = true,
            )
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                OutlinedTextField(
                    value = vm.smtpPort,
                    onValueChange = { vm.smtpPort = it },
                    label = { Text("Port") },
                    modifier = Modifier.weight(1f),
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                )
                SecurityDropdown(
                    label = "Security",
                    selected = vm.smtpSecurity,
                    onSelected = { vm.smtpSecurity = it },
                    modifier = Modifier.weight(1f),
                )
            }

            vm.error?.let { err ->
                Text(err, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall)
            }
            Button(
                onClick = { vm.addAccount(onSuccess = onSuccess) },
                enabled = vm.isValid,
                modifier = Modifier.fillMaxWidth(),
            ) {
                if (vm.isLoading) {
                    CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                } else {
                    Text("Add Account")
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SecurityDropdown(
    label: String,
    selected: String,
    onSelected: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    var expanded by remember { mutableStateOf(false) }
    ExposedDropdownMenuBox(
        expanded = expanded,
        onExpandedChange = { expanded = it },
        modifier = modifier,
    ) {
        OutlinedTextField(
            value = selected,
            onValueChange = {},
            readOnly = true,
            label = { Text(label) },
            trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = expanded) },
            modifier = Modifier.menuAnchor(ExposedDropdownMenuAnchorType.PrimaryNotEditable),
            singleLine = true,
        )
        ExposedDropdownMenu(
            expanded = expanded,
            onDismissRequest = { expanded = false },
        ) {
            SECURITY_OPTIONS.forEach { option ->
                DropdownMenuItem(
                    text = { Text(option) },
                    onClick = {
                        onSelected(option)
                        expanded = false
                    },
                )
            }
        }
    }
}
