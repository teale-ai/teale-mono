package com.teale.android.service

import android.content.Context
import android.content.pm.PackageManager
import android.os.SystemClock
import android.util.Log
import com.teale.android.BuildConfig
import com.teale.android.TealeApplication
import java.io.File
import java.io.IOException
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.TimeUnit

/**
 * Supervises the two native subprocesses that make this phone a supply node:
 *   - `libllamaserver.so` — llama.cpp HTTP server listening on 127.0.0.1:11436
 *   - `libtealenode.so`   — teale-node, connects to the relay and serves its
 *                           local control API on 127.0.0.1:11437
 *
 * Binaries are executed from `applicationInfo.nativeLibraryDir` only: they
 * ship inside the APK as lib*.so (see scripts/deploy-pixel.sh). Android 10+
 * does not allow executing files from external storage or /data/local/tmp.
 *
 * Blocking: every public method may wait for processes to start or exit, so
 * call them from a background thread / Dispatchers.IO. One instance per app
 * process ([get]) so a stopping service and a starting one never race over
 * ports or the identity file.
 */
class SupplyProcessManager private constructor(private val context: Context) {

    /** Notified (on a watcher thread) when a supply process exits on its own. */
    fun interface Listener {
        fun onProcessExited(name: String, exitCode: Int)
    }

    data class StartConfig(
        val accelerationMode: SupplyAccelerationMode,
        val advertisedModelId: String = DEFAULT_MODEL_ID,
    )

    sealed interface StartResult {
        data class Running(
            val profile: SupplyRuntimeProfile,
            val fellBackToCpu: Boolean,
            /** True when processes were (re)launched by this call. */
            val launched: Boolean,
        ) : StartResult

        data class MissingArtifacts(val detail: String) : StartResult
        data class Failed(val detail: String) : StartResult
    }

    @Volatile
    var listener: Listener? = null

    private val workDir: File get() = File(context.filesDir, "supply")

    /** Bumped on every stop so watchers of old processes stay silent. */
    @Volatile
    private var generation = 0L

    @Volatile
    private var running = false
    private var llamaProcess: Process? = null
    private var nodeProcess: Process? = null
    private var activeProfile: SupplyRuntimeProfile? = null
    private var activeFellBack = false

    init {
        // A previous app process may have died before cleaning up.
        NodeConfigWriter.deleteIdentity(workDir)
    }

