package com.teale.android.service

import android.os.Build
import android.util.Log
import java.io.File

object NodeConfigWriter {

    private const val TAG = "NodeConfigWriter"

    /** Port of teale-node's local control API (`/status`, `/pause`, `/resume`). */
    const val CONTROL_PORT = 11437

    /**
     * How long teale-node drains in-flight requests after SIGTERM. Kept short on
     * Android so a stop/relaunch does not race the old process (the process
     * manager waits slightly longer than this before force-killing).
     */
    const val SHUTDOWN_TIMEOUT_SECONDS = 5

    const val CONTEXT_SIZE = 4096

    /**
     * Location teale-node reads its Ed25519 identity from on Android: relative
     * to its working directory (see node/src/identity.rs).
     */
    fun identityFile(workDir: File): File = File(File(workDir, ".teale"), "wan-identity.key")

    /**
     * Seed the node identity with this device's WanIdentity seed, so the
     * supply-side node_id matches the phone's deviceID and credits land in the
     * wallet the app reads from.
     *
     * teale-node only reads this file at startup and has no env/stdin option,
     * so the plaintext copy exists only between this call and the moment the
     * node answers on its control port; [deleteIdentity] removes it then, and
     * again on every stop.
     */
    fun writeIdentity(workDir: File, seed: ByteArray): File {
        require(seed.size == 32) { "identity seed must be 32 bytes" }
        val file = identityFile(workDir)
        file.parentFile?.mkdirs()
        if (file.exists()) file.delete()
        file.createNewFile()
        // Owner-only, on top of the app-private filesDir.
        file.setReadable(false, false)
        file.setWritable(false, false)
        file.setReadable(true, true)
        file.setWritable(true, true)
        file.writeBytes(seed)
        return file
    }

    /** Overwrite and remove the plaintext identity seed, if present. */
    fun deleteIdentity(workDir: File) {
        val file = identityFile(workDir)
        if (!file.exists()) return
        runCatching { file.writeBytes(ByteArray(file.length().toInt().coerceAtLeast(32))) }
        if (!file.delete()) {
            Log.w(TAG, "could not delete $file")
        }
    }

    /** Write `teale-node.toml` into [workDir] and return it. */
    fun writeConfig(
        workDir: File,
        relayUrl: String,
        profile: SupplyRuntimeProfile,
        llamaPort: Int,
        advertisedModelId: String,
        maxConcurrentRequests: Int = 1,
    ): File {
        val toml = buildToml(
            relayUrl = relayUrl,
            displayName = deviceDisplayName(Build.MANUFACTURER, Build.MODEL),
            gpuBackend = profile.nodeGpuBackend,
            gpuLayers = profile.gpuLayers,
            maxConcurrentRequests = maxConcurrentRequests,
            llamaPort = llamaPort,
            advertisedModelId = advertisedModelId,
        )
        val f = File(workDir, "teale-node.toml")
        f.writeText(toml)
        return f
    }

    /** "Google" + "Pixel 9 Pro Fold" -> "Google Pixel 9 Pro Fold", without doubling the brand. */
    fun deviceDisplayName(manufacturer: String?, model: String?): String {
        val maker = manufacturer.orEmpty().trim()
        val name = model.orEmpty().trim()
        return when {
            name.isEmpty() && maker.isEmpty() -> "Android device"
            name.isEmpty() -> maker
            maker.isEmpty() || name.startsWith(maker, ignoreCase = true) -> name
            else -> "${maker.replaceFirstChar { it.uppercaseChar() }} $name"
        }
    }

    internal fun buildToml(
        relayUrl: String,
        displayName: String,
        gpuBackend: String,
        gpuLayers: Int,
        maxConcurrentRequests: Int,
        llamaPort: Int,
        advertisedModelId: String,
    ): String = buildString {
        appendLine("backend = \"llama\"")
        appendLine()
        appendLine("[relay]")
        appendLine("url = ${tomlString(relayUrl)}")
        appendLine()
        appendLine("[node]")
        appendLine("display_name = ${tomlString(displayName)}")
        appendLine("gpu_backend = ${tomlString(gpuBackend)}")
        appendLine("max_concurrent_requests = $maxConcurrentRequests")
        appendLine("heartbeat_interval_seconds = 10")
        appendLine("shutdown_timeout_seconds = $SHUTDOWN_TIMEOUT_SECONDS")
        appendLine()
        appendLine("[control]")
        appendLine("port = $CONTROL_PORT")
        appendLine()
        appendLine("[llama]")
        // With --no-backend, teale-node only uses `port` + `model_id` and
        // skips spawning. `binary`/`model` are required fields, so they get
        // placeholders. llama-server itself is launched by the app with the
        // same -ngl value written to gpu_layers.
        appendLine("binary = \"unused-with-no-backend\"")
        appendLine("model = \"unused-with-no-backend\"")
        appendLine("model_id = ${tomlString(advertisedModelId)}")
        appendLine("port = $llamaPort")
        appendLine("context_size = $CONTEXT_SIZE")
        appendLine("gpu_layers = $gpuLayers")
    }

    private fun tomlString(value: String): String {
        val escaped = buildString {
            value.forEach { c ->
                when {
                    c == '\\' -> append("\\\\")
                    c == '"' -> append("\\\"")
                    c < ' ' -> append("\\u").append(c.code.toString(16).padStart(4, '0'))
                    else -> append(c)
                }
            }
        }
        return "\"$escaped\""
    }
}
