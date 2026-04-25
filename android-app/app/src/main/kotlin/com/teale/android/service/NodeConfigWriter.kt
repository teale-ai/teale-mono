package com.teale.android.service

import com.teale.android.BuildConfig
import com.teale.android.TealeApplication
import java.io.File

object NodeConfigWriter {

    /**
     * Write `teale-node.toml` into workDir and seed the node identity file at
     * `<workDir>/.teale/wan-identity.key` with this device's WanIdentity seed,
     * so the supply-side node_id matches the phone's deviceID — credits earned
     * from inference land in the same wallet the Android app reads from.
     */
    fun writeConfig(
        workDir: File,
        hasLlamaServer: Boolean,
        llamaPort: Int = 11436,
        advertisedModelId: String = "google/gemma-3-1b-it",
        nodeGpuBackend: String = "cpu",
        maxConcurrentRequests: Int = 1,
    ): File {
        val identityDir = File(workDir, ".teale").apply { mkdirs() }
        val identityFile = File(identityDir, "wan-identity.key")
        val seed = TealeApplication.instance.container.identity.privateSeed()
        if (!identityFile.exists() || identityFile.readBytes().size != 32) {
            identityFile.writeBytes(seed)
        }

        val toml = buildString {
            appendLine("backend = \"llama\"")
            appendLine()
            appendLine("[relay]")
            appendLine("url = \"${BuildConfig.RELAY_URL}\"")
            appendLine()
            appendLine("[node]")
            appendLine("display_name = \"Pixel 9 Pro Fold\"")
            appendLine("gpu_backend = \"$nodeGpuBackend\"")
            appendLine("max_concurrent_requests = $maxConcurrentRequests")
            appendLine("heartbeat_interval_seconds = 10")
            appendLine("shutdown_timeout_seconds = 30")
            appendLine()
            appendLine("[llama]")
            // When --no-backend is passed, teale-node only uses `port` +
            // `model_id` and skips spawning. `binary`/`model` are required
            // fields so we write placeholders.
            appendLine("binary = \"unused-with-no-backend\"")
            appendLine("model = \"unused-with-no-backend\"")
            if (hasLlamaServer) {
                appendLine("model_id = \"$advertisedModelId\"")
            }
            appendLine("port = $llamaPort")
            appendLine("context_size = 4096")
            appendLine("gpu_layers = 0")
        }
        val f = File(workDir, "teale-node.toml")
        f.writeText(toml)
        return f
    }
}
