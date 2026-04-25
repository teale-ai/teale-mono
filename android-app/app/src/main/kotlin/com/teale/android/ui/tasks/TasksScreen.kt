package com.teale.android.ui.tasks

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import com.teale.android.R
import com.teale.android.TealeApplication
import com.teale.android.data.chat.AutomationTaskEntity
import com.teale.android.data.tasks.TaskReadiness
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import androidx.compose.ui.res.stringResource

private val SCHEDULE_OPTIONS = listOf(15L, 60L, 240L, 1440L)

class TasksViewModel : ViewModel() {
    private val repo = TealeApplication.instance.container.taskRepository

    private val _tasks = MutableStateFlow<List<AutomationTaskEntity>>(emptyList())
    val tasks: StateFlow<List<AutomationTaskEntity>> = _tasks.asStateFlow()

    init {
        viewModelScope.launch {
            repo.seedDefaults()
            repo.syncAllScheduledWork()
            repo.observeTasks().collect { _tasks.value = it }
        }
    }

    fun setEnabled(taskId: String, enabled: Boolean) {
        viewModelScope.launch { repo.setEnabled(taskId, enabled) }
    }

    fun setSchedule(task: AutomationTaskEntity, scheduleMinutes: Long) {
        viewModelScope.launch {
            repo.setSchedule(
                taskId = task.id,
                scheduleMinutes = scheduleMinutes,
                requiresCharging = task.requiresCharging,
                requiresUnmeteredNetwork = task.requiresUnmeteredNetwork,
            )
        }
    }

    fun runNow(taskId: String) {
        repo.runNow(taskId)
    }
}

@Composable
fun TasksScreen(viewModel: TasksViewModel = viewModel()) {
    val tasks by viewModel.tasks.collectAsState()

    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        item {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(
                    stringResource(R.string.tasks_title),
                    style = MaterialTheme.typography.headlineSmall,
                    fontWeight = FontWeight.SemiBold,
                )
                Text(
                    stringResource(R.string.tasks_subtitle),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
        items(tasks, key = { it.id }) { task ->
            TaskCard(
                task = task,
                onEnabledChange = { viewModel.setEnabled(task.id, it) },
                onRunNow = { viewModel.runNow(task.id) },
                onSelectSchedule = { viewModel.setSchedule(task, it) },
            )
        }
    }
}

@Composable
private fun TaskCard(
    task: AutomationTaskEntity,
    onEnabledChange: (Boolean) -> Unit,
    onRunNow: () -> Unit,
    onSelectSchedule: (Long) -> Unit,
) {
    val readinessReady = task.readiness == TaskReadiness.READY
    val badgeColor = if (readinessReady) {
        MaterialTheme.colorScheme.primaryContainer
    } else {
        MaterialTheme.colorScheme.surfaceVariant
    }
    val badgeText = when (task.readiness) {
        TaskReadiness.READY -> stringResource(R.string.tasks_readiness_ready)
        TaskReadiness.SMS_ROLE_REQUIRED -> stringResource(R.string.tasks_readiness_sms)
        TaskReadiness.GMAIL_INTEGRATION_REQUIRED -> stringResource(R.string.tasks_readiness_email)
        else -> task.readiness
    }

    Card(
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
    ) {
        Column(
            modifier = Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(task.title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                    Text(
                        task.description,
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                Switch(
                    checked = task.enabled,
                    onCheckedChange = onEnabledChange,
                    enabled = readinessReady,
                )
            }

            Text(
                badgeText,
                modifier = Modifier
                    .clip(RoundedCornerShape(999.dp))
                    .background(badgeColor)
                    .padding(horizontal = 10.dp, vertical = 6.dp),
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurface,
            )

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                SCHEDULE_OPTIONS.forEach { option ->
                    FilterChip(
                        selected = task.scheduleMinutes == option,
                        onClick = { onSelectSchedule(option) },
                        enabled = readinessReady,
                        label = { Text(scheduleLabel(option)) },
                    )
                }
            }

            if (task.lastRunSummary != null) {
                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(
                        stringResource(R.string.tasks_last_run),
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Text(
                        formatLastRun(task.lastRunAt),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Text(task.lastRunSummary, style = MaterialTheme.typography.bodySmall)
                }
            } else {
                Text(
                    stringResource(R.string.tasks_never_run),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    stringResource(R.string.tasks_workmanager_note),
                    modifier = Modifier.weight(1f),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Spacer(Modifier.height(0.dp))
                TextButton(onClick = onRunNow, enabled = readinessReady) {
                    Text(stringResource(R.string.tasks_run_now))
                }
            }
        }
    }
}

private fun scheduleLabel(minutes: Long): String = when (minutes) {
    15L -> "15m"
    60L -> "1h"
    240L -> "4h"
    1440L -> "Daily"
    else -> "${minutes}m"
}

private fun formatLastRun(timestamp: Long?): String {
    if (timestamp == null) return "—"
    return SimpleDateFormat("MMM d · h:mm a", Locale.getDefault()).format(Date(timestamp))
}
