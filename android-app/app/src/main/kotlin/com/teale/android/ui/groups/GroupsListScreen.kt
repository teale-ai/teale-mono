package com.teale.android.ui.groups

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Group
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.teale.android.R

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun GroupsListScreen(
    onOpenGroup: (String) -> Unit,
    vm: GroupsViewModel = viewModel(),
) {
    val groups by vm.groups.collectAsState()
    var showCreate by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) { vm.refreshList() }

    Scaffold(
        floatingActionButton = {
            FloatingActionButton(onClick = { showCreate = true }) {
                Icon(Icons.Filled.Add, contentDescription = stringResource(R.string.groups_new))
            }
        }
    ) { padding ->
        Box(Modifier.padding(padding).fillMaxSize()) {
            if (groups.isEmpty()) {
                EmptyState(Modifier.align(Alignment.Center))
            } else {
                LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(vertical = 8.dp)) {
                    items(groups, key = { it.groupID }) { g ->
                        ListItem(
                            headlineContent = { Text(g.title, fontWeight = FontWeight.Medium) },
                            supportingContent = {
                                Text(
                                    pluralStringResource(
                                        R.plurals.groups_member_count,
                                        g.memberCount.toInt(),
                                        g.memberCount.toInt(),
                                    )
                                )
                            },
                            leadingContent = {
                                Icon(Icons.Filled.Group, contentDescription = null)
                            },
                            modifier = Modifier.fillMaxWidth().clickable { onOpenGroup(g.groupID) },
                        )
                        HorizontalDivider()
                    }
                }
            }
        }
    }

    if (showCreate) {
        CreateGroupDialog(
            onDismiss = { showCreate = false },
            onCreate = { title ->
                vm.createGroup(title) { id ->
                    showCreate = false
                    onOpenGroup(id)
                }
            },
        )
    }
}

@Composable
private fun EmptyState(modifier: Modifier = Modifier) {
    Column(
        modifier = modifier.padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Icon(
            Icons.Filled.Group,
            contentDescription = null,
            modifier = Modifier.size(48.dp),
            tint = MaterialTheme.colorScheme.primary,
        )
        Spacer(Modifier.height(12.dp))
        Text(stringResource(R.string.groups_empty_title), style = MaterialTheme.typography.titleMedium)
        Spacer(Modifier.height(4.dp))
        Text(
            stringResource(R.string.groups_empty_desc),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun CreateGroupDialog(
    onDismiss: () -> Unit,
    onCreate: (String) -> Unit,
) {
    var title by remember { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.groups_new)) },
        text = {
            OutlinedTextField(
                value = title,
                onValueChange = { title = it },
                label = { Text(stringResource(R.string.groups_title_label)) },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
        },
        confirmButton = {
            TextButton(
                onClick = { if (title.isNotBlank()) onCreate(title.trim()) },
                enabled = title.isNotBlank(),
            ) { Text(stringResource(R.string.action_create)) }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text(stringResource(R.string.action_cancel)) }
        },
    )
}

