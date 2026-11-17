package com.teale.android.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NodeConfigWriterTest {

    private fun toml(profile: SupplyRuntimeProfile, displayName: String = "Google Pixel 8") =
        NodeConfigWriter.buildToml(
            relayUrl = "wss://relay.example/ws",
            displayName = displayName,
            gpuBackend = profile.nodeGpuBackend,
            gpuLayers = profile.gpuLayers,
            maxConcurrentRequests = 1,
            llamaPort = 11436,
            advertisedModelId = "google/gemma-3-1b-it",
        )

    @Test
    fun `gpu layers follow the runtime profile`() {
        val accelerated = toml(SupplyRuntimeProfile.AcceleratedBeta)
        assertTrue(accelerated.contains("gpu_backend = \"vulkan\""))
        assertTrue(accelerated.contains("gpu_layers = 999"))

        val cpu = toml(SupplyRuntimeProfile.ConservativeCpu)
        assertTrue(cpu.contains("gpu_backend = \"cpu\""))
        assertTrue(cpu.contains("gpu_layers = 0"))
    }

    @Test
    fun `config pins control port, short shutdown and model id`() {
        val text = toml(SupplyRuntimeProfile.ConservativeCpu)
        assertTrue(text.contains("[control]\nport = 11437"))
        assertTrue(text.contains("shutdown_timeout_seconds = 5"))
        assertTrue(text.contains("model_id = \"google/gemma-3-1b-it\""))
        assertFalse(text.contains("Pixel 9 Pro Fold"))
    }

    @Test
    fun `display name is escaped for toml`() {
        val text = toml(SupplyRuntimeProfile.ConservativeCpu, displayName = "Acme \"X\" \\1")
        assertTrue(text.contains("display_name = \"Acme \\\"X\\\" \\\\1\""))
    }

    @Test
    fun `display name combines manufacturer and model without repeating the brand`() {
        assertEquals("Google Pixel 9 Pro Fold", NodeConfigWriter.deviceDisplayName("Google", "Pixel 9 Pro Fold"))
        assertEquals("Samsung SM-S928B", NodeConfigWriter.deviceDisplayName("samsung", "SM-S928B"))
        assertEquals("OnePlus 12", NodeConfigWriter.deviceDisplayName("OnePlus", "OnePlus 12"))
        assertEquals("Android device", NodeConfigWriter.deviceDisplayName(null, " "))
    }
}
