package com.teale.android.service

import android.os.PowerManager
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SupplyPolicyTest {

    @Test
    fun `charging only pauses when unplugged`() {
        val gate = gateSupply(
            chargingOnly = true,
            environment = SupplyEnvironmentSnapshot(
                isCharging = false,
                thermalStatus = PowerManager.THERMAL_STATUS_NONE,
            )
        )

        assertTrue(gate is SupplyGate.WaitingForCharge)
    }

    @Test
    fun `severe thermal status pauses even when charging`() {
        val gate = gateSupply(
            chargingOnly = false,
            environment = SupplyEnvironmentSnapshot(
                isCharging = true,
                thermalStatus = PowerManager.THERMAL_STATUS_SEVERE,
            )
        )

        assertTrue(gate is SupplyGate.ThermalPaused)
    }

    @Test
    fun `active thermal pause holds the gate even at moderate status`() {
        val gate = gateSupply(
            chargingOnly = false,
            environment = SupplyEnvironmentSnapshot(
                isCharging = true,
                thermalStatus = PowerManager.THERMAL_STATUS_MODERATE,
                thermalPauseActive = true,
            )
        )

        assertTrue(gate is SupplyGate.ThermalPaused)
    }

    @Test
    fun `auto mode prefers accelerated profile on capable devices`() {
        assertEquals(
            SupplyRuntimeProfile.AcceleratedBeta,
            desiredRuntimeProfile(SupplyAccelerationMode.Auto, deviceSupportsAcceleration = true),
        )
    }

    @Test
    fun `cpu mode stays conservative regardless of hardware`() {
        assertEquals(
            SupplyRuntimeProfile.ConservativeCpu,
            desiredRuntimeProfile(
                SupplyAccelerationMode.CpuOnly,
                deviceSupportsAcceleration = true,
            ),
        )
    }

    @Test
    fun `thermal pause starts at severe and keeps its start time`() {
        val start = nextThermalPauseSince(
            status = PowerManager.THERMAL_STATUS_SEVERE,
            nowMs = 1_000L,
            pausedSinceMs = null,
        )
        assertEquals(1_000L, start)

        val later = nextThermalPauseSince(
            status = PowerManager.THERMAL_STATUS_CRITICAL,
            nowMs = 50_000L,
            pausedSinceMs = start,
        )
        assertEquals(1_000L, later)
    }

    @Test
    fun `thermal pause does not resume at moderate even after the minimum duration`() {
        val since = nextThermalPauseSince(
            status = PowerManager.THERMAL_STATUS_MODERATE,
            nowMs = MIN_THERMAL_PAUSE_MS * 10,
            pausedSinceMs = 0L,
        )
        assertEquals(0L, since)
    }

    @Test
    fun `thermal pause does not resume at light before the minimum duration`() {
        val since = nextThermalPauseSince(
            status = PowerManager.THERMAL_STATUS_LIGHT,
            nowMs = MIN_THERMAL_PAUSE_MS - 1,
            pausedSinceMs = 0L,
        )
        assertEquals(0L, since)
    }

    @Test
    fun `thermal pause resumes at light once the minimum duration has passed`() {
        assertNull(
            nextThermalPauseSince(
                status = PowerManager.THERMAL_STATUS_LIGHT,
                nowMs = MIN_THERMAL_PAUSE_MS,
                pausedSinceMs = 0L,
            )
        )
        assertNull(
            nextThermalPauseSince(
                status = PowerManager.THERMAL_STATUS_NONE,
                nowMs = MIN_THERMAL_PAUSE_MS + 1,
                pausedSinceMs = 0L,
            )
        )
    }

    @Test
    fun `no pause below severe when not already paused`() {
        assertNull(
            nextThermalPauseSince(
                status = PowerManager.THERMAL_STATUS_MODERATE,
                nowMs = 10L,
                pausedSinceMs = null,
            )
        )
    }

    @Test
    fun `restart backoff doubles and is capped`() {
        assertEquals(2_000L, supplyRestartBackoffMs(1))
        assertEquals(4_000L, supplyRestartBackoffMs(2))
        assertEquals(8_000L, supplyRestartBackoffMs(3))
        assertEquals(32_000L, supplyRestartBackoffMs(5))
        assertEquals(60_000L, supplyRestartBackoffMs(6))
        assertEquals(60_000L, supplyRestartBackoffMs(100))
        assertEquals(2_000L, supplyRestartBackoffMs(0))
    }
}
