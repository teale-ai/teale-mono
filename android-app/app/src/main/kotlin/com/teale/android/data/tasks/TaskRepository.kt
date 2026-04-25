package com.teale.android.data.tasks

import android.content.Context
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.workDataOf
import com.teale.android.data.chat.AutomationTaskEntity
import com.teale.android.data.chat.TaskDao
import com.teale.android.tasks.AssistantTaskWorker
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.flow.Flow

object TaskKind {
    const val MORNING_BRIEF = "morning_brief"
    const val AGENDA_PREP = "agenda_prep"
    const val SMS_AUTO_REPLY = "sms_auto_reply"
    const val EMAIL_TRIAGE = "email_triage"
    const val EMAIL_MARK_READ = "email_mark_read"
}

object TaskReadiness {
    const val READY = "ready"
    const val SMS_ROLE_REQUIRED = "sms_role_required"
    const val GMAIL_INTEGRATION_REQUIRED = "gmail_integration_required"
}

class TaskRepository(
    private val context: Context,
    private val dao: TaskDao,
) {
    fun observeTasks(): Flow<List<AutomationTaskEntity>> = dao.observeTasks()

    suspend fun seedDefaults() {
        if (dao.listTasks().isNotEmpty()) {
            return
        }
        dao.upsertTasks(defaultTasks())
    }

    suspend fun listTasks(): List<AutomationTaskEntity> = dao.listTasks()

    suspend fun getTask(taskId: String): AutomationTaskEntity? = dao.getTask(taskId)

    suspend fun setEnabled(taskId: String, enabled: Boolean) {
        val task = dao.getTask(taskId) ?: return
        val nextEnabled = enabled && task.readiness == TaskReadiness.READY
        dao.updateSchedule(
            taskId = taskId,
            enabled = nextEnabled,
            scheduleMinutes = task.scheduleMinutes,
            requiresCharging = task.requiresCharging,
            requiresUnmeteredNetwork = task.requiresUnmeteredNetwork,
        )
        syncScheduledWork(task.copy(enabled = nextEnabled))
    }

    suspend fun setSchedule(
        taskId: String,
        scheduleMinutes: Long,
        requiresCharging: Boolean,
        requiresUnmeteredNetwork: Boolean,
    ) {
        val task = dao.getTask(taskId) ?: return
        dao.updateSchedule(
            taskId = taskId,
            enabled = task.enabled,
            scheduleMinutes = scheduleMinutes,
            requiresCharging = requiresCharging,
            requiresUnmeteredNetwork = requiresUnmeteredNetwork,
        )
        syncScheduledWork(
            task.copy(
                scheduleMinutes = scheduleMinutes,
                requiresCharging = requiresCharging,
                requiresUnmeteredNetwork = requiresUnmeteredNetwork,
            )
        )
    }

    suspend fun recordTaskRun(taskId: String, status: String, summary: String) {
        dao.updateLastRun(
            taskId = taskId,
            lastRunAt = System.currentTimeMillis(),
            lastRunStatus = status,
            lastRunSummary = summary,
        )
    }

    fun runNow(taskId: String) {
        val request = OneTimeWorkRequestBuilder<AssistantTaskWorker>()
            .setInputData(workDataOf(AssistantTaskWorker.KEY_TASK_ID to taskId))
            .setConstraints(baseConstraints(requiresCharging = false, requiresUnmeteredNetwork = false))
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 15, TimeUnit.SECONDS)
            .build()
        WorkManager.getInstance(context).enqueueUniqueWork(
            "$WORK_NAME_PREFIX$taskId-manual",
            ExistingWorkPolicy.REPLACE,
            request,
        )
    }

    suspend fun syncAllScheduledWork() {
        dao.listTasks().forEach { syncScheduledWork(it) }
    }

    private fun syncScheduledWork(task: AutomationTaskEntity) {
        val workManager = WorkManager.getInstance(context)
        val uniqueName = "$WORK_NAME_PREFIX${task.id}"
        if (!task.enabled || task.readiness != TaskReadiness.READY) {
            workManager.cancelUniqueWork(uniqueName)
            return
        }

        val intervalMinutes = task.scheduleMinutes.coerceAtLeast(MIN_SCHEDULE_MINUTES)
        val request = PeriodicWorkRequestBuilder<AssistantTaskWorker>(
            intervalMinutes,
            TimeUnit.MINUTES,
        )
            .setInputData(workDataOf(AssistantTaskWorker.KEY_TASK_ID to task.id))
            .setConstraints(
                baseConstraints(
                    requiresCharging = task.requiresCharging,
                    requiresUnmeteredNetwork = task.requiresUnmeteredNetwork,
                )
            )
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
            .build()

        workManager.enqueueUniquePeriodicWork(
            uniqueName,
            ExistingPeriodicWorkPolicy.UPDATE,
            request,
        )
    }

    private fun baseConstraints(
        requiresCharging: Boolean,
        requiresUnmeteredNetwork: Boolean,
    ): Constraints = Constraints.Builder()
        .setRequiresCharging(requiresCharging)
        .setRequiredNetworkType(
            if (requiresUnmeteredNetwork) NetworkType.UNMETERED else NetworkType.CONNECTED
        )
        .build()

    private fun defaultTasks(): List<AutomationTaskEntity> = listOf(
        AutomationTaskEntity(
            id = "morning-brief",
            kind = TaskKind.MORNING_BRIEF,
            title = "Morning brief",
            description = "Uses Teale over the network to turn your calendar into a compact brief for today.",
            scheduleMinutes = 24 * 60,
            requiresCharging = false,
            requiresUnmeteredNetwork = false,
            enabled = false,
            readiness = TaskReadiness.READY,
        ),
        AutomationTaskEntity(
            id = "agenda-prep",
            kind = TaskKind.AGENDA_PREP,
            title = "Agenda prep",
            description = "Scans upcoming calendar events and flags meetings, travel, and likely follow-ups.",
            scheduleMinutes = 4 * 60,
            requiresCharging = false,
            requiresUnmeteredNetwork = false,
            enabled = false,
            readiness = TaskReadiness.READY,
        ),
        AutomationTaskEntity(
            id = "sms-auto-reply",
            kind = TaskKind.SMS_AUTO_REPLY,
            title = "SMS auto-reply",
            description = "Future: automatically answer incoming texts with Teale. Android requires the SMS role for a reliable implementation.",
            scheduleMinutes = 15,
            requiresCharging = false,
            requiresUnmeteredNetwork = false,
            enabled = false,
            readiness = TaskReadiness.SMS_ROLE_REQUIRED,
        ),
        AutomationTaskEntity(
            id = "email-triage",
            kind = TaskKind.EMAIL_TRIAGE,
            title = "Email triage",
            description = "Future: check mail, summarize inbox changes, and queue likely replies. Needs Gmail or IMAP integration, not just phone permissions.",
            scheduleMinutes = 60,
            requiresCharging = false,
            requiresUnmeteredNetwork = true,
            enabled = false,
            readiness = TaskReadiness.GMAIL_INTEGRATION_REQUIRED,
        ),
        AutomationTaskEntity(
            id = "email-mark-read",
            kind = TaskKind.EMAIL_MARK_READ,
            title = "Inbox cleanup",
            description = "Future: mark routine email as read and file low-priority mail. Needs account-level email APIs.",
            scheduleMinutes = 60,
            requiresCharging = false,
            requiresUnmeteredNetwork = true,
            enabled = false,
            readiness = TaskReadiness.GMAIL_INTEGRATION_REQUIRED,
        ),
    )

    companion object {
        private const val WORK_NAME_PREFIX = "teale-task-"
        private const val MIN_SCHEDULE_MINUTES = 15L
    }
}
