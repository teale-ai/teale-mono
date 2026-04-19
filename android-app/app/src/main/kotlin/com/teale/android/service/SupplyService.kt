package com.teale.android.service

import android.app.Notification
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import com.teale.android.MainActivity
import com.teale.android.R
import com.teale.android.TealeApplication

/**
 * ForegroundService that supervises teale-node + llama-server on the device.
 * Binaries are expected at `nativeLibraryDir/libtealenode.so` and
 * `nativeLibraryDir/libllamaserver.so` (or overridden via Settings).
 *
 * If the binaries aren't present, the service shows a notification noting
 * "supply ready — push binaries via adb" and waits for a subsequent restart.
 */
class SupplyService : Service() {

    private lateinit var processManager: SupplyProcessManager

    override fun onCreate() {
        super.onCreate()
        processManager = SupplyProcessManager(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action ?: ACTION_START
        when (action) {
            ACTION_START -> startForegroundInternal()
            ACTION_STOP -> {
                processManager.stop()
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return START_NOT_STICKY
            }
        }
        return START_STICKY
    }

    private fun startForegroundInternal() {
        val launchIntent = Intent(this, MainActivity::class.java)
        val pi = PendingIntent.getActivity(
            this, 0, launchIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val notif: Notification = NotificationCompat.Builder(this, TealeApplication.SUPPLY_CHANNEL_ID)
            .setContentTitle(getString(R.string.supply_notification_title))
            .setContentText(getString(R.string.supply_notification_text))
            .setSmallIcon(R.drawable.ic_supply_tile)
            .setContentIntent(pi)
            .setOngoing(true)
            .build()
        startForeground(NOTIF_ID, notif)
        processManager.start()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        processManager.stop()
        super.onDestroy()
    }

    companion object {
        private const val NOTIF_ID = 4201
        const val ACTION_START = "com.teale.android.supply.START"
        const val ACTION_STOP = "com.teale.android.supply.STOP"

        fun toggle(context: Context, enabled: Boolean) {
            val intent = Intent(context, SupplyService::class.java).apply {
                action = if (enabled) ACTION_START else ACTION_STOP
            }
            if (enabled) {
                try {
                    context.startForegroundService(intent)
                } catch (t: Throwable) {
                    Log.w("SupplyService", "startForegroundService: ${t.message}")
                }
            } else {
                context.startService(intent)
            }
        }
    }
}
