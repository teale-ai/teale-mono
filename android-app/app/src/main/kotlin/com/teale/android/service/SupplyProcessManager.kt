package com.teale.android.service

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import java.io.File
import java.io.IOException
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Supervises the two native subprocesses that make this phone a supply node:
 *   - `libllamaserver.so` — llama.cpp HTTP server listening on 127.0.0.1:11436
 *   - `libtealenode.so`   — teale-node, connects to wss://relay.teale.com/ws
 *
 * Binaries are picked up from `applicationInfo.nativeLibraryDir` (APK-bundled)
 * with a fallback to `/sdcard/Android/data/com.teale.android/files/` so they
 * can be pushed via adb during dev without rebuilding the APK every time.
 */
class SupplyProcessManager(private val context: Context) {

    data class StartConfig(
        val accelerationMode: SupplyAccelerationMode,
        val advertisedModelId: String = DEFAULT_MODEL_ID,
    )

    sealed interface StartResult {
        data class Running(
            val profile: SupplyRuntimeProfile,
            val fellBackToCpu: Boolean,
        ) : StartResult

        data class MissingArtifacts(val detail: String) : StartResult
        data class Failed(val detail: String) : StartResult
    }

    private val running = AtomicBoolean(false)
    private var llamaProcess: Process? = null
    private var nodeProcess: Process? = null
    private var nodeOutThread: Thread? = null
    private var llamaOutThread: Thread? = null
    private var activeProfile: SupplyRuntimeProfile? = null

    @Synchronized
    fun ensureStarted(config: StartConfig): StartResult {
        val desiredProfile = desiredRuntimeProfile(
            mode = config.accelerationMode,
            deviceSupportsAcceleration = deviceSupportsAcceleration(context),
        )

        if (running.get() && activeProfile == desiredProfile && processesAlive()) {
            Log.i(TAG, "already running with profile=$desiredProfile")
            return StartResult.Running(profile = desiredProfile, fellBackToCpu = false)
        }

        stopInternal()

        val (llamaBin, nodeBin, model) = resolveBinariesAndModel()
        if (llamaBin == null || nodeBin == null || model == null) {
            val detail = buildString {
                append("missing artifacts:")
                if (llamaBin == null) append(" llama-server")
                if (nodeBin == null) append(" teale-node")
                if (model == null) append(" gguf-model")
            }
            Log.w(TAG, detail)
            return StartResult.MissingArtifacts(detail)
        }

        return runCatching {
            launchProfile(desiredProfile, llamaBin, nodeBin, model, config)
            StartResult.Running(profile = desiredProfile, fellBackToCpu = false)
        }.getOrElse { error ->
            Log.w(TAG, "launch failed for profile=$desiredProfile: ${error.message}")
            stopInternal()
            if (desiredProfile == SupplyRuntimeProfile.AcceleratedBeta) {
                runCatching {
                    launchProfile(
                        profile = SupplyRuntimeProfile.ConservativeCpu,
                        llamaBin = llamaBin,
                        nodeBin = nodeBin,
                        model = model,
                        config = config,
                    )
                    StartResult.Running(
                        profile = SupplyRuntimeProfile.ConservativeCpu,
                        fellBackToCpu = true,
                    )
                }.getOrElse { fallbackError ->
                    stopInternal()
                    StartResult.Failed(
                        "accelerated launch failed (${error.message}); cpu fallback failed (${fallbackError.message})"
                    )
                }
            } else {
                StartResult.Failed(error.message ?: "unknown supply launch failure")
            }
        }
    }

    @Synchronized
    fun stop() {
        stopInternal()
    }

    private fun launchProfile(
        profile: SupplyRuntimeProfile,
        llamaBin: File,
        nodeBin: File,
        model: File,
        config: StartConfig,
    ) {
        val workDir = File(context.filesDir, "supply").apply { mkdirs() }
        val llamaPort = 11436

        val llamaBuilder = ProcessBuilder(
            llamaBin.absolutePath,
            "-m", model.absolutePath,
            "--host", "127.0.0.1",
            "--port", llamaPort.toString(),
            "-c", "4096",
            "-ngl", profile.gpuLayers.toString(),
            "-t", "4",
        ).directory(workDir).redirectErrorStream(true)
        llamaBuilder.environment()["LD_LIBRARY_PATH"] =
            context.applicationInfo.nativeLibraryDir +
                ":" + (llamaBuilder.environment()["LD_LIBRARY_PATH"] ?: "")
        Log.i(TAG, "exec llama-server (${profile.name}): ${llamaBuilder.command().joinToString(" ")}")
        llamaProcess = llamaBuilder.start()
        llamaOutThread = pipeOutput("llama-server", llamaProcess!!)
        Thread.sleep(2000)
        requireAlive(llamaProcess, "llama-server")

        val configFile = NodeConfigWriter.writeConfig(
            workDir = workDir,
            hasLlamaServer = true,
            llamaPort = llamaPort,
            advertisedModelId = config.advertisedModelId,
            nodeGpuBackend = profile.nodeGpuBackend,
            maxConcurrentRequests = 1,
        )
        val nodeBuilder = ProcessBuilder(
            nodeBin.absolutePath,
            "--config", configFile.absolutePath,
            "--no-backend",
        ).directory(workDir).redirectErrorStream(true)
        nodeBuilder.environment()["LD_LIBRARY_PATH"] =
            context.applicationInfo.nativeLibraryDir +
                ":" + (nodeBuilder.environment()["LD_LIBRARY_PATH"] ?: "")
        Log.i(TAG, "exec teale-node (${profile.name}): ${nodeBuilder.command().joinToString(" ")}")
        nodeProcess = nodeBuilder.start()
        nodeOutThread = pipeOutput("teale-node", nodeProcess!!)
        Thread.sleep(1500)
        requireAlive(nodeProcess, "teale-node")

        activeProfile = profile
        running.set(true)
        Log.i(TAG, "SupplyService up with profile=$profile")
    }

