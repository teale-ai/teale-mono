package com.teale.android.ui.chat

import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.AssistChip
import androidx.compose.material3.AssistChipDefaults
import androidx.compose.material3.Badge
import androidx.compose.material3.BadgedBox
import androidx.compose.material3.Card
import androidx.compose.material3.ElevatedCard
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilledIconButton
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.teale.android.R
import com.teale.android.data.chat.ChatMessageEntity
import com.teale.android.data.chat.ChatThreadEntity
import com.teale.android.data.inference.NetworkModel
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

private val InboundBubble = RoundedCornerShape(topStart = 4.dp, topEnd = 18.dp, bottomEnd = 18.dp, bottomStart = 18.dp)
private val OutboundBubble = RoundedCornerShape(topStart = 18.dp, topEnd = 4.dp, bottomEnd = 18.dp, bottomStart = 18.dp)

@Composable
fun ChatScreen(viewModel: ChatViewModel = viewModel()) {
    val threads by viewModel.threads.collectAsState()
    val selectedThread by viewModel.selectedThread.collectAsState()
    val messages by viewModel.messages.collectAsState()
    val networkModels by viewModel.networkModels.collectAsState()
    val networkStats by viewModel.networkStats.collectAsState()
    val walletBalance by viewModel.walletBalance.collectAsState()
    val settings by viewModel.settingsSnapshot.collectAsState()
    val thinking by viewModel.isThinking.collectAsState()
    val error by viewModel.error.collectAsState()
    val info by viewModel.info.collectAsState()
    val interruptedDrafts by viewModel.interruptedDrafts.collectAsState()

    val interruptedDraft = selectedThread?.id?.let(interruptedDrafts::get)
    var input by rememberSaveable { mutableStateOf("") }
    val listState = rememberLazyListState()

    LaunchedEffect(messages.size, thinking, interruptedDraft?.text) {
        val totalRows = messages.size + if (interruptedDraft != null) 1 else 0
        if (totalRows > 0) {
            listState.animateScrollToItem(totalRows - 1)
        }
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
    ) {
        HomeOverview(
            networkDevices = networkStats?.totalDevices,
            networkModels = networkStats?.totalModels,
            walletCredits = walletBalance?.balance_credits,
            supplyEnabled = settings.supplyEnabled,
        )
        ThreadStrip(
            threads = threads,
            selectedThread = selectedThread,
            busy = thinking,
            onSelect = viewModel::selectThread,
            onCreate = viewModel::createThread,
            onClose = viewModel::closeThread,
        )
        ModelPicker(
            thread = selectedThread,
            models = networkModels,
            busy = thinking,
            onChange = viewModel::setThreadModel,
        )
        info?.let {
            InlineBanner(
                text = it,
                containerColor = MaterialTheme.colorScheme.secondaryContainer,
                contentColor = MaterialTheme.colorScheme.onSecondaryContainer,
                onDismiss = viewModel::clearInfo,
            )
        }
        error?.let {
            InlineBanner(
                text = it,
                containerColor = MaterialTheme.colorScheme.errorContainer,
                contentColor = MaterialTheme.colorScheme.onErrorContainer,
                onDismiss = viewModel::clearError,
            )
        }
        HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)

        Box(Modifier.weight(1f)) {
            LazyColumn(
                state = listState,
                modifier = Modifier.fillMaxSize(),
                contentPadding = PaddingValues(horizontal = 12.dp, vertical = 10.dp),
                verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                if (messages.isEmpty() && interruptedDraft == null) {
                    item {
                        EmptyThreadCard()
                    }
                }
                itemsWithGrouping(messages)
                if (thinking) {
                    item { TypingIndicator() }
                }
                if (interruptedDraft != null && !thinking) {
                    item {
                        InterruptedDraftCard(interruptedDraft.text)
                    }
                }
            }
        }

        Composer(
            value = input,
            enabled = !thinking,
            onChange = { input = it },
            onSend = {
                if (input.isNotBlank()) {
                    viewModel.send(input)
                    input = ""
                }
            },
        )
    }
}

