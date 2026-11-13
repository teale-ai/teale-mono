package com.teale.android.service

import android.Manifest
import android.app.Notification
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.BatteryManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log
import androidx.core.app.ActivityCompat
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
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/**
 * ForegroundService that supervises teale-node + llama-server on the device.
 *
 * Supply is intentionally conservative on Android: explicit opt-in, charging
 * first, and paused when thermal status is severe or worse (resuming only once
 * the phone is back to LIGHT and a minimum pause has passed). On capable
 * phones the service attempts an accelerated Vulkan profile first, then falls
 * back to the conservative CPU profile if startup fails.
 *
 * Supervision: each child process has an exit watcher, and a periodic
 * liveness tick double-checks both processes and polls teale-node's local
 * `/status`. Unexpected exits restart supply with exponential backoff; after
 * [MAX_SUPPLY_RESTART_ATTEMPTS] consecutive failures the service stops the
 * processes and surfaces [SupplyState.Error].
 *
 * Threading: lifecycle callbacks, state and notifications stay on the main
 * thread; process start/stop and HTTP calls run on Dispatchers.IO.
 */
class SupplyService : Service() {

    private lateinit var processManager: SupplyProcessManager
    private lateinit var settingsStore: SettingsStore
    private lateinit var powerManager: PowerManager
    private val nodeClient = NodeLocalClient()

    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val reevaluateMutex = Mutex()

    private var isCharging: Boolean = false
    private var thermalStatus: Int = PowerManager.THERMAL_STATUS_NONE
    private var thermalPausedSinceMs: Long? = null
    private var userPaused: Boolean = false
    private var restartAttempts: Int = 0
    private var restartJob: Job? = null
    private var runningSinceMs: Long? = null
    private var isForeground: Boolean = false

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

    private val exitListener = SupplyProcessManager.Listener { name, exitCode ->
        // Called on a watcher thread.
        serviceScope.launch { onProcessExited("$name exited (exit=$exitCode)") }
    }

