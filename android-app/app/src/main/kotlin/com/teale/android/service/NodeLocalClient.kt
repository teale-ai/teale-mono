package com.teale.android.service

import android.util.Log
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.util.concurrent.TimeUnit

/**
 * Blocking loopback HTTP helpers for the two on-device supply processes.
 * Call from a background thread / Dispatchers.IO only.
 *
 * Cleartext is allowed for 127.0.0.1/localhost only, via
 * res/xml/network_security_config.xml.
 */
internal object LocalHttp {
    private const val TAG = "LocalHttp"

    private val client: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(1, TimeUnit.SECONDS)
        .readTimeout(3, TimeUnit.SECONDS)
        .callTimeout(5, TimeUnit.SECONDS)
        .retryOnConnectionFailure(false)
        .build()

    /** HTTP status code and body, or null when nothing answered. */
    fun get(url: String): Pair<Int, String>? = execute(Request.Builder().url(url).get().build())

    fun post(url: String): Pair<Int, String>? =
        execute(Request.Builder().url(url).post(ByteArray(0).toRequestBody()).build())

    private fun execute(request: Request): Pair<Int, String>? = try {
        client.newCall(request).execute().use { response ->
            response.code to (response.body?.string().orEmpty())
        }
    } catch (e: Exception) {
        Log.v(TAG, "${request.method} ${request.url}: ${e.message}")
        null
    }
}

/** Snapshot of teale-node's `GET /status` (LegacyStatusDTO in node/src/status_server.rs). */
@Serializable
data class NodeStatus(
    /** "supplying", "paused" or "error". */
    val state: String = "unknown",
    @SerialName("paused_reason") val pausedReason: String? = null,
    @SerialName("requests_today") val requestsToday: Long = 0,
    @SerialName("credits_today") val creditsToday: Long = 0,
    @SerialName("on_ac") val onAc: Boolean = false,
    @SerialName("throttle_level") val throttleLevel: Int = 100,
) {
    val isSupplying: Boolean get() = state == "supplying"
}

/** Client for teale-node's local control API on 127.0.0.1:[port]. */
class NodeLocalClient(private val port: Int = NodeConfigWriter.CONTROL_PORT) {

    private val json = Json { ignoreUnknownKeys = true }

    private fun url(path: String) = "http://127.0.0.1:$port$path"

    /** True when the node answers `/status` with 200. */
    fun isUp(): Boolean = LocalHttp.get(url("/status"))?.first == 200

    fun status(): NodeStatus? {
        val (code, body) = LocalHttp.get(url("/status")) ?: return null
        if (code != 200) return null
        return runCatching { json.decodeFromString(NodeStatus.serializer(), body) }
            .onFailure { Log.w(TAG, "unparseable /status: ${it.message}") }
            .getOrNull()
    }

    fun pause(): Boolean = LocalHttp.post(url("/pause"))?.first == 200

    fun resume(): Boolean = LocalHttp.post(url("/resume"))?.first == 200

    private companion object {
        const val TAG = "NodeLocalClient"
    }
}
