package com.teale.android.data.auth

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.util.concurrent.TimeUnit

class UsernameClient(
    private val baseUrl: String,
    private val tokenClient: TokenExchangeClient,
) {
    private val http = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(15, TimeUnit.SECONDS)
        .build()
    private val json = Json { ignoreUnknownKeys = true }

    suspend fun setUsername(username: String): Boolean = withContext(Dispatchers.IO) {
        if (username.isBlank()) return@withContext false
        val token = tokenClient.bearer()
        val body = json.encodeToString(Req.serializer(), Req(username))
            .toRequestBody("application/json".toMediaType())
        val req = Request.Builder()
            .url("$baseUrl/v1/auth/device/username")
            .patch(body)
            .addHeader("Authorization", "Bearer $token")
            .build()
        http.newCall(req).execute().use { it.isSuccessful }
    }

    @Serializable
    private data class Req(val username: String)
}