    override fun onCreate() {
        super.onCreate()
        val app = TealeApplication.instance
        processManager = SupplyProcessManager.get(this)
        processManager.listener = exitListener
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
        serviceScope.launch {
            while (isActive) {
                delay(LIVENESS_INTERVAL_MS)
                livenessTick()
            }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (val action = intent?.action ?: ACTION_START) {
            ACTION_STOP -> {
                restartJob?.cancel()
                serviceScope.launch {
                    reevaluateMutex.withLock {
                        withContext(Dispatchers.IO) { processManager.stop() }
                        runningSinceMs = null
                        publish(SupplyState.Off)
                    }
                    stopForeground(STOP_FOREGROUND_REMOVE)
                    isForeground = false
                    stopSelf(startId)
                }
                return START_NOT_STICKY
            }
            ACTION_PAUSE, ACTION_RESUME -> {
                val paused = action == ACTION_PAUSE
                val wasForeground = isForeground
                // Every startForegroundService() must be answered with startForeground().
                ensureForeground(currentOrStarting())
                if (!wasForeground) {
                    // The service was not running: bring supply up first.
                    userPaused = paused
                    serviceScope.launch { reevaluateSupply(action) }
                } else {
                    serviceScope.launch { setUserPaused(paused) }
                }
            }
            else -> {
                ensureForeground(currentOrStarting())
                // An explicit start/refresh is a fresh chance after a crash loop.
                restartJob?.cancel()
                restartAttempts = 0
                serviceScope.launch { reevaluateSupply(action) }
            }
        }
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        runCatching { unregisterReceiver(batteryReceiver) }
        runCatching { powerManager.removeThermalStatusListener(thermalListener) }
        serviceScope.cancel()
        processManager.listener = null
        _state.value = SupplyState.Off
        // Stopping waits for the processes to exit; keep that off the main thread.
        val manager = processManager
        Thread({ manager.stop() }, "supply-stop").start()
        super.onDestroy()
    }

    private suspend fun reevaluateSupply(reason: String, fromRestart: Boolean = false) {
        reevaluateMutex.withLock {
            val snapshot = settingsStore.snapshot.first()
            if (!snapshot.supplyEnabled) {
                withContext(Dispatchers.IO) { processManager.stop() }
                runningSinceMs = null
                publish(SupplyState.Off)
                stopForeground(STOP_FOREGROUND_REMOVE)
                isForeground = false
                stopSelf()
                return
            }

            thermalPausedSinceMs = nextThermalPauseSince(
                status = thermalStatus,
                nowMs = SystemClock.elapsedRealtime(),
                pausedSinceMs = thermalPausedSinceMs,
            )
            val environment = SupplyEnvironmentSnapshot(
                isCharging = isCharging,
                thermalStatus = thermalStatus,
                thermalPauseActive = thermalPausedSinceMs != null,
            )

            when (val gate = gateSupply(snapshot.supplyChargingOnly, environment)) {
                SupplyGate.Ready -> {
                    if (_state.value !is SupplyState.Running) publish(SupplyState.Starting)
                    val config = SupplyProcessManager.StartConfig(
                        accelerationMode = SupplyAccelerationMode.fromStorage(
                            snapshot.supplyAccelerationMode
                        )
                    )
                    val result = withContext(Dispatchers.IO) { processManager.ensureStarted(config) }
                    when (result) {
                        is SupplyProcessManager.StartResult.Running -> {
                            var node = (_state.value as? SupplyState.Running)?.node
                            if (result.launched) {
                                runningSinceMs = SystemClock.elapsedRealtime()
                                node = withContext(Dispatchers.IO) {
                                    if (userPaused) nodeClient.pause()
                                    nodeClient.status()
                                }
                            }
                            publish(
                                SupplyState.Running(
                                    profile = result.profile,
                                    fellBackToCpu = result.fellBackToCpu,
                                    userPaused = userPaused,
                                    node = node,
                                )
                            )
                        }
                        is SupplyProcessManager.StartResult.MissingArtifacts -> {
                            runningSinceMs = null
                            publish(SupplyState.MissingArtifacts(result.detail))
                        }
                        is SupplyProcessManager.StartResult.Failed -> {
                            runningSinceMs = null
                            if (fromRestart) {
                                scheduleRestart(result.detail)
                            } else {
                                publish(SupplyState.Error(result.detail))
                            }
                        }
                    }
                }
                SupplyGate.WaitingForCharge -> {
                    withContext(Dispatchers.IO) { processManager.stop() }
                    runningSinceMs = null
                    publish(SupplyState.WaitingForCharge)
                }
                is SupplyGate.ThermalPaused -> {
                    withContext(Dispatchers.IO) { processManager.stop() }
                    runningSinceMs = null
                    publish(SupplyState.ThermalPaused(thermalStatusName(gate.thermalStatus)))
                }
            }
            Log.i(
                TAG,
                "reevaluated supply ($reason): charging=$isCharging " +
                    "thermal=${thermalStatusName(thermalStatus)} state=${_state.value}"
            )
        }
    }

    private fun onProcessExited(reason: String) {
        if (_state.value !is SupplyState.Running) return
        Log.w(TAG, "supply process died: $reason")
        runningSinceMs = null
        scheduleRestart(reason)
    }

    /** Stops what is left of supply now and relaunches it after a backoff. */
    private fun scheduleRestart(reason: String) {
        if (restartJob?.isActive == true) return
        restartAttempts += 1
        if (restartAttempts > MAX_SUPPLY_RESTART_ATTEMPTS) {
            restartJob = serviceScope.launch {
                reevaluateMutex.withLock {
                    withContext(Dispatchers.IO) { processManager.stop() }
                }
                publish(
                    SupplyState.Error(
                        "$reason; gave up after $MAX_SUPPLY_RESTART_ATTEMPTS restarts"
                    )
                )
            }
            return
        }
        val delayMs = supplyRestartBackoffMs(restartAttempts)
        publish(SupplyState.Restarting(restartAttempts, MAX_SUPPLY_RESTART_ATTEMPTS, reason))
        restartJob = serviceScope.launch {
            reevaluateMutex.withLock {
                withContext(Dispatchers.IO) { processManager.stop() }
            }
            delay(delayMs)
            // Clear the handle first so a failed relaunch can schedule the next attempt.
            restartJob = null
            reevaluateSupply("restart #$restartAttempts", fromRestart = true)
        }
    }

    private suspend fun livenessTick() {
        when (val current = _state.value) {
            is SupplyState.Running -> {
                // Skip the tick while a start/stop is in progress.
                if (!reevaluateMutex.tryLock()) return
                val alive = try {
                    withContext(Dispatchers.IO) { processManager.processesAlive() }
                } finally {
                    reevaluateMutex.unlock()
                }
                if (!alive) {
                    onProcessExited("supply process not alive at liveness check")
                    return
                }
                val since = runningSinceMs
                if (since != null &&
                    SystemClock.elapsedRealtime() - since >= SUPPLY_STABLE_RUN_MS
                ) {
                    restartAttempts = 0
                }
                val node = withContext(Dispatchers.IO) { nodeClient.status() }
                val latest = _state.value
                if (latest is SupplyState.Running) {
                    publish(latest.copy(node = node ?: latest.node, userPaused = userPaused))
                }
            }
            // Lets the minimum thermal pause expire even if the status never changes again.
            is SupplyState.ThermalPaused -> reevaluateSupply("thermal-tick")
            else -> Unit
        }
    }

    private suspend fun setUserPaused(paused: Boolean) {
        userPaused = paused
        val current = _state.value as? SupplyState.Running ?: return
        val node = withContext(Dispatchers.IO) {
            val ok = if (paused) nodeClient.pause() else nodeClient.resume()
            if (!ok) Log.w(TAG, "teale-node did not accept ${if (paused) "pause" else "resume"}")
            nodeClient.status()
        }
        val latest = _state.value as? SupplyState.Running ?: current
        publish(latest.copy(userPaused = paused, node = node ?: latest.node))
    }

    private fun publish(state: SupplyState) {
        if (_state.value == state) return
        _state.value = state
        if (state != SupplyState.Off && isForeground) {
            updateNotification(state)
        }
    }

    private fun currentOrStarting(): SupplyState =
        _state.value.takeUnless { it == SupplyState.Off } ?: SupplyState.Starting

    private fun ensureForeground(state: SupplyState) {
        val notification = buildNotification(state)
        ServiceCompat.startForeground(
            this,
            NOTIF_ID,
            notification,
            ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
        )
        isForeground = true
        if (_state.value == SupplyState.Off) _state.value = state
    }

    private fun updateNotification(state: SupplyState) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ActivityCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        NotificationManagerCompat.from(this).notify(NOTIF_ID, buildNotification(state))
    }

