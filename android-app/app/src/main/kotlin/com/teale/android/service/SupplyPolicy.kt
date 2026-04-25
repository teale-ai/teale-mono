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
    if (isThermallyBlocked(environment.thermalStatus)) {
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

fun isThermallyBlocked(status: Int): Boolean =
    status >= PowerManager.THERMAL_STATUS_SEVERE

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
