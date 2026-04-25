package com.teale.android.tasks

import android.content.Context
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import com.teale.android.R
import com.teale.android.TealeApplication
import com.teale.android.data.inference.ChatEvent
import com.teale.android.data.inference.ChatMessage
import com.teale.android.data.tasks.TaskKind
import com.teale.android.data.tasks.TaskReadiness
import com.teale.android.skills.CalendarSkill
import kotlinx.coroutines.flow.first

class AssistantTaskWorker(
    appContext: Context,
    params: WorkerParameters,
) : CoroutineWorker(appContext, params) {

    override suspend fun doWork(): Result {
        val app = applicationContext as TealeApplication
        val repo = app.container.taskRepository
        val gatewayClient = app.container.gatewayClient
        val taskId = inputData.getString(KEY_TASK_ID) ?: return Result.failure()
        val task = repo.getTask(taskId) ?: return Result.failure()

        if (task.readiness != TaskReadiness.READY) {
            repo.recordTaskRun(
                taskId = task.id,
                status = "blocked",
                summary = blockedSummary(task.readiness),
            )
            return Result.success()
        }

        return runCatching {
            val settings = app.container.settingsStore.snapshot.first()
            val models = gatewayClient.listModels()
            val modelId = models.firstOrNull { it.id == settings.preferredModel }?.id
                ?: models.firstOrNull()?.id
                ?: settings.preferredModel

            if (modelId.isBlank()) {
                throw IllegalStateException("No demand models are available for Tasks.")
            }

            val summary = when (task.kind) {
                TaskKind.MORNING_BRIEF -> runCalendarTask(
                    modelId = modelId,
                    systemPrompt =
                        "You are Teale running as a scheduled phone assistant. Summarize the user's day in 4 concise bullets with the most important priorities first.",
                    userPrompt =
                        "Build a morning brief from the device calendar. Mention urgent timing, travel, preparation work, and any obvious conflicts.",
                )

                TaskKind.AGENDA_PREP -> runCalendarTask(
                    modelId = modelId,
                    systemPrompt =
                        "You are Teale running as a scheduled phone assistant. Focus on preparation and follow-up risks, not generic encouragement.",
                    userPrompt =
                        "Review the device calendar and call out meetings that need prep, materials, travel time, or a follow-up draft.",
                )

                else -> blockedSummary(task.readiness)
            }

            repo.recordTaskRun(task.id, status = "ok", summary = summary)
            notify(task.title, summary)
            Result.success()
        }.getOrElse { error ->
            val message = error.message ?: "task failed"
            repo.recordTaskRun(task.id, status = "error", summary = message)
            Result.retry()
        }
    }

    private suspend fun runCalendarTask(
        modelId: String,
        systemPrompt: String,
        userPrompt: String,
    ): String {
        val app = applicationContext as TealeApplication
        val gatewayClient = app.container.gatewayClient
        val calendarContext = if (CalendarSkill.hasPermission(app)) {
            CalendarSkill.upcomingSummary(app)
        } else {
            app.getString(R.string.calendar_permission_hint)
        }

        val response = StringBuilder()
        var streamError: String? = null
        gatewayClient.streamChat(
            model = modelId,
            messages = listOf(
                ChatMessage("system", systemPrompt),
                ChatMessage("user", "$userPrompt\n\n$calendarContext"),
            ),
            temperature = 0.4,
        ).collect { event ->
            when (event) {
                is ChatEvent.Delta -> response.append(event.text)
                is ChatEvent.Error -> streamError = event.message
                is ChatEvent.Usage -> Unit
                ChatEvent.Final -> Unit
            }
        }

        if (streamError != null) {
            throw IllegalStateException(streamError)
        }

        return response.toString().trim().ifBlank {
            applicationContext.getString(R.string.tasks_run_empty)
        }
    }

    private fun blockedSummary(readiness: String): String = when (readiness) {
        TaskReadiness.SMS_ROLE_REQUIRED ->
            applicationContext.getString(R.string.tasks_readiness_sms_body)
        TaskReadiness.GMAIL_INTEGRATION_REQUIRED ->
            applicationContext.getString(R.string.tasks_readiness_email_body)
        else -> applicationContext.getString(R.string.tasks_run_empty)
    }

    private fun notify(title: String, summary: String) {
        val notification = NotificationCompat.Builder(applicationContext, TealeApplication.TASKS_CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_supply_tile)
            .setContentTitle(title)
            .setContentText(summary)
            .setStyle(NotificationCompat.BigTextStyle().bigText(summary))
            .setAutoCancel(true)
            .build()
        NotificationManagerCompat.from(applicationContext)
            .notify(title.hashCode(), notification)
    }

    companion object {
        const val KEY_TASK_ID = "task_id"
    }
}