    private fun requireAlive(process: Process?, name: String) {
        if (process == null || !process.isAlive) {
            val exitCode = runCatching { process?.exitValue() }.getOrNull()
            throw IllegalStateException("$name exited during warmup (exit=$exitCode)")
        }
    }

    private fun processesAlive(): Boolean =
        llamaProcess?.isAlive == true && nodeProcess?.isAlive == true

    private fun stopInternal() {
        val hadProcesses =
            running.getAndSet(false) || llamaProcess != null || nodeProcess != null || activeProfile != null
        runCatching { nodeProcess?.destroy() }
        runCatching { llamaProcess?.destroy() }
        nodeProcess = null
        llamaProcess = null
        nodeOutThread = null
        llamaOutThread = null
        activeProfile = null
        if (hadProcesses) {
            Log.i(TAG, "SupplyService down")
        }
    }

    private fun resolveBinariesAndModel(): Triple<File?, File?, File?> {
        val nativeDir = File(context.applicationInfo.nativeLibraryDir)
        val llama = candidates("libllamaserver.so").firstOrNull { it.exists() }
        val node = candidates("libtealenode.so").firstOrNull { it.exists() }

        // Model lookup order:
        //   1. /data/local/tmp/gemma.gguf — primary dev drop via `adb push`
        //      (universally readable by apps, unlike /sdcard/.../files/*)
        //   2. App's external-files dir (listFiles) — only works when the
        //      file was created by the app itself due to scoped-storage
        //   3. nativeLibraryDir/gemma.gguf — only works if bundled in APK
        val externalDir = context.getExternalFilesDir(null)
        val modelDir = externalDir?.let { File(it, "models") }
        val model = listOfNotNull(
            File("/data/local/tmp/gemma.gguf").takeIf { it.exists() && it.canRead() },
            modelDir?.listFiles { f -> f.name.endsWith(".gguf") }?.firstOrNull(),
            File(nativeDir, "gemma.gguf").takeIf { it.exists() },
        ).firstOrNull()

        Log.i(TAG, "resolved: llama=$llama node=$node model=$model")
        return Triple(llama, node, model)
    }

    private fun candidates(name: String): List<File> {
        val nativeDir = File(context.applicationInfo.nativeLibraryDir)
        val extDir = context.getExternalFilesDir(null) ?: context.filesDir
        val tmpDir = File("/data/local/tmp")
        return listOf(
            File(nativeDir, name),
            File(extDir, name),
            File(extDir, name.removePrefix("lib").removeSuffix(".so")),
            File(tmpDir, name),
            File(tmpDir, name.removePrefix("lib").removeSuffix(".so")),
        )
    }

    private fun pipeOutput(tag: String, process: Process): Thread {
        val t = Thread {
            try {
                process.inputStream.bufferedReader().use { reader ->
                    reader.lineSequence().forEach { line ->
                        Log.i(tag, line)
                    }
                }
            } catch (_: IOException) {
                // Process exited.
            }
        }
        t.isDaemon = true
        t.start()
        return t
    }

    companion object {
        private const val TAG = "SupplyPM"
        private const val DEFAULT_MODEL_ID = "google/gemma-3-1b-it"

        fun deviceSupportsAcceleration(context: Context): Boolean {
            val pm = context.packageManager
            val hardware = Build.HARDWARE.lowercase()
            val product = Build.PRODUCT.lowercase()
            return pm.hasSystemFeature(PackageManager.FEATURE_VULKAN_HARDWARE_LEVEL) ||
                hardware.contains("tensor") ||
                hardware.contains("qcom") ||
                product.contains("pixel")
        }
    }
}
