package com.teale.android.data.inference

import com.teale.android.data.auth.TokenExchangeClient
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.flowOn
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
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

/** One streaming event from the gateway. */
sealed class ChatEvent {
    data class Delta(val text: String) : ChatEvent()
    data class Final(val tokensOut: Int) : ChatEvent()
    data class Error(val message: String) : ChatEvent()
}

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

        var tokensOut = 0
        val listener = object : EventSourceListener() {
            override fun onEvent(
                eventSource: EventSource,
                id: String?,
                type: String?,
                data: String
            ) {
                if (data == "[DONE]") {
                    trySend(ChatEvent.Final(tokensOut))
                    close()
                    return
                }
                val root = runCatching { json.parseToJsonElement(data) }.getOrNull() ?: return
                val obj = runCatching { root.jsonObject }.getOrNull() ?: return
                val choice = (obj["choices"] as? JsonArray)?.firstOrNull() as? JsonObject ?: return
                val delta = choice["delta"] as? JsonObject ?: return
                val content = delta["content"]
                if (content != null) {
                    val t = runCatching { content.jsonPrimitive.content }
                        .getOrElse { content.toString().trim('"') }
                    if (t.isNotEmpty()) {
                        tokensOut++
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
            }
        )
    }
}

@Serializable
data class ChatMessage(val role: String, val content: String)
