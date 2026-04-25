package com.teale.android.service

import android.os.PowerManager
import org.junit.Assert.assertEquals
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
}
