package com.teale.android

import android.app.Application
import android.app.NotificationChannel
import android.app.NotificationManager
import com.teale.android.data.AppContainer
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

class TealeApplication : Application() {
    lateinit var container: AppContainer
        private set

    private val appScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    override fun onCreate() {
        super.onCreate()
        instance = this
        container = AppContainer(this)
        ensureNotificationChannel()
        appScope.launch {
            container.taskRepository.seedDefaults()
            container.taskRepository.syncAllScheduledWork()
        }
    }

    private fun ensureNotificationChannel() {
        val nm = getSystemService(NotificationManager::class.java) ?: return
        val supplyChannel = NotificationChannel(
            SUPPLY_CHANNEL_ID,
            getString(R.string.supply_notification_channel),
            NotificationManager.IMPORTANCE_LOW,
        )
        val tasksChannel = NotificationChannel(
            TASKS_CHANNEL_ID,
            getString(R.string.tasks_notification_channel),
            NotificationManager.IMPORTANCE_DEFAULT,
        )
        nm.createNotificationChannels(listOf(supplyChannel, tasksChannel))
    }

    companion object {
        const val SUPPLY_CHANNEL_ID = "teale_supply"
        const val TASKS_CHANNEL_ID = "teale_tasks"
        lateinit var instance: TealeApplication
            private set
    }
}
