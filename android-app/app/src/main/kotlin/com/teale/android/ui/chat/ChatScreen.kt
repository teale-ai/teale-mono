package com.teale.android.ui.chat

import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
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
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlinx.coroutines.launch

// ── Bubble shapes (WhatsApp-style: round except the "tail" corner) ──
private val InboundBubble = RoundedCornerShape(topStart = 4.dp, topEnd = 18.dp, bottomEnd = 18.dp, bottomStart = 18.dp)
private val OutboundBubble = RoundedCornerShape(topStart = 18.dp, topEnd = 4.dp, bottomEnd = 18.dp, bottomStart = 18.dp)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ChatScreen(viewModel: ChatViewModel = viewModel()) {
    val messages by viewModel.messages.collectAsState()
    val thinking by viewModel.isThinking.collectAsState()
    val error by viewModel.error.collectAsState()
    var input by rememberSaveable { mutableStateOf("") }
    val listState = rememberLazyListState()
    val scope = rememberCoroutineScope()

    LaunchedEffect(messages.size, thinking) {
        val last = messages.size + if (thinking) 1 else 0
        if (last > 0) listState.animateScrollToItem((last - 1).coerceAtLeast(0))
    }

    Column(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background)) {
        PresenceHeader(isThinking = thinking)
        HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)

        Box(Modifier.weight(1f)) {
            LazyColumn(
                state = listState,
                modifier = Modifier.fillMaxSize(),
                contentPadding = PaddingValues(horizontal = 12.dp, vertical = 10.dp),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                itemsWithGrouping(messages)
                if (thinking) item { TypingIndicator() }
            }
        }

        error?.let {
            Row(
                Modifier.fillMaxWidth()
                    .background(MaterialTheme.colorScheme.errorContainer)
                    .padding(horizontal = 16.dp, vertical = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text("⚠ $it", color = MaterialTheme.colorScheme.onErrorContainer, modifier = Modifier.weight(1f))
                TextButton(onClick = { viewModel.clearError() }) { Text(stringResource(R.string.action_dismiss)) }
            }
        }

        Composer(
            value = input,
            enabled = !thinking,
            onChange = { input = it },
            onSend = {
                val t = input
                if (t.isNotBlank()) {
                    viewModel.send(t)
                    input = ""
                    scope.launch { /* auto-scroll handled in LaunchedEffect */ }
                }
            },
        )
    }
}

private fun androidx.compose.foundation.lazy.LazyListScope.itemsWithGrouping(
    messages: List<ChatMessageEntity>,
) {
    for (i in messages.indices) {
        val m = messages[i]
        val prev = messages.getOrNull(i - 1)
        // Group if same role and posted within 2 minutes of prev — hides avatar +
        // tightens spacing so a burst of tokens reads as one thought.
        val grouped = prev != null &&
            prev.role == m.role &&
            (m.timestamp - prev.timestamp) < 2 * 60 * 1000

        item(key = m.id) {
            MessageBubble(m, groupedWithPrev = grouped)
        }
    }
}

@Composable
private fun PresenceHeader(isThinking: Boolean) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.surface)
            .padding(horizontal = 16.dp, vertical = 12.dp),
    ) {
        TealeAvatar(sizeDp = 36)
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(
                stringResource(R.string.ai_name),
                style = MaterialTheme.typography.titleMedium,
                color = MaterialTheme.colorScheme.onSurface,
            )
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(
                    Modifier.size(8.dp).clip(CircleShape)
                        .background(MaterialTheme.colorScheme.primary)
                )
                Spacer(Modifier.width(6.dp))
                Text(
                    if (isThinking) stringResource(R.string.chat_typing)
                    else stringResource(R.string.chat_presence_online),
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

@Composable
private fun MessageBubble(message: ChatMessageEntity, groupedWithPrev: Boolean) {
    val isUser = message.role == "user"
    val shape: Shape = if (isUser) OutboundBubble else InboundBubble
    val bgColor = if (isUser) MaterialTheme.colorScheme.primary
    else MaterialTheme.colorScheme.surface
    val textColor = if (isUser) MaterialTheme.colorScheme.onPrimary
    else MaterialTheme.colorScheme.onSurface

    Row(
        horizontalArrangement = if (isUser) Arrangement.End else Arrangement.Start,
        modifier = Modifier.fillMaxWidth()
            .padding(top = if (groupedWithPrev) 0.dp else 4.dp),
    ) {
        // Inbound bubbles get a Teale avatar on the first in a group.
        if (!isUser) {
            if (groupedWithPrev) {
                Spacer(Modifier.width(36.dp + 8.dp))
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
                    text = if (message.content.isEmpty() && message.streaming) "…"
                    else message.content,
                    color = textColor,
                    style = MaterialTheme.typography.bodyLarge,
                )
            }
            if (!groupedWithPrev) {
                Text(
                    text = SimpleDateFormat("h:mm a", Locale.getDefault())
                        .format(Date(message.timestamp))
                        .lowercase(Locale.getDefault()),
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    style = MaterialTheme.typography.labelSmall,
                    modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp),
                )
            }
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
        ) { AnimatedDots() }
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
                Modifier.size(7.dp).clip(CircleShape)
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
            modifier = Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 8.dp),
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
                modifier = Modifier.size(48.dp).padding(bottom = 4.dp),
                colors = IconButtonDefaults.filledIconButtonColors(
                    containerColor = MaterialTheme.colorScheme.primary.copy(alpha = sendAlpha),
                    contentColor = MaterialTheme.colorScheme.onPrimary,
                ),
            ) {
                Icon(Icons.AutoMirrored.Filled.Send, contentDescription = stringResource(R.string.action_send))
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
        // Stylised two-tone "T" mark — we intentionally don't render the full
        // brain glyph at this size since at 36dp it blurs into a blob.
        Text(
            "T",
            color = Color.White,
            fontWeight = FontWeight.Bold,
            style = MaterialTheme.typography.titleMedium,
        )
    }
}
