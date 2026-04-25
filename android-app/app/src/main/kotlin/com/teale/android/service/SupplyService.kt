package com.teale.android.service

import android.app.Notification
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.os.BatteryManager
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import com.teale.android.MainActivity
import com.teale.android.R
import com.teale.android.TealeApplication
import com.teale.android.data.settings.SettingsStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * ForegroundService that supervises teale-node + llama-server on the device.
 *
 * Supply is intentionally conservative on Android: explicit opt-in, charging
 * first, and paused when thermal status is severe or worse. On capable phones
 * the service attempts an accelerated Vulkan profile first, then falls back to
 * the conservative CPU profile if startup fails.
 */
class SupplyService : Service() {

    private lateinit var processManager: SupplyProcessManager
    private lateinit var settingsStore: SettingsStore
    private lateinit var powerManager: PowerManager

    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val reevaluateMutex = Mutex()

    private var isCharging: Boolean = false
    private var thermalStatus: Int = PowerManager.THERMAL_STATUS_NONE

    private val batteryReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (updateChargingState(intent)) {
                serviceScope.launch { reevaluateSupply("battery") }
            }
        }
    }

    private val thermalListener = PowerManager.OnThermalStatusChangedListener { status ->
        if (thermalStatus != status) {
            thermalStatus = status
            serviceScope.launch { reevaluateSupply("thermal") }
        }
    }

    override fun onCreate() {
        super.onCreate()
        val app = TealeApplication.instance
        processManager = SupplyProcessManager(this)
        settingsStore = app.container.settingsStore
        powerManager = getSystemService(PowerManager::class.java)
        thermalStatus = powerManager.currentThermalStatus
        val stickyBattery = ContextCompat.registerReceiver(
            this,
            batteryReceiver,
            IntentFilter(Intent.ACTION_BATTERY_CHANGED),
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
        updateChargingState(stickyBattery)
        powerManager.addThermalStatusListener(mainExecutor, thermalListener)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action ?: ACTION_START) {
            ACTION_STOP -> {
                processManager.stop()
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_START,
            ACTION_REFRESH -> {
                ensureForeground(SupplyUiState.Starting)
                serviceScope.launch { reevaluateSupply(intent?.action ?: ACTION_START) }
            }
        }
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        runCatching { unregisterReceiver(batteryReceiver) }
        runCatching { powerManager.removeThermalStatusListener(thermalListener) }
        processManager.stop()
        serviceScope.cancel()
        super.onDestroy()
    }

    private suspend fun reevaluateSupply(reason: String) {
        reevaluateMutex.withLock {
            val snapshot = settingsStore.snapshot.first()
            if (!snapshot.supplyEnabled) {
                processManager.stop()
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return
            }

            val environment = SupplyEnvironmentSnapshot(
                isCharging = isCharging,
                thermalStatus = thermalStatus,
            )

            when (val gate = gateSupply(snapshot.supplyChargingOnly, environment)) {
                SupplyGate.Ready -> {
                    val result = processManager.ensureStarted(
                        SupplyProcessManager.StartConfig(
                            accelerationMode = SupplyAccelerationMode.fromStorage(
                                snapshot.supplyAccelerationMode
                            )
                        )
                    )
                    val uiState = when (result) {
                        is SupplyProcessManager.StartResult.Running -> {
                            SupplyUiState.Running(
                                profile = result.profile,
                                fellBackToCpu = result.fellBackToCpu,
                            )
                        }
                        is SupplyProcessManager.StartResult.MissingArtifacts ->
                            SupplyUiState.MissingArtifacts(result.detail)
                        is SupplyProcessManager.StartResult.Failed ->
                            SupplyUiState.Error(result.detail)
                    }
                    updateNotification(uiState)
                }
                SupplyGate.WaitingForCharge -> {
                    processManager.stop()
                    updateNotification(SupplyUiState.WaitingForCharge)
                }
                is SupplyGate.ThermalPaused -> {
                    processManager.stop()
                    updateNotification(
                        SupplyUiState.ThermalPaused(thermalStatusName(gate.thermalStatus))
                    )
                }
            }
            Log.i(
                TAG,
                "reevaluated supply ($reason): charging=$isCharging thermal=${thermalStatusName(thermalStatus)}"
            )
        }
    }

    private fun ensureForeground(state: SupplyUiState) {
        val notification = buildNotification(state)
        ServiceCompat.startForeground(
            this,
            NOTIF_ID,
            notification,
            ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
        )
    }

    private fun updateNotification(state: SupplyUiState) {
        NotificationManagerCompat.from(this).notify(NOTIF_ID, buildNotification(state))
    }

    private fun buildNotification(state: SupplyUiState): Notification {
        val launchIntent = Intent(this, MainActivity::class.java)
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return NotificationCompat.Builder(this, TealeApplication.SUPPLY_CHANNEL_ID)
            .setContentTitle(getString(R.string.supply_notification_title))
            .setContentText(contentTextFor(state))
            .setStyle(NotificationCompat.BigTextStyle().bigText(contentTextFor(state)))
            .setSmallIcon(R.drawable.ic_supply_tile)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .build()
    }

    private fun contentTextFor(state: SupplyUiState): String = when (state) {
        SupplyUiState.Starting ->
            getString(R.string.supply_notification_text_starting)
        SupplyUiState.WaitingForCharge ->
            getString(R.string.supply_notification_text_waiting_for_charge)
        is SupplyUiState.ThermalPaused ->
            getString(R.string.supply_notification_text_paused_thermal, state.level)
        is SupplyUiState.MissingArtifacts ->
            getString(R.string.supply_notification_text_missing_artifacts)
        is SupplyUiState.Error ->
            getString(R.string.supply_notification_text_error)
        is SupplyUiState.Running -> when {
            state.fellBackToCpu ->
                getString(R.string.supply_notification_text_running_cpu_fallback)
            state.profile == SupplyRuntimeProfile.AcceleratedBeta ->
                getString(R.string.supply_notification_text_running_gpu)
            else ->
                getString(R.string.supply_notification_text_running_cpu)
        }
    }

    private fun updateChargingState(intent: Intent?): Boolean {
        intent ?: return false
        val status = intent.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
        val plugged = intent.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0)
        val next = plugged != 0 ||
            status == BatteryManager.BATTERY_STATUS_CHARGING ||
            status == BatteryManager.BATTERY_STATUS_FULL
        val changed = next != isCharging
        isCharging = next
        return changed
    }

    private sealed interface SupplyUiState {
        data object Starting : SupplyUiState
        data object WaitingForCharge : SupplyUiState
        data class ThermalPaused(val level: String) : SupplyUiState
        data class MissingArtifacts(val detail: String) : SupplyUiState
        data class Error(val detail: String) : SupplyUiState
        data class Running(
            val profile: SupplyRuntimeProfile,
            val fellBackToCpu: Boolean,
        ) : SupplyUiState
    }

    companion object {
        private const val TAG = "SupplyService"
        private const val NOTIF_ID = 4201

        const val ACTION_START = "com.teale.android.supply.START"
        const val ACTION_STOP = "com.teale.android.supply.STOP"
        const val ACTION_REFRESH = "com.teale.android.supply.REFRESH"

        fun toggle(context: Context, enabled: Boolean) {
            val intent = Intent(context, SupplyService::class.java).apply {
                action = if (enabled) ACTION_START else ACTION_STOP
            }
            if (enabled) {
                try {
                    context.startForegroundService(intent)
                } catch (t: Throwable) {
                    Log.w(TAG, "startForegroundService: ${t.message}")
                }
            } else {
                context.startService(intent)
            }
        }

        fun refresh(context: Context) {
            val intent = Intent(context, SupplyService::class.java).apply {
                action = ACTION_REFRESH
            }
            try {
                context.startForegroundService(intent)
            } catch (t: Throwable) {
                Log.w(TAG, "refresh startForegroundService: ${t.message}")
            }
        }
    }
}
