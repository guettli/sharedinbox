package de.sharedinbox.ui.screen

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import de.sharedinbox.core.jmap.mail.Email
import de.sharedinbox.core.jmap.mail.EmailKeyword
import de.sharedinbox.ui.viewmodel.SearchViewModel

@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
fun SearchScreen(
    accountId: String,
    onNavigateToDetail: (emailId: String) -> Unit,
    onBack: () -> Unit,
    vm: SearchViewModel,
) {
    vm.init(accountId)
    val inSelection = vm.inSelectionMode
    val focusRequester = remember { FocusRequester() }

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
                    title = {
                        TextField(
                            value = vm.query,
                            onValueChange = { vm.onQueryChange(it) },
                            placeholder = { Text("Search emails…") },
                            singleLine = true,
                            leadingIcon = {
                                Icon(Icons.Default.Search, contentDescription = null)
                            },
                            trailingIcon = if (vm.query.isNotEmpty()) {
                                {
                                    IconButton(onClick = { vm.onQueryChange("") }) {
                                        Icon(Icons.Default.Close, contentDescription = "Clear search")
                                    }
                                }
                            } else null,
                            colors = TextFieldDefaults.colors(
                                focusedContainerColor = Color.Transparent,
                                unfocusedContainerColor = Color.Transparent,
                                focusedIndicatorColor = Color.Transparent,
                                unfocusedIndicatorColor = Color.Transparent,
                            ),
                            modifier = Modifier
                                .fillMaxWidth()
                                .focusRequester(focusRequester),
                        )
                    },
                    navigationIcon = {
                        IconButton(onClick = onBack) {
                            Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                        }
                    },
                )
            }
        },
    ) { padding ->
        Box(
            Modifier
                .fillMaxSize()
                .padding(padding),
        ) {
            when {
                vm.isSearching -> CircularProgressIndicator(
                    Modifier
                        .align(Alignment.Center)
                        .semantics { contentDescription = "Searching" },
                )

                vm.error != null -> ErrorContent(
                    message = vm.error!!,
                    onRetry = { vm.onQueryChange(vm.query) },
                    modifier = Modifier.align(Alignment.Center),
                )

                vm.query.isBlank() -> Text(
                    text = "Type to search across subject, sender, and preview.",
                    style = MaterialTheme.typography.bodyLarge,
                    modifier = Modifier
                        .align(Alignment.Center)
                        .padding(horizontal = 24.dp),
                )

                vm.results.isEmpty() -> Text(
                    text = "No results for \"${vm.query}\".",
                    style = MaterialTheme.typography.bodyLarge,
                    modifier = Modifier
                        .align(Alignment.Center)
                        .padding(horizontal = 24.dp),
                )

                else -> LazyColumn(Modifier.fillMaxSize()) {
                    items(vm.results, key = { it.id }) { email ->
                        val selected = email.id in vm.selectedIds
                        SearchEmailRow(
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
        }
    }

    LaunchedEffect(Unit) {
        focusRequester.requestFocus()
    }
}

@Composable
private fun SearchEmailRow(
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
        modifier = Modifier
            .combinedClickable(onClick = onClick, onLongClick = onLongClick)
            .semantics {
                contentDescription = buildString {
                    if (isUnread) append("Unread. ")
                    append(email.subject ?: "No subject")
                    append(". From $from")
                }
            },
    )
}
