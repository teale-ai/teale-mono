package com.teale.android.data.auth

import com.teale.android.data.identity.WanIdentity
import com.teale.android.data.identity.toHexLower
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.util.Base64
import java.util.concurrent.TimeUnit

class TokenExchangeException(message: String) : Exception(message)

class TokenExchangeClient(
    private val baseUrl: String,
    private val identity: WanIdentity,
) {
    private val client = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .build()
    private val json = Json { ignoreUnknownKeys = true }
    private val mutex = Mutex()

    @Volatile private var cachedToken: String? = null
    @Volatile private var expiresAt: Long = 0

    /** Returns a valid bearer token, performing challenge→exchange as needed. */
    suspend fun bearer(): String = mutex.withLock {
        val now = System.currentTimeMillis() / 1000
        cachedToken?.let { if (expiresAt - now > 60) return@withLock it }
        exchange()
    }

    fun invalidate() {
        cachedToken = null
        expiresAt = 0
    }

    private suspend fun exchange(): String = withContext(Dispatchers.IO) {
        val deviceId = identity.deviceId()

        // 1) Challenge
        val challengeBody = json.encodeToString(
            ChallengeReq.serializer(),
            ChallengeReq(deviceId)
        ).toRequestBody("application/json".toMediaType())
        val cReq = Request.Builder()
            .url("$baseUrl/v1/auth/device/challenge")
            .post(challengeBody)
            .build()
        val cRes = client.newCall(cReq).execute()
        if (!cRes.isSuccessful) {
            val body = cRes.body?.string().orEmpty()
            throw TokenExchangeException("challenge ${cRes.code}: $body")
        }
        val challenge = json.decodeFromString(
            ChallengeRes.serializer(),
            cRes.body!!.string()
        )

        // 2) Sign nonce (base64 → bytes) then exchange
        val nonceBytes = Base64.getDecoder().decode(challenge.nonce)
        val signature = identity.sign(nonceBytes).toHexLower()
        val exchBody = json.encodeToString(
            ExchangeReq.serializer(),
            ExchangeReq(deviceId, challenge.nonce, signature)
        ).toRequestBody("application/json".toMediaType())
        val eReq = Request.Builder()
            .url("$baseUrl/v1/auth/device/exchange")
            .post(exchBody)
            .build()
        val eRes = client.newCall(eReq).execute()
        if (!eRes.isSuccessful) {
            val body = eRes.body?.string().orEmpty()
            throw TokenExchangeException("exchange ${eRes.code}: $body")
        }
        val exchange = json.decodeFromString(
            ExchangeRes.serializer(),
            eRes.body!!.string()
        )
        cachedToken = exchange.token
        expiresAt = exchange.expiresAt
        exchange.token
    }

    fun deviceId(): String = identity.deviceId()

    @Serializable
    data class ChallengeReq(val deviceID: String)
    @Serializable
    data class ChallengeRes(val nonce: String, val expiresAt: Long)
    @Serializable
    data class ExchangeReq(val deviceID: String, val nonce: String, val signature: String)
    @Serializable
    data class ExchangeRes(val token: String, val expiresAt: Long, val welcomeBonus: Long? = null)
}
