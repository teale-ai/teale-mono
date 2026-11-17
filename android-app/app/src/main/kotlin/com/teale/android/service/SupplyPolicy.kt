package com.teale.android.service

import android.os.PowerManager

enum class SupplyAccelerationMode(val storageValue: String) {
    Auto("auto"),
    CpuOnly("cpu");

    companion object {
        fun fromStorage(value: String): SupplyAccelerationMode =
            entries.firstOrNull { it.storageValue == value } ?: Auto
    }
}

enum class SupplyRuntimeProfile(
    val gpuLayers: Int,
    val nodeGpuBackend: String,
) {
    AcceleratedBeta(gpuLayers = 999, nodeGpuBackend = "vulkan"),
    ConservativeCpu(gpuLayers = 0, nodeGpuBackend = "cpu"),
}

data class SupplyEnvironmentSnapshot(
    val isCharging: Boolean,
    val thermalStatus: Int,
    /**
     * Whether the thermal pause is in effect. Computed with hysteresis by
     * [nextThermalPauseSince]; defaults to the instantaneous threshold.
     */
    val thermalPauseActive: Boolean = isThermallyBlocked(thermalStatus),
)

sealed interface SupplyGate {
    data object Ready : SupplyGate
    data object WaitingForCharge : SupplyGate
    data class ThermalPaused(val thermalStatus: Int) : SupplyGate
}

fun gateSupply(
    chargingOnly: Boolean,
    environment: SupplyEnvironmentSnapshot,
): SupplyGate {
    if (chargingOnly && !environment.isCharging) {
        return SupplyGate.WaitingForCharge
    }
    if (environment.thermalPauseActive) {
        return SupplyGate.ThermalPaused(environment.thermalStatus)
    }
    return SupplyGate.Ready
}

fun desiredRuntimeProfile(
    mode: SupplyAccelerationMode,
    deviceSupportsAcceleration: Boolean,
): SupplyRuntimeProfile = when {
    mode == SupplyAccelerationMode.CpuOnly -> SupplyRuntimeProfile.ConservativeCpu
    deviceSupportsAcceleration -> SupplyRuntimeProfile.AcceleratedBeta
    else -> SupplyRuntimeProfile.ConservativeCpu
}

/** Supply stops at or above this thermal status. */
fun isThermallyBlocked(status: Int): Boolean =
    status >= PowerManager.THERMAL_STATUS_SEVERE

/** After a thermal pause, supply only resumes at or below this status. */
fun isThermallyClearToResume(status: Int): Boolean =
    status <= PowerManager.THERMAL_STATUS_LIGHT

/** A thermal pause lasts at least this long, so the model is not reloaded in a tight loop. */
const val MIN_THERMAL_PAUSE_MS: Long = 5 * 60 * 1000L

/**
 * Thermal gate with hysteresis. Returns the (monotonic clock) time the
 * current thermal pause started, or null when supply may run.
 *
 * - At [PowerManager.THERMAL_STATUS_SEVERE] or above, supply is paused.
 * - Once paused, it stays paused until the status is back to
 *   [PowerManager.THERMAL_STATUS_LIGHT] or lower AND at least [minPauseMs]
 *   has passed since the pause began. MODERATE alone never resumes.
 */
fun nextThermalPauseSince(
    status: Int,
    nowMs: Long,
    pausedSinceMs: Long?,
    minPauseMs: Long = MIN_THERMAL_PAUSE_MS,
): Long? {
    if (isThermallyBlocked(status)) {
        return pausedSinceMs ?: nowMs
    }
    if (pausedSinceMs == null) {
        return null
    }
    val pausedLongEnough = nowMs - pausedSinceMs >= minPauseMs
    return if (isThermallyClearToResume(status) && pausedLongEnough) null else pausedSinceMs
}

/** Consecutive unexpected exits tolerated before supply gives up with an error. */
const val MAX_SUPPLY_RESTART_ATTEMPTS: Int = 5

/** A run this long without a crash resets the restart counter. */
const val SUPPLY_STABLE_RUN_MS: Long = 5 * 60 * 1000L

/**
 * Exponential backoff before restart attempt [attempt] (1-based):
 * 2 s, 4 s, 8 s, 16 s, 32 s, then capped at [maxMs].
 */
fun supplyRestartBackoffMs(
    attempt: Int,
    baseMs: Long = 2_000L,
    maxMs: Long = 60_000L,
): Long {
    val exponent = (attempt - 1).coerceIn(0, 20)
    return (baseMs shl exponent).coerceAtMost(maxMs)
}

fun thermalStatusName(status: Int): String = when (status) {
    PowerManager.THERMAL_STATUS_NONE -> "nominal"
    PowerManager.THERMAL_STATUS_LIGHT -> "light"
    PowerManager.THERMAL_STATUS_MODERATE -> "moderate"
    PowerManager.THERMAL_STATUS_SEVERE -> "severe"
    PowerManager.THERMAL_STATUS_CRITICAL -> "critical"
    PowerManager.THERMAL_STATUS_EMERGENCY -> "emergency"
    PowerManager.THERMAL_STATUS_SHUTDOWN -> "shutdown"
    else -> "unknown"
}
