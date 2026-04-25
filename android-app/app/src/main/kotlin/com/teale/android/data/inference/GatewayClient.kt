package com.teale.android.data.inference

import com.teale.android.data.auth.TokenExchangeClient
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.flowOn
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerialName
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okhttp3.sse.EventSource
import okhttp3.sse.EventSourceListener
import okhttp3.sse.EventSources
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.withContext

/** One streaming event from the gateway. */
sealed class ChatEvent {
    data class Delta(val text: String) : ChatEvent()
    data class Usage(
        val promptTokens: Int?,
        val completionTokens: Int?,
    ) : ChatEvent()
    data object Final : ChatEvent()
    data class Error(val message: String) : ChatEvent()
}

@Serializable
data class ModelPricing(
    val prompt: String? = null,
    val completion: String? = null,
)

@Serializable
data class NetworkModel(
    val id: String,
    @SerialName("owned_by") val ownedBy: String? = null,
    val description: String? = null,
    val pricing: ModelPricing? = null,
    @SerialName("loaded_device_count") val loadedDeviceCount: Int? = null,
)

@Serializable
data class ModelsResponse(
    val data: List<NetworkModel> = emptyList(),
    @SerialName("connected_device_count") val connectedDeviceCount: Int? = null,
)

@Serializable
data class NetworkStatsSnapshot(
    @SerialName("totalDevices") val totalDevices: Int,
    @SerialName("totalRamGB") val totalRamGB: Double,
    @SerialName("totalModels") val totalModels: Int,
    @SerialName("avgTtftMs") val avgTtftMs: Int? = null,
    @SerialName("avgTps") val avgTps: Float? = null,
    @SerialName("totalCreditsEarned") val totalCreditsEarned: Long,
    @SerialName("totalCreditsSpent") val totalCreditsSpent: Long,
    @SerialName("totalUsdcDistributedCents") val totalUsdcDistributedCents: Long,
)

class GatewayClient(
    private val baseUrl: String,
    private val tokenClient: TokenExchangeClient,
) {
    private val http = OkHttpClient.Builder()
        .connectTimeout(20, TimeUnit.SECONDS)
        .readTimeout(10, TimeUnit.MINUTES)
        .build()
    private val json = Json { ignoreUnknownKeys = true }
    private val factory = EventSources.createFactory(http)

    /**
     * Stream a chat completion. Emits Delta for every token, Final at end,
     * Error on failure. Caller collects the Flow.
     */
    fun streamChat(
        model: String,
        messages: List<ChatMessage>,
        temperature: Double = 0.7,
    ): Flow<ChatEvent> = callbackFlow<ChatEvent> {
        val token = try {
            tokenClient.bearer()
        } catch (t: Throwable) {
            trySend(ChatEvent.Error("auth: ${t.message}"))
            close()
            return@callbackFlow
        }

        val body = buildRequestJson(model, messages, temperature)
        val request = Request.Builder()
            .url("$baseUrl/v1/chat/completions")
            .addHeader("Authorization", "Bearer $token")
            .addHeader("Accept", "text/event-stream")
            .post(body.toRequestBody("application/json".toMediaType()))
            .build()

        val listener = object : EventSourceListener() {
            override fun onEvent(
                eventSource: EventSource,
                id: String?,
                type: String?,
                data: String
            ) {
                if (data == "[DONE]") {
                    trySend(ChatEvent.Final)
                    close()
                    return
                }
                val root = runCatching { json.parseToJsonElement(data) }.getOrNull() ?: return
                val obj = runCatching { root.jsonObject }.getOrNull() ?: return
                parseUsage(obj)?.let { usage ->
                    trySend(ChatEvent.Usage(usage.promptTokens, usage.completionTokens))
                }
                val choice = (obj["choices"] as? JsonArray)?.firstOrNull() as? JsonObject ?: return
                val delta = choice["delta"] as? JsonObject ?: return
                val content = delta["content"]
                if (content != null) {
                    val t = runCatching { content.jsonPrimitive.content }
                        .getOrElse { content.toString().trim('"') }
                    if (t.isNotEmpty()) {
                        trySend(ChatEvent.Delta(t))
                    }
                }
            }

            override fun onFailure(
                eventSource: EventSource,
                t: Throwable?,
                response: Response?
            ) {
                val msg = t?.message ?: response?.message ?: "unknown"
                trySend(ChatEvent.Error("sse: $msg (${response?.code ?: -1})"))
                if (response?.code == 401) tokenClient.invalidate()
                close()
            }

            override fun onClosed(eventSource: EventSource) {
                close()
            }
        }

        val source = factory.newEventSource(request, listener)
        awaitClose { source.cancel() }
    }.flowOn(Dispatchers.IO)

    suspend fun listModels(): List<NetworkModel> = withContext(Dispatchers.IO) {
        val token = tokenClient.bearer()
        val req = Request.Builder()
            .url("$baseUrl/v1/models")
            .addHeader("Authorization", "Bearer $token")
            .addHeader("Accept", "application/json")
            .build()
        http.newCall(req).execute().use { response ->
            if (response.code == 401) {
                tokenClient.invalidate()
            }
            if (!response.isSuccessful) {
                return@withContext emptyList()
            }
            val body = response.body?.string().orEmpty()
            json.decodeFromString(ModelsResponse.serializer(), body).data
        }
    }

    suspend fun fetchNetworkStats(): NetworkStatsSnapshot? = withContext(Dispatchers.IO) {
        val token = tokenClient.bearer()
        val req = Request.Builder()
            .url("$baseUrl/v1/network/stats")
            .addHeader("Authorization", "Bearer $token")
            .build()
        http.newCall(req).execute().use { response ->
            if (response.code == 401) {
                tokenClient.invalidate()
            }
            if (!response.isSuccessful) {
                return@withContext null
            }
            val body = response.body?.string().orEmpty()
            json.decodeFromString(NetworkStatsSnapshot.serializer(), body)
        }
    }

    private fun buildRequestJson(
        model: String,
        messages: List<ChatMessage>,
        temperature: Double,
    ): String {
        val messagesArr = buildJsonArray {
            for (m in messages) {
                add(buildJsonObject {
                    put("role", m.role)
                    put("content", m.content)
                })
            }
        }
        return json.encodeToString(
            JsonObject.serializer(),
            buildJsonObject {
                put("model", model)
                put("stream", true)
                put("temperature", temperature)
                put("messages", messagesArr)
                put(
                    "stream_options",
                    buildJsonObject {
                        put("include_usage", true)
                    }
                )
            }
        )
    }

    private fun parseUsage(obj: JsonObject): ChatEvent.Usage? {
        val usage = obj["usage"] as? JsonObject ?: return null
        val promptTokens = usage["prompt_tokens"]?.jsonPrimitive?.contentOrNull?.toIntOrNull()
        val completionTokens =
            usage["completion_tokens"]?.jsonPrimitive?.contentOrNull?.toIntOrNull()
        if (promptTokens == null && completionTokens == null) {
            return null
        }
        return ChatEvent.Usage(promptTokens, completionTokens)
    }
}

@Serializable
data class ChatMessage(val role: String, val content: String)