@Composable
private fun HomeOverview(
    networkDevices: Int?,
    networkModels: Int?,
    walletCredits: Long?,
    supplyEnabled: Boolean,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 14.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Text(
            stringResource(R.string.home_title),
            style = MaterialTheme.typography.headlineSmall,
            fontWeight = FontWeight.SemiBold,
        )
        Text(
            stringResource(R.string.home_subtitle),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        LazyRow(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            item {
                OverviewCard(
                    label = stringResource(R.string.home_card_network),
                    value = networkDevices?.toString() ?: "—",
                    note = stringResource(R.string.home_card_network_note, networkModels ?: 0),
                )
            }
            item {
                OverviewCard(
                    label = stringResource(R.string.home_card_wallet),
                    value = walletCredits?.let { "%,d".format(it) } ?: "—",
                    note = stringResource(R.string.home_card_wallet_note),
                )
            }
            item {
                OverviewCard(
                    label = stringResource(R.string.home_card_supply),
                    value = if (supplyEnabled) stringResource(R.string.home_supply_on) else stringResource(R.string.home_supply_off),
                    note = stringResource(R.string.home_card_supply_note),
                )
            }
        }
    }
}

@Composable
private fun OverviewCard(label: String, value: String, note: String) {
    ElevatedCard(modifier = Modifier.width(176.dp)) {
        Column(
            modifier = Modifier.padding(14.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Text(label, style = MaterialTheme.typography.labelMedium)
            Text(value, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
            Text(
                note,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun ThreadStrip(
    threads: List<ChatThreadEntity>,
    selectedThread: ChatThreadEntity?,
    busy: Boolean,
    onSelect: (String) -> Unit,
    onCreate: () -> Unit,
    onClose: (String) -> Unit,
) {
    LazyRow(
        modifier = Modifier.fillMaxWidth(),
        contentPadding = PaddingValues(horizontal = 16.dp, vertical = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        items(threads, key = { it.id }) { thread ->
            BadgedBox(
                badge = {
                    if (thread.id == selectedThread?.id) {
                        Badge()
                    }
                }
            ) {
                FilterChip(
                    selected = thread.id == selectedThread?.id,
                    onClick = { onSelect(thread.id) },
                    label = { Text(thread.title) },
                    trailingIcon = if (threads.size > 1) {
                        {
                            IconButton(
                                onClick = { onClose(thread.id) },
                                enabled = !busy,
                                modifier = Modifier.size(18.dp),
                            ) {
                                Icon(
                                    Icons.Filled.Close,
                                    contentDescription = stringResource(R.string.chat_close_thread),
                                    modifier = Modifier.size(14.dp),
                                )
                            }
                        }
                    } else null,
                )
            }
        }
        item {
            AssistChip(
                onClick = onCreate,
                enabled = !busy,
                label = { Text(stringResource(R.string.chat_new_thread)) },
                leadingIcon = {
                    Icon(Icons.Filled.Add, contentDescription = null)
                },
                colors = AssistChipDefaults.assistChipColors(),
            )
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ModelPicker(
    thread: ChatThreadEntity?,
    models: List<NetworkModel>,
    busy: Boolean,
    onChange: (String) -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    val selectedModel = models.firstOrNull { it.id == thread?.selectedModelId } ?: models.firstOrNull()
    val value = selectedModel?.id ?: stringResource(R.string.chat_models_waiting)

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 4.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        ExposedDropdownMenuBox(
            expanded = expanded,
            onExpandedChange = { expanded = !expanded && models.isNotEmpty() && !busy },
        ) {
            OutlinedTextField(
                readOnly = true,
                value = value,
                onValueChange = { },
                modifier = Modifier
                    .fillMaxWidth()
                    .menuAnchor(),
                label = { Text(stringResource(R.string.chat_model_picker_title)) },
                supportingText = {
                    Text(
                        selectedModel?.description ?: stringResource(R.string.chat_model_picker_note)
                    )
                },
                trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = expanded) },
            )
            ExposedDropdownMenu(
                expanded = expanded,
                onDismissRequest = { expanded = false },
            ) {
                models.forEach { model ->
                    DropdownMenuItem(
                        text = {
                            Column {
                                Text(model.id)
                                model.description?.let {
                                    Text(
                                        it,
                                        style = MaterialTheme.typography.bodySmall,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    )
                                }
                            }
                        },
                        onClick = {
                            onChange(model.id)
                            expanded = false
                        },
                    )
                }
            }
        }
        Text(
            stringResource(R.string.chat_thread_context_note),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun InlineBanner(
    text: String,
    containerColor: Color,
    contentColor: Color,
    onDismiss: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(containerColor)
            .padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(text, color = contentColor, modifier = Modifier.weight(1f))
        TextButton(onClick = onDismiss) {
            Text(stringResource(R.string.action_dismiss))
        }
    }
}

@Composable
private fun EmptyThreadCard() {
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(
                stringResource(R.string.chat_empty_title),
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
            )
            Text(
                stringResource(R.string.chat_thread_context_note),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

private fun androidx.compose.foundation.lazy.LazyListScope.itemsWithGrouping(
    messages: List<ChatMessageEntity>,
) {
    for (i in messages.indices) {
        val message = messages[i]
        val previous = messages.getOrNull(i - 1)
        val grouped = previous != null &&
            previous.role == message.role &&
            (message.timestamp - previous.timestamp) < 2 * 60 * 1000
        item(key = message.id) {
            MessageBubble(message = message, groupedWithPrev = grouped)
        }
    }
}

@Composable
private fun MessageBubble(message: ChatMessageEntity, groupedWithPrev: Boolean) {
    val isUser = message.role == "user"
    val shape: Shape = if (isUser) OutboundBubble else InboundBubble
    val bgColor = if (isUser) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.surface
    val textColor = if (isUser) MaterialTheme.colorScheme.onPrimary else MaterialTheme.colorScheme.onSurface
    val usageMeta = message.tokenCount?.let { count ->
        val countLabel = "%,d".format(count)
        if (message.role == "user") {
            if (message.tokenEstimated) {
                stringResource(R.string.chat_tokens_in_approx, countLabel)
            } else {
                stringResource(R.string.chat_tokens_in, countLabel)
            }
        } else {
            if (message.tokenEstimated) {
                stringResource(R.string.chat_tokens_out_approx, countLabel)
            } else {
                stringResource(R.string.chat_tokens_out, countLabel)
            }
        }
    }

    Row(
        horizontalArrangement = if (isUser) Arrangement.End else Arrangement.Start,
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = if (groupedWithPrev) 0.dp else 4.dp),
    ) {
        if (!isUser) {
            if (groupedWithPrev) {
                Spacer(Modifier.width(44.dp))
            } else {
                TealeAvatar(sizeDp = 36)
                Spacer(Modifier.width(8.dp))
            }
        }

        Column(
            horizontalAlignment = if (isUser) Alignment.End else Alignment.Start,
            modifier = Modifier.widthIn(max = 320.dp),
        ) {
            Box(
                modifier = Modifier
                    .clip(shape)
                    .background(bgColor)
                    .padding(horizontal = 14.dp, vertical = 10.dp)
            ) {
                Text(
                    text = if (message.content.isEmpty() && message.streaming) "…" else message.content,
                    color = textColor,
                    style = MaterialTheme.typography.bodyLarge,
                )
            }
            Row(
                modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = SimpleDateFormat("h:mm a", Locale.getDefault())
                        .format(Date(message.timestamp))
                        .lowercase(Locale.getDefault()),
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    style = MaterialTheme.typography.labelSmall,
                )
                usageMeta?.let {
                    Text(
                        text = " · $it",
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        style = MaterialTheme.typography.labelSmall,
                    )
                }
            }
        }
    }
}

@Composable
private fun InterruptedDraftCard(text: String) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = androidx.compose.material3.CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceVariant,
        ),
    ) {
        Column(
            modifier = Modifier.padding(14.dp),
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Text(
                stringResource(R.string.chat_interrupted_title),
                style = MaterialTheme.typography.labelLarge,
                fontWeight = FontWeight.SemiBold,
            )
            Text(text, style = MaterialTheme.typography.bodyMedium)
            Text(
                stringResource(R.string.chat_interrupted_body),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun TypingIndicator() {
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(top = 4.dp)) {
        TealeAvatar(sizeDp = 36)
        Spacer(Modifier.width(8.dp))
        Box(
            modifier = Modifier
                .clip(InboundBubble)
                .background(MaterialTheme.colorScheme.surface)
                .padding(horizontal = 14.dp, vertical = 12.dp)
        ) {
            AnimatedDots()
        }
    }
}

@Composable
private fun AnimatedDots() {
    val transition = rememberInfiniteTransition(label = "dots")
    Row(verticalAlignment = Alignment.CenterVertically) {
        repeat(3) { idx ->
            val alpha by transition.animateFloat(
                initialValue = 0.3f,
                targetValue = 1f,
                animationSpec = infiniteRepeatable(
                    animation = tween(durationMillis = 600, delayMillis = idx * 120),
                ),
                label = "dot-$idx",
            )
            Box(
                Modifier
                    .size(7.dp)
                    .clip(CircleShape)
                    .background(MaterialTheme.colorScheme.primary.copy(alpha = alpha))
            )
            if (idx < 2) Spacer(Modifier.width(4.dp))
        }
    }
}

@Composable
private fun Composer(
    value: String,
    enabled: Boolean,
    onChange: (String) -> Unit,
    onSend: () -> Unit,
) {
    val canSend = enabled && value.isNotBlank()
    val sendAlpha by animateFloatAsState(if (canSend) 1f else 0.35f, label = "send-alpha")
    Surface(
        tonalElevation = 2.dp,
        color = MaterialTheme.colorScheme.surface,
    ) {
        Row(
            verticalAlignment = Alignment.Bottom,
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 10.dp, vertical = 8.dp),
        ) {
            OutlinedTextField(
                value = value,
                onValueChange = onChange,
                placeholder = { Text(stringResource(R.string.chat_hint)) },
                modifier = Modifier.weight(1f),
                shape = RoundedCornerShape(24.dp),
                singleLine = false,
                maxLines = 5,
                enabled = enabled,
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Default),
                textStyle = MaterialTheme.typography.bodyLarge,
            )
            Spacer(Modifier.width(8.dp))
            FilledIconButton(
                onClick = onSend,
                enabled = canSend,
                modifier = Modifier
                    .size(48.dp)
                    .padding(bottom = 4.dp),
                colors = IconButtonDefaults.filledIconButtonColors(
                    containerColor = MaterialTheme.colorScheme.primary.copy(alpha = sendAlpha),
                    contentColor = MaterialTheme.colorScheme.onPrimary,
                ),
            ) {
                Icon(
                    Icons.AutoMirrored.Filled.Send,
                    contentDescription = stringResource(R.string.action_send),
                )
            }
        }
    }
}

@Composable
internal fun TealeAvatar(sizeDp: Int) {
    Box(
        modifier = Modifier
            .size(sizeDp.dp)
            .clip(CircleShape)
            .background(MaterialTheme.colorScheme.primary),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            "T",
            color = Color.White,
            fontWeight = FontWeight.Bold,
            style = MaterialTheme.typography.titleMedium,
        )
    }
}
