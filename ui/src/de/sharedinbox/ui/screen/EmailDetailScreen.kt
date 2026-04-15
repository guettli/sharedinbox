package de.sharedinbox.ui.screen

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.painter.BitmapPainter
import androidx.compose.ui.unit.dp
import de.sharedinbox.ui.html.HtmlView
import de.sharedinbox.ui.navigation.Screen
import de.sharedinbox.ui.viewmodel.EmailDetailViewModel

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun EmailDetailScreen(
    accountId: String,
    emailId: String,
    onBack: () -> Unit,
    onNavigateToCompose: (Screen.Compose) -> Unit,
    vm: EmailDetailViewModel,
) {
    vm.init(accountId, emailId)
    val email = vm.email

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(email?.subject ?: "Email") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
                actions = {
                    if (email != null) {
                        val replySubject =
                            if (email.subject?.startsWith("Re:") == true) {
                                email.subject ?: ""
                            } else {
                                "Re: ${email.subject ?: ""}"
                            }
                        val quotedBody =
                            buildString {
                                append("\n\n--- Original message ---\n")
                                email.from?.firstOrNull()?.let { append("From: ${it.name ?: it.email}\n") }
                                append("\n")
                                append(
                                    email.textBody
                                        .firstOrNull()
                                        ?.partId
                                        ?.let { email.bodyValues[it]?.value } ?: "",
                                )
                            }
                        val replyTo = email.replyTo?.firstOrNull() ?: email.from?.firstOrNull()
                        TextButton(onClick = {
                            onNavigateToCompose(
                                Screen.Compose(
                                    accountId = accountId,
                                    replyToEmailId = email.id,
                                    prefillTo = replyTo?.email ?: "",
                                    prefillSubject = replySubject,
                                    prefillBody = quotedBody,
                                ),
                            )
                        }) {
                            Text("Reply")
                        }
                        val ccAddresses =
                            (email.to.orEmpty() + email.cc.orEmpty())
                                .filter { it.email != accountId }
                                .joinToString(", ") { it.email }
                        TextButton(onClick = {
                            onNavigateToCompose(
                                Screen.Compose(
                                    accountId = accountId,
                                    replyToEmailId = email.id,
                                    prefillTo = replyTo?.email ?: "",
                                    prefillCc = ccAddresses,
                                    prefillSubject = replySubject,
                                    prefillBody = quotedBody,
                                ),
                            )
                        }) {
                            Text("Reply All")
                        }
                        var menuExpanded by remember { mutableStateOf(false) }
                        IconButton(onClick = { menuExpanded = true }) {
                            Icon(Icons.Default.MoreVert, contentDescription = "More actions")
                        }
                        DropdownMenu(
                            expanded = menuExpanded,
                            onDismissRequest = { menuExpanded = false },
                        ) {
                            DropdownMenuItem(
                                text = { Text("Archive") },
                                onClick = {
                                    menuExpanded = false
                                    vm.archive(onBack)
                                },
                                enabled = !vm.mutationInProgress,
                            )
                            DropdownMenuItem(
                                text = { Text("Delete") },
                                onClick = {
                                    menuExpanded = false
                                    vm.delete(onBack)
                                },
                                enabled = !vm.mutationInProgress,
                            )
                            DropdownMenuItem(
                                text = { Text("Mark as spam") },
                                onClick = {
                                    menuExpanded = false
                                    vm.markAsSpam(onBack)
                                },
                                enabled = !vm.mutationInProgress,
                            )
                        }
                    }
                },
            )
        },
    ) { padding ->
        when {
            vm.isLoading ->
                Box(
                    modifier = Modifier.fillMaxSize().padding(padding),
                    contentAlignment = Alignment.Center,
                ) {
                    CircularProgressIndicator()
                }

            vm.error != null ->
                Box(
                    modifier = Modifier.fillMaxSize().padding(padding),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(vm.error!!, color = MaterialTheme.colorScheme.error)
                }

            email != null ->
                Column(
                    modifier =
                        Modifier
                            .fillMaxSize()
                            .padding(padding)
                            .padding(16.dp)
                            .verticalScroll(rememberScrollState()),
                ) {
                    Text(
                        text = email.subject ?: "(no subject)",
                        style = MaterialTheme.typography.headlineSmall,
                    )
                    Spacer(Modifier.height(4.dp))
                    val from = email.from?.joinToString { it.name ?: it.email } ?: "Unknown"
                    Text(
                        text = "From: $from",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.secondary,
                    )
                    HorizontalDivider(Modifier.padding(vertical = 12.dp))
                    val textBody =
                        email.textBody
                            .firstOrNull()
                            ?.partId
                            ?.let { email.bodyValues[it]?.value }
                    val htmlBody =
                        email.htmlBody
                            .firstOrNull()
                            ?.partId
                            ?.let { email.bodyValues[it]?.value }
                    val hasImages = htmlBody != null && IMG_TAG.containsMatchIn(htmlBody)
                    if (hasImages && !vm.imagesAllowed) {
                        ImagesBanner(onLoadImages = { vm.allowImages() })
                    }
                    if (htmlBody != null) {
                        HtmlView(
                            html = htmlBody,
                            blockNetworkImages = !vm.imagesAllowed,
                            modifier = Modifier.fillMaxWidth(),
                        )
                    } else {
                        Text(textBody ?: "(no body)", style = MaterialTheme.typography.bodyMedium)
                    }
                    if (vm.inlineImages.isNotEmpty()) {
                        Spacer(Modifier.height(8.dp))
                        InlineImagesSection(vm.inlineImages)
                    }

                    // Attachments
                    if (vm.attachments.isNotEmpty()) {
                        HorizontalDivider(Modifier.padding(vertical = 12.dp))
                        Text(
                            text = "Attachments",
                            style = MaterialTheme.typography.labelLarge,
                            color = MaterialTheme.colorScheme.secondary,
                        )
                        Spacer(Modifier.height(4.dp))
                        vm.attachments.forEach { part ->
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                modifier = Modifier.fillMaxWidth().padding(vertical = 2.dp),
                            ) {
                                Text(
                                    text = "[A]",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.secondary,
                                )
                                Spacer(Modifier.width(4.dp))
                                Text(
                                    text = part.name ?: "attachment",
                                    style = MaterialTheme.typography.bodySmall,
                                    modifier = Modifier.weight(1f),
                                )
                                part.size?.let { sz ->
                                    Text(
                                        text = formatSize(sz),
                                        style = MaterialTheme.typography.bodySmall,
                                        color = MaterialTheme.colorScheme.secondary,
                                    )
                                    Spacer(Modifier.width(8.dp))
                                }
                                val isDownloading = vm.downloadingBlobId == part.blobId
                                Button(
                                    onClick = { vm.downloadAttachment(part) },
                                    enabled = !isDownloading && part.blobId != null,
                                ) {
                                    if (isDownloading) {
                                        CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 2.dp)
                                    } else {
                                        Text("Open")
                                    }
                                }
                            }
                        }
                        vm.downloadError?.let { err ->
                            Text(
                                text = err,
                                color = MaterialTheme.colorScheme.error,
                                style = MaterialTheme.typography.bodySmall,
                            )
                        }
                    }
                }
        }
    }
}

private val IMG_TAG = Regex("<img\\b", RegexOption.IGNORE_CASE)

@Composable
private fun ImagesBanner(onLoadImages: () -> Unit) {
    Surface(
        color = MaterialTheme.colorScheme.secondaryContainer,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 4.dp),
        ) {
            Text(
                "Images are blocked",
                style = MaterialTheme.typography.bodySmall,
                modifier = Modifier.weight(1f),
            )
            TextButton(onClick = onLoadImages) { Text("Load images") }
        }
    }
}

@Composable
private fun InlineImagesSection(images: Map<String, ImageBitmap>) {
    Column {
        images.values.forEach { bitmap ->
            Image(
                painter = BitmapPainter(bitmap),
                contentDescription = null,
                modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
            )
        }
    }
}

private fun formatSize(bytes: Long): String =
    when {
        bytes < 1024 -> "$bytes B"
        bytes < 1024 * 1024 -> "${bytes / 1024} KB"
        else -> {
            val tenths = (bytes * 10L / (1024L * 1024L))
            "${tenths / 10}.${tenths % 10} MB"
        }
    }