    private fun buildNotification(state: SupplyState): Notification {
        val launchIntent = Intent(this, MainActivity::class.java)
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val text = contentTextFor(state)
        return NotificationCompat.Builder(this, TealeApplication.SUPPLY_CHANNEL_ID)
            .setContentTitle(getString(R.string.supply_notification_title))
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setSmallIcon(R.drawable.ic_supply_tile)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .build()
    }

    private fun contentTextFor(state: SupplyState): String = supplyStateText(this, state)

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

    companion object {
        private const val TAG = "SupplyService"
        private const val NOTIF_ID = 4201
        private const val LIVENESS_INTERVAL_MS = 15_000L

        const val ACTION_START = "com.teale.android.supply.START"
        const val ACTION_STOP = "com.teale.android.supply.STOP"
        const val ACTION_REFRESH = "com.teale.android.supply.REFRESH"
        const val ACTION_PAUSE = "com.teale.android.supply.PAUSE"
        const val ACTION_RESUME = "com.teale.android.supply.RESUME"

        private val _state = MutableStateFlow<SupplyState>(SupplyState.Off)

        /** Real supply state for the UI (Home card, Settings). */
        val state: StateFlow<SupplyState> = _state.asStateFlow()

        fun toggle(context: Context, enabled: Boolean) {
            if (enabled) {
                sendStart(context, ACTION_START)
            } else {
                val intent = Intent(context, SupplyService::class.java).apply {
                    action = ACTION_STOP
                }
                try {
                    context.startService(intent)
                } catch (t: IllegalStateException) {
                    // Background start not allowed (API 26+). The service can
                    // only be running if it is in the foreground, in which case
                    // startService would have worked, so a plain stop is enough.
                    Log.i(TAG, "startService(STOP) not allowed, stopping directly: ${t.message}")
                    context.stopService(Intent(context, SupplyService::class.java))
                    _state.value = SupplyState.Off
                }
            }
        }

        fun refresh(context: Context) = sendStart(context, ACTION_REFRESH)

        /** Pause or resume serving without stopping the processes. */
        fun setPaused(context: Context, paused: Boolean) =
            sendStart(context, if (paused) ACTION_PAUSE else ACTION_RESUME)

        private fun sendStart(context: Context, action: String) {
            val intent = Intent(context, SupplyService::class.java).apply {
                this.action = action
            }
            try {
                ContextCompat.startForegroundService(context, intent)
            } catch (t: Exception) {
                Log.w(TAG, "startForegroundService($action): ${t.message}")
            }
        }
    }
}

/** Human-readable text for [state], shared by the notification and the Home card. */
fun supplyStateText(context: Context, state: SupplyState): String = when (state) {
    SupplyState.Off -> context.getString(R.string.home_supply_off)
    SupplyState.Starting ->
        context.getString(R.string.supply_notification_text_starting)
    is SupplyState.Restarting ->
        context.getString(
            R.string.supply_notification_text_restarting,
            state.attempt,
            state.maxAttempts,
        )
    SupplyState.WaitingForCharge ->
        context.getString(R.string.supply_notification_text_waiting_for_charge)
    is SupplyState.ThermalPaused ->
        context.getString(R.string.supply_notification_text_paused_thermal, state.level)
    is SupplyState.MissingArtifacts ->
        context.getString(R.string.supply_notification_text_missing_artifacts)
    is SupplyState.Error ->
        context.getString(R.string.supply_notification_text_error, state.detail)
    is SupplyState.Running -> when {
        state.userPaused ->
            context.getString(R.string.supply_notification_text_paused_user)
        state.node != null && !state.node.isSupplying ->
            context.getString(
                R.string.supply_notification_text_node_not_serving,
                state.node.pausedReason ?: state.node.state,
            )
        state.fellBackToCpu ->
            context.getString(R.string.supply_notification_text_running_cpu_fallback)
        state.profile == SupplyRuntimeProfile.AcceleratedBeta ->
            context.getString(R.string.supply_notification_text_running_gpu)
        else ->
            context.getString(R.string.supply_notification_text_running_cpu)
    }
}
