package com.teale.android.service

import android.content.Context
import android.util.Log
import java.io.File
import java.io.IOException
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Supervises the two native subprocesses that make this phone a supply node:
 *   - `libllamaserver.so` — llama.cpp HTTP server listening on 127.0.0.1:8080
 *   - `libtealenode.so`   — teale-node, connects to wss://relay.teale.com/ws
 *
 * Binaries are picked up from `applicationInfo.nativeLibraryDir` (APK-bundled)
 * with a fallback to `/sdcard/Android/data/com.teale.android/files/` so they
 * can be pushed via adb during dev without rebuilding the APK every time.
 */
class SupplyProcessManager(private val context: Context) {

    private val running = AtomicBoolean(false)
    private var llamaProcess: Process? = null
    private var nodeProcess: Process? = null
    private var nodeOutThread: Thread? = null
    private var llamaOutThread: Thread? = null

    fun start() {
        if (!running.compareAndSet(false, true)) {
            Log.i(TAG, "already running")
            return
        }
        try {
            val (llamaBin, nodeBin, model) = resolveBinariesAndModel()
            if (llamaBin == null || nodeBin == null) {
                Log.w(TAG, "missing binary — push via adb: llama=$llamaBin node=$nodeBin")
                running.set(false)
                return
            }
            val workDir = File(context.filesDir, "supply").apply { mkdirs() }

            if (model == null) {
                Log.w(TAG, "no model GGUF found; node will register without a loaded model")
            }

            val llamaPort = 11436

            // 1) Start llama-server (only if we have a model to serve)
            if (model != null) {
                val pb = ProcessBuilder(
                    llamaBin.absolutePath,
                    "-m", model.absolutePath,
                    "--host", "127.0.0.1",
                    "--port", llamaPort.toString(),
                    "-c", "4096",
                    "-ngl", "0",
                    "-t", "4",
                ).directory(workDir).redirectErrorStream(true)
                // Ensure the dynamic linker can find libllama.so, libggml*.so
                // bundled alongside the binary in the APK's native-lib dir.
                pb.environment()["LD_LIBRARY_PATH"] =
                    context.applicationInfo.nativeLibraryDir +
                        ":" + (pb.environment()["LD_LIBRARY_PATH"] ?: "")
                Log.i(TAG, "exec llama-server: ${pb.command().joinToString(" ")}")
                llamaProcess = pb.start()
                llamaOutThread = pipeOutput("llama-server", llamaProcess!!)
                Thread.sleep(2000) // give it a beat to open the socket
            }

            // 2) Render teale-node config, then start node
            val configFile = NodeConfigWriter.writeConfig(
                context,
                workDir,
                hasLlamaServer = (model != null),
                llamaPort = llamaPort,
            )
            val nodeCmd = mutableListOf(
                nodeBin.absolutePath,
                "--config", configFile.absolutePath,
            )
            // We manage llama-server ourselves above — tell teale-node to
            // connect to the existing backend instead of spawning its own.
            if (model != null) nodeCmd += "--no-backend"
            val pb2 = ProcessBuilder(nodeCmd)
                .directory(workDir)
                .redirectErrorStream(true)
            pb2.environment()["LD_LIBRARY_PATH"] =
                context.applicationInfo.nativeLibraryDir +
                    ":" + (pb2.environment()["LD_LIBRARY_PATH"] ?: "")
            Log.i(TAG, "exec teale-node: ${pb2.command().joinToString(" ")}")
            nodeProcess = pb2.start()
            nodeOutThread = pipeOutput("teale-node", nodeProcess!!)

            Log.i(TAG, "SupplyService up")
        } catch (t: Throwable) {
            Log.e(TAG, "start failed", t)
            stop()
        }
    }

    fun stop() {
        if (!running.compareAndSet(true, false)) return
        runCatching { nodeProcess?.destroy() }
        runCatching { llamaProcess?.destroy() }
        Log.i(TAG, "SupplyService down")
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
            } catch (_: IOException) { /* process exited */ }
        }
        t.isDaemon = true
        t.start()
        return t
    }

    companion object {
        private const val TAG = "SupplyPM"
    }
}