    @Synchronized
    fun ensureStarted(config: StartConfig): StartResult {
        val desiredProfile = desiredRuntimeProfile(
            mode = config.accelerationMode,
            deviceSupportsAcceleration = deviceSupportsAcceleration(context),
        )

        val active = activeProfile
        if (running && processesAliveLocked() && active != null &&
            (active == desiredProfile || activeFellBack)
        ) {
            Log.i(TAG, "already running with profile=$active")
            return StartResult.Running(
                profile = active,
                fellBackToCpu = activeFellBack,
                launched = false,
            )
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

        return try {
            launchProfile(desiredProfile, llamaBin, nodeBin, model, config, fellBack = false)
            StartResult.Running(profile = desiredProfile, fellBackToCpu = false, launched = true)
        } catch (error: Exception) {
            Log.w(TAG, "launch failed for profile=$desiredProfile: ${error.message}")
            stopInternal()
            if (desiredProfile == SupplyRuntimeProfile.AcceleratedBeta) {
                try {
                    launchProfile(
                        profile = SupplyRuntimeProfile.ConservativeCpu,
                        llamaBin = llamaBin,
                        nodeBin = nodeBin,
                        model = model,
                        config = config,
                        fellBack = true,
                    )
                    StartResult.Running(
                        profile = SupplyRuntimeProfile.ConservativeCpu,
                        fellBackToCpu = true,
                        launched = true,
                    )
                } catch (fallbackError: Exception) {
                    stopInternal()
                    StartResult.Failed(
                        "accelerated launch failed (${error.message}); " +
                            "cpu fallback failed (${fallbackError.message})"
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

    /** True while supply is up and both processes are alive. */
    @Synchronized
    fun processesAlive(): Boolean = running && processesAliveLocked()

    private fun processesAliveLocked(): Boolean =
        llamaProcess?.isAlive == true && nodeProcess?.isAlive == true

    private fun launchProfile(
        profile: SupplyRuntimeProfile,
        llamaBin: File,
        nodeBin: File,
        model: File,
        config: StartConfig,
        fellBack: Boolean,
    ) {
        val dir = workDir.apply { mkdirs() }
        val gen = generation

        awaitPortFree(LLAMA_PORT)
        awaitPortFree(NodeConfigWriter.CONTROL_PORT)

        val llamaBuilder = ProcessBuilder(
            llamaBin.absolutePath,
            "-m", model.absolutePath,
            "--host", "127.0.0.1",
            "--port", LLAMA_PORT.toString(),
            "-c", NodeConfigWriter.CONTEXT_SIZE.toString(),
            "-ngl", profile.gpuLayers.toString(),
            "-t", "4",
        ).directory(dir).redirectErrorStream(true)
        llamaBuilder.environment()["LD_LIBRARY_PATH"] =
            context.applicationInfo.nativeLibraryDir +
                ":" + (llamaBuilder.environment()["LD_LIBRARY_PATH"] ?: "")
        Log.i(TAG, "exec llama-server (${profile.name}): ${llamaBuilder.command().joinToString(" ")}")
        val llama = llamaBuilder.start()
        llamaProcess = llama
        pipeOutput("llama-server", llama)
        // llama-server answers 503 while the model loads and 200 once it can
        // serve. A Vulkan crash during load shows up here as an exit, which
        // sends the caller to the CPU fallback.
        awaitHttpOk(llama, "llama-server", "http://127.0.0.1:$LLAMA_PORT/health", LLAMA_READY_TIMEOUT_MS)

        val configFile = NodeConfigWriter.writeConfig(
            workDir = dir,
            relayUrl = BuildConfig.RELAY_URL,
            profile = profile,
            llamaPort = LLAMA_PORT,
            advertisedModelId = config.advertisedModelId,
            maxConcurrentRequests = 1,
        )
        NodeConfigWriter.writeIdentity(dir, TealeApplication.instance.container.identity.privateSeed())
        val nodeBuilder = ProcessBuilder(
            nodeBin.absolutePath,
            "--config", configFile.absolutePath,
            "--no-backend",
        ).directory(dir).redirectErrorStream(true)
        nodeBuilder.environment()["LD_LIBRARY_PATH"] =
            context.applicationInfo.nativeLibraryDir +
                ":" + (nodeBuilder.environment()["LD_LIBRARY_PATH"] ?: "")
        Log.i(TAG, "exec teale-node (${profile.name}): ${nodeBuilder.command().joinToString(" ")}")
        val node = nodeBuilder.start()
        nodeProcess = node
        pipeOutput("teale-node", node)
        try {
            // The node loads its identity before it opens the control port,
            // so once /status answers the plaintext seed is no longer needed.
            awaitHttpOk(
                node,
                "teale-node",
                "http://127.0.0.1:${NodeConfigWriter.CONTROL_PORT}/status",
                NODE_READY_TIMEOUT_MS,
            )
        } finally {
            NodeConfigWriter.deleteIdentity(dir)
        }

        activeProfile = profile
        activeFellBack = fellBack
        running = true
        watch("llama-server", llama, gen)
        watch("teale-node", node, gen)
        Log.i(TAG, "supply up with profile=$profile")
    }

    private fun awaitHttpOk(process: Process, name: String, url: String, timeoutMs: Long) {
        val deadline = SystemClock.elapsedRealtime() + timeoutMs
        while (true) {
            requireAlive(process, name)
            if (LocalHttp.get(url)?.first == 200) return
            if (SystemClock.elapsedRealtime() >= deadline) {
                throw IllegalStateException(
                    "$name did not become healthy at $url within ${timeoutMs / 1000}s"
                )
            }
            Thread.sleep(HEALTH_POLL_MS)
        }
    }

    /** Waits for a previous instance to release [port]; fails if something else keeps it. */
    private fun awaitPortFree(port: Int) {
        val deadline = SystemClock.elapsedRealtime() + PORT_FREE_TIMEOUT_MS
        while (isPortInUse(port)) {
            if (SystemClock.elapsedRealtime() >= deadline) {
                throw IllegalStateException("port $port is still in use by another process")
            }
            Thread.sleep(HEALTH_POLL_MS)
        }
    }

    private fun isPortInUse(port: Int): Boolean = try {
        Socket().use { it.connect(InetSocketAddress("127.0.0.1", port), 200) }
        true
    } catch (_: IOException) {
        false
    }

    private fun requireAlive(process: Process, name: String) {
        if (!process.isAlive) {
            val exitCode = runCatching { process.exitValue() }.getOrNull()
            throw IllegalStateException("$name exited during startup (exit=$exitCode)")
        }
    }

    private fun watch(name: String, process: Process, gen: Long) {
        val t = Thread({
            val exitCode = try {
                process.waitFor()
            } catch (_: InterruptedException) {
                return@Thread
            }
            if (gen == generation && running) {
                Log.w(TAG, "$name exited unexpectedly (exit=$exitCode)")
                listener?.onProcessExited(name, exitCode)
            }
        }, "supply-watch-$name")
        t.isDaemon = true
        t.start()
    }

    private fun stopInternal() {
        generation++
        val hadProcesses = running || llamaProcess != null || nodeProcess != null
        running = false
        NodeConfigWriter.deleteIdentity(workDir)
        // Stop the node first so it deregisters before its backend goes away.
        nodeProcess?.let { terminate("teale-node", it, NODE_STOP_TIMEOUT_MS) }
        llamaProcess?.let { terminate("llama-server", it, LLAMA_STOP_TIMEOUT_MS) }
        nodeProcess = null
        llamaProcess = null
        activeProfile = null
        activeFellBack = false
        if (hadProcesses) {
            Log.i(TAG, "supply down")
        }
    }

    /** SIGTERM, wait up to [graceMs], then SIGKILL and wait for the exit. */
    private fun terminate(name: String, process: Process, graceMs: Long) {
        if (!process.isAlive) return
        process.destroy()
        val exited = try {
            process.waitFor(graceMs, TimeUnit.MILLISECONDS)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            false
        }
        if (!exited) {
            Log.w(TAG, "$name ignored SIGTERM for ${graceMs}ms; killing")
            process.destroyForcibly()
            runCatching { process.waitFor(KILL_WAIT_MS, TimeUnit.MILLISECONDS) }
        }
    }

    private fun resolveBinariesAndModel(): Triple<File?, File?, File?> {
        val nativeDir = File(context.applicationInfo.nativeLibraryDir)
        val llama = File(nativeDir, "libllamaserver.so").takeIf { it.exists() }
        val node = File(nativeDir, "libtealenode.so").takeIf { it.exists() }

        // Model lookup order (the model is only read, never executed):
        //   1. /data/local/tmp/gemma.gguf — dev drop via `adb push`
        //   2. App's external-files dir (listFiles) — only works when the
        //      file was created by the app itself due to scoped storage
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

    private fun pipeOutput(tag: String, process: Process) {
        val t = Thread({
            try {
                process.inputStream.bufferedReader().use { reader ->
                    reader.lineSequence().forEach { line ->
                        Log.i(tag, line)
                    }
                }
            } catch (_: IOException) {
                // Process exited.
            }
        }, "supply-log-$tag")
        t.isDaemon = true
        t.start()
    }

    companion object {
        private const val TAG = "SupplyPM"
        private const val DEFAULT_MODEL_ID = "google/gemma-3-1b-it"

        const val LLAMA_PORT = 11436

        private const val HEALTH_POLL_MS = 500L
        private const val LLAMA_READY_TIMEOUT_MS = 120_000L
        private const val NODE_READY_TIMEOUT_MS = 30_000L
        private const val PORT_FREE_TIMEOUT_MS = 15_000L
        private const val NODE_STOP_TIMEOUT_MS =
            (NodeConfigWriter.SHUTDOWN_TIMEOUT_SECONDS + 3) * 1_000L
        private const val LLAMA_STOP_TIMEOUT_MS = 5_000L
        private const val KILL_WAIT_MS = 2_000L

        /** Vulkan 1.1 encoded as VK_MAKE_VERSION(1, 1, 0). */
        private const val VULKAN_1_1 = (1 shl 22) or (1 shl 12)

        @Volatile
        private var instance: SupplyProcessManager? = null

        fun get(context: Context): SupplyProcessManager =
            instance ?: synchronized(this) {
                instance ?: SupplyProcessManager(context.applicationContext).also { instance = it }
            }

        /**
         * llama.cpp's Vulkan backend needs Vulkan 1.1+. FEATURE_VULKAN_HARDWARE_LEVEL
         * alone is present on practically every API 29+ device, so it is not a
         * useful gate.
         */
        fun deviceSupportsAcceleration(context: Context): Boolean =
            context.packageManager.hasSystemFeature(
                PackageManager.FEATURE_VULKAN_HARDWARE_VERSION,
                VULKAN_1_1,
            )
    }
}
