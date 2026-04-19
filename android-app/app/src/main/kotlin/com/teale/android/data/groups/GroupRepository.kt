package com.teale.android.data.groups

import com.teale.android.data.auth.TokenExchangeClient
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.util.concurrent.TimeUnit

@Serializable
data class GroupSummary(
    val groupID: String,
    val title: String,
    val createdBy: String,
    val createdAt: Long,
    val memberCount: Long,
)

@Serializable
data class GroupMessage(
    val id: String,
    val groupID: String,
    val senderDeviceID: String,
    val type: String,
    val content: String,
    val refMessageID: String? = null,
    val timestamp: Long,
)

@Serializable
data class MessagesRes(val messages: List<GroupMessage>)

@Serializable
data class GroupsListRes(val groups: List<GroupSummary>)

@Serializable
private data class CreateGroupReq(
    val title: String,
    val memberDeviceIDs: List<String> = emptyList(),
)

@Serializable
private data class PostMessageReq(
    val type: String = "text",
    val content: String,
    val refMessageID: String? = null,
)

@Serializable
data class MemoryEntry(
    val id: String,
    val groupID: String,
    val category: String? = null,
    val text: String,
    val sourceMessageID: String? = null,
    val createdAt: Long,
)

@Serializable
private data class RememberReq(
    val category: String? = null,
    val text: String,
    val sourceMessageID: String? = null,
)

@Serializable
data class RecallRes(val entries: List<MemoryEntry>)

class GroupRepository(
    private val baseUrl: String,
    private val tokenClient: TokenExchangeClient,
) {
    private val http = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .build()
    private val json = Json { ignoreUnknownKeys = true }

    suspend fun listMine(): List<GroupSummary> = withContext(Dispatchers.IO) {
        val req = authed("/v1/groups/mine").build()
        http.newCall(req).execute().use { r ->
            if (!r.isSuccessful) return@use emptyList()
            json.decodeFromString(
                GroupsListRes.serializer(), r.body?.string().orEmpty()
            ).groups
        }
    }

    suspend fun create(title: String, members: List<String> = emptyList()): GroupSummary? =
        withContext(Dispatchers.IO) {
            val body = json.encodeToString(
                CreateGroupReq.serializer(),
                CreateGroupReq(title, members)
            ).toRequestBody("application/json".toMediaType())
            val req = authed("/v1/groups").post(body).build()
            http.newCall(req).execute().use { r ->
                if (!r.isSuccessful) return@withContext null
                json.decodeFromString(GroupSummary.serializer(), r.body?.string().orEmpty())
            }
        }

    suspend fun postMessage(groupId: String, content: String, type: String = "text"): GroupMessage? =
        withContext(Dispatchers.IO) {
            val body = json.encodeToString(
                PostMessageReq.serializer(),
                PostMessageReq(type, content)
            ).toRequestBody("application/json".toMediaType())
            val req = authed("/v1/groups/$groupId/messages").post(body).build()
            http.newCall(req).execute().use { r ->
                if (!r.isSuccessful) return@withContext null
                json.decodeFromString(GroupMessage.serializer(), r.body?.string().orEmpty())
            }
        }

    suspend fun listMessages(groupId: String, since: Long = 0): List<GroupMessage> =
        withContext(Dispatchers.IO) {
            val req = authed("/v1/groups/$groupId/messages?since=$since&limit=200").build()
            http.newCall(req).execute().use { r ->
                if (!r.isSuccessful) return@use emptyList()
                json.decodeFromString(
                    MessagesRes.serializer(), r.body?.string().orEmpty()
                ).messages
            }
        }

    suspend fun remember(groupId: String, text: String, category: String? = null): MemoryEntry? =
        withContext(Dispatchers.IO) {
            val body = json.encodeToString(
                RememberReq.serializer(),
                RememberReq(category, text)
            ).toRequestBody("application/json".toMediaType())
            val req = authed("/v1/groups/$groupId/memory").post(body).build()
            http.newCall(req).execute().use { r ->
                if (!r.isSuccessful) return@withContext null
                json.decodeFromString(MemoryEntry.serializer(), r.body?.string().orEmpty())
            }
        }

    suspend fun recall(groupId: String): List<MemoryEntry> = withContext(Dispatchers.IO) {
        val req = authed("/v1/groups/$groupId/memory").build()
        http.newCall(req).execute().use { r ->
            if (!r.isSuccessful) return@use emptyList()
            json.decodeFromString(
                RecallRes.serializer(), r.body?.string().orEmpty()
            ).entries
        }
    }

    private suspend fun authed(path: String): Request.Builder {
        val token = tokenClient.bearer()
        return Request.Builder()
            .url("$baseUrl$path")
            .addHeader("Authorization", "Bearer $token")
    }
}
