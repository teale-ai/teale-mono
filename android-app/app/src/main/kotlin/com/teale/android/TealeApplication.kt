package com.teale.android

import android.app.Application
import android.app.NotificationChannel
import android.app.NotificationManager
import com.teale.android.data.AppContainer

class TealeApplication : Application() {
    lateinit var container: AppContainer
        private set

    override fun onCreate() {
        super.onCreate()
        instance = this
        container = AppContainer(this)
        ensureNotificationChannel()
    }

    private fun ensureNotificationChannel() {
        val nm = getSystemService(NotificationManager::class.java) ?: return
        val channel = NotificationChannel(
            SUPPLY_CHANNEL_ID,
            getString(R.string.supply_notification_channel),
            NotificationManager.IMPORTANCE_LOW,
        )
        nm.createNotificationChannel(channel)
    }

    companion object {
        const val SUPPLY_CHANNEL_ID = "teale_supply"
        lateinit var instance: TealeApplication
            private set
    }
}
